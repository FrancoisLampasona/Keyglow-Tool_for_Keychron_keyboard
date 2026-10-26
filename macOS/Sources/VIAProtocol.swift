import Foundation

struct VIADevice: Identifiable, Codable, Equatable, Sendable {
    let id: UInt64
    let name: String
    let transport: String
    let productID: Int
}

struct VIALighting: Codable, Equatable, Sendable {
    var brightness: UInt8
    var effect: UInt8
    var speed: UInt8
    var hue: UInt8
    var saturation: UInt8
}
struct VIAHSV: Codable, Equatable, Sendable {
    var hue: UInt8
    var saturation: UInt8
    var value: UInt8
}
struct VIAMixedEffect: Codable, Equatable, Sendable {
    var effect: UInt8
    var hue: UInt8
    var saturation: UInt8
    var speed: UInt8
    var durationMilliseconds: UInt32
}
struct VIACustomRGB: Codable, Equatable, Sendable {
    var type: UInt8
    var colors: [VIAHSV]
    var ledIndices: [[UInt8]]
    var regions: [UInt8]
    var effects: [[VIAMixedEffect]]
    var supportedIndicatorsMask: UInt8
    var indicatorsDisabledMask: UInt8
    var indicatorColor: VIAHSV
}
struct VIAWirelessSettings: Codable, Equatable, Sendable {
    var backlightTimeoutSeconds: UInt16
    var sleepTimeoutSeconds: UInt16
}
struct VIASnapshot: Codable, Equatable, Sendable {
    var layers: [[UInt16]]
    /// One encoder per layer: [counter-clockwise, clockwise]. Push is matrix 0,13.
    var encoders: [[UInt16]]
    var macroBuffer: [UInt8]
    var macroCount: Int
    var macroCapacity: Int
    var lighting: VIALighting
    var firmwareVersion: String
    var protocolVersion: UInt16
    var productID: Int
    var rows: Int = 6
    var cols: Int = 20
    var featureFlags: UInt16 = 0
    var miscCapabilities: UInt8 = 0
    var customRGB: VIACustomRGB? = nil
    var wireless: VIAWirelessSettings? = nil
    var nkro: Bool? = nil
    var nkroCanSet: Bool = false
    var warnings: [String] = []
}

/// Synchronous, confined to the thread that owns the USB session.
protocol VIAExchange: AnyObject {
    func exchange(_ request: [UInt8]) throws -> [UInt8]
}

enum VIAError: LocalizedError, Equatable, Sendable {
    case invalid(String)
    case missingDevice
    case incompatibleDevice
    case onMainThread
    case io(String, Int32)
    case timeout(UInt8)
    case unsupported(UInt8)
    case failedCommand(UInt8, UInt8)
    case malformedResponse
    case conflict
    case readback(String)
    case partialWrite(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let reason): return reason
        case .missingDevice: return "Q6 Max USB non rilevata. Collega il cavo, seleziona Cable e riprova."
        case .incompatibleDevice: return "Dispositivo USB o interfaccia Raw HID non compatibile con la Q6 Max."
        case .onMainThread: return "La sessione USB deve essere eseguita fuori dal thread dell’interfaccia."
        case .io(let operation, let code): return "\(operation) USB non riuscita (\(String(format: "0x%08X", UInt32(bitPattern: code)))). Chiudi gli altri configuratori e verifica l’accesso di macOS."
        case .timeout(let command): return "La tastiera non ha risposto al comando \(String(format: "%02X", command)). Ricollega la tastiera e rileggi prima di riprovare."
        case .unsupported(let command): return "Il firmware non supporta il comando \(String(format: "%02X", command))."
        case .failedCommand(let command, let subcommand): return "Il firmware ha rifiutato il comando \(String(format: "%02X/%02X", command, subcommand))."
        case .malformedResponse: return "Risposta USB incompleta o non corrispondente alla richiesta."
        case .conflict: return "Le impostazioni della tastiera sono cambiate dopo la lettura. Rileggi prima di applicare la bozza. Nessuna modifica inviata."
        case .readback(let section): return "La rilettura di \(section) non corrisponde alle modifiche richieste. Rileggi la tastiera prima di riprovare."
        case .partialWrite(let reason): return "Applicazione interrotta: alcune modifiche potrebbero essere già memorizzate. Rileggi la tastiera. \(reason)"
        }
    }
}

enum VIAProtocol {
    static let reportLength = 32
    static let chunkLength = 28
    static let supportedVersion: UInt16 = 12

    static func packet(_ bytes: [UInt8]) throws -> [UInt8] {
        guard !bytes.isEmpty, bytes.count <= reportLength else { throw VIAError.invalid("Pacchetto VIA non valido.") }
        return bytes + Array(repeating: 0, count: reportLength - bytes.count)
    }
    static func big16(_ value: Int) throws -> [UInt8] {
        guard (0...65535).contains(value) else { throw VIAError.invalid("Offset fuori intervallo.") }
        return [UInt8(value >> 8), UInt8(value & 255)]
    }
    static func uint16(_ bytes: [UInt8], _ index: Int) -> UInt16 { (UInt16(bytes[index]) << 8) | UInt16(bytes[index + 1]) }
    static func little16(_ bytes: [UInt8], _ index: Int) -> UInt16 { UInt16(bytes[index]) | (UInt16(bytes[index + 1]) << 8) }
    static func little32(_ bytes: [UInt8], _ index: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | (UInt32(bytes[index + $1]) << (8 * $1)) }
    }
    static func littleBytes(_ value: UInt32) -> [UInt8] { (0..<4).map { UInt8((value >> (8 * $0)) & 255) } }
    static func chunkRequest(command: UInt8, offset: Int, count: Int, bytes: [UInt8] = []) throws -> [UInt8] {
        guard (1...chunkLength).contains(count), bytes.isEmpty || bytes.count == count else { throw VIAError.invalid("Dimensione blocco VIA non valida.") }
        return try packet([command] + big16(offset) + [UInt8(count)] + bytes)
    }
    /// Fields overwritten by the firmware are excluded from response correlation.
    static func responseMatches(_ response: [UInt8], request: [UInt8]) -> Bool {
        guard response.count == reportLength, request.count == reportLength else { return false }
        if response[0] == 0xFF { return true }
        guard response[0] == request[0] else { return false }
        let echoed: Int
        switch request[0] {
        case 0x04, 0x05, 0x0E, 0x0F, 0x12, 0x13, 0x14, 0x15: echoed = 4
        case 0x07, 0x08: echoed = 3
        case 0x02, 0x03, 0x09, 0xA7, 0xA8: echoed = 2
        default: echoed = 1
        }
        return response.prefix(echoed) == request.prefix(echoed)
    }
    static func checkResponse(_ response: [UInt8], request: [UInt8]) throws {
        guard response.count == reportLength else { throw VIAError.malformedResponse }
        if response[0] == 0xFF { throw VIAError.unsupported(request[0]) }
        guard responseMatches(response, request: request) else { throw VIAError.malformedResponse }
        if request[0] == 0xA7 || request[0] == 0xA8 {
            guard response[2] == 0 else { throw VIAError.failedCommand(request[0], request[1]) }
        }
    }
}

enum VIAMacroAction: Codable, Equatable, Sendable {
    case text(String)
    case tap(UInt8)
    case down(UInt8)
    case up(UInt8)
    case delay(UInt16)
}

enum VIAMacroCodec {
    /// QMK/VIA protocol 12 uses the send_string prefix. Text is ASCII, not UTF-8.
    static func encode(_ macros: [[VIAMacroAction]], count: Int, capacity: Int) throws -> [UInt8] {
        guard (1...64).contains(count), (count + 1...65535).contains(capacity), macros.count <= count else { throw VIAError.invalid("Numero o spazio macro non valido.") }
        var buffer = [UInt8]()
        for index in 0..<count {
            for action in index < macros.count ? macros[index] : [] {
                switch action {
                case .text(let text):
                    let bytes = Array(text.utf8)
                    guard bytes.allSatisfy({ $0 >= 2 && $0 < 128 }) else { throw VIAError.invalid("Le macro QMK accettano testo ASCII. Per caratteri italiani accentati usa sequenze di tasti compatibili con il layout del sistema.") }
                    buffer += bytes
                case .tap(let key), .down(let key), .up(let key):
                    guard key != 0 else { throw VIAError.invalid("Una macro non può contenere il tasto nullo.") }
                    let operation: UInt8
                    switch action { case .tap: operation = 1; case .down: operation = 2; default: operation = 3 }
                    buffer += [1, operation, key]
                case .delay(let milliseconds): buffer += [1, 4] + Array(String(milliseconds).utf8) + [0x7C]
                }
            }
            buffer.append(0)
        }
        guard buffer.count < capacity else { throw VIAError.invalid("Le macro superano lo spazio disponibile sulla tastiera.") }
        return buffer + Array(repeating: 0, count: capacity - buffer.count)
    }
    static func decode(_ buffer: [UInt8], count: Int) throws -> [[VIAMacroAction]] {
        guard (0...64).contains(count), !buffer.isEmpty, buffer.last == 0 else { throw VIAError.invalid("Buffer macro incompleto o segnato come scrittura in corso.") }
        var cursor = 0
        var macros = [[VIAMacroAction]]()
        for _ in 0..<count {
            var actions = [VIAMacroAction](), text = [UInt8]()
            func flush() { if !text.isEmpty { actions.append(.text(String(decoding: text, as: UTF8.self))); text = [] } }
            var terminated = false
            while cursor < buffer.count {
                let b = buffer[cursor]; cursor += 1
                if b == 0 { flush(); terminated = true; break }
                if b != 1 {
                    guard b < 128 else { throw VIAError.invalid("La macro contiene byte di testo non ASCII, conservati senza conversione.") }
                    text.append(b); continue
                }
                flush()
                guard cursor < buffer.count else { throw VIAError.invalid("Macro troncata.") }
                let operation = buffer[cursor]; cursor += 1
                if (1...3).contains(operation) {
                    guard cursor < buffer.count, buffer[cursor] != 0 else { throw VIAError.invalid("Comando macro troncato.") }
                    let key = buffer[cursor]; cursor += 1
                    actions.append(operation == 1 ? .tap(key) : operation == 2 ? .down(key) : .up(key))
                } else if operation == 4 {
                    var digits = [UInt8]()
                    while cursor < buffer.count && (48...57).contains(buffer[cursor]) { digits.append(buffer[cursor]); cursor += 1 }
                    guard !digits.isEmpty, cursor < buffer.count, let delay = UInt16(String(decoding: digits, as: UTF8.self)) else { throw VIAError.invalid("Ritardo macro non valido.") }
                    // send_string consumes the first non-digit; normally VIA uses '|'.
                    let delimiter = buffer[cursor]; cursor += 1
                    guard delimiter == 0x7C || delimiter == 0 else { throw VIAError.invalid("Terminatore del ritardo macro non riconosciuto; buffer conservato.") }
                    actions.append(.delay(delay))
                    if delimiter == 0 { terminated = true; break }
                } else { throw VIAError.invalid("Comando macro non supportato; il buffer originale è conservato.") }
            }
            guard terminated else { throw VIAError.invalid("Manca il terminatore della macro.") }
            macros.append(actions)
        }
        return macros
    }
}
