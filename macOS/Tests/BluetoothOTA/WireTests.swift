import Foundation

@main @MainActor
struct WireTests {
    static var checks = 0
    static func check(_ value: @autoclosure () throws -> Bool, _ note: String = "", line: Int = #line) rethrows {
        checks += 1
        if try !value() { fatalError("Wire test line \(line): \(note)") }
    }
    static func rejects(_ expected: BluetoothOTAWire.Failure? = nil, _ body: () throws -> Void, line: Int = #line) {
        checks += 1
        do { try body(); fatalError("Expected rejection at \(line)") }
        catch let error as BluetoothOTAWire.Failure {
            if let expected, error != expected { fatalError("At \(line), expected \(expected), got \(error)") }
        } catch { fatalError("Unexpected error at \(line): \(error)") }
    }
    static func bytes(_ hex: String) -> [UInt8] {
        stride(from: 0, to: hex.count, by: 2).map {
            let start = hex.index(hex.startIndex, offsetBy: $0)
            return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)!
        }
    }
    static func le32(_ frame: [UInt8], _ offset: Int) -> UInt32 {
        frame[offset..<(offset + 4)].enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * $1.offset) }
    }
    static func put32(_ value: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) } }
    static func rawReports(_ packet: [UInt8]) -> [[UInt8]] {
        packet.flatMap { [[0, 0x80 | $0 >> 4, 0, 0, 0, 0, 0, 0], [0, 0x90 | $0 & 15, 0, 0, 0, 0, 0, 0]] }
    }
    static func accept(_ parser: inout BluetoothOTAWire.ReplyParser, _ bytes: [UInt8], id: UInt32 = 1, now: UInt32) throws -> BluetoothOTAWire.Reply? {
        try bytes.withUnsafeBufferPointer { try parser.accept(reportID: id, bytes: $0, nowMilliseconds: now) }
    }
    static func decode(_ frame: [UInt8], reports: [[UInt8]]? = nil, includedID: Bool = false, start: UInt32 = 100) throws -> BluetoothOTAWire.Reply {
        var parser = try BluetoothOTAWire.ReplyParser(expectedOperation: frame[5], requestID: le32(frame, 6))
        var now = start
        for report in reports ?? rawReports(frame) {
            now &+= 100
            _ = try accept(&parser, includedID ? [1] + report : report, now: now)
        }
        return try parser.finish()
    }

    struct Fixture: Decodable { let name: String; let kind: Int; let frameHex: String }
    struct Fixtures: Decodable { let frames: [Fixture] }
    static func main() throws {
        let vectors = try JSONDecoder().decode(Fixtures.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))).frames
        let lookup = Dictionary(uniqueKeysWithValues: vectors.map { ($0.name, bytes($0.frameHex)) })
        let maximum = lookup["request-data-max"]!, maxReply = lookup["ack-max"]!, commit = lookup["ack-commit"]!
        check(BluetoothOTAWire.crc32(Array("123456789".utf8)) == 0xcbf43926)
        check(BluetoothOTAWire.crc16(Array("123456789".utf8)) == 0x29b1)
        for fixture in vectors {
            let frame = bytes(fixture.frameHex)
            if fixture.kind == 1 {
                let parsed = try BluetoothOTAWire.parseRequest(frame)
                try check(BluetoothOTAWire.request(operation: parsed.operation, requestID: parsed.requestID, payload: parsed.payload) == frame, fixture.name)
                let masks = try BluetoothOTAWire.ledMasks(for: frame)
                check(masks.count == 1 + frame.count * 4 && masks.first == 0)
                check(!RGBProtocol.validMasks(masks), "OTA cannot enter the production RGB sender")
                var reconstructed: [UInt8] = [], byte: UInt8 = 0
                for (index, mask) in masks.dropFirst().enumerated() {
                    check(mask <= 7 && mask & 4 == (index % 2 == 0 ? 4 : 0))
                    byte = (byte << 2) | (mask & 3)
                    if index % 4 == 3 { reconstructed.append(byte); byte = 0 }
                }
                check(reconstructed == frame)
            } else {
                let reply = try BluetoothOTAWire.parseReply(frame)
                try check(BluetoothOTAWire.reply(operation: reply.operation, requestID: reply.requestID, result: reply.result, flags: reply.flags, payload: reply.payload) == frame)
                let reports = try BluetoothOTAWire.replyReports(for: frame)
                check(reports.count == frame.count * 2 + 1 && reports.last == [UInt8](repeating: 0, count: 8))
                for (index, report) in reports.dropLast().enumerated() {
                    check(report.count == 8 && report.enumerated().allSatisfy { $0.offset == 1 || $0.element == 0 })
                    check(report[1] & 0xf0 == (index % 2 == 0 ? 0x80 : 0x90))
                }
                try check(decode(frame) == reply)
                try check(decode(frame, includedID: true, start: UInt32.max - 200) == reply, "timer wrap and prefixed report ID")
                let receipt = try BluetoothOTAWire.acknowledgementReceipt(for: frame)
                check(BluetoothOTAWire.receiptMatches(receipt, pendingReply: frame))
            }
        }
        try check(BluetoothOTAWire.copyRequest(requestID: 0xaabbccdd, destinationOffset: 512, sourceOffset: 1024, length: 4096) == lookup["request-copy"]!)
        try check(BluetoothOTAWire.copyRequest(requestID: 0x10203040, destinationOffset: 0, sourceOffset: 0, length: 98304) == lookup["request-copy-full"]!)
        for length: UInt32 in [0, 98305, UInt32.max] {
            rejects(.bounds) { _ = try BluetoothOTAWire.copyRequest(requestID: 1, destinationOffset: 0, sourceOffset: 0, length: length) }
        }
        for result in UInt32(0)...12 { try check(BluetoothOTAWire.compactResult(engineResult: result) == UInt8(result)) }
        for result in UInt32(0x100)...0x102 { try check(BluetoothOTAWire.compactResult(engineResult: result) == UInt8(result - 0x80)) }
        for result: UInt32 in [13, 0x80, 0x103, 0x200, .max] { rejects(.unknownResult) { _ = try BluetoothOTAWire.compactResult(engineResult: result) } }

        // Exhaust every single-bit corruption; no CRC-corrupt request or reply is accepted.
        for bit in 0..<(maximum.count * 8) {
            var corrupt = maximum; corrupt[bit / 8] ^= 1 << (bit % 8)
            rejects { _ = try BluetoothOTAWire.parseRequest(corrupt) }
        }
        for bit in 0..<(maxReply.count * 8) {
            var corrupt = maxReply; corrupt[bit / 8] ^= 1 << (bit % 8)
            rejects { _ = try BluetoothOTAWire.parseReply(corrupt) }
            rejects { _ = try decode(corrupt) }
        }
        for count in 0..<maxReply.count { rejects { _ = try BluetoothOTAWire.parseReply(Array(maxReply.prefix(count))) } }
        for count in 0..<maximum.count { rejects { _ = try BluetoothOTAWire.parseRequest(Array(maximum.prefix(count))) } }
        let maxReports = rawReports(maxReply)
        for count in 0..<maxReports.count {
            rejects(.incomplete) { _ = try decode(maxReply, reports: Array(maxReports.prefix(count))) }
        }
        for index in 0..<(maxReports.count - 1) {
            var reordered = maxReports; reordered.swapAt(index, index + 1)
            rejects(.markerSequence) { _ = try decode(maxReply, reports: reordered) }
        }
        for index in 0..<maxReports.count {
            var dropped = maxReports; dropped.remove(at: index)
            rejects { _ = try decode(maxReply, reports: dropped) }
            var duplicate = maxReports; duplicate.insert(maxReports[index], at: index)
            rejects { _ = try decode(maxReply, reports: duplicate) }
        }

        let reply = try BluetoothOTAWire.parseReply(commit)
        let inputLengths: [(UInt32, Int)] = [(1, 8), (2, 2), (3, 7), (4, 20), (6, 1)]
        for (id, length) in inputLengths {
            for included in [false, true] {
                var idle = [UInt8](repeating: 0, count: length)
                if included { idle.insert(UInt8(id), at: 0) }
                var idleParser = try BluetoothOTAWire.ReplyParser(expectedOperation: reply.operation, requestID: reply.requestID)
                try check(accept(&idleParser, idle, id: id, now: 0) == nil)
                check(idleParser.symbolCount == 0 && idleParser.completedReply == nil)
                for index in 0..<length where id != 1 || index != 1 {
                    var parser = try BluetoothOTAWire.ReplyParser(expectedOperation: reply.operation, requestID: reply.requestID)
                    var activity = [UInt8](repeating: 0, count: length); activity[index] = 1
                    if included { activity.insert(UInt8(id), at: 0) }
                    rejects(.inputActivity) { _ = try accept(&parser, activity, id: id, now: 1) }
                    rejects(.finished) { _ = try accept(&parser, rawReports(commit)[0], now: 2) }
                    check(parser.symbolCount == 0 && parser.completedReply == nil)
                }
            }
        }
        for (id, payloadLength) in inputLengths {
            for length in 0...(payloadLength + 3) where length != payloadLength {
                var parser = try BluetoothOTAWire.ReplyParser(expectedOperation: 5, requestID: reply.requestID)
                rejects(.invalidReport) { _ = try accept(&parser, [UInt8](repeating: 0, count: length), id: id, now: 1) }
            }
            var wrongPrefix = [UInt8](repeating: 0, count: payloadLength + 1); wrongPrefix[0] = UInt8(id) ^ 0xff
            rejects(.invalidReport) { _ = try wrongPrefix.withUnsafeBufferPointer { try BluetoothOTAWire.assertIdleInput(reportID: id, bytes: $0) } }
            // Matching first byte is actual input when the length has no prefix.
            var active = [UInt8](repeating: 0, count: payloadLength); active[0] = UInt8(id)
            rejects(.inputActivity) { _ = try active.withUnsafeBufferPointer { try BluetoothOTAWire.assertIdleInput(reportID: id, bytes: $0) } }
        }
        var parser = try BluetoothOTAWire.ReplyParser(expectedOperation: 5, requestID: reply.requestID)
        try check(accept(&parser, [0, 0], id: 9, now: 1) == nil)
        rejects(.inputActivity) { _ = try [UInt8(255), 255].withUnsafeBufferPointer { try BluetoothOTAWire.assertIdleInput(reportID: 9, bytes: $0) } }
        try check([UInt8(0), 0x8f, 0, 0, 0, 0, 0, 0].withUnsafeBufferPointer { try BluetoothOTAWire.assertIdleInput(reportID: 1, bytes: $0) } == 0x8f)
        try check(accept(&parser, [UInt8](repeating: 0, count: 8), now: 2) == nil)
        try check(accept(&parser, [UInt8](repeating: 0, count: 20), id: 4, now: 3) == nil)
        try check(accept(&parser, [4] + [UInt8](repeating: 0, count: 20), id: 4, now: 4) == nil)
        try parser.tick(nowMilliseconds: 999999) // caller owns first-symbol deadline
        _ = try accept(&parser, rawReports(commit)[0], now: UInt32.max - 200)
        try parser.tick(nowMilliseconds: 798) // 999ms since first symbol, across wrap
        rejects(.timedOut) { try parser.tick(nowMilliseconds: 799) }
        rejects(.finished) { try parser.tick(nowMilliseconds: 800) }
        var total = try BluetoothOTAWire.ReplyParser(expectedOperation: 8, requestID: le32(maxReply, 6))
        var now: UInt32 = 0
        for report in maxReports.prefix(61) { _ = try accept(&total, report, now: now); now += 999 }
        rejects(.timedOut) { _ = try accept(&total, maxReports[61], now: now) }
        for (operation, identifier) in [(UInt8(4), reply.requestID), (UInt8(5), reply.requestID &+ 1)] {
            var mismatch = try BluetoothOTAWire.ReplyParser(expectedOperation: operation, requestID: identifier)
            rejects(.replyMismatch) { for (i, report) in rawReports(commit).enumerated() { _ = try accept(&mismatch, report, now: UInt32(i * 100)) } }
        }
        try check(BluetoothOTAWire.acknowledgementReceipt(for: commit) == lookup["request-receipt"]!)
        for offset in 8...14 {
            var receipt = lookup["request-receipt"]!; receipt[offset] ^= 1
            receipt.replaceSubrange((receipt.count - 4)..<receipt.count, with: put32(BluetoothOTAWire.crc32(Array(receipt.dropLast(4)))))
            check(!BluetoothOTAWire.receiptMatches(receipt, pendingReply: commit))
        }
        rejects(.invalidOperation) { _ = try BluetoothOTAWire.request(operation: 0, requestID: 1) }
        rejects(.bounds) { _ = try BluetoothOTAWire.request(operation: 2, requestID: 1, payload: [UInt8](repeating: 0, count: 261)) }
        rejects(.bounds) { _ = try BluetoothOTAWire.reply(operation: 3, requestID: 1, result: 0, flags: 0, payload: [UInt8](repeating: 0, count: 129)) }
        rejects(.invalidFlags) { _ = try BluetoothOTAWire.reply(operation: 3, requestID: 1, result: 0, flags: 16) }
        rejects(.unknownResult) { _ = try BluetoothOTAWire.reply(operation: 3, requestID: 1, result: 13, flags: 0) }
        rejects(.invalidOperation) { _ = try BluetoothOTAWire.reply(operation: 0x7f, requestID: 1, result: 0, flags: 0) }
        check(BluetoothOTAWire.replyIntervalAllowed(milliseconds: 100))
        for rate: UInt16 in [0, 20, 40, 80, 101] { rejects(.invalidReplyRate) { _ = try BluetoothOTAWire.ReplyParser(expectedOperation: 3, requestID: 1, replyIntervalMilliseconds: rate) } }
        check(BluetoothOTAWire.replyIntervalAllowed(milliseconds: 40, calibratedReplyRates: 1))
        check(BluetoothOTAWire.replyIntervalAllowed(milliseconds: 20, calibratedReplyRates: 2))
        check(!BluetoothOTAWire.replyIntervalAllowed(milliseconds: 40, calibratedReplyRates: 2))
        check(!BluetoothOTAWire.replyIntervalAllowed(milliseconds: 100, calibratedReplyRates: 4))

        var legacy: [UInt8] = [0x4b, 0x47, 0x4f, 0x54, 1, 0x83, 104, 0] + put32(123) + put32(0x100) + put32(15) + Array(20..<116)
        legacy += put32(BluetoothOTAWire.crc32(legacy))
        let short = try BluetoothOTAWire.parseReply(BluetoothOTAWire.compactReply(fromLegacy: legacy, includeState: false))
        check(short.operation == 3 && short.requestID == 123 && short.result == 0x80 && short.flags == 15 && short.payload.isEmpty)
        let state = try BluetoothOTAWire.parseReply(BluetoothOTAWire.compactReply(fromLegacy: legacy, includeState: true))
        check(state.payload == Array(20..<116))
        legacy[12] = 0; legacy[13] = 2
        legacy.replaceSubrange(116..<120, with: put32(BluetoothOTAWire.crc32(Array(legacy.prefix(116)))))
        rejects(.unknownResult) { _ = try BluetoothOTAWire.compactReply(fromLegacy: legacy, includeState: false) }
        print("Bluetooth OTA Swift wire: \(checks) assertions passed; shared C vectors, no hardware linked.")
    }
}
