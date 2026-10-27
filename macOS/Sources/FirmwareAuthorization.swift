// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import CryptoKit
import Security
import LocalAuthentication

/// A local owner's symmetric authorization key. This is not a publisher
/// signature or an anti-rollback mechanism. Never log/export its raw material.
struct FirmwareOwnerKey: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    fileprivate let material: Data
    let keyID: Data

    init(rawRepresentation: Data) throws {
        guard rawRepresentation.count == 32,
              rawRepresentation.contains(where: { $0 != 0 }),
              rawRepresentation.contains(where: { $0 != 0xff }) else {
            throw FirmwareAuthorization.Failure.invalidKey
        }
        material = Data(rawRepresentation)
        keyID = Data(SHA256.hash(data: rawRepresentation).prefix(16))
    }

    /// Call only in an explicit, user-approved first provisioning operation.
    /// Constructing the app or a key store never generates an owner key.
    static func generateForUserApprovedBootstrap() throws -> Self {
        try Self(rawRepresentation: FirmwareAuthorization.secureRandomBytes(count: 32))
    }

    var description: String { "FirmwareOwnerKey(<redacted>)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: [(label: String?, value: Any)]()) }
}

enum FirmwareAuthorization {
    static let targetID: UInt32 = 0x08613434
    static let applicationAddress: UInt32 = 0x08008000
    static let maximumImageSize: UInt32 = 98304
    static let keySlotAddress: UInt32 = 0x08003f00
    static let operation: UInt8 = 7
    static let helloOperation: UInt8 = 8
    static let payloadSize = 149
    static let keySlotSize = 64
    private static let domain = Data("KEYGLOW-OTA-AUTH-V2".utf8)
    private static let helloDomain = Data("KEYGLOW-OTA-HELLO-V1".utf8)
    private static let keySlotMagic = Data("KGKY0001".utf8)

    enum Failure: Error, Equatable {
        case invalidKey, invalidKeyID, wrongKey, wrongTarget, wrongAddress
        case invalidImageLength, invalidDigest, invalidNonce, nonceMismatch
        case sourceMismatch, payloadLength, invalidReplace, authenticationFailed
        case keySlotLength, keySlotMagic, keySlotCRC, keySlotReserved
        case keyAlreadyStored, randomFailure(Int32), keychainFailure(Int32)
    }

    struct Manifest: Equatable, Sendable {
        let target: UInt32
        let address: UInt32
        let length: UInt32
        let build: UInt32
        let sha256: Data

        init(target: UInt32, address: UInt32, length: UInt32, build: UInt32, sha256: Data) throws {
            guard target == targetID else { throw Failure.wrongTarget }
            guard address == applicationAddress else { throw Failure.wrongAddress }
            guard (8...maximumImageSize).contains(length) else { throw Failure.invalidImageLength }
            guard sha256.count == 32 else { throw Failure.invalidDigest }
            self.target = target; self.address = address; self.length = length
            self.build = build; self.sha256 = Data(sha256)
        }

        fileprivate var encoded: Data {
            var result = Data()
            for value in [target, address, length, build] { appendLE(value, to: &result) }
            result.append(sha256)
            return result
        }
    }

    /// Identity must be obtained from the selected controller, including for a
    /// literal-only update. A local cached file cannot establish this identity.
    struct InstalledImage: Equatable, Sendable {
        let length: UInt32
        let sha256: Data

        init(length: UInt32, sha256: Data) throws {
            guard (8...maximumImageSize).contains(length) else { throw Failure.invalidImageLength }
            guard sha256.count == 32 else { throw Failure.invalidDigest }
            self.length = length; self.sha256 = Data(sha256)
        }
    }

    struct VerifiedBegin: Equatable, Sendable {
        let manifest: Manifest
        let source: InstalledImage
        let nonce: Data
        let keyID: Data
        let replace: Bool
    }

    struct VerifiedHello: Equatable, Sendable {
        let target: UInt32
        let image: InstalledImage
        let keyID: Data
        let capabilities: UInt32
        let build: UInt32
    }

    /// This field is untrusted until verifyHelloPayload succeeds. Its sole use
    /// before authentication is selecting the matching local owner-key account.
    static func helloKeyID(_ payload: Data) throws -> Data {
        guard payload.count == 96 else { throw Failure.payloadLength }
        return Data(Array(payload)[40..<56])
    }

    static func verifyHelloPayload(_ payload: Data, ownerKey: FirmwareOwnerKey,
                                   expectedNonce: Data) throws -> VerifiedHello {
        guard payload.count == 96 else { throw Failure.payloadLength }
        guard expectedNonce.count == 16 else { throw Failure.invalidNonce }
        let bytes = Array(payload)
        guard Data(bytes[40..<56]) == ownerKey.keyID else { throw Failure.wrongKey }
        var authenticated = helloDomain
        authenticated.append(expectedNonce)
        authenticated.append(contentsOf: bytes[0..<64])
        guard HMAC<SHA256>.isValidAuthenticationCode(Data(bytes[64..<96]),
                                                    authenticating: authenticated,
                                                    using: SymmetricKey(data: ownerKey.material)) else {
            throw Failure.authenticationFailed
        }
        let target = readLE(bytes, 0)
        guard target == targetID else { throw Failure.wrongTarget }
        let image = try InstalledImage(length: readLE(bytes, 4), sha256: Data(bytes[8..<40]))
        return VerifiedHello(target: target, image: image, keyID: ownerKey.keyID,
                             capabilities: readLE(bytes, 56), build: readLE(bytes, 60))
    }

    /// Only call when beginning a transaction. A random nonce gives transaction
    /// uniqueness/correlation; it does not itself prevent replay or rollback.
    static func generateTransactionNonce() throws -> Data { try secureRandomBytes(count: 16) }

    static func makePayload(manifest: Manifest, source: InstalledImage,
                            reportedCurrentImage: InstalledImage, nonce: Data,
                            replace: Bool, ownerKey: FirmwareOwnerKey) throws -> Data {
        guard source == reportedCurrentImage else { throw Failure.sourceMismatch }
        guard nonce.count == 16 else { throw Failure.invalidNonce }
        var payload = manifest.encoded
        appendLE(source.length, to: &payload)
        payload.append(source.sha256)
        payload.append(nonce)
        payload.append(ownerKey.keyID)
        payload.append(replace ? 1 : 0)
        var authenticated = domain
        authenticated.append(payload)
        payload.append(contentsOf: HMAC<SHA256>.authenticationCode(for: authenticated,
                                                                  using: SymmetricKey(data: ownerKey.material)))
        return payload
    }

    /// Verifies an exact canonical payload and binds it to the expected pending
    /// transaction and the observed current controller image. Target image
    /// bytes/vectors and their final full SHA-256 must still be checked separately.
    static func verifyPayload(_ payload: Data, ownerKey: FirmwareOwnerKey,
                              reportedCurrentImage: InstalledImage, expectedNonce: Data) throws -> VerifiedBegin {
        guard payload.count == payloadSize else { throw Failure.payloadLength }
        guard expectedNonce.count == 16 else { throw Failure.invalidNonce }
        let bytes = Array(payload)
        let id = Data(bytes[100..<116])
        guard id == ownerKey.keyID else { throw Failure.wrongKey }
        var authenticated = domain
        authenticated.append(contentsOf: bytes[0..<117])
        guard HMAC<SHA256>.isValidAuthenticationCode(Data(bytes[117..<149]),
                                                    authenticating: authenticated,
                                                    using: SymmetricKey(data: ownerKey.material)) else {
            throw Failure.authenticationFailed
        }
        let manifest = try Manifest(target: readLE(bytes, 0), address: readLE(bytes, 4),
                                    length: readLE(bytes, 8), build: readLE(bytes, 12),
                                    sha256: Data(bytes[16..<48]))
        let source = try InstalledImage(length: readLE(bytes, 48), sha256: Data(bytes[52..<84]))
        guard source == reportedCurrentImage else { throw Failure.sourceMismatch }
        let nonce = Data(bytes[84..<100])
        guard nonce == expectedNonce else { throw Failure.nonceMismatch }
        guard bytes[116] <= 1 else { throw Failure.invalidReplace }
        return VerifiedBegin(manifest: manifest, source: source, nonce: nonce,
                             keyID: id, replace: bytes[116] == 1)
    }

    /// Contains a secret: only use as part of explicitly approved bootstrap
    /// provisioning. Do not attach it to diagnostics, profiles, logs or releases.
    static func bootstrapKeySlot(ownerKey: FirmwareOwnerKey) -> Data {
        var slot = keySlotMagic
        slot.append(ownerKey.material)
        slot.append(ownerKey.keyID)
        appendLE(crc32(slot), to: &slot)
        slot.append(contentsOf: repeatElement(UInt8(0xff), count: 4))
        return slot
    }

    static func parseKeySlot(_ slot: Data, expectedKeyID: Data? = nil) throws -> FirmwareOwnerKey {
        guard slot.count == keySlotSize else { throw Failure.keySlotLength }
        if let expectedKeyID, expectedKeyID.count != 16 { throw Failure.invalidKeyID }
        let bytes = Array(slot)
        guard Data(bytes[0..<8]) == keySlotMagic else { throw Failure.keySlotMagic }
        guard bytes[60..<64].allSatisfy({ $0 == 0xff }) else { throw Failure.keySlotReserved }
        guard crc32(Data(bytes[0..<56])) == readLE(bytes, 56) else { throw Failure.keySlotCRC }
        let key = try FirmwareOwnerKey(rawRepresentation: Data(bytes[8..<40]))
        guard Data(bytes[40..<56]) == key.keyID else { throw Failure.wrongKey }
        if let expectedKeyID, expectedKeyID != key.keyID { throw Failure.wrongKey }
        return key
    }

    fileprivate static func secureRandomBytes(count: Int) throws -> Data {
        var result = Data(count: count)
        let status = result.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, count, buffer.baseAddress!)
        }
        guard status == errSecSuccess else { throw Failure.randomFailure(status) }
        return result
    }

    private static func appendLE(_ value: UInt32, to data: inout Data) {
        for shift in stride(from: 0, to: 32, by: 8) { data.append(UInt8(truncatingIfNeeded: value >> shift)) }
    }

    private static func readLE(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 |
        UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var result = UInt32.max
        for byte in data {
            result ^= UInt32(byte)
            for _ in 0..<8 { result = (result >> 1) ^ (result & 1 == 1 ? 0xedb88320 : 0) }
        }
        return ~result
    }
}

protocol FirmwareOwnerKeyStoring {
    func load(keyID: Data) throws -> FirmwareOwnerKey?
    /// Add only. Never silently overwrite a different owner key.
    func add(_ key: FirmwareOwnerKey) throws
}

/// No I/O in init. These methods access only a dedicated generic-password
/// service/account pair; they do not enumerate the user's other credentials.
/// Tests use an in-memory implementation and never instantiate this store.
struct KeychainFirmwareOwnerKeyStore: FirmwareOwnerKeyStoring {
    private static let service = "local.tastiera.bluetooth-prototype.firmware-owner-key.v1"

    func load(keyID: Data) throws -> FirmwareOwnerKey? {
        var query = try Self.query(keyID: keyID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        // The caller can explain a locked/denied Keychain in its user flow;
        // a background lookup must not unexpectedly request credentials.
        let authentication = LAContext()
        authentication.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = authentication
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw FirmwareAuthorization.Failure.keychainFailure(status) }
        guard let data = result as? Data else { throw FirmwareAuthorization.Failure.invalidKey }
        let key = try FirmwareOwnerKey(rawRepresentation: data)
        guard key.keyID == keyID else { throw FirmwareAuthorization.Failure.wrongKey }
        return key
    }

    func add(_ key: FirmwareOwnerKey) throws {
        var attributes = try Self.query(keyID: key.keyID)
        attributes[kSecValueData as String] = key.material
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        attributes[kSecAttrLabel as String] = "Keyglow firmware owner key"
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem { throw FirmwareAuthorization.Failure.keyAlreadyStored }
        guard status == errSecSuccess else { throw FirmwareAuthorization.Failure.keychainFailure(status) }
    }

    private static func query(keyID: Data) throws -> [String: Any] {
        guard keyID.count == 16 else { throw FirmwareAuthorization.Failure.invalidKeyID }
        return [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: keyID.map { String(format: "%02x", $0) }.joined(),
                kSecAttrSynchronizable as String: false]
    }
}
