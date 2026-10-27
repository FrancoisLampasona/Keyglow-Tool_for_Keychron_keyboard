// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import CryptoKit

/// Offline planning only. A verified digest must come from an independently
/// established installed-image identity; a file name is never an identity.
struct FirmwareDeltaPlan: Sendable {
    static let targetID: UInt32 = 0x08613434
    static let applicationAddress: UInt32 = 0x08008000
    static let maximumImageSize = 96 * 1024
    static let chunkSize = 256
    static let maximumCopyRunSize = maximumImageSize

    enum Failure: Error, Equatable {
        case wrongTarget, wrongAddress, imageSize, invalidVectors
        case invalidDigest, unverifiedBaseline, invalidChunk, copyBounds
        case reconstructionMismatch, invalidEstimate
    }

    enum BaselineUse: Equatable, Sendable {
        case verified
        case missingImage, missingDigest, invalidDigest, digestMismatch, invalidImage
    }

    struct Chunk: Equatable, Sendable {
        enum Contents: Equatable, Sendable {
            case copy(sourceOffset: Int, length: Int)
            case literal(Data)
        }
        let destinationOffset: Int
        let contents: Contents

        var length: Int {
            switch contents {
            case .copy(_, let length): return length
            case .literal(let bytes): return bytes.count
            }
        }
    }

    /// COPY wire metadata. Runs contain complete target chunks (apart from the
    /// final image tail) and are capped at the receiver's application-size limit.
    /// `chunks` retains the full 256-byte decomposition for durable progress.
    struct CopyRun: Equatable, Sendable {
        let destinationOffset: Int
        let sourceOffset: Int
        let length: Int
        let chunkCount: Int
    }

    let target: UInt32
    let address: UInt32
    let imageSize: Int
    let imageSHA256: Data
    let baselineUse: BaselineUse
    let baselineSize: Int?
    let baselineSHA256: Data?
    let chunks: [Chunk]
    let copyRuns: [CopyRun]

    var copiedBytes: Int {
        chunks.reduce(0) { count, chunk in
            if case .copy = chunk.contents { return count + chunk.length }
            return count
        }
    }
    var literalBytes: Int { imageSize - copiedBytes }

    private init(target: UInt32, address: UInt32, imageSize: Int, imageSHA256: Data,
                 baselineUse: BaselineUse, baselineSize: Int?, baselineSHA256: Data?,
                 chunks: [Chunk], copyRuns: [CopyRun]) {
        self.target = target; self.address = address; self.imageSize = imageSize
        self.imageSHA256 = imageSHA256; self.baselineUse = baselineUse
        self.baselineSize = baselineSize; self.baselineSHA256 = baselineSHA256
        self.chunks = chunks; self.copyRuns = copyRuns
    }

    static func sha256(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }

    static func make(oldAppData: Data?, newAppData: Data, verifiedOldSHA256: Data?,
                     target: UInt32, address: UInt32 = applicationAddress) throws -> Self {
        guard target == targetID else { throw Failure.wrongTarget }
        guard address == applicationAddress else { throw Failure.wrongAddress }
        try validateImage(newAppData)
        let use = assessBaseline(oldAppData, verifiedOldSHA256)
        let baseline = use == .verified ? oldAppData : nil
        let old = baseline.map(Array.init) ?? []
        let new = Array(newAppData)
        var indices: [Int: [UInt64: [Int]]] = [:]
        var chunks: [Chunk] = []

        for destination in stride(from: 0, to: new.count, by: chunkSize) {
            let length = min(chunkSize, new.count - destination)
            let bytes = new[destination..<(destination + length)]
            var source: Int?
            if old.count >= length {
                // Prefer the same address; this also keeps repeated padding
                // deterministic and avoids indexing an unchanged image.
                if destination <= old.count - length,
                   old[destination..<(destination + length)].elementsEqual(bytes) {
                    source = destination
                } else {
                    if indices[length] == nil { indices[length] = rollingIndex(old, length: length) }
                    if let candidates = indices[length]?[hash(bytes)] {
                        source = candidates.first {
                            old[$0..<($0 + length)].elementsEqual(bytes)
                        }
                    }
                }
            }
            if let source {
                chunks.append(Chunk(destinationOffset: destination,
                                    contents: .copy(sourceOffset: source, length: length)))
            } else {
                chunks.append(Chunk(destinationOffset: destination, contents: .literal(Data(bytes))))
            }
        }

        let digest = sha256(newAppData)
        let reconstructed = try reconstruct(chunks: chunks, baseline: baseline,
                                            verifiedBaselineSHA256: use == .verified ? verifiedOldSHA256 : nil,
                                            imageSize: new.count, expectedSHA256: digest,
                                            target: target, address: address)
        guard reconstructed == newAppData else { throw Failure.reconstructionMismatch }
        return Self(target: target, address: address, imageSize: new.count, imageSHA256: digest,
                    baselineUse: use, baselineSize: baseline?.count,
                    baselineSHA256: use == .verified ? verifiedOldSHA256 : nil,
                    chunks: chunks, copyRuns: coalescedRuns(chunks))
    }

    /// Independent bounds and digest checks also permit testing untrusted plans.
    /// A plan never stores or executes a device address supplied by a chunk.
    static func reconstruct(chunks: [Chunk], baseline: Data?, verifiedBaselineSHA256: Data?,
                            imageSize: Int, expectedSHA256: Data, target: UInt32,
                            address: UInt32 = applicationAddress) throws -> Data {
        guard target == targetID else { throw Failure.wrongTarget }
        guard address == applicationAddress else { throw Failure.wrongAddress }
        guard (8...maximumImageSize).contains(imageSize) else { throw Failure.imageSize }
        guard expectedSHA256.count == 32 else { throw Failure.invalidDigest }
        guard chunks.count == (imageSize + chunkSize - 1) / chunkSize else { throw Failure.invalidChunk }
        let hasCopy = chunks.contains { if case .copy = $0.contents { return true }; return false }
        if hasCopy, assessBaseline(baseline, verifiedBaselineSHA256) != .verified {
            throw Failure.unverifiedBaseline
        }
        let old = baseline.map(Array.init) ?? []
        var result = Data()
        result.reserveCapacity(imageSize)
        for (index, chunk) in chunks.enumerated() {
            let expectedOffset = index * chunkSize
            let expectedLength = min(chunkSize, imageSize - expectedOffset)
            guard chunk.destinationOffset == expectedOffset, chunk.length == expectedLength else {
                throw Failure.invalidChunk
            }
            switch chunk.contents {
            case .copy(let offset, let length):
                guard offset >= 0, offset <= old.count, length <= old.count - offset else {
                    throw Failure.copyBounds
                }
                result.append(contentsOf: old[offset..<(offset + length)])
            case .literal(let data): result.append(data)
            }
        }
        guard result.count == imageSize, sha256(result) == expectedSHA256 else {
            throw Failure.reconstructionMismatch
        }
        try validateImage(result)
        return result
    }

    private static func assessBaseline(_ image: Data?, _ digest: Data?) -> BaselineUse {
        guard let image else { return .missingImage }
        guard let digest else { return .missingDigest }
        guard digest.count == 32 else { return .invalidDigest }
        guard (try? validateImage(image)) != nil else { return .invalidImage }
        guard sha256(image) == digest else { return .digestMismatch }
        return .verified
    }

    private static func validateImage(_ data: Data) throws {
        guard (8...maximumImageSize).contains(data.count) else { throw Failure.imageSize }
        let bytes = Array(data.prefix(8))
        func word(_ offset: Int) -> UInt32 {
            UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 |
            UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
        }
        let stack = word(0), reset = word(4), pc = reset & ~UInt32(1)
        guard stack >= 0x20000008, stack <= 0x20010000, stack & 7 == 0,
              reset & 1 == 1, pc >= applicationAddress + 8,
              pc < applicationAddress + UInt32(data.count) else { throw Failure.invalidVectors }
    }

    private static func hash(_ bytes: ArraySlice<UInt8>) -> UInt64 {
        bytes.reduce(UInt64(0)) { ($0 &* 257) &+ (UInt64($1) + 1) }
    }

    /// Rolling hashes only find candidates. Exact byte equality above is always
    /// required, so a hash collision cannot produce an incorrect COPY.
    private static func rollingIndex(_ bytes: [UInt8], length: Int) -> [UInt64: [Int]] {
        guard length > 0, length <= bytes.count else { return [:] }
        var power: UInt64 = 1
        for _ in 1..<length { power = power &* 257 }
        var value = hash(bytes[0..<length])
        var result: [UInt64: [Int]] = [value: [0]]
        if bytes.count > length {
            for offset in 1...(bytes.count - length) {
                value = ((value &- ((UInt64(bytes[offset - 1]) + 1) &* power)) &* 257)
                    &+ (UInt64(bytes[offset + length - 1]) + 1)
                result[value, default: []].append(offset)
            }
        }
        return result
    }

    private static func coalescedRuns(_ chunks: [Chunk]) -> [CopyRun] {
        var result: [CopyRun] = []
        for chunk in chunks {
            guard case .copy(let source, let length) = chunk.contents else { continue }
            if let last = result.last,
               last.destinationOffset + last.length == chunk.destinationOffset,
               last.sourceOffset + last.length == source,
               last.length + length <= maximumCopyRunSize {
                result[result.count - 1] = CopyRun(destinationOffset: last.destinationOffset,
                                                   sourceOffset: last.sourceOffset,
                                                   length: last.length + length,
                                                   chunkCount: last.chunkCount + 1)
            } else {
                result.append(CopyRun(destinationOffset: chunk.destinationOffset,
                                      sourceOffset: source, length: length, chunkCount: 1))
            }
        }
        return result
    }
}

extension FirmwareDeltaPlan {
    struct Exchange: Equatable, Sendable {
        let requestBytes: Int
        let replyBytes: Int
    }

    /// KGOT includes its 12-byte header and 4-byte CRC. Compact KGAK is 15
    /// bytes, plus the 96-byte STATUS body. These are application protocol
    /// counts, not BLE over-the-air byte counts or proof of a working carrier.
    var protocolExchanges: [Exchange] {
        var result = [Exchange(requestBytes: 32, replyBytes: 111),  // fresh authenticated HELLO
                      Exchange(requestBytes: 16, replyBytes: 111), // classify previous stage before AUTH
                      Exchange(requestBytes: 165, replyBytes: 15), // AUTH_BEGIN: 149-byte payload
                      Exchange(requestBytes: 16, replyBytes: 111)] // resume STATUS
        let runs = Dictionary(uniqueKeysWithValues: copyRuns.map { ($0.destinationOffset, $0) })
        for chunk in chunks {
            switch chunk.contents {
            case .literal(let data):
                result.append(Exchange(requestBytes: 20 + data.count, replyBytes: 15))
            case .copy:
                if runs[chunk.destinationOffset] != nil {
                    // COPY operation 6: destination/source/length, each LE32.
                    result.append(Exchange(requestBytes: 28, replyBytes: 15))
                }
            }
        }
        result.append(Exchange(requestBytes: 16, replyBytes: 15))  // FINISH
        result.append(Exchange(requestBytes: 16, replyBytes: 15))  // COMMIT
        result.append(Exchange(requestBytes: 32, replyBytes: 111)) // reconnected authenticated HELLO
        return result
    }

    struct TransportModel: Sendable {
        let requestBitsPerWrite: Int
        let replyBitsPerReport: Int
        let requestBoundaryWrites: Int
        let replyBoundaryReports: Int
        let requestReportBytes: Int
        let replyReportBytes: Int

        /// Current proposed carrier framing: four one-byte LED writes per
        /// request byte, initial baseline + restoration, two eight-byte HID
        /// input reports per reply byte and one final all-zero input report.
        /// This makes no claim that an OTA transfer has been hardware tested.
        static let ledAndReservedByte = Self(requestBitsPerWrite: 2, replyBitsPerReport: 4,
                                             requestBoundaryWrites: 2, replyBoundaryReports: 1,
                                             requestReportBytes: 1, replyReportBytes: 8)
    }

    struct AirOverhead: Sendable {
        /// Explicit link-level assumptions, including ATT/L2CAP/LL/encryption
        /// and acknowledgements as appropriate to the measured transport.
        /// Leave absent when unknown; HID payload bytes are not RF bytes.
        let additionalBytesPerWrite: Int
        let additionalBytesPerReport: Int
        let additionalBytesPerExchange: Int
    }

    struct TimingEvidence: Sendable {
        /// Measured end-to-end write durations and reply-report intervals.
        /// Do not infer these from one mixed request/settling/reply trial.
        let writeSeconds: ClosedRange<Double>
        let replyReportSeconds: ClosedRange<Double>
        /// Explicit scenario allowance for erase/verification, settling,
        /// typing pauses, retransmission backoff, restart and reconnect.
        /// Unknown/unbounded pauses keep the completion estimate absent.
        let additionalPauseSeconds: ClosedRange<Double>?
    }

    struct TransferBudget: Sendable {
        let exchanges: Int
        let requestProtocolBytes: Int
        let replyProtocolBytes: Int
        let writes: Int
        let replyReports: Int
        let allowedRetryExchanges: Int
        let writesWithRetryAllowance: Int
        let replyReportsWithRetryAllowance: Int
        let reportPayloadBytesWithRetryAllowance: Int
        let estimatedAirBytesWithRetryAllowance: Int?
        /// Transport component only; never a completion ETA.
        let measuredTransportSeconds: ClosedRange<Double>?
        /// An explicitly bounded scenario, not a promised completion time.
        let scenarioDurationSeconds: ClosedRange<Double>?
    }

    /// An explicit retry fraction budgets whole repeated exchanges, rounded
    /// up, each charged at the largest request and reply size. Extra exchanges
    /// account for authentication, capability
    /// or baseline-identity checks whose format is outside this planner.
    func budget(transport: TransportModel, retryAllowance: Double,
                additionalExchanges: [Exchange] = [], airOverhead: AirOverhead? = nil,
                timing: TimingEvidence? = nil) throws -> TransferBudget {
        guard (1...32768).contains(transport.requestBitsPerWrite),
              (1...32768).contains(transport.replyBitsPerReport),
              (0...4096).contains(transport.requestBoundaryWrites),
              (0...4096).contains(transport.replyBoundaryReports),
              (1...4096).contains(transport.requestReportBytes),
              (1...4096).contains(transport.replyReportBytes),
              retryAllowance.isFinite, (0...10).contains(retryAllowance),
              additionalExchanges.count <= 4096 else { throw Failure.invalidEstimate }
        let exchanges = protocolExchanges + additionalExchanges
        guard exchanges.allSatisfy({ (1...65536).contains($0.requestBytes) &&
                                    (1...65536).contains($0.replyBytes) }) else {
            throw Failure.invalidEstimate
        }
        if let overhead = airOverhead {
            guard (0...65536).contains(overhead.additionalBytesPerWrite),
                  (0...65536).contains(overhead.additionalBytesPerReport),
                  (0...65536).contains(overhead.additionalBytesPerExchange) else {
                throw Failure.invalidEstimate
            }
        }
        func count(_ bytes: Int, _ bits: Int, _ boundary: Int) -> Int {
            (bytes * 8 + bits - 1) / bits + boundary
        }
        // Every validated compact reply is followed by a 19-byte KGOT
        // ACK_ACK receipt, with its own baseline and indicator restoration.
        let receiptWrites = count(19, transport.requestBitsPerWrite, transport.requestBoundaryWrites)
        let writeCounts = exchanges.map { count($0.requestBytes, transport.requestBitsPerWrite,
                                                transport.requestBoundaryWrites) + receiptWrites }
        let reportCounts = exchanges.map { count($0.replyBytes, transport.replyBitsPerReport,
                                                 transport.replyBoundaryReports) }
        let writes = writeCounts.reduce(0, +), reports = reportCounts.reduce(0, +)
        let retryCount = Int(ceil(Double(exchanges.count) * retryAllowance))
        let budgetWrites = writes + retryCount * (writeCounts.max() ?? 0)
        let budgetReports = reports + retryCount * (reportCounts.max() ?? 0)
        let payloadBytes = budgetWrites * transport.requestReportBytes + budgetReports * transport.replyReportBytes
        let airBytes = airOverhead.map {
            payloadBytes + budgetWrites * $0.additionalBytesPerWrite + budgetReports * $0.additionalBytesPerReport
                + (exchanges.count + retryCount) * $0.additionalBytesPerExchange
        }
        var transportSeconds: ClosedRange<Double>?
        var scenarioSeconds: ClosedRange<Double>?
        if let timing {
            func valid(_ range: ClosedRange<Double>) -> Bool {
                range.lowerBound.isFinite && range.upperBound.isFinite &&
                    range.lowerBound >= 0 && range.upperBound <= 86_400
            }
            guard valid(timing.writeSeconds), valid(timing.replyReportSeconds),
                  timing.additionalPauseSeconds.map(valid) ?? true else { throw Failure.invalidEstimate }
            let lower = Double(writes) * timing.writeSeconds.lowerBound + Double(reports) * timing.replyReportSeconds.lowerBound
            let upper = Double(budgetWrites) * timing.writeSeconds.upperBound + Double(budgetReports) * timing.replyReportSeconds.upperBound
            transportSeconds = lower...upper
            if let pause = timing.additionalPauseSeconds {
                scenarioSeconds = (lower + pause.lowerBound)...(upper + pause.upperBound)
            }
        }
        return TransferBudget(exchanges: exchanges.count,
                              requestProtocolBytes: exchanges.reduce(0) { $0 + $1.requestBytes + 19 },
                              replyProtocolBytes: exchanges.reduce(0) { $0 + $1.replyBytes },
                              writes: writes, replyReports: reports,
                              allowedRetryExchanges: retryCount,
                              writesWithRetryAllowance: budgetWrites, replyReportsWithRetryAllowance: budgetReports,
                              reportPayloadBytesWithRetryAllowance: payloadBytes,
                              estimatedAirBytesWithRetryAllowance: airBytes,
                              measuredTransportSeconds: transportSeconds, scenarioDurationSeconds: scenarioSeconds)
    }
}
