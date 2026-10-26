import Foundation
import CoreFoundation
import CryptoKit

/// Keychron Launcher's keymap JSON format, verified against its 2026-10-26 bundle.
/// This format contains keycodes and encoder directions, not macros or lighting.
enum LauncherBackup {
    // Module 62856: vendorProductId(vendor, product) = 65536 * vendor + product.
    static let deviceID = 875_825_249 // 0x3434:0x0861, Q6 Max ISO Encoder
    static let version = "1.0.0"

    enum Failure: LocalizedError {
        case invalidFile, wrongDevice, unsupportedVersion, checksum, invalidLayout, invalidEncoder
        var errorDescription: String? {
            switch self {
            case .invalidFile: "Il file non è una mappa tasti valida di Keychron Launcher."
            case .wrongDevice: "La mappa appartiene a un’altra tastiera: serve Q6 Max ISO (3434:0861)."
            case .unsupportedVersion: "Questa versione del formato Launcher non è supportata."
            case .checksum: "Il controllo d’integrità della mappa Launcher non corrisponde."
            case .invalidLayout: "La mappa deve contenere 4 livelli e tutti i tasti della Q6 Max ISO."
            case .invalidEncoder: "La manopola deve contenere due direzioni per ciascuno dei 4 livelli."
            }
        }
    }

    static func encode(layers: [[UInt16]], encoders: [[UInt16]]) throws -> Data {
        guard layers.count == 4, layers.allSatisfy({ $0.count == 120 }) else { throw Failure.invalidLayout }
        guard encoders.count == 4, encoders.allSatisfy({ $0.count == 2 }) else { throw Failure.invalidEncoder }
        // Construct the numeric-only payload explicitly: this preserves the exact property
        // order used by JSON.stringify instead of depending on Swift dictionary iteration.
        let keymap = "[" + layers.map { layer in
            "[" + layer.enumerated().map { index, code in
                "{\"col\":\(index % 20),\"row\":\(index / 20),\"val\":\(code)}"
            }.joined(separator: ",") + "]"
        }.joined(separator: ",") + "]"
        let knob = "[" + encoders.map { "{\"left\":\($0[0]),\"right\":\($0[1])}" }.joined(separator: ",") + "]"
        return Data("{\"id\":\(deviceID),\"keymap\":\(keymap),\"version\":\"\(version)\",\"MD5\":\"\(digest(keymap))\",\"knob\":\(knob)}".utf8)
    }

    static func decode(_ data: Data) throws -> (layers: [[UInt16]], encoders: [[UInt16]]?) {
        guard data.count <= 2_000_000,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let identifier = integer(root["id"], maximum: Int(UInt32.max)) else { throw Failure.invalidFile }
        guard identifier == deviceID else { throw Failure.wrongDevice }
        if let fileVersion = root["version"] { guard fileVersion as? String == version else { throw Failure.unsupportedVersion } }
        guard let checksum = root["MD5"] as? String, checksum.utf8.count == 32 else { throw Failure.invalidFile }

        // JSON.parse -> JSON.stringify removes whitespace, normalizes numbers/escaped
        // property names, and retains string-property insertion order. Read that order
        // from the original source; .sortedKeys would reject valid reordered files.
        var outer = Scanner(bytes: Array(data))
        let span = try outer.keymapSpan()
        var scanner = Scanner(bytes: Array(data[span]))
        let result = try parseKeymap(&scanner)
        guard digest(result.canonical) == checksum else { throw Failure.checksum }

        var encoders: [[UInt16]]?
        if let rawKnob = root["knob"] {
            guard let values = rawKnob as? [[String: Any]], values.count == 4 else { throw Failure.invalidEncoder }
            encoders = try values.map { value in
                guard Set(value.keys) == Set(["left", "right"]),
                      let left = integer(value["left"], maximum: 65_535),
                      let right = integer(value["right"], maximum: 65_535) else { throw Failure.invalidEncoder }
                return [UInt16(left), UInt16(right)]
            }
        }
        return (result.layers, encoders)
    }

    private static func digest(_ text: String) -> String {
        Insecure.MD5.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func integer(_ value: Any?, maximum: Int) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let value = number.doubleValue
        guard value.isFinite, value >= 0, value <= Double(maximum), value.rounded(.towardZero) == value else { return nil }
        return Int(value)
    }

    private static func parseKeymap(_ scanner: inout Scanner) throws -> (layers: [[UInt16]], canonical: String) {
        let required = Set(KeyboardDefinition.q6ISO.keys.map(\.matrixIndex))
        var layers = [[UInt16]](), serializedLayers = [String]()
        try scanner.expect(91)
        while !scanner.consume(93) {
            guard layers.count < 4 else { throw Failure.invalidLayout }
            try scanner.expect(91)
            var layer = [UInt16](repeating: 0, count: 120), seen = Set<Int>(), objects = [String]()
            while !scanner.consume(93) {
                guard objects.count < 126 else { throw Failure.invalidLayout }
                try scanner.expect(123)
                var values = [String: Int](), properties = [String]()
                while !scanner.consume(125) {
                    let key = try scanner.string()
                    guard ["col", "row", "val"].contains(key), values[key] == nil else { throw Failure.invalidLayout }
                    try scanner.expect(58)
                    let value = try scanner.unsignedInteger()
                    values[key] = value
                    properties.append("\"\(key)\":\(value)")
                    if scanner.consume(125) { break }
                    try scanner.expect(44)
                }
                guard let row = values["row"], let col = values["col"], let code = values["val"],
                      col < 20, row < 7, code <= 65_535 else { throw Failure.invalidLayout }
                let index = row * 20 + col
                guard seen.insert(index).inserted else { throw Failure.invalidLayout }
                if row < 6 { layer[index] = UInt16(code) }
                else {
                    // The current Launcher slices all 28 response bytes in the final
                    // 8-key chunk. Accept its six zero padding entries, never write them.
                    guard col < 6, code == 0 else { throw Failure.invalidLayout }
                }
                objects.append("{" + properties.joined(separator: ",") + "}")
                if scanner.consume(93) { break }
                try scanner.expect(44)
            }
            guard required.isSubset(of: seen) else { throw Failure.invalidLayout }
            layers.append(layer)
            serializedLayers.append("[" + objects.joined(separator: ",") + "]")
            if scanner.consume(93) { break }
            try scanner.expect(44)
        }
        scanner.whitespace()
        guard layers.count == 4, scanner.position == scanner.bytes.count else { throw Failure.invalidLayout }
        return (layers, "[" + serializedLayers.joined(separator: ",") + "]")
    }

    /// Small scanner for an already JSONSerialization-validated document. Only the
    /// numeric keymap subtree needs ordered decoding; other fields use Foundation.
    private struct Scanner {
        let bytes: [UInt8]
        var position = 0

        mutating func whitespace() {
            while position < bytes.count, [9, 10, 13, 32].contains(bytes[position]) { position += 1 }
        }
        mutating func consume(_ byte: UInt8) -> Bool {
            whitespace()
            guard position < bytes.count, bytes[position] == byte else { return false }
            position += 1
            return true
        }
        mutating func expect(_ byte: UInt8) throws {
            guard consume(byte) else { throw Failure.invalidFile }
        }
        mutating func string() throws -> String {
            whitespace()
            let start = position
            try expect(34)
            while position < bytes.count {
                let byte = bytes[position]
                position += 1
                if byte == 92 { position += 1 }
                else if byte == 34 {
                    guard let result = try? JSONSerialization.jsonObject(with: Data(bytes[start..<position]), options: .fragmentsAllowed) as? String else { throw Failure.invalidFile }
                    return result
                }
            }
            throw Failure.invalidFile
        }
        mutating func unsignedInteger() throws -> Int {
            whitespace()
            let start = position
            while position < bytes.count, [43, 45, 46, 48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 69, 101].contains(bytes[position]) { position += 1 }
            guard position > start, let number = Double(String(decoding: bytes[start..<position], as: UTF8.self)),
                  number.isFinite, number >= 0, number <= 65_535, number.rounded(.towardZero) == number else { throw Failure.invalidLayout }
            return Int(number)
        }
        mutating func skipValue(depth: Int = 0) throws {
            guard depth < 16 else { throw Failure.invalidFile }
            whitespace()
            guard position < bytes.count else { throw Failure.invalidFile }
            if bytes[position] == 34 { _ = try string(); return }
            if bytes[position] == 123 || bytes[position] == 91 {
                let close: UInt8 = bytes[position] == 123 ? 125 : 93
                position += 1
                while !consume(close) {
                    try skipValue(depth: depth + 1)
                    whitespace()
                    if position < bytes.count, bytes[position] == 44 || bytes[position] == 58 { position += 1 }
                }
                return
            }
            let start = position
            while position < bytes.count, ![9, 10, 13, 32, 44, 58, 93, 125].contains(bytes[position]) { position += 1 }
            guard position > start else { throw Failure.invalidFile }
        }
        mutating func keymapSpan() throws -> Range<Int> {
            try expect(123)
            var keys = Set<String>(), span: Range<Int>?
            while !consume(125) {
                let key = try string()
                guard keys.insert(key).inserted else { throw Failure.invalidFile }
                try expect(58)
                whitespace()
                let start = position
                try skipValue()
                if key == "keymap" { span = start..<position }
                if consume(125) { break }
                try expect(44)
            }
            whitespace()
            guard position == bytes.count, let span else { throw Failure.invalidFile }
            return span
        }
    }
}
