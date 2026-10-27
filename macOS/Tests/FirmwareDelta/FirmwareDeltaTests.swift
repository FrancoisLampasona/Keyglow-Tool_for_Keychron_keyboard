// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

@main
struct FirmwareDeltaTests {
    typealias Plan = FirmwareDeltaPlan
    typealias Chunk = Plan.Chunk

    struct Random {
        var state: UInt64
        mutating func byte() -> UInt8 {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return UInt8(truncatingIfNeeded: state)
        }
    }

    static func image(_ count: Int, seed: UInt64 = 123) -> Data {
        var rng = Random(state: seed)
        var result = Data((0..<count).map { _ in rng.byte() })
        if count >= 8 { word(&result, 0, 0x20010000); word(&result, 4, Plan.applicationAddress + 9) }
        return result
    }

    static func word(_ data: inout Data, _ offset: Int, _ value: UInt32) {
        for i in 0..<4 { data[offset + i] = UInt8(truncatingIfNeeded: value >> (i * 8)) }
    }

    static func checkThrows(_ failure: Plan.Failure, _ body: () throws -> Void) {
        do { try body(); preconditionFailure("Expected \(failure)") }
        catch { precondition(error as? Plan.Failure == failure, "Unexpected error: \(error)") }
    }

    static func make(_ old: Data?, _ new: Data, digest: Data? = nil) throws -> Plan {
        try Plan.make(oldAppData: old, newAppData: new,
                      verifiedOldSHA256: digest, target: Plan.targetID)
    }

    static func checkReconstruction(_ plan: Plan, _ old: Data?, _ new: Data) throws {
        let result = try Plan.reconstruct(chunks: plan.chunks, baseline: old,
                                          verifiedBaselineSHA256: plan.baselineSHA256,
                                          imageSize: plan.imageSize, expectedSHA256: plan.imageSHA256,
                                          target: plan.target)
        precondition(result == new)
        precondition(plan.copiedBytes + plan.literalBytes == new.count)
        precondition(plan.imageSHA256 == Plan.sha256(new))
    }

    static func main() throws {
        let old = image(800)
        let digest = Plan.sha256(old)
        let unchanged = try make(old, old, digest: digest)
        precondition(unchanged.baselineUse == .verified)
        precondition(unchanged.literalBytes == 0 && unchanged.copiedBytes == 800)
        precondition(unchanged.chunks.count == 4 && unchanged.chunks.last?.length == 32)
        precondition(unchanged.copyRuns == [Plan.CopyRun(destinationOffset: 0, sourceOffset: 0,
                                                       length: 800, chunkCount: 4)])
        try checkReconstruction(unchanged, old, old)

        var changed = old; changed[300] ^= 0x55
        let changedPlan = try make(old, changed, digest: digest)
        precondition(changedPlan.literalBytes == 256 && changedPlan.copyRuns.count == 2)
        try checkReconstruction(changedPlan, old, changed)

        // A COPY can point to an unaligned old offset, including the final byte.
        var moved = image(1024, seed: 5)
        moved.replaceSubrange(256..<512, with: old[301..<557])
        moved.replaceSubrange(512..<768, with: old[544..<800])
        let movedPlan = try make(old, moved, digest: digest)
        precondition(movedPlan.chunks[1].contents == .copy(sourceOffset: 301, length: 256))
        precondition(movedPlan.chunks[2].contents == .copy(sourceOffset: 544, length: 256))
        try checkReconstruction(movedPlan, old, moved)

        var short = image(271, seed: 9)
        short.replaceSubrange(256..<271, with: old[19..<34])
        let shortPlan = try make(old, short, digest: digest)
        precondition(shortPlan.chunks.last?.contents == .copy(sourceOffset: 19, length: 15))
        try checkReconstruction(shortPlan, old, short)

        for (base, hash, reason): (Data?, Data?, Plan.BaselineUse) in [
            (nil, digest, .missingImage), (old, nil, .missingDigest),
            (old, Data(), .invalidDigest), (old, Data(repeating: 0, count: 32), .digestMismatch),
            (Data(repeating: 0, count: 8), Data(repeating: 0, count: 32), .invalidImage),
            (Data(repeating: 0, count: Plan.maximumImageSize + 1), digest, .invalidImage)
        ] {
            let plan = try make(base, old, digest: hash)
            precondition(plan.baselineUse == reason && plan.literalBytes == old.count)
            precondition(plan.baselineSHA256 == nil && plan.baselineSize == nil)
            try checkReconstruction(plan, nil, old)
        }

        checkThrows(.wrongTarget) {
            _ = try Plan.make(oldAppData: old, newAppData: old, verifiedOldSHA256: digest, target: 0)
        }
        checkThrows(.wrongAddress) {
            _ = try Plan.make(oldAppData: old, newAppData: old, verifiedOldSHA256: digest,
                              target: Plan.targetID, address: 0x08000000)
        }
        for size in [0, 7, Plan.maximumImageSize + 1] {
            checkThrows(.imageSize) { _ = try make(nil, image(size)) }
        }
        for (offset, invalid): (Int, UInt32) in [
            (0, 0x20000000), (0, 0x20000009), (0, 0x20010008),
            (4, Plan.applicationAddress + 8), (4, Plan.applicationAddress + 1),
            (4, Plan.applicationAddress + UInt32(old.count) + 1), (4, UInt32.max)
        ] {
            var invalidImage = old; word(&invalidImage, offset, invalid)
            checkThrows(.invalidVectors) { _ = try make(nil, invalidImage) }
        }
        checkThrows(.invalidVectors) { _ = try make(nil, image(8)) }
        _ = try make(nil, image(9))

        func reconstruct(_ chunks: [Chunk], baseline: Data? = old,
                         hash: Data? = digest, size: Int = 800, expected: Data = digest) throws {
            _ = try Plan.reconstruct(chunks: chunks, baseline: baseline,
                                     verifiedBaselineSHA256: hash, imageSize: size,
                                     expectedSHA256: expected, target: Plan.targetID)
        }
        for source in [-1, Int.min, Int.max, 800, 545] {
            var malicious = unchanged.chunks
            malicious[0] = Chunk(destinationOffset: 0, contents: .copy(sourceOffset: source, length: 256))
            checkThrows(.copyBounds) { try reconstruct(malicious) }
        }
        for length in [-1, 0, 255, 257, Int.max] {
            var malicious = unchanged.chunks
            malicious[0] = Chunk(destinationOffset: 0, contents: .copy(sourceOffset: 0, length: length))
            checkThrows(.invalidChunk) { try reconstruct(malicious) }
        }
        var wrongOffset = unchanged.chunks
        wrongOffset[0] = Chunk(destinationOffset: Int.max, contents: .copy(sourceOffset: 0, length: 256))
        checkThrows(.invalidChunk) { try reconstruct(wrongOffset) }
        checkThrows(.invalidChunk) { try reconstruct(Array(unchanged.chunks.dropLast())) }
        checkThrows(.invalidChunk) { try reconstruct(unchanged.chunks.reversed()) }
        checkThrows(.invalidDigest) { try reconstruct(unchanged.chunks, expected: Data()) }
        checkThrows(.imageSize) { try reconstruct(unchanged.chunks, size: Int.max) }
        checkThrows(.unverifiedBaseline) { try reconstruct(unchanged.chunks, hash: nil) }
        checkThrows(.unverifiedBaseline) { try reconstruct(unchanged.chunks, baseline: changed) }
        var wrongLiteral = unchanged.chunks
        wrongLiteral[0] = Chunk(destinationOffset: 0, contents: .literal(Data(repeating: 0, count: 256)))
        checkThrows(.reconstructionMismatch) { try reconstruct(wrongLiteral) }

        // Max-size and deterministic randomized cases exercise both matching
        // indexes, repeated padding, unequal lengths and 1..255 byte tails.
        let large = image(Plan.maximumImageSize, seed: 900)
        let largePlan = try make(large, large, digest: Plan.sha256(large))
        precondition(largePlan.chunks.count == 384 && largePlan.literalBytes == 0)
        precondition(largePlan.copyRuns.count == 1)
        precondition(largePlan.copyRuns.allSatisfy { $0.length == Plan.maximumImageSize && $0.chunkCount == 384 })
        var padded = Data(repeating: 0xff, count: Plan.maximumImageSize)
        word(&padded, 0, 0x20000008); word(&padded, 4, Plan.applicationAddress + 9)
        let paddedPlan = try make(padded, large, digest: Plan.sha256(padded))
        try checkReconstruction(paddedPlan, padded, large)
        var rng = Random(state: 81237)
        for trial in 1...80 {
            let size = 9 + Int(rng.byte()) * 17
            let baseline = image(size + Int(rng.byte()), seed: UInt64(trial))
            var next = image(size, seed: UInt64(trial + 200))
            if size >= 512 {
                let offset = Int(rng.byte()) % (baseline.count - 256 + 1)
                next.replaceSubrange(256..<512, with: baseline[offset..<(offset + 256)])
            }
            let plan = try make(baseline, next, digest: Plan.sha256(baseline))
            try checkReconstruction(plan, baseline, next)
        }

        let baseBudget = try unchanged.budget(transport: .ledAndReservedByte, retryAllowance: 0)
        precondition(baseBudget.exchanges == 8)
        precondition(baseBudget.requestProtocolBytes == 473 && baseBudget.replyProtocolBytes == 504)
        precondition(baseBudget.writes == 1924 && baseBudget.replyReports == 1016)
        precondition(baseBudget.reportPayloadBytesWithRetryAllowance == 10052)
        precondition(baseBudget.allowedRetryExchanges == 0)
        precondition(baseBudget.estimatedAirBytesWithRetryAllowance == nil)
        precondition(baseBudget.measuredTransportSeconds == nil && baseBudget.scenarioDurationSeconds == nil)
        let timedBudget = try unchanged.budget(transport: .ledAndReservedByte, retryAllowance: 0.25,
                                               airOverhead: .init(additionalBytesPerWrite: 10,
                                                                  additionalBytesPerReport: 20,
                                                                  additionalBytesPerExchange: 4),
                                               timing: .init(writeSeconds: 0.01...0.02,
                                                             replyReportSeconds: 0.02...0.04,
                                                             additionalPauseSeconds: nil))
        precondition(timedBudget.allowedRetryExchanges == 2)
        precondition(timedBudget.writesWithRetryAllowance == 3404)
        precondition(timedBudget.replyReportsWithRetryAllowance == 1462)
        precondition(timedBudget.estimatedAirBytesWithRetryAllowance == 78420)
        precondition(abs(timedBudget.measuredTransportSeconds!.lowerBound - 39.56) < 0.000001)
        precondition(abs(timedBudget.measuredTransportSeconds!.upperBound - 126.56) < 0.000001)
        precondition(timedBudget.scenarioDurationSeconds == nil) // no invented pause/ETA
        let scenario = try unchanged.budget(transport: .ledAndReservedByte, retryAllowance: 0.25,
                                            timing: .init(writeSeconds: 0.01...0.02,
                                                          replyReportSeconds: 0.02...0.04,
                                                          additionalPauseSeconds: 10...100))
        precondition(abs(scenario.scenarioDurationSeconds!.lowerBound - 49.56) < 0.000001)
        precondition(abs(scenario.scenarioDurationSeconds!.upperBound - 226.56) < 0.000001)
        let extra = try unchanged.budget(transport: .ledAndReservedByte, retryAllowance: 0,
                                         additionalExchanges: [.init(requestBytes: 5, replyBytes: 6)])
        precondition(extra.writes == 2024 && extra.replyReports == 1029)
        // Packet transport rounds every frame separately, preserving boundaries.
        let packet = try unchanged.budget(transport: .init(requestBitsPerWrite: 160,
                                                          replyBitsPerReport: 160,
                                                          requestBoundaryWrites: 0,
                                                          replyBoundaryReports: 0,
                                                          requestReportBytes: 20,
                                                          replyReportBytes: 20), retryAllowance: 0)
        precondition(packet.writes == 27 && packet.replyReports == 28)
        for retry in [-1.0, Double.nan, Double.infinity, 11] {
            checkThrows(.invalidEstimate) { _ = try unchanged.budget(transport: .ledAndReservedByte, retryAllowance: retry) }
        }
        checkThrows(.invalidEstimate) {
            _ = try unchanged.budget(transport: .init(requestBitsPerWrite: 0, replyBitsPerReport: 4,
                                                     requestBoundaryWrites: 2, replyBoundaryReports: 1,
                                                     requestReportBytes: 1, replyReportBytes: 8), retryAllowance: 0)
        }
        checkThrows(.invalidEstimate) {
            _ = try unchanged.budget(transport: .ledAndReservedByte, retryAllowance: 0,
                                      additionalExchanges: [.init(requestBytes: Int.max, replyBytes: 1)])
        }
        checkThrows(.invalidEstimate) {
            _ = try unchanged.budget(transport: .ledAndReservedByte, retryAllowance: 0,
                                      timing: .init(writeSeconds: 0...Double.infinity,
                                                    replyReportSeconds: 0...1, additionalPauseSeconds: nil))
        }
        print("Firmware delta planning: verified baselines, vectors, relocation, reconstruction, bounds and randomized cases passed; no hardware access")
    }
}
