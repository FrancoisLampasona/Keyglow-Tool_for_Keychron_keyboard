// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import AppKit
import Combine
import UniformTypeIdentifiers
import Darwin

enum FirmwareUpdateFailure: Error, LocalizedError {
    case invalidPackage, rawBuildRequired, ownerKeyMissing, capabilityMissing
    case identityChanged, replyMismatch, deviceResult(UInt8), invalidStatus, stageMismatch
    case installationUnconfirmed, privateFileExists, storageFailure
    var errorDescription: String? {
        switch self {
        case .invalidPackage: return "Il firmware non è un’immagine valida per Q6 Max ISO con loader Keyglow. Scegli un pacchetto .kgfw verificato."
        case .rawBuildRequired: return "Per un file .bin indica il numero build usato nella compilazione. Il nome del file non basta."
        case .ownerKeyMissing: return "La chiave proprietario di questa tastiera non è nel Portachiavi. Completa la prima configurazione USB su questo Mac."
        case .capabilityMissing: return "Il controller non dichiara tutte le funzioni necessarie. Completa la prima installazione USB del firmware Keyglow."
        case .identityChanged: return "Il firmware o la tastiera sono cambiati dopo la verifica. Rileggi la tastiera prima di avviare."
        case .replyMismatch: return "La risposta non corrisponde alla richiesta. Trasferimento fermato: verifica nuovamente la sessione."
        case .deviceResult(0x80): return "La tastiera non ha autorizzato l’operazione. Verifica la chiave proprietario prima di riprovare."
        case .deviceResult(0x81): return "La batteria non soddisfa il controllo di alimentazione. Ricarica la tastiera prima di riprovare via Bluetooth."
        case .deviceResult(0x82): return "La tastiera è rimasta occupata. Rilascia tasti e manopola, poi verifica nuovamente la sessione."
        case .deviceResult(let code): return "Il controller ha rifiutato l’operazione (codice \(code)). Nessun nuovo tentativo viene avviato automaticamente."
        case .invalidStatus, .stageMismatch: return "Lo stato salvato sulla tastiera non corrisponde al file scelto. Rileggi la sessione; ricomincia solo se vuoi sostituire il trasferimento precedente."
        case .installationUnconfirmed: return "Installazione non confermata dopo il ricollegamento. Rileggi la tastiera prima di riprendere; non viene dichiarato il completamento."
        case .privateFileExists: return "Il file privato della prima configurazione esiste già e non è valido. Non è stato sostituito."
        case .storageFailure: return "Impossibile salvare i dati privati con i permessi richiesti. La chiave non viene mostrata né esportata nei log."
        }
    }
}

struct FirmwareUpdateArtifact: Sendable {
    let image: Data
    let manifest: FirmwareAuthorization.Manifest
    let fileName: String

    static func parse(_ data: Data, fileName: String, isPackage: Bool, rawBuild: UInt32? = nil) throws -> Self {
        let image: Data
        let manifest: FirmwareAuthorization.Manifest
        if isPackage {
            let bytes = Array(data)
            guard (68...(60 + FirmwareDeltaPlan.maximumImageSize)).contains(bytes.count),
                  Array(bytes.prefix(8)) == Array("KGFW0001".utf8),
                  BluetoothOTAWire.crc32(Array(bytes[0..<56])) == firmwareLE(bytes, 56) else {
                throw FirmwareUpdateFailure.invalidPackage
            }
            manifest = try .init(target: firmwareLE(bytes, 8), address: firmwareLE(bytes, 12),
                                 length: firmwareLE(bytes, 16), build: firmwareLE(bytes, 20),
                                 sha256: Data(bytes[24..<56]))
            image = Data(bytes[60...])
            guard image.count == Int(manifest.length), FirmwareDeltaPlan.sha256(image) == manifest.sha256 else {
                throw FirmwareUpdateFailure.invalidPackage
            }
        } else {
            guard let rawBuild else { throw FirmwareUpdateFailure.rawBuildRequired }
            guard data.count <= FirmwareDeltaPlan.maximumImageSize else { throw FirmwareUpdateFailure.invalidPackage }
            image = data
            manifest = try .init(target: FirmwareAuthorization.targetID, address: FirmwareAuthorization.applicationAddress,
                                 length: UInt32(data.count), build: rawBuild, sha256: FirmwareDeltaPlan.sha256(data))
        }
        // The planner independently validates relocated stack/reset vectors.
        _ = try FirmwareDeltaPlan.make(oldAppData: nil, newAppData: image, verifiedOldSHA256: nil,
                                        target: manifest.target, address: manifest.address)
        return Self(image: image, manifest: manifest, fileName: fileName)
    }
}

struct FirmwareUpdateReview: Sendable {
    let artifact: FirmwareUpdateArtifact
    let controller: FirmwareAuthorization.VerifiedHello
    let plan: FirmwareDeltaPlan
    /// A separate, read-only STATUS response. Nil means no valid staged session.
    let staging: FirmwareStagingStatus?
    var isAlreadyInstalled: Bool {
        controller.image.length == artifact.manifest.length && controller.image.sha256 == artifact.manifest.sha256 &&
            controller.build == artifact.manifest.build
    }
}

struct FirmwareStagingStatus: Equatable, Sendable {
    let manifest: FirmwareAuthorization.Manifest
    let missing: Set<Int>
    let flags: UInt8
    var chunkCount: Int { (Int(manifest.length) + 255) / 256 }
    var savedChunks: Int { chunkCount - missing.count }
    var ready: Bool { flags & 2 != 0 }
    var committed: Bool { flags & 4 != 0 }
    var installed: Bool { flags & 8 != 0 }
    var summary: String {
        if installed { return "Installazione precedente completata" }
        if committed { return "Installazione confermata, riavvio da verificare" }
        if ready { return "Immagine completa e verificata" }
        return savedChunks == 0 ? "Trasferimento preparato, nessun blocco salvato" : "Trasferimento da completare"
    }
}

struct FirmwareUpdateProgress: Sendable {
    enum Stage: Sendable { case reading, keyAccess, authorizing, status, transferring, verifying, committing, reconnecting }
    let stage: Stage
    let completedBytes: Int
    let totalBytes: Int
    var message: String {
        switch stage {
        case .reading: return "Verifico identità e firmware della tastiera…"
        case .keyAccess: return "Accedo alla chiave nel Portachiavi. Se macOS lo chiede, autorizza Keyglow nella finestra di sistema."
        case .authorizing: return "Autorizzo questo aggiornamento…"
        case .status: return "Leggo i blocchi già salvati sulla tastiera…"
        case .transferring: return "Trasferisco e verifico i blocchi mancanti…"
        case .verifying: return "Verifico l’intera immagine sul controller…"
        case .committing: return "Confermo l’installazione…"
        case .reconnecting: return "Attendo il ricollegamento e verifico il firmware installato…"
        }
    }
}

/// Synchronous worker-only coordinator. All device, key and cache access is
/// injected, allowing the complete state machine to run against offline fakes.
final class FirmwareUpdateCoordinator {
    typealias Exchange = ([UInt8], OTAUpdateCancellation) throws -> BluetoothOTAExchangeResult
    private let exchange: Exchange
    private let loadKey: (Data) throws -> FirmwareOwnerKey?
    private let baseline: (FirmwareAuthorization.InstalledImage) throws -> Data?
    private let nonce: () throws -> Data
    private let wait: (TimeInterval, OTAUpdateCancellation) throws -> Void
    private let progress: (FirmwareUpdateProgress) -> Void
    private var requestID: UInt32 = 0
    // Retained only during one explicit review/install action, including its
    // fresh authenticated HELLO checks. Never shared between user actions.
    private var actionKey: FirmwareOwnerKey?

    init(exchange: @escaping Exchange, loadKey: @escaping (Data) throws -> FirmwareOwnerKey?,
         baseline: @escaping (FirmwareAuthorization.InstalledImage) throws -> Data?,
         nonce: @escaping () throws -> Data = FirmwareAuthorization.generateTransactionNonce,
         wait: @escaping (TimeInterval, OTAUpdateCancellation) throws -> Void = { seconds, cancellation in
             let until = Date().addingTimeInterval(seconds)
             while Date() < until {
                 if cancellation.isCancelled { throw OTAChannelFailure.cancelled }
                 Thread.sleep(forTimeInterval: max(0, min(0.05, until.timeIntervalSinceNow)))
             }
         }, progress: @escaping (FirmwareUpdateProgress) -> Void = { _ in }) {
        self.exchange = exchange; self.loadKey = loadKey; self.baseline = baseline
        self.nonce = nonce; self.wait = wait; self.progress = progress
    }

    func review(_ artifact: FirmwareUpdateArtifact, cancellation: OTAUpdateCancellation) throws -> FirmwareUpdateReview {
        actionKey = nil
        defer { actionKey = nil }
        progress(.init(stage: .reading, completedBytes: 0, totalBytes: artifact.image.count))
        let controller = try hello(cancellation, totalBytes: artifact.image.count)
        guard controller.capabilities & 7 == 7 else { throw FirmwareUpdateFailure.capabilityMissing }
        progress(.init(stage: .status, completedBytes: 0, totalBytes: artifact.image.count))
        let staging = try Self.stage(transact(operation: 3, acceptedResults: [0, 2], cancellation: cancellation))
        let old = try baseline(controller.image)
        let plan = try FirmwareDeltaPlan.make(oldAppData: old, newAppData: artifact.image,
                                              verifiedOldSHA256: controller.image.sha256,
                                              target: controller.target)
        return .init(artifact: artifact, controller: controller, plan: plan, staging: staging)
    }

    func install(_ review: FirmwareUpdateReview, replace: Bool,
                 cancellation: OTAUpdateCancellation) throws -> FirmwareAuthorization.VerifiedHello {
        actionKey = nil
        defer { actionKey = nil }
        let total = review.artifact.image.count
        progress(.init(stage: .reading, completedBytes: 0, totalBytes: total))
        let fresh = try hello(cancellation, totalBytes: total)
        guard fresh == review.controller else { throw FirmwareUpdateFailure.identityChanged }
        if review.isAlreadyInstalled { return fresh }
        progress(.init(stage: .status, completedBytes: 0, totalBytes: total))
        let previous = try transact(operation: 3, acceptedResults: [0, 2], cancellation: cancellation)
        let replaceStage = try Self.replacementPolicy(previous, controller: fresh,
                                                      target: review.artifact.manifest, userReplace: replace)
        let key = try ownerKey(for: fresh.keyID, totalBytes: total)
        let auth = try FirmwareAuthorization.makePayload(manifest: review.artifact.manifest, source: fresh.image,
                                                         reportedCurrentImage: fresh.image, nonce: nonce(),
                                                         replace: replaceStage, ownerKey: key)
        progress(.init(stage: .authorizing, completedBytes: 0, totalBytes: total))
        _ = try transact(operation: 7, payload: Array(auth), cancellation: cancellation)
        progress(.init(stage: .status, completedBytes: 0, totalBytes: total))
        let status = try transact(operation: 3, cancellation: cancellation)
        let missing = try Self.missingChunks(status, manifest: review.artifact.manifest)
        var completed = review.plan.chunks.filter { !missing.contains($0.destinationOffset / 256) }.reduce(0) { $0 + $1.length }
        let operations = Self.pendingChunks(review.plan.chunks, missing: missing)
        for operation in operations {
            progress(.init(stage: .transferring, completedBytes: completed, totalBytes: total))
            switch operation.contents {
            case .copy(let source, let length):
                let payload = firmwareLEBytes(UInt32(operation.destinationOffset)) + firmwareLEBytes(UInt32(source)) + firmwareLEBytes(UInt32(length))
                _ = try transact(operation: 6, payload: payload, cancellation: cancellation)
            case .literal(let bytes):
                _ = try transact(operation: 2, payload: firmwareLEBytes(UInt32(operation.destinationOffset)) + Array(bytes), cancellation: cancellation)
            }
            completed += operation.length
        }
        progress(.init(stage: .verifying, completedBytes: completed, totalBytes: total))
        _ = try transact(operation: 4, cancellation: cancellation)
        progress(.init(stage: .committing, completedBytes: completed, totalBytes: total))
        _ = try transact(operation: 5, cancellation: cancellation)
        progress(.init(stage: .reconnecting, completedBytes: completed, totalBytes: total))
        // No mutation retries. Only a bounded fresh authenticated identity read
        // can establish installation after the COMMIT receipt and reboot.
        for attempt in 0..<3 {
            try wait(attempt == 0 ? 2 : 3, cancellation)
            do {
                let installed = try hello(cancellation, totalBytes: total)
                if installed.keyID == fresh.keyID,
                   installed.image.length == review.artifact.manifest.length,
                   installed.image.sha256 == review.artifact.manifest.sha256,
                   installed.build == review.artifact.manifest.build { return installed }
            } catch {
                if !Self.retryableRead(error) { throw error }
                // An unacknowledged device reply expires after 60 seconds.
                // Never send a new read over a possibly pending reply.
                if attempt < 2 { try wait(61, cancellation) }
            }
        }
        throw FirmwareUpdateFailure.installationUnconfirmed
    }

    private func ownerKey(for id: Data, totalBytes: Int) throws -> FirmwareOwnerKey {
        if let actionKey {
            guard actionKey.keyID == id else { throw FirmwareUpdateFailure.identityChanged }
            return actionKey
        }
        progress(.init(stage: .keyAccess, completedBytes: 0, totalBytes: totalBytes))
        guard let key = try loadKey(id) else { throw FirmwareUpdateFailure.ownerKeyMissing }
        guard key.keyID == id else { throw FirmwareAuthorization.Failure.wrongKey }
        actionKey = key
        return key
    }

    private func hello(_ cancellation: OTAUpdateCancellation, totalBytes: Int) throws -> FirmwareAuthorization.VerifiedHello {
        let challenge = try nonce()
        guard challenge.count == 16 else { throw FirmwareAuthorization.Failure.invalidNonce }
        let reply = try transact(operation: 8, payload: Array(challenge), cancellation: cancellation)
        let payload = Data(reply.payload)
        let id = try FirmwareAuthorization.helloKeyID(payload)
        let key = try ownerKey(for: id, totalBytes: totalBytes)
        return try FirmwareAuthorization.verifyHelloPayload(payload, ownerKey: key, expectedNonce: challenge)
    }

    private func transact(operation: UInt8, payload: [UInt8] = [],
                          acceptedResults: Set<UInt8> = [0],
                          cancellation: OTAUpdateCancellation) throws -> BluetoothOTAWire.Reply {
        if cancellation.isCancelled { throw OTAChannelFailure.cancelled }
        requestID &+= 1
        let frame = try BluetoothOTAWire.request(operation: operation, requestID: requestID, payload: payload)
        let result = try exchange(frame, cancellation)
        let reply = result.reply
        guard reply.operation == operation, reply.requestID == requestID, result.receiptSubmitted else {
            throw FirmwareUpdateFailure.replyMismatch
        }
        // Independently verify the compact reply's canonical fields and CRC,
        // even when an injected channel returns a typed value.
        let encoded = try BluetoothOTAWire.reply(operation: reply.operation, requestID: reply.requestID,
                                                result: reply.result, flags: reply.flags, payload: reply.payload)
        guard try BluetoothOTAWire.parseReply(encoded) == reply else { throw FirmwareUpdateFailure.replyMismatch }
        if cancellation.isCancelled { throw OTAChannelFailure.cancelled }
        guard acceptedResults.contains(reply.result) else { throw FirmwareUpdateFailure.deviceResult(reply.result) }
        if operation != 3 && operation != 8 && !reply.payload.isEmpty { throw FirmwareUpdateFailure.replyMismatch }
        return reply
    }

    private static func stage(_ reply: BluetoothOTAWire.Reply) throws -> FirmwareStagingStatus? {
        let bytes = reply.payload
        guard reply.operation == 3, [0, 2].contains(reply.result) else { throw FirmwareUpdateFailure.invalidStatus }
        if reply.result == 2 {
            guard reply.flags == 0, bytes.count == 96, bytes.allSatisfy({ $0 == 0 }) else {
                throw FirmwareUpdateFailure.invalidStatus
            }
            return nil
        }
        guard bytes.count == 96, reply.flags & 1 == 1,
              !(reply.flags & 4 != 0 && reply.flags & 2 == 0),
              !(reply.flags & 8 != 0 && reply.flags & 4 == 0) else { throw FirmwareUpdateFailure.invalidStatus }
        guard let recorded = try? FirmwareAuthorization.Manifest(target: firmwareLE(bytes, 0), address: firmwareLE(bytes, 4),
                                                                 length: firmwareLE(bytes, 8), build: firmwareLE(bytes, 12),
                                                                 sha256: Data(bytes[16..<48])) else {
            throw FirmwareUpdateFailure.invalidStatus
        }
        let count = (Int(recorded.length) + 255) / 256
        let missing = Set((0..<count).filter { bytes[48 + $0 / 8] & (1 << ($0 % 8)) != 0 })
        guard reply.flags & 2 == 0 || missing.isEmpty else { throw FirmwareUpdateFailure.invalidStatus }
        return FirmwareStagingStatus(manifest: recorded, missing: missing, flags: reply.flags)
    }

    private static func replacementPolicy(_ reply: BluetoothOTAWire.Reply,
                                           controller: FirmwareAuthorization.VerifiedHello,
                                           target: FirmwareAuthorization.Manifest, userReplace: Bool) throws -> Bool {
        guard let stage = try stage(reply) else { return false }
        if stage.installed {
            // Bootstrap and completed updates leave a durable installed stage.
            // Replace it only when every identity field agrees with the freshly
            // authenticated running controller; never infer this from a flag.
            guard stage.manifest.target == controller.target,
                  stage.manifest.address == FirmwareAuthorization.applicationAddress,
                  stage.manifest.length == controller.image.length,
                  stage.manifest.sha256 == controller.image.sha256,
                  stage.manifest.build == controller.build else { throw FirmwareUpdateFailure.stageMismatch }
            return true
        }
        if stage.committed {
            guard !userReplace, stage.manifest == target else { throw FirmwareUpdateFailure.stageMismatch }
            return false // Resume the committed target; never erase it.
        }
        if userReplace { return true }
        guard stage.manifest == target else { throw FirmwareUpdateFailure.stageMismatch }
        return false
    }

    private static func missingChunks(_ reply: BluetoothOTAWire.Reply,
                                      manifest: FirmwareAuthorization.Manifest) throws -> Set<Int> {
        guard let stage = try stage(reply), stage.manifest == manifest else { throw FirmwareUpdateFailure.stageMismatch }
        return stage.missing
    }

    static func pendingChunks(_ chunks: [FirmwareDeltaPlan.Chunk], missing: Set<Int>) -> [FirmwareDeltaPlan.Chunk] {
        var result: [FirmwareDeltaPlan.Chunk] = []
        for chunk in chunks where missing.contains(chunk.destinationOffset / 256) {
            if case .copy(let source, let length) = chunk.contents,
               let last = result.last, case .copy(let oldSource, let oldLength) = last.contents,
               last.destinationOffset + oldLength == chunk.destinationOffset, oldSource + oldLength == source,
               oldLength + length <= FirmwareDeltaPlan.maximumCopyRunSize {
                result[result.count - 1] = .init(destinationOffset: last.destinationOffset,
                                                  contents: .copy(sourceOffset: oldSource, length: oldLength + length))
            } else { result.append(chunk) }
        }
        return result
    }

    private static func retryableRead(_ error: Error) -> Bool {
        if let failure = error as? OTAChannelFailure { return [.noDevice, .disconnected, .deadline].contains(failure) }
        return (error as? BluetoothOTAWire.Failure) == .timedOut
    }
}

private func firmwareLE(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
    UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
}
private func firmwareLEBytes(_ value: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) } }

enum FirmwareUpdateFiles {
    struct Provisioning: Sendable { let keyID: Data; let slotURL: URL }
    static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Keyglow/Firmware", isDirectory: true)
    }
    static func boundedRead(_ url: URL, maximum: Int) throws -> Data {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let bytes = try file.read(upToCount: maximum + 1) ?? Data()
        guard bytes.count <= maximum else { throw FirmwareUpdateFailure.invalidPackage }
        return bytes
    }
    static func baseline(_ identity: FirmwareAuthorization.InstalledImage) -> Data? {
        let cached = root.appendingPathComponent("cache", isDirectory: true)
            .appendingPathComponent(firmwareHex(identity.sha256) + ".bin")
        let candidates = [cached, Bundle.main.url(forResource: "firmware-base", withExtension: "bin")].compactMap { $0 }
        for url in candidates {
            if let data = try? boundedRead(url, maximum: FirmwareDeltaPlan.maximumImageSize),
               data.count == Int(identity.length), FirmwareDeltaPlan.sha256(data) == identity.sha256 { return data }
        }
        return nil
    }
    static func cacheVerified(_ artifact: FirmwareUpdateArtifact) throws {
        let directory = root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try artifact.image.write(to: directory.appendingPathComponent(firmwareHex(artifact.manifest.sha256) + ".bin"), options: .atomic)
    }
    /// Called only by the explicit first-setup action. Existing valid slots are
    /// reused; neither a new owner key nor a replacement is made at startup.
    static func provisionOwnerKey() throws -> Provisioning {
        let privateDirectory = root.appendingPathComponent("private", isDirectory: true)
        let url = privateDirectory.appendingPathComponent("keyslot.bin")
        let manager = FileManager.default
        let store = KeychainFirmwareOwnerKeyStore()
        if manager.fileExists(atPath: url.path) {
            let attributes = try manager.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  let permissions = attributes[.posixPermissions] as? NSNumber,
                  permissions.intValue & 0o077 == 0,
                  let slot = try? boundedRead(url, maximum: 64),
                  let key = try? FirmwareAuthorization.parseKeySlot(slot) else {
                throw FirmwareUpdateFailure.privateFileExists
            }
            if try store.load(keyID: key.keyID) == nil { try store.add(key) }
            return Provisioning(keyID: key.keyID, slotURL: url)
        }
        try manager.createDirectory(at: privateDirectory, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        let attributes = try manager.attributesOfItem(atPath: privateDirectory.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw FirmwareUpdateFailure.storageFailure }
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: privateDirectory.path)
        let key = try FirmwareOwnerKey.generateForUserApprovedBootstrap()
        let slot = FirmwareAuthorization.bootstrapKeySlot(ownerKey: key)
        let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw FirmwareUpdateFailure.storageFailure }
        defer { Darwin.close(descriptor) }
        let written = slot.withUnsafeBytes { buffer -> Bool in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { return false }
                offset += count
            }
            return Darwin.fsync(descriptor) == 0
        }
        guard written else { throw FirmwareUpdateFailure.storageFailure }
        try store.add(key)
        return Provisioning(keyID: key.keyID, slotURL: url)
    }
}

func firmwareHex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

@MainActor
final class FirmwareUpdateModel: ObservableObject {
    enum Phase: Equatable { case idle, fileReady, reading, review, updating, paused, complete, failed }
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var artifact: FirmwareUpdateArtifact?
    @Published private(set) var review: FirmwareUpdateReview?
    @Published private(set) var message = "Scegli il firmware, verifica la tastiera e rivedi il trasferimento prima di avviare."
    @Published private(set) var progress: FirmwareUpdateProgress?
    @Published private(set) var isBusy = false
    @Published private(set) var canCancel = false
    @Published private(set) var provisioning: FirmwareUpdateFiles.Provisioning?
    @Published private(set) var pendingRawName: String?
    @Published var rawBuild = ""
    @Published var replaceUncommitted = false
    @Published var transferPause: Double = 0.08
    @Published private(set) var cooldownUntil: Date?
    var onBusyChanged: (Bool) -> Void = { _ in }
    private var pendingRaw: Data?
    private var cancellation = OTAUpdateCancellation()
    private var actionID = UUID()
    private let reviewAction: (@Sendable (FirmwareUpdateArtifact, Double, OTAUpdateCancellation) throws -> FirmwareUpdateReview)?
    private let provisioningAction: @Sendable () throws -> FirmwareUpdateFiles.Provisioning

    init(reviewAction: (@Sendable (FirmwareUpdateArtifact, Double, OTAUpdateCancellation) throws -> FirmwareUpdateReview)? = nil,
         provisioningAction: @escaping @Sendable () throws -> FirmwareUpdateFiles.Provisioning = FirmwareUpdateFiles.provisionOwnerKey) {
        self.reviewAction = reviewAction; self.provisioningAction = provisioningAction
    }

    func selectArtifact(_ value: FirmwareUpdateArtifact) {
        guard !isBusy else { return }
        artifact = value; review = nil; pendingRaw = nil; pendingRawName = nil; progress = nil
        replaceUncommitted = false; phase = .fileReady
    }

    var canStart: Bool { !isBusy && review != nil && phase == .review && review?.isAlreadyInstalled == false }
    var plannedWrites: Int? {
        try? review?.plan.budget(transport: .ledAndReservedByte, retryAllowance: 0.25,
                                additionalExchanges: reconnectAllowance).writesWithRetryAllowance
    }
    private var reconnectAllowance: [FirmwareDeltaPlan.Exchange] {
        [.init(requestBytes: 32, replyBytes: 111), .init(requestBytes: 32, replyBytes: 111)]
    }
    var hasBundledFirmware: Bool { Bundle.main.url(forResource: "firmware-update", withExtension: "kgfw") != nil }
    var estimate: String? {
        guard let plan = review?.plan,
              let base = try? plan.budget(transport: .ledAndReservedByte, retryAllowance: 0,
                                          timing: .init(writeSeconds: (transferPause + 0.026)...(transferPause + 0.041),
                                                        replyReportSeconds: 0.1...0.1, additionalPauseSeconds: nil)),
              let budget = try? plan.budget(transport: .ledAndReservedByte, retryAllowance: 0.25,
                                            additionalExchanges: reconnectAllowance,
                                            timing: .init(writeSeconds: (transferPause + 0.026)...(transferPause + 0.041),
                                                          replyReportSeconds: 0.1...0.1, additionalPauseSeconds: nil)),
              let baseTransfer = base.measuredTransportSeconds,
              let transfer = budget.measuredTransportSeconds else { return nil }
        // Lab observation: ~26ms mean / 41ms maximum write latency on short
        // trials, not a proven bound on a whole firmware transfer. Include
        // settling, reset, COPY work and two pending-reply expiry intervals.
        // Retry HELLO reads contribute only to the upper scenario.
        let low = baseTransfer.lowerBound + Double(base.exchanges) * 0.8 + 2
        let high = transfer.upperBound + Double(budget.exchanges + budget.allowedRetryExchanges) * 0.8 +
            Double(plan.copyRuns.count) * 60 + 124
        func duration(_ seconds: Double) -> String {
            let minutes = max(1, Int(ceil(seconds / 60)))
            return minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) min"
        }
        return "\(duration(low)) – \(duration(high))"
    }

    func useBundledFirmware() {
        guard !isBusy, let url = Bundle.main.url(forResource: "firmware-update", withExtension: "kgfw") else { return }
        do {
            let data = try FirmwareUpdateFiles.boundedRead(url, maximum: FirmwareDeltaPlan.maximumImageSize + 60)
            artifact = try .parse(data, fileName: url.lastPathComponent, isPackage: true)
            review = nil; pendingRaw = nil; pendingRawName = nil; progress = nil; replaceUncommitted = false
            phase = .fileReady; message = "Firmware incluso verificato localmente. Leggi la tastiera prima di avviare."
        } catch { fail(error) }
    }

    func chooseFile() {
        guard !isBusy else { return }
        let panel = NSOpenPanel()
        panel.title = "Scegli firmware Q6 Max ISO"
        panel.allowedContentTypes = [UTType(filenameExtension: "kgfw"), UTType(filenameExtension: "bin")].compactMap { $0 }
        panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try FirmwareUpdateFiles.boundedRead(url, maximum: FirmwareDeltaPlan.maximumImageSize + 60)
            artifact = nil; review = nil; progress = nil; pendingRaw = nil; pendingRawName = nil; replaceUncommitted = false
            if url.pathExtension.lowercased() == "bin" {
                pendingRaw = data; pendingRawName = url.lastPathComponent; rawBuild = ""
                phase = .fileReady; message = "Indica il numero build della compilazione per validare questo file .bin."
            } else {
                artifact = try .parse(data, fileName: url.lastPathComponent, isPackage: true)
                phase = .fileReady; message = "File verificato localmente. Ora leggi la tastiera via Bluetooth."
            }
        } catch { fail(error) }
    }

    func validateRaw() {
        guard !isBusy, let data = pendingRaw, let name = pendingRawName else { return }
        do {
            guard let build = UInt32(rawBuild.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw FirmwareUpdateFailure.rawBuildRequired
            }
            artifact = try .parse(data, fileName: name, isPackage: false, rawBuild: build)
            pendingRaw = nil; pendingRawName = nil; phase = .fileReady
            message = "Immagine e vettori verificati. Il numero build verrà confrontato dopo l’installazione."
        } catch { fail(error) }
    }

    func verifyKeyboard() {
        guard !isBusy, let artifact else { return }
        if let cooldownUntil, Date() < cooldownUntil {
            message = "Attendi la scadenza della risposta precedente prima di rileggere la tastiera."
            return
        }
        cooldownUntil = nil
        let pause = transferPause
        let action = reviewAction
        let (id, token) = begin(.reading)
        review = nil; message = "Verifico la Q6 Max via Bluetooth. Evita di digitare durante lo scambio."
        Task.detached(priority: .userInitiated) { [self] in
            let owner = self
            let result = Result {
                if let action { return try action(artifact, pause, token) }
                return try Self.worker(pause: pause) { update in
                    Task { @MainActor in
                        guard owner.actionID == id, owner.isBusy else { return }
                        owner.progress = update; owner.message = update.message
                    }
                }.review(artifact, cancellation: token)
            }
            await finishReview(result, id: id)
        }
    }

    func start() {
        guard canStart, let review else { return }
        let replace = replaceUncommitted
        let pause = transferPause
        let (id, token) = begin(.updating)
        message = "Avvio dell’aggiornamento richiesto. Non digitare durante gli scambi."
        Task.detached(priority: .userInitiated) { [self] in
            let owner = self
            let worker = Self.worker(pause: pause) { update in
                Task { @MainActor in
                    guard owner.actionID == id, owner.isBusy else { return }
                    owner.progress = update; owner.message = update.message
                }
            }
            let result = Result { try worker.install(review, replace: replace, cancellation: token) }
            if case .success = result { try? FirmwareUpdateFiles.cacheVerified(review.artifact) }
            await finishInstall(result, id: id)
        }
    }

    func cancel() {
        guard isBusy, canCancel else { return }
        cancellation.cancel()
        message = "Interruzione richiesta. Attendo la chiusura dello scambio e il ripristino degli indicatori…"
    }

    func prepareOwnerKey() {
        guard !isBusy else { return }
        review = nil
        let action = provisioningAction
        let (id, _) = begin(.reading, cancellable: false)
        message = "Preparo la chiave privata per la prima configurazione USB…"
        Task.detached(priority: .userInitiated) { [self] in
            let result = Result { try action() }
            await finishProvisioning(result, id: id)
        }
    }

    private func begin(_ phase: Phase, cancellable: Bool = true) -> (UUID, OTAUpdateCancellation) {
        actionID = UUID(); cancellation = OTAUpdateCancellation()
        self.phase = phase; isBusy = true; canCancel = cancellable; onBusyChanged(true)
        return (actionID, cancellation)
    }
    private func endBusy() { isBusy = false; canCancel = false; onBusyChanged(false) }
    private func fail(_ error: Error) {
        let requestMayHaveStarted: Bool
        if let channel = error as? OTAChannelFailure {
            switch channel {
            case .permissionDenied, .noDevice, .ambiguousDevice, .incompatibleDescriptor,
                 .openFailed, .snapshotFailed, .invalidSnapshot, .invalidInterval:
                requestMayHaveStarted = false
            default: requestMayHaveStarted = true
            }
        } else { requestMayHaveStarted = error is BluetoothOTAWire.Failure || error is OTAInputReportFailure }
        if requestMayHaveStarted {
            cooldownUntil = Date().addingTimeInterval(61)
        }
        review = nil
        phase = (error as? OTAChannelFailure) == .cancelled ? .paused : .failed
        if let auth = error as? FirmwareAuthorization.Failure {
            switch auth {
            case .authenticationFailed, .wrongKey, .nonceMismatch:
                message = "Autenticazione della tastiera non riuscita. Nessun aggiornamento autorizzato: verifica la chiave proprietario e rileggi la tastiera."
            case .keychainFailure(let status): message = "Portachiavi non disponibile (\(status)). Sblocca il Portachiavi del Mac e riprova l’azione."
            default: message = "I dati del firmware o della chiave non superano la verifica. Scegli un pacchetto valido per Q6 Max ISO."
            }
        } else { message = error.localizedDescription }
        if isBusy { endBusy() }
    }
    private func finishReview(_ result: Result<FirmwareUpdateReview, Error>, id: UUID) {
        guard id == actionID else { return }
        endBusy()
        switch result {
        case .success(let value):
            review = value; phase = .review
            message = value.isAlreadyInstalled ? "Questa immagine è già installata: identità, hash e build verificati via Bluetooth." : "Tastiera verificata. Controlla il riepilogo e avvia quando sei pronto."
        case .failure(let error): fail(error)
        }
    }
    private func finishInstall(_ result: Result<FirmwareAuthorization.VerifiedHello, Error>, id: UUID) {
        guard id == actionID else { return }
        endBusy()
        switch result {
        case .success(let installed):
            phase = .complete; review = nil
            message = "Aggiornamento completato: build \(installed.build), dimensione e SHA-256 verificati dopo il riavvio via Bluetooth."
        case .failure(let error): fail(error)
        }
    }
    private func finishProvisioning(_ result: Result<FirmwareUpdateFiles.Provisioning, Error>, id: UUID) {
        guard id == actionID else { return }
        endBusy()
        switch result {
        case .success(let value):
            provisioning = value; phase = artifact == nil ? .idle : .fileReady
            message = "Chiave privata pronta. La prima installazione del loader richiede ancora USB; questa azione non ha modificato la tastiera."
        case .failure(let error): fail(error)
        }
    }

    nonisolated private static func worker(pause: Double, progress: @escaping @Sendable (FirmwareUpdateProgress) -> Void = { _ in }) -> FirmwareUpdateCoordinator {
        FirmwareUpdateCoordinator(exchange: { frame, cancellation in
            try BluetoothOTAChannel().exchange(frame: frame, pause: pause, io: BluetoothOTAIO(), cancellation: cancellation)
        }, loadKey: { try KeychainFirmwareOwnerKeyStore().load(keyID: $0) },
           baseline: { FirmwareUpdateFiles.baseline($0) }, progress: progress)
    }
}
