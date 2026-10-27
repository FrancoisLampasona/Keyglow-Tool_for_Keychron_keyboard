// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import CryptoKit

@main
struct FirmwareUpdateTests {
    static let rawKey = Data(1...32) // Public synthetic fixture, never provisioned.
    static func le(_ value: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) } }
    static func word(_ data: [UInt8], _ offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | UInt32(data[offset + $1]) << (8 * $1) }
    }
    static func image(seed: UInt8) -> Data {
        var data = Data((0..<1057).map { UInt8(truncatingIfNeeded: ($0 * 73 + Int(seed)) ^ ($0 >> 3)) })
        data.replaceSubrange(0..<8, with: le(0x20010000) + le(0x08008009))
        return data
    }
    static func artifact(_ data: Data, build: UInt32 = 9) throws -> FirmwareUpdateArtifact {
        try FirmwareUpdateArtifact.parse(data, fileName: "synthetic.bin", isPackage: false, rawBuild: build)
    }
    static func rejects(_ action: () throws -> Void) {
        do { try action(); preconditionFailure("Expected rejection") } catch {}
    }
    final class Device {
        let key: FirmwareOwnerKey
        var current: Data
        var build: UInt32 = 8
        var stage: Data?
        var manifest: FirmwareAuthorization.Manifest?
        var missing = Set<Int>()
        var ready = false
        var committed = false
        var installed = false
        var eraseCount = 0
        var replaceFlags: [Bool] = []
        var operations: [UInt8] = []
        var dataOffsets: [Int] = []
        var copyLengths: [Int] = []
        var failBefore: UInt8?
        var failAfter: UInt8?
        var failure: Error = OTAChannelFailure.disconnected
        var waits: [TimeInterval] = []
        var cancelDuringRecovery = false
        var corrupt: UInt8?
        var wrongStatus = false
        var wrongInstalledBuild = false
        var forgeHello = false
        var forgeAfterCommit = false
        var cancelAfter: UInt8?
        var typingBefore: UInt8?
        var nonceCounter: UInt8 = 1
        var keyLoads = 0
        var keyLoadFails = false
        var progressStages: [FirmwareUpdateProgress.Stage] = []
        var statusFault: Int?
        init(_ data: Data) throws { current = data; key = try FirmwareOwnerKey(rawRepresentation: rawKey) }
        func seedStage(_ image: Data, build: UInt32, committed: Bool, installed: Bool) throws {
            manifest = try artifact(image, build: build).manifest
            stage = image; missing = []; ready = committed; self.committed = committed; self.installed = installed
        }
        func identity() throws -> FirmwareAuthorization.InstalledImage {
            try .init(length: UInt32(current.count), sha256: FirmwareDeltaPlan.sha256(current))
        }
        func worker(baseline: Data? = nil, keyPresent: Bool = true) -> FirmwareUpdateCoordinator {
            FirmwareUpdateCoordinator(exchange: { [self] in try exchange($0, $1) },
                                      loadKey: { [self] id in
                                          keyLoads += 1
                                          precondition(progressStages.last == .keyAccess)
                                          if keyLoadFails { throw FirmwareAuthorization.Failure.keychainFailure(-1) }
                                          return keyPresent && id == key.keyID ? key : nil
                                      },
                                      baseline: { _ in baseline },
                                      nonce: { [self] in nonceCounter &+= 1; return Data(repeating: nonceCounter, count: 16) },
                                      wait: { [self] seconds, cancellation in
                                          waits.append(seconds)
                                          if cancelDuringRecovery && seconds == 61 { cancellation.cancel() }
                                          if cancellation.isCancelled { throw OTAChannelFailure.cancelled }
                                      },
                                      progress: { [self] in progressStages.append($0.stage) })
        }
        func exchange(_ frame: [UInt8], _ cancellation: OTAUpdateCancellation) throws -> BluetoothOTAExchangeResult {
            let request = try BluetoothOTAWire.parseRequest(frame)
            let op = request.operation; operations.append(op)
            if typingBefore == op { throw BluetoothOTAWire.Failure.inputActivity }
            if failBefore == op { throw failure }
            var payload: [UInt8] = []; var flags: UInt8 = 1; var result: UInt8 = 0
            switch op {
            case 8:
                let source = try identity()
                payload = le(FirmwareAuthorization.targetID) + le(source.length) + Array(source.sha256) + Array(key.keyID) + le(7) + le(build)
                let message = Data("KEYGLOW-OTA-HELLO-V1".utf8) + Data(request.payload) + Data(payload)
                payload += Array(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: rawKey)))
                if forgeHello { payload[95] ^= 1 }
            case 7:
                let parsed = try FirmwareAuthorization.verifyPayload(Data(request.payload), ownerKey: key,
                                                                     reportedCurrentImage: identity(),
                                                                     expectedNonce: Data(request.payload[84..<100]))
                replaceFlags.append(parsed.replace)
                var restart = stage == nil
                if let existing = manifest {
                    if existing == parsed.manifest && !parsed.replace { restart = false }
                    else if committed && !installed { result = 9 }
                    else if existing == parsed.manifest && installed { restart = false }
                    else if !parsed.replace { result = 5 }
                    else { restart = true }
                }
                if result == 0 && restart {
                    eraseCount += 1
                    stage = Data(repeating: 0xff, count: Int(parsed.manifest.length))
                    manifest = parsed.manifest
                    missing = Set(0..<((Int(parsed.manifest.length) + 255) / 256))
                    ready = false; committed = false; installed = false
                }
                flags = 1 | (ready ? 2 : 0) | (committed ? 4 : 0) | (installed ? 8 : 0)
            case 3:
                if let manifest {
                    payload = le(wrongStatus ? 0 : manifest.target) + le(manifest.address) + le(manifest.length) + le(manifest.build) + Array(manifest.sha256)
                    var bitmap = [UInt8](repeating: 0, count: 48)
                    for index in missing { bitmap[index / 8] |= 1 << (index % 8) }
                    payload += bitmap
                    flags = 1 | (ready ? 2 : 0) | (committed ? 4 : 0) | (installed ? 8 : 0)
                } else {
                    result = 2; flags = 0; payload = [UInt8](repeating: 0, count: 96)
                    if wrongStatus { payload[0] = 1 }
                }
                switch statusFault {
                case 0: payload.removeLast()
                case 1: flags = 0
                case 2: flags = 5 // Commit requires verified image.
                case 3: flags = 9 // Installed requires commit.
                case 4: flags = 3 // Verified image cannot have missing chunks.
                case 5: result = 2; flags = 0 // No-session response must be all zero.
                case 6: result = 0; flags = 1; payload = [UInt8](repeating: 0, count: 96)
                default: break
                }
            case 2:
                let offset = Int(word(request.payload, 0)); dataOffsets.append(offset)
                let data = request.payload.dropFirst(4)
                stage!.replaceSubrange(offset..<(offset + data.count), with: data)
                missing.remove(offset / 256)
            case 6:
                let destination = Int(word(request.payload, 0)), source = Int(word(request.payload, 4)), length = Int(word(request.payload, 8))
                copyLengths.append(length)
                stage!.replaceSubrange(destination..<(destination + length), with: current[source..<(source + length)])
                for index in stride(from: destination, to: destination + length, by: 256) { missing.remove(index / 256) }
            case 4:
                precondition(missing.isEmpty && FirmwareDeltaPlan.sha256(stage!) == manifest!.sha256)
                ready = true; flags = 3
            case 5:
                precondition(missing.isEmpty)
                current = stage!; build = wrongInstalledBuild ? manifest!.build + 1 : manifest!.build
                ready = true; committed = true; installed = true; flags = 7
                if forgeAfterCommit { forgeHello = true }
            default: preconditionFailure("Unexpected operation")
            }
            if failAfter == op { throw failure }
            if cancelAfter == op { cancellation.cancel() }
            let encoded = try BluetoothOTAWire.reply(operation: op, requestID: request.requestID, result: result, flags: flags, payload: payload)
            var reply = try BluetoothOTAWire.parseReply(encoded)
            if corrupt == op {
                reply = .init(operation: reply.operation, requestID: reply.requestID, result: reply.result,
                              flags: reply.flags, payload: reply.payload, crc: reply.crc ^ 1)
            }
            return .init(reply: reply, duration: 0, outputReports: 0, receiptSubmitted: true)
        }
    }

    @MainActor static func main() async throws {
        let old = image(seed: 1)
        var next = old; next[300] ^= 1
        let selected = try artifact(next)
        let device = try Device(old)
        try device.seedStage(old, build: 8, committed: true, installed: true)
        let coordinator = device.worker(baseline: old)
        let review = try coordinator.review(selected, cancellation: .init())
        precondition(review.plan.literalBytes == 256 && review.plan.copiedBytes == old.count - 256)
        precondition(device.operations == [8, 3] && device.keyLoads == 1)
        precondition(review.staging?.manifest.build == 8 && review.staging?.flags == 15)
        precondition(review.staging?.savedChunks == 5 && review.staging?.missing.isEmpty == true)
        let installed = try coordinator.install(review, replace: false, cancellation: .init())
        precondition(installed.image.sha256 == selected.manifest.sha256 && installed.build == 9)
        precondition(device.operations == [8, 3, 8, 3, 7, 3, 6, 2, 6, 4, 5, 8])
        // Review and install each load once; AUTH and post-reboot HELLO reuse
        // only the install's local key, while every HELLO remains authenticated.
        precondition(device.keyLoads == 2 && device.progressStages.filter { $0 == .keyAccess }.count == 2)
        precondition(device.replaceFlags == [true] && device.eraseCount == 1)
        precondition(device.dataOffsets == [256] && device.current == next)

        // A completed bootstrap stage is replaced only if it describes the
        // freshly authenticated running controller in every identity field.
        for field in 0..<3 {
            let stale = try Device(old)
            try stale.seedStage(old, build: 8, committed: true, installed: true)
            let original = stale.manifest!
            stale.manifest = try .init(target: original.target, address: original.address,
                                       length: field == 0 ? original.length + 1 : original.length,
                                       build: field == 1 ? 7 : original.build,
                                       sha256: field == 2 ? selected.manifest.sha256 : original.sha256)
            let worker = stale.worker(baseline: old)
            let reviewed = try worker.review(selected, cancellation: .init())
            rejects { _ = try worker.install(reviewed, replace: false, cancellation: .init()) }
            rejects { _ = try worker.install(reviewed, replace: true, cancellation: .init()) }
            precondition(!stale.operations.contains(7) && stale.eraseCount == 0)
        }
        let pendingMatch = try Device(old)
        try pendingMatch.seedStage(next, build: 9, committed: true, installed: false)
        let pendingWorker = pendingMatch.worker(baseline: old)
        let pendingReview = try pendingWorker.review(selected, cancellation: .init())
        _ = try pendingWorker.install(pendingReview, replace: false, cancellation: .init())
        precondition(pendingMatch.replaceFlags.isEmpty && pendingMatch.eraseCount == 0)
        precondition(!pendingMatch.operations.contains(2) && !pendingMatch.operations.contains(6))
        precondition(pendingMatch.operations == [8, 3, 8, 3, 4, 5, 8])
        // Only a fresh matching READY stage takes the short finalization path.
        for changedSinceReview in [false, true] {
            let complete = try Device(old)
            try complete.seedStage(next, build: 9, committed: false, installed: false)
            complete.ready = true
            let worker = complete.worker(baseline: old)
            let reviewed = try worker.review(selected, cancellation: .init())
            precondition(reviewed.hasReadyTarget)
            if changedSinceReview { complete.ready = false; complete.missing = [1] }
            _ = try worker.install(reviewed, replace: false, cancellation: .init())
            precondition(complete.operations.contains(7) == changedSinceReview)
            precondition(complete.eraseCount == 0 && complete.build == 9)
            if !changedSinceReview { precondition(complete.operations == [8, 3, 8, 3, 4, 5, 8]) }
        }
        for matching in [false, true] {
            let pending = try Device(old)
            try pending.seedStage(matching ? next : image(seed: 8), build: 9, committed: true, installed: false)
            let worker = pending.worker()
            let reviewed = try worker.review(selected, cancellation: .init())
            rejects { _ = try worker.install(reviewed, replace: true, cancellation: .init()) }
            if !matching { rejects { _ = try worker.install(reviewed, replace: false, cancellation: .init()) } }
            precondition(!pending.operations.contains(7) && pending.eraseCount == 0)
        }
        let uncommitted = try Device(old)
        try uncommitted.seedStage(old, build: 8, committed: false, installed: false)
        let uncommittedWorker = uncommitted.worker(baseline: old)
        let uncommittedReview = try uncommittedWorker.review(selected, cancellation: .init())
        rejects { _ = try uncommittedWorker.install(uncommittedReview, replace: false, cancellation: .init()) }
        precondition(uncommitted.eraseCount == 0 && uncommitted.replaceFlags.isEmpty)
        _ = try uncommittedWorker.install(uncommittedReview, replace: true, cancellation: .init())
        precondition(uncommitted.replaceFlags == [true] && uncommitted.eraseCount == 1)

        let missingBase = try Device(old)
        let literalWorker = missingBase.worker()
        let literalReview = try literalWorker.review(selected, cancellation: .init())
        precondition(literalReview.plan.literalBytes == next.count)
        precondition(literalReview.staging == nil && missingBase.operations == [8, 3])
        _ = try literalWorker.install(literalReview, replace: false, cancellation: .init())
        precondition(!missingBase.operations.contains(6))

        let forgedBase = try Device(old)
        let fallback = try forgedBase.worker(baseline: image(seed: 9)).review(selected, cancellation: .init())
        precondition(fallback.plan.literalBytes == next.count)
        let noKey = try Device(old)
        rejects { _ = try noKey.worker(keyPresent: false).review(selected, cancellation: .init()) }
        precondition(noKey.operations == [8])
        let forgedIdentity = try Device(old); forgedIdentity.forgeHello = true
        rejects { _ = try forgedIdentity.worker().review(selected, cancellation: .init()) }
        precondition(forgedIdentity.operations == [8])

        let changed = try Device(old)
        let changedWorker = changed.worker(baseline: old)
        let changedReview = try changedWorker.review(selected, cancellation: .init())
        changed.current = image(seed: 4)
        rejects { _ = try changedWorker.install(changedReview, replace: false, cancellation: .init()) }
        precondition(changed.operations == [8, 3, 8] && changed.keyLoads == 2)

        for failure: UInt8 in [7, 3, 2, 4] {
            let interrupted = try Device(old)
            let worker = interrupted.worker()
            let originalReview = try worker.review(selected, cancellation: .init())
            interrupted.failAfter = failure
            let previousOperations = interrupted.operations.filter { $0 == failure }.count
            rejects { _ = try worker.install(originalReview, replace: false, cancellation: .init()) }
            precondition(interrupted.operations.filter { $0 == failure }.count == previousOperations + 1)
            if failure != 5 { precondition(!interrupted.operations.contains(5)) }
        }
        // A COMMIT transport failure is ambiguous. Never repeat COMMIT; wait
        // out pending replies and accept only an authenticated target identity.
        for transport: OTAChannelFailure in [.restoreFailed, .disconnected, .deadline] {
            for applied in [false, true] {
                let uncertain = try Device(old)
                let worker = uncertain.worker()
                let reviewed = try worker.review(selected, cancellation: .init())
                uncertain.failure = transport
                if applied { uncertain.failAfter = 5 } else { uncertain.failBefore = 5 }
                if applied {
                    let result = try worker.install(reviewed, replace: false, cancellation: .init())
                    precondition(result.build == 9 && result.image.sha256 == selected.manifest.sha256)
                } else { rejects { _ = try worker.install(reviewed, replace: false, cancellation: .init()) } }
                precondition(uncertain.operations.filter { $0 == 5 }.count == 1)
                precondition(uncertain.waits.first == 61)
                precondition(uncertain.operations.filter { $0 == 8 }.count == (applied ? 3 : 5))
            }
        }
        for failure: Error in [BluetoothOTAWire.Failure.inputActivity, OTAChannelFailure.cancelled, FirmwareUpdateFailure.replyMismatch] {
            let halted = try Device(old); let worker = halted.worker()
            let reviewed = try worker.review(selected, cancellation: .init())
            halted.failure = failure; halted.failAfter = 5
            rejects { _ = try worker.install(reviewed, replace: false, cancellation: .init()) }
            precondition(halted.waits.isEmpty && halted.operations.filter { $0 == 8 }.count == 2)
        }
        let cancelledRecovery = try Device(old); let recoveryWorker = cancelledRecovery.worker()
        let recoveryReview = try recoveryWorker.review(selected, cancellation: .init())
        cancelledRecovery.failAfter = 5; cancelledRecovery.cancelDuringRecovery = true
        rejects { _ = try recoveryWorker.install(recoveryReview, replace: false, cancellation: .init()) }
        precondition(cancelledRecovery.waits == [61] && cancelledRecovery.operations.filter { $0 == 8 }.count == 2)
        let corrupt = try Device(old)
        let corruptWorker = corrupt.worker()
        let corruptReview = try corruptWorker.review(selected, cancellation: .init())
        corrupt.corrupt = 2
        rejects { _ = try corruptWorker.install(corruptReview, replace: false, cancellation: .init()) }
        precondition(corrupt.operations.filter { $0 == 2 }.count == 1 && !corrupt.operations.contains(4))

        let resume = try Device(old)
        let resumeWorker = resume.worker()
        let initialReview = try resumeWorker.review(selected, cancellation: .init())
        resume.failAfter = 2
        rejects { _ = try resumeWorker.install(initialReview, replace: false, cancellation: .init()) }
        precondition(resume.dataOffsets == [0])
        resume.failAfter = nil
        let resumedReview = try resumeWorker.review(selected, cancellation: .init())
        _ = try resumeWorker.install(resumedReview, replace: false, cancellation: .init())
        precondition(resume.dataOffsets == [0, 256, 512, 768, 1024])
        precondition(resume.replaceFlags == [false, false] && resume.eraseCount == 1)

        let badState = try Device(old)
        let badWorker = badState.worker(baseline: old)
        let badReview = try badWorker.review(selected, cancellation: .init())
        badState.wrongStatus = true
        rejects { _ = try badWorker.install(badReview, replace: false, cancellation: .init()) }
        precondition(!badState.operations.contains(2) && !badState.operations.contains(6))

        let wrongBuild = try Device(old)
        let wrongWorker = wrongBuild.worker(baseline: old)
        let wrongReview = try wrongWorker.review(selected, cancellation: .init())
        wrongBuild.wrongInstalledBuild = true
        rejects { _ = try wrongWorker.install(wrongReview, replace: false, cancellation: .init()) }
        precondition(wrongBuild.operations.filter { $0 == 5 }.count == 1)
        precondition(wrongBuild.operations.filter { $0 == 8 }.count == 5)
        let cancelled = OTAUpdateCancellation(); cancelled.cancel()
        let idle = try Device(old)
        rejects { _ = try idle.worker().review(selected, cancellation: cancelled) }
        precondition(idle.operations.isEmpty)
        let midCancel = try Device(old)
        let midWorker = midCancel.worker()
        let midReview = try midWorker.review(selected, cancellation: .init())
        midCancel.cancelAfter = 2
        rejects { _ = try midWorker.install(midReview, replace: false, cancellation: .init()) }
        precondition(midCancel.dataOffsets.count == 1 && !midCancel.operations.contains(4))
        let typing = try Device(old)
        let typingWorker = typing.worker()
        let typingReview = try typingWorker.review(selected, cancellation: .init())
        typing.typingBefore = 2
        rejects { _ = try typingWorker.install(typingReview, replace: false, cancellation: .init()) }
        precondition(typing.operations.filter { $0 == 2 }.count == 1 && !typing.operations.contains(4))

        let already = try Device(next); already.build = 9
        let alreadyWorker = already.worker()
        let alreadyReview = try alreadyWorker.review(selected, cancellation: .init())
        precondition(alreadyReview.isAlreadyInstalled)
        _ = try alreadyWorker.install(alreadyReview, replace: false, cancellation: .init())
        precondition(already.operations == [8, 3, 8] && already.keyLoads == 2)
        let confirmedModel = FirmwareUpdateModel(reviewAction: { _, _, _ in alreadyReview })
        confirmedModel.selectArtifact(selected); confirmedModel.verifyKeyboard()
        for _ in 0..<100 where confirmedModel.isBusy { try await Task.sleep(for: .milliseconds(10)) }
        precondition(confirmedModel.phase == .complete && !confirmedModel.canStart)

        // Read-only review distinguishes an AUTH that prepared staging from
        // an empty/previous stage without issuing AUTH again or writing blocks.
        let staged = try Device(old)
        try staged.seedStage(next, build: 9, committed: false, installed: false)
        staged.missing = [1, 3]
        let stagedReview = try staged.worker().review(selected, cancellation: .init())
        precondition(staged.operations == [8, 3] && staged.eraseCount == 0)
        precondition(stagedReview.staging?.manifest == selected.manifest)
        precondition(stagedReview.staging?.savedChunks == 3 && stagedReview.staging?.missing == [1, 3])
        precondition(stagedReview.staging?.flags == 1 && stagedReview.staging?.ready == false)
        for fault in 0...6 {
            let malformed = try Device(old)
            try malformed.seedStage(next, build: 9, committed: false, installed: false)
            malformed.missing = [0]; malformed.statusFault = fault
            rejects { _ = try malformed.worker().review(selected, cancellation: .init()) }
            precondition(malformed.operations == [8, 3] && malformed.eraseCount == 0)
        }
        let crcState = try Device(old); crcState.corrupt = 3
        rejects { _ = try crcState.worker().review(selected, cancellation: .init()) }
        precondition(crcState.operations == [8, 3])

        // Success, a malformed status, cancellation and Keychain failure all
        // end the action scope; a subsequent action must load its own key.
        let scoped = try Device(old)
        let scopedWorker = scoped.worker()
        _ = try scopedWorker.review(selected, cancellation: .init())
        _ = try scopedWorker.review(selected, cancellation: .init())
        precondition(scoped.keyLoads == 2)
        scoped.wrongStatus = true
        rejects { _ = try scopedWorker.review(selected, cancellation: .init()) }
        scoped.wrongStatus = false
        _ = try scopedWorker.review(selected, cancellation: .init())
        precondition(scoped.keyLoads == 4)
        scoped.cancelAfter = 3
        rejects { _ = try scopedWorker.review(selected, cancellation: .init()) }
        scoped.cancelAfter = nil
        _ = try scopedWorker.review(selected, cancellation: .init())
        precondition(scoped.keyLoads == 6)
        scoped.keyLoadFails = true
        rejects { _ = try scopedWorker.review(selected, cancellation: .init()) }
        scoped.keyLoadFails = false
        _ = try scopedWorker.review(selected, cancellation: .init())
        precondition(scoped.keyLoads == 8 && scoped.operations.allSatisfy { $0 == 8 || $0 == 3 })

        let forgedAgain = try Device(old)
        let forgedWorker = forgedAgain.worker()
        _ = try forgedWorker.review(selected, cancellation: .init())
        forgedAgain.forgeHello = true
        rejects { _ = try forgedWorker.review(selected, cancellation: .init()) }
        precondition(forgedAgain.keyLoads == 2 && forgedAgain.operations == [8, 3, 8])
        let forgedReboot = try Device(old)
        let rebootWorker = forgedReboot.worker()
        let rebootReview = try rebootWorker.review(selected, cancellation: .init())
        forgedReboot.forgeAfterCommit = true
        rejects { _ = try rebootWorker.install(rebootReview, replace: false, cancellation: .init()) }
        precondition(forgedReboot.keyLoads == 2)
        precondition(forgedReboot.operations.filter { $0 == 5 }.count == 1)
        precondition(forgedReboot.operations.filter { $0 == 8 }.count == 3)

        var header = Array("KGFW0001".utf8) + le(selected.manifest.target) + le(selected.manifest.address) + le(selected.manifest.length) + le(selected.manifest.build) + Array(selected.manifest.sha256)
        header += le(BluetoothOTAWire.crc32(header))
        let package = Data(header) + next
        let decoded = try FirmwareUpdateArtifact.parse(package, fileName: "synthetic.kgfw", isPackage: true)
        precondition(decoded.image == next && decoded.manifest == selected.manifest)
        for offset in [0, 8, 12, 16, 24, 56, 60, package.count - 1] {
            var bad = package; bad[offset] ^= 1
            rejects { _ = try FirmwareUpdateArtifact.parse(bad, fileName: "synthetic.kgfw", isPackage: true) }
        }
        rejects { _ = try FirmwareUpdateArtifact.parse(next, fileName: "synthetic.bin", isPackage: false) }
        let unchangedPlan = try FirmwareDeltaPlan.make(oldAppData: old, newAppData: old,
                                                       verifiedOldSHA256: FirmwareDeltaPlan.sha256(old), target: FirmwareDeltaPlan.targetID)
        let holes = FirmwareUpdateCoordinator.pendingChunks(unchangedPlan.chunks, missing: [0, 2, 3, 4])
        precondition(holes.count == 2 && holes[0].length == 256 && holes[1].length == 545)

        // Preflight failures cannot leave a reply pending on the keyboard.
        // Real transmission failures still require expiry before another read.
        for failure in [OTAChannelFailure.permissionDenied, .noDevice, .snapshotFailed, .writeFailed, .deadline] {
            let model = FirmwareUpdateModel(reviewAction: { _, _, _ in throw failure })
            model.selectArtifact(selected); model.verifyKeyboard()
            for _ in 0..<100 where model.isBusy { try await Task.sleep(for: .milliseconds(10)) }
            precondition(model.phase == .failed && !model.isBusy)
            let shouldWait = failure == .writeFailed || failure == .deadline
            precondition((model.cooldownUntil != nil) == shouldWait)
        }
        let inputFailure = OTAInputReportFailure(cause: .inputActivity, reportID: 4, byteCount: 20,
                                                operation: 6, phase: .response)
        let diagnosedModel = FirmwareUpdateModel(reviewAction: { _, _, _ in throw inputFailure })
        diagnosedModel.selectArtifact(selected); diagnosedModel.verifyKeyboard()
        for _ in 0..<100 where diagnosedModel.isBusy { try await Task.sleep(for: .milliseconds(10)) }
        precondition(diagnosedModel.phase == .failed && diagnosedModel.cooldownUntil != nil)
        precondition(diagnosedModel.message == inputFailure.localizedDescription)

        // A removed view must not orphan the global busy flag. Detached work
        // retains its model until the MainActor completion has cleared it.
        var reviewFinished = false
        weak var reviewingModel: FirmwareUpdateModel?
        do {
            let model = FirmwareUpdateModel(reviewAction: { _, _, _ in
                Thread.sleep(forTimeInterval: 0.03); return review
            })
            model.onBusyChanged = { if !$0 { reviewFinished = true } }
            model.selectArtifact(selected); model.verifyKeyboard(); reviewingModel = model
        }
        for _ in 0..<100 where !reviewFinished { try await Task.sleep(for: .milliseconds(10)) }
        precondition(reviewFinished)
        for _ in 0..<20 where reviewingModel != nil { try await Task.sleep(for: .milliseconds(10)) }
        precondition(reviewingModel == nil)
        var setupFinished = false
        weak var setupModel: FirmwareUpdateModel?
        do {
            let model = FirmwareUpdateModel(provisioningAction: {
                Thread.sleep(forTimeInterval: 0.03)
                return .init(keyID: Data(repeating: 1, count: 16), slotURL: URL(fileURLWithPath: "/tmp/synthetic-not-created/keyslot.bin"))
            })
            model.onBusyChanged = { if !$0 { setupFinished = true } }
            model.prepareOwnerKey(); precondition(!model.canCancel); setupModel = model
        }
        for _ in 0..<100 where !setupFinished { try await Task.sleep(for: .milliseconds(10)) }
        precondition(setupFinished)
        for _ in 0..<20 where setupModel != nil { try await Task.sleep(for: .milliseconds(10)) }
        precondition(setupModel == nil)
        print("Firmware workflow: package, authenticated identity, delta/literal, resume, cancellation, corruption, mutation failures and post-reboot verification passed; fake transport and synthetic key only")
    }
}
