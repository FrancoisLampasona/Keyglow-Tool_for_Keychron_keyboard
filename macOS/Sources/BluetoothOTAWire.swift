import Foundation

/// Pure wire codec. Encoding, CRC validation and a matching acknowledgement do
/// not authorize a manifest, prove flash safety, or prove that a reset occurred.
enum BluetoothOTAWire {
    static let requestMaximumBytes = 276
    static let requestPayloadMaximumBytes = 260
    static let replyPayloadMaximumBytes = 128
    static let replyMaximumBytes = 143
    static let acknowledgementReceiptOperation: UInt8 = 0x7f
    static let defaultReplyIntervalMilliseconds: UInt16 = 100
    static let calibratedReply40: UInt8 = 1
    static let calibratedReply20: UInt8 = 2

    enum Failure: Error, Equatable, LocalizedError {
        case bounds, invalidOperation, invalidVersion, invalidMagic, invalidFlags, unknownResult
        case crcMismatch, replyMismatch, markerSequence, inputActivity, invalidReport
        case timedOut, incomplete, invalidReplyRate, finished
        var errorDescription: String? {
            switch self {
            case .inputActivity: return "Trasferimento interrotto dalla digitazione; nessun tasto è stato registrato."
            case .timedOut: return "Risposta Bluetooth incompleta entro il limite previsto."
            case .invalidReplyRate: return "La velocità di risposta richiesta non è stata calibrata e concordata."
            case .crcMismatch: return "La verifica CRC della risposta Bluetooth non è riuscita."
            case .replyMismatch: return "La risposta appartiene a una richiesta diversa."
            case .incomplete: return "La risposta Bluetooth è troncata."
            default: return "Formato del protocollo Bluetooth non valido (\(self))."
            }
        }
    }

    struct Request: Equatable, Sendable {
        let operation: UInt8
        let requestID: UInt32
        let payload: [UInt8]
    }
    struct Reply: Equatable, Sendable {
        let operation: UInt8
        let requestID: UInt32
        let result: UInt8
        let flags: UInt8
        let payload: [UInt8]
        let crc: UInt16
    }

    static func crc16(_ bytes: [UInt8]) -> UInt16 {
        var crc: UInt16 = 0xffff
        for byte in bytes {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 { crc = crc & 0x8000 != 0 ? (crc &<< 1) ^ 0x1021 : crc &<< 1 }
        }
        return crc
    }
    static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 != 0 ? 0xedb8_8320 : 0) }
        }
        return ~crc
    }
    private static func little32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        bytes[offset..<(offset + 4)].enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * $1.offset) }
    }
    private static func put32(_ value: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) } }
    private static func validOperation(_ value: UInt8) -> Bool { (1...acknowledgementReceiptOperation).contains(value) }
    private static func validResult(_ value: UInt8) -> Bool { value <= 12 || (0x80...0x82).contains(value) }

    static func request(operation: UInt8, requestID: UInt32, payload: [UInt8] = []) throws -> [UInt8] {
        guard validOperation(operation) else { throw Failure.invalidOperation }
        guard payload.count <= requestPayloadMaximumBytes else { throw Failure.bounds }
        var frame: [UInt8] = [0x4b, 0x47, 0x4f, 0x54, 1, operation, UInt8(payload.count & 255), UInt8(payload.count >> 8)]
        frame += put32(requestID) + payload
        frame += put32(crc32(frame))
        return frame
    }
    static func parseRequest(_ frame: [UInt8]) throws -> Request {
        guard (16...requestMaximumBytes).contains(frame.count), (Int(frame[6]) | Int(frame[7]) << 8) + 16 == frame.count else { throw Failure.bounds }
        guard Array(frame.prefix(4)) == [0x4b, 0x47, 0x4f, 0x54] else { throw Failure.invalidMagic }
        guard frame[4] == 1 else { throw Failure.invalidVersion }
        guard validOperation(frame[5]) else { throw Failure.invalidOperation }
        guard little32(frame, frame.count - 4) == crc32(Array(frame.dropLast(4))) else { throw Failure.crcMismatch }
        return Request(operation: frame[5], requestID: little32(frame, 8), payload: Array(frame[12..<(frame.count - 4)]))
    }
    static func copyRequest(requestID: UInt32, destinationOffset: UInt32, sourceOffset: UInt32, length: UInt32) throws -> [UInt8] {
        guard (1...98_304).contains(length) else { throw Failure.bounds }
        return try request(operation: 6, requestID: requestID, payload: put32(destinationOffset) + put32(sourceOffset) + put32(length))
    }
    static func ledMasks(for frame: [UInt8]) throws -> [UInt8] {
        _ = try parseRequest(frame)
        var masks: [UInt8] = [0], clock: UInt8 = 4
        masks.reserveCapacity(1 + frame.count * 4)
        for byte in frame {
            for shift in stride(from: 6, through: 0, by: -2) {
                masks.append(clock | ((byte >> shift) & 3)); clock ^= 4
            }
        }
        return masks
    }

    static func compactResult(engineResult: UInt32) throws -> UInt8 {
        if engineResult <= 12 { return UInt8(engineResult) }
        if (0x100...0x102).contains(engineResult) { return UInt8(0x80 + engineResult - 0x100) }
        throw Failure.unknownResult
    }
    static func reply(operation: UInt8, requestID: UInt32, result: UInt8, flags: UInt8,
                      payload: [UInt8] = []) throws -> [UInt8] {
        guard validOperation(operation), operation != acknowledgementReceiptOperation else { throw Failure.invalidOperation }
        guard validResult(result) else { throw Failure.unknownResult }
        guard flags & 0xf0 == 0 else { throw Failure.invalidFlags }
        guard payload.count <= replyPayloadMaximumBytes else { throw Failure.bounds }
        var frame: [UInt8] = [0x4b, 0x47, 0x41, 0x4b, 1, operation]
        frame += put32(requestID) + [result, flags, UInt8(payload.count)] + payload
        let crc = crc16(frame)
        frame += [UInt8(crc >> 8), UInt8(crc & 255)]
        return frame
    }
    static func parseReply(_ frame: [UInt8]) throws -> Reply {
        guard (15...replyMaximumBytes).contains(frame.count), Int(frame[12]) + 15 == frame.count else { throw Failure.bounds }
        guard Array(frame.prefix(4)) == [0x4b, 0x47, 0x41, 0x4b] else { throw Failure.invalidMagic }
        guard frame[4] == 1 else { throw Failure.invalidVersion }
        guard validOperation(frame[5]), frame[5] != acknowledgementReceiptOperation else { throw Failure.invalidOperation }
        guard validResult(frame[10]) else { throw Failure.unknownResult }
        guard frame[11] & 0xf0 == 0 else { throw Failure.invalidFlags }
        let crc = UInt16(frame[frame.count - 2]) << 8 | UInt16(frame[frame.count - 1])
        guard crc == crc16(Array(frame.dropLast(2))) else { throw Failure.crcMismatch }
        return Reply(operation: frame[5], requestID: little32(frame, 6), result: frame[10], flags: frame[11], payload: Array(frame[13..<(frame.count - 2)]), crc: crc)
    }
    static func compactReply(fromLegacy legacy: [UInt8], includeState: Bool) throws -> [UInt8] {
        guard legacy.count == 120, legacy[6] == 104, legacy[7] == 0 else { throw Failure.bounds }
        guard Array(legacy.prefix(4)) == [0x4b, 0x47, 0x4f, 0x54], legacy[4] == 1,
              legacy[5] & 0x80 != 0 else { throw Failure.invalidMagic }
        guard little32(legacy, 116) == crc32(Array(legacy.prefix(116))) else { throw Failure.crcMismatch }
        let flags = little32(legacy, 16)
        guard flags <= 15 else { throw Failure.invalidFlags }
        return try reply(operation: legacy[5] & 0x7f, requestID: little32(legacy, 8),
                         result: compactResult(engineResult: little32(legacy, 12)), flags: UInt8(flags),
                         payload: includeState ? Array(legacy[20..<116]) : [])
    }

    /// Only reserved bytes carry data; no report can contain a key or modifier.
    static func replyReports(for frame: [UInt8]) throws -> [[UInt8]] {
        _ = try parseReply(frame)
        var reports: [[UInt8]] = []
        reports.reserveCapacity(frame.count * 2 + 1)
        for byte in frame {
            reports.append([0, 0x80 | byte >> 4, 0, 0, 0, 0, 0, 0])
            reports.append([0, 0x90 | byte & 15, 0, 0, 0, 0, 0, 0])
        }
        reports.append([UInt8](repeating: 0, count: 8))
        return reports
    }
    static func replyIntervalAllowed(milliseconds: UInt16, calibratedReplyRates: UInt8 = 0) -> Bool {
        guard calibratedReplyRates & ~3 == 0 else { return false }
        return milliseconds == 100 ||
            (milliseconds == 40 && calibratedReplyRates & calibratedReply40 != 0) ||
            (milliseconds == 20 && calibratedReplyRates & calibratedReply20 != 0)
    }

    static func acknowledgementReceipt(for reply: [UInt8]) throws -> [UInt8] {
        try acknowledgementReceipt(for: parseReply(reply))
    }
    static func acknowledgementReceipt(for reply: Reply) throws -> [UInt8] {
        let verified = try self.reply(operation: reply.operation, requestID: reply.requestID, result: reply.result, flags: reply.flags, payload: reply.payload)
        guard UInt16(verified[verified.count - 2]) << 8 | UInt16(verified[verified.count - 1]) == reply.crc else { throw Failure.crcMismatch }
        return try request(operation: acknowledgementReceiptOperation, requestID: reply.requestID,
                           payload: [reply.operation, UInt8(reply.crc >> 8), UInt8(reply.crc & 255)])
    }
    static func receiptMatches(_ request: [UInt8], pendingReply: [UInt8]) -> Bool {
        guard let receipt = try? parseRequest(request), let pending = try? parseReply(pendingReply) else { return false }
        return receipt.operation == acknowledgementReceiptOperation && receipt.requestID == pending.requestID &&
            receipt.payload == [pending.operation, UInt8(pending.crc >> 8), UInt8(pending.crc & 255)]
    }

    /// Checks callback memory in place, including after a complete reply while
    /// its receipt is still being sent. No key or consumer data is copied.
    /// Only report 1 exposes a reserved byte. Unknown nonzero reports fail closed.
    static func assertIdleInput(reportID: UInt32, bytes: UnsafeBufferPointer<UInt8>) throws -> UInt8? {
        // Exact input payload lengths from the observed Q6 Max BLE descriptor:
        // keyboard1, consumer2, mouse3, NKRO4, system6. The optional numbered
        // report prefix is framing, not input activity; never strip it by value
        // alone because an unprefixed first payload byte can equal its ID.
        let expectedLength: Int
        switch reportID {
        case 1: expectedLength = 8
        case 2: expectedLength = 2
        case 3: expectedLength = 7
        case 4: expectedLength = 20
        case 6: expectedLength = 1
        default:
            guard bytes.allSatisfy({ $0 == 0 }) else { throw Failure.inputActivity }
            return nil
        }
        let offset: Int
        if bytes.count == expectedLength { offset = 0 }
        else if bytes.count == expectedLength + 1, bytes[0] == UInt8(reportID) { offset = 1 }
        else { throw Failure.invalidReport }
        if reportID != 1 {
            guard bytes[offset...].allSatisfy({ $0 == 0 }) else { throw Failure.inputActivity }
            return nil
        }
        guard bytes[offset] == 0, bytes[(offset + 2)...].allSatisfy({ $0 == 0 }) else { throw Failure.inputActivity }
        return bytes[offset + 1]
    }

    /// Per-transaction parser. Keys are checked in the callback's input memory;
    /// only reserved diagnostic nibbles are copied. It never persists input.
    struct ReplyParser {
        let expectedOperation: UInt8
        let requestID: UInt32
        let replyIntervalMilliseconds: UInt16
        private var packet: [UInt8] = []
        private var highNibble: UInt8 = 0
        private var expectedBytes: Int?
        private var startedAt: UInt32?
        private var lastSymbolAt: UInt32?
        private var failed = false
        private(set) var symbolCount = 0
        private(set) var completedReply: Reply?

        init(expectedOperation: UInt8, requestID: UInt32, replyIntervalMilliseconds: UInt16 = 100,
             calibratedReplyRates: UInt8 = 0) throws {
            guard validOperation(expectedOperation), expectedOperation != acknowledgementReceiptOperation else { throw Failure.invalidOperation }
            guard replyIntervalAllowed(milliseconds: replyIntervalMilliseconds, calibratedReplyRates: calibratedReplyRates) else { throw Failure.invalidReplyRate }
            self.expectedOperation = expectedOperation; self.requestID = requestID
            self.replyIntervalMilliseconds = replyIntervalMilliseconds
            packet.reserveCapacity(replyMaximumBytes)
        }

        mutating func tick(nowMilliseconds now: UInt32) throws {
            guard !failed else { throw Failure.finished }
            guard completedReply == nil else { return }
            if let startedAt, now &- startedAt >= 60_000 {
                failed = true; packet.removeAll(keepingCapacity: false); throw Failure.timedOut
            }
            if let lastSymbolAt, now &- lastSymbolAt >= 1_000 {
                failed = true; packet.removeAll(keepingCapacity: false); throw Failure.timedOut
            }
        }

        mutating func accept(reportID: UInt32, bytes: UnsafeBufferPointer<UInt8>, nowMilliseconds now: UInt32) throws -> Reply? {
            guard !failed, completedReply == nil else { throw Failure.finished }
            do {
                try tick(nowMilliseconds: now)
                guard let symbol = try assertIdleInput(reportID: reportID, bytes: bytes) else { return nil }
                if symbol == 0 { return nil }
                guard symbolCount < replyMaximumBytes * 2, symbol & 0xf0 == (symbolCount % 2 == 0 ? 0x80 : 0x90) else { throw Failure.markerSequence }
                if startedAt == nil { startedAt = now }
                lastSymbolAt = now
                if symbolCount % 2 == 0 { highNibble = (symbol & 15) << 4 }
                else { packet.append(highNibble | (symbol & 15)); highNibble = 0 }
                symbolCount += 1
                guard symbolCount % 2 == 0 else { return nil }
                if packet.count == 4, packet != [0x4b, 0x47, 0x41, 0x4b] { throw Failure.invalidMagic }
                if packet.count == 5, packet[4] != 1 { throw Failure.invalidVersion }
                if packet.count == 13 {
                    guard Int(packet[12]) <= replyPayloadMaximumBytes else { throw Failure.bounds }
                    expectedBytes = 15 + Int(packet[12])
                }
                guard packet.count == expectedBytes else { return nil }
                let reply = try parseReply(packet)
                guard reply.operation == expectedOperation, reply.requestID == requestID else { throw Failure.replyMismatch }
                completedReply = reply
                packet.removeAll(keepingCapacity: false)
                return reply
            } catch {
                failed = true; packet.removeAll(keepingCapacity: false); highNibble = 0
                throw error
            }
        }

        func finish() throws -> Reply {
            guard !failed, let completedReply else { throw Failure.incomplete }
            return completedReply
        }
    }
}
