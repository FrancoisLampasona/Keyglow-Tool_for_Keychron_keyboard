// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import CryptoKit

@main
struct FirmwareAuthorizationTests {
    typealias Auth = FirmwareAuthorization

    // Deliberately public synthetic test material, never a provisioned key.
    static let sampleKey = Data(1...32)
    static let sampleNonce = Data(0xa0...0xaf)
    static let domain = Data("KEYGLOW-OTA-AUTH-V2".utf8)

    final class MemoryStore: FirmwareOwnerKeyStoring {
        private var values: [Data: FirmwareOwnerKey] = [:]
        func load(keyID: Data) throws -> FirmwareOwnerKey? {
            guard keyID.count == 16 else { throw Auth.Failure.invalidKeyID }
            return values[keyID]
        }
        func add(_ key: FirmwareOwnerKey) throws {
            guard values[key.keyID] == nil else { throw Auth.Failure.keyAlreadyStored }
            values[key.keyID] = key
        }
    }

    static func hex(_ text: String) -> Data {
        var output = Data()
        var cursor = text.startIndex
        while cursor < text.endIndex {
            let end = text.index(cursor, offsetBy: 2)
            output.append(UInt8(text[cursor..<end], radix: 16)!)
            cursor = end
        }
        return output
    }

    static func rejects(_ failure: Auth.Failure? = nil, _ action: () throws -> Void) {
        do { try action(); preconditionFailure("Expected rejection") }
        catch {
            guard let error = error as? Auth.Failure else { preconditionFailure("Unexpected error type") }
            if let failure { precondition(error == failure, "Unexpected failure category") }
        }
    }

    static func word(_ value: UInt32, into data: inout Data, at offset: Int) {
        for index in 0..<4 { data[offset + index] = UInt8(truncatingIfNeeded: value >> (8 * index)) }
    }

    static func sign(_ prefix: Data, domain: Data = domain) -> Data {
        var result = prefix
        result.append(contentsOf: HMAC<SHA256>.authenticationCode(for: domain + prefix,
                                                                  using: SymmetricKey(data: sampleKey)))
        return result
    }

    // Test-only independent CRC implementation using a generated lookup table.
    static func repairSlotCRC(_ input: Data) -> Data {
        let table: [UInt32] = (0..<256).map { index in
            var value = UInt32(index)
            for _ in 0..<8 { value = value & 1 == 1 ? (value >> 1) ^ 0xedb88320 : value >> 1 }
            return value
        }
        var crc = UInt32.max
        for byte in input.prefix(56) { crc = table[Int((crc ^ UInt32(byte)) & 255)] ^ (crc >> 8) }
        var result = input
        word(~crc, into: &result, at: 56)
        return result
    }

    static func main() throws {
        let key = try FirmwareOwnerKey(rawRepresentation: sampleKey)
        // Constants produced independently with Python hashlib/hmac/zlib.
        let expectedID = hex("ae216c2ef5247a3782c135efa279a3e4")
        let targetSHA = hex("25de0f3adb202ee035265ecf50d9e148b2d5addd4a219beac4d4e5fe82dd5afd")
        let sourceSHA = hex("745e003227303368257bc32414c71085b6883ac5190db56aba428ca7f1c6a92e")
        let expectedHMAC = hex("d4f5e0aaee3ab706a6ee1aa1183e18167f115ec20ae22e26f1b71174df57224c")
        precondition(Data(SHA256.hash(data: Data("keyglow synthetic target".utf8))) == targetSHA)
        precondition(Data(SHA256.hash(data: Data("keyglow synthetic baseline".utf8))) == sourceSHA)
        precondition(key.keyID == expectedID && domain.count == 19)

        let manifest = try Auth.Manifest(target: Auth.targetID, address: Auth.applicationAddress,
                                         length: 513, build: 0x01020304, sha256: targetSHA)
        let source = try Auth.InstalledImage(length: 1024, sha256: sourceSHA)
        let payload = try Auth.makePayload(manifest: manifest, source: source, reportedCurrentImage: source,
                                           nonce: sampleNonce, replace: false, ownerKey: key)
        precondition(payload.count == 149 && payload.suffix(32) == expectedHMAC)
        precondition(payload.prefix(16) == hex("34346108008000080102000004030201"))
        precondition(payload[48..<52] == hex("00040000"))
        precondition(payload[84..<100] == sampleNonce && payload[100..<116] == expectedID && payload[116] == 0)
        func verify(_ value: Data, current: Auth.InstalledImage = source,
                    expectedNonce: Data = sampleNonce, ownerKey: FirmwareOwnerKey = key) throws {
            _ = try Auth.verifyPayload(value, ownerKey: ownerKey, reportedCurrentImage: current, expectedNonce: expectedNonce)
        }
        let parsed = try Auth.verifyPayload(payload, ownerKey: key, reportedCurrentImage: source, expectedNonce: sampleNonce)
        precondition(parsed.manifest == manifest && parsed.source == source && !parsed.replace)
        precondition(parsed.keyID == expectedID && parsed.nonce == sampleNonce)
        var helloPrefix = hex("3434610800040000") + sourceSHA + expectedID + hex("0700000004030201")
        let helloDomain = Data("KEYGLOW-OTA-HELLO-V1".utf8)
        let helloTag = Data(HMAC<SHA256>.authenticationCode(for: helloDomain + sampleNonce + helloPrefix,
                                                           using: SymmetricKey(data: sampleKey)))
        precondition(helloTag == hex("a3bb856a035aa3117e3f31d24a84bd1b501f331d0b1a941f8e985481ec6db799"))
        let hello = helloPrefix + helloTag
        let helloID = try Auth.helloKeyID(hello)
        precondition(helloID == expectedID)
        let verifiedHello = try Auth.verifyHelloPayload(hello, ownerKey: key, expectedNonce: sampleNonce)
        precondition(verifiedHello.image == source && verifiedHello.build == 0x01020304 && verifiedHello.capabilities == 7)
        for index in hello.indices {
            var bad = hello; bad[index] ^= 1
            rejects { _ = try Auth.verifyHelloPayload(bad, ownerKey: key, expectedNonce: sampleNonce) }
        }
        rejects(.authenticationFailed) {
            _ = try Auth.verifyHelloPayload(hello, ownerKey: key, expectedNonce: Data(repeating: 0, count: 16))
        }
        rejects(.payloadLength) { _ = try Auth.helloKeyID(hello.dropLast()) }
        word(0, into: &helloPrefix, at: 0)
        let wrongTargetHello = helloPrefix + Data(HMAC<SHA256>.authenticationCode(for: helloDomain + sampleNonce + helloPrefix,
                                                                                using: SymmetricKey(data: sampleKey)))
        rejects(.wrongTarget) { _ = try Auth.verifyHelloPayload(wrongTargetHello, ownerKey: key, expectedNonce: sampleNonce) }
        let replacement = try Auth.makePayload(manifest: manifest, source: source, reportedCurrentImage: source,
                                               nonce: sampleNonce, replace: true, ownerKey: key)
        let parsedReplacement = try Auth.verifyPayload(replacement, ownerKey: key,
                                                       reportedCurrentImage: source, expectedNonce: sampleNonce)
        precondition(parsedReplacement.replace)
        for size in [0, 1, 116, 117, 148, 150, 300] {
            rejects(.payloadLength) { try verify(Data(repeating: 0, count: size)) }
        }
        for index in payload.indices {
            var corrupted = payload; corrupted[index] ^= 1
            rejects { try verify(corrupted) }
        }
        rejects(.authenticationFailed) { try verify(sign(payload.prefix(117), domain: domain + Data([0]))) }
        rejects(.authenticationFailed) { try verify(sign(payload.prefix(117), domain: Data())) }
        let wrongKey = try FirmwareOwnerKey(rawRepresentation: Data(2...33))
        rejects(.wrongKey) { try verify(payload, ownerKey: wrongKey) }
        rejects(.nonceMismatch) { try verify(payload, expectedNonce: Data(repeating: 0, count: 16)) }
        rejects(.invalidNonce) { try verify(payload, expectedNonce: Data()) }
        let differentLength = try Auth.InstalledImage(length: 1023, sha256: sourceSHA)
        let differentHash = try Auth.InstalledImage(length: 1024, sha256: targetSHA)
        for different in [differentLength, differentHash] {
            rejects(.sourceMismatch) { try verify(payload, current: different) }
            rejects(.sourceMismatch) {
                _ = try Auth.makePayload(manifest: manifest, source: source, reportedCurrentImage: different,
                                          nonce: sampleNonce, replace: false, ownerKey: key)
            }
        }
        rejects(.invalidNonce) {
            _ = try Auth.makePayload(manifest: manifest, source: source, reportedCurrentImage: source,
                                      nonce: sampleNonce + Data([0]), replace: false, ownerKey: key)
        }
        // Validly signed but noncanonical inputs must still fail validation.
        for (offset, value, failure): (Int, UInt32, Auth.Failure) in [
            (0, 0, .wrongTarget), (4, 0x08000000, .wrongAddress),
            (8, 7, .invalidImageLength), (8, UInt32.max, .invalidImageLength),
            (48, 0, .invalidImageLength), (48, 98305, .invalidImageLength)
        ] {
            var prefix = Data(payload.prefix(117)); word(value, into: &prefix, at: offset)
            rejects(failure) { try verify(sign(prefix)) }
        }
        var invalidReplace = Data(payload.prefix(117)); invalidReplace[116] = 2
        rejects(.invalidReplace) { try verify(sign(invalidReplace)) }
        for length: UInt32 in [0, 7, 98305, UInt32.max] {
            rejects(.invalidImageLength) { _ = try Auth.InstalledImage(length: length, sha256: sourceSHA) }
        }
        for length in [0, 31, 33, 128] {
            rejects(.invalidDigest) { _ = try Auth.InstalledImage(length: 8, sha256: Data(repeating: 1, count: length)) }
        }
        _ = try Auth.InstalledImage(length: 8, sha256: sourceSHA)
        _ = try Auth.InstalledImage(length: 98304, sha256: sourceSHA)

        let slot = Auth.bootstrapKeySlot(ownerKey: key)
        precondition(slot.count == 64 && slot.prefix(8) == Data("KGKY0001".utf8))
        precondition(slot[8..<40] == sampleKey && slot[40..<56] == expectedID)
        precondition(slot[56..<60] == hex("eebd8796") && slot.suffix(4) == Data(repeating: 255, count: 4))
        let parsedSlot = try Auth.parseKeySlot(slot, expectedKeyID: expectedID)
        precondition(parsedSlot.keyID == expectedID)
        for index in slot.indices {
            var corrupted = slot; corrupted[index] ^= 1
            rejects { _ = try Auth.parseKeySlot(corrupted) }
        }
        rejects(.keySlotLength) { _ = try Auth.parseKeySlot(slot.dropLast()) }
        rejects(.keySlotLength) { _ = try Auth.parseKeySlot(slot + Data([0])) }
        rejects(.invalidKeyID) { _ = try Auth.parseKeySlot(slot, expectedKeyID: Data()) }
        rejects(.wrongKey) { _ = try Auth.parseKeySlot(slot, expectedKeyID: wrongKey.keyID) }
        var wrongStoredID = slot; wrongStoredID[40] ^= 1
        rejects(.wrongKey) { _ = try Auth.parseKeySlot(repairSlotCRC(wrongStoredID)) }
        for value: UInt8 in [0, 255] {
            var invalidKey = slot
            invalidKey.replaceSubrange(8..<40, with: Data(repeating: value, count: 32))
            rejects(.invalidKey) { _ = try Auth.parseKeySlot(repairSlotCRC(invalidKey)) }
            rejects(.invalidKey) { _ = try FirmwareOwnerKey(rawRepresentation: Data(repeating: value, count: 32)) }
        }
        for length in [0, 31, 33] {
            rejects(.invalidKey) { _ = try FirmwareOwnerKey(rawRepresentation: Data(repeating: 1, count: length)) }
        }
        // Data slices may have nonzero startIndex; parsing must not assume zero.
        let slicedSlot = (Data([0, 0, 0]) + slot).dropFirst(3)
        let parsedSlicedSlot = try Auth.parseKeySlot(slicedSlot)
        precondition(parsedSlicedSlot.keyID == expectedID)
        let slicedPayload = (Data([0]) + payload).dropFirst()
        try verify(slicedPayload)

        let store: any FirmwareOwnerKeyStoring = MemoryStore()
        let missingKey = try store.load(keyID: key.keyID)
        precondition(missingKey == nil)
        try store.add(key)
        let loaded = try store.load(keyID: key.keyID)!
        precondition(loaded.keyID == expectedID)
        try verify(payload, ownerKey: loaded)
        rejects(.keyAlreadyStored) { try store.add(key) }
        let missingOtherKey = try store.load(keyID: wrongKey.keyID)
        precondition(missingOtherKey == nil)
        rejects(.invalidKeyID) { _ = try store.load(keyID: Data()) }
        precondition(String(describing: key) == "FirmwareOwnerKey(<redacted>)")
        precondition(String(reflecting: key) == "FirmwareOwnerKey(<redacted>)")
        precondition(Mirror(reflecting: key).children.isEmpty)
        print("Firmware authorization: independent HMAC/keyslot vector, canonical bounds, tampering, owner identity, source binding and in-memory store passed; no randomness, Keychain or hardware operations")
    }
}
