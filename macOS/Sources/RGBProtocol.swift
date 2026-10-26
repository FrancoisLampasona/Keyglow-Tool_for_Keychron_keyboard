import Foundation

/// Experimental protocol shared with firmware/; this is not Keychron's stock protocol.
enum RGBProtocol {
    static let interval: TimeInterval = 0.080

    enum PacketError: LocalizedError {
        case unsupportedEffect
        var errorDescription: String? { "Via Bluetooth sono disponibili spegnimento e 22 effetti. RGB per tasto e Mix richiedono ancora USB." }
    }

    static func crc16(_ bytes: [UInt8]) -> UInt16 {
        var crc: UInt16 = 0xffff
        for byte in bytes {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 {
                crc = (crc & 0x8000) != 0 ? (crc &<< 1) ^ 0x1021 : crc &<< 1
            }
        }
        return crc
    }

    static func packet(hue: UInt8, saturation: UInt8, value: UInt8, off: Bool = false) -> [UInt8] {
        var bytes: [UInt8] = [0x4b, 0x52, 0x47, 0x42, 1, off ? 2 : 1,
                              off ? 0 : hue, off ? 0 : saturation, off ? 0 : value]
        let crc = crc16(bytes)
        bytes += [UInt8(crc >> 8), UInt8(crc & 0xff)]
        return bytes
    }

    /// v2 uses the explicitly mapped effect IDs in qmk_rgb_ble_bridge.c.
    /// An off packet has a canonical zero payload, independent of the draft.
    static func statePacket(effect: Int, hue: UInt8, saturation: UInt8, value: UInt8, speed: UInt8) throws -> [UInt8] {
        try encodeState(version: 2, command: 3, effect: effect, hue: hue, saturation: saturation, value: value, speed: speed)
    }

    /// v3 is accepted without physical arming by firmware Tastiera 0.6.
    /// Persistence is a distinct command; v1/v2 can never request an EEPROM write.
    static func directStatePacket(effect: Int, hue: UInt8, saturation: UInt8, value: UInt8, speed: UInt8, save: Bool) throws -> [UInt8] {
        try encodeState(version: 3, command: save ? 4 : 3, effect: effect, hue: hue, saturation: saturation, value: value, speed: speed)
    }

    private static func encodeState(version: UInt8, command: UInt8, effect: Int, hue: UInt8, saturation: UInt8, value: UInt8, speed: UInt8) throws -> [UInt8] {
        guard (0...22).contains(effect) else { throw PacketError.unsupportedEffect }
        var bytes: [UInt8] = [0x4b, 0x52, 0x47, 0x42, version, command, UInt8(effect),
                             effect == 0 ? 0 : hue, effect == 0 ? 0 : saturation,
                             effect == 0 ? 0 : value, effect == 0 ? 0 : speed]
        let crc = crc16(bytes)
        bytes += [UInt8(crc >> 8), UInt8(crc & 0xff)]
        return bytes
    }

    /// Validate before opening HID: reject truncated, reordered or arbitrary
    /// masks, while retaining compatibility with the original v1 decoder.
    static func validMasks(_ masks: [UInt8]) -> Bool {
        guard [45, 53].contains(masks.count), masks.first == 0 else { return false }
        var bytes: [UInt8] = []; var byte: UInt8 = 0
        for (index, mask) in masks.dropFirst().enumerated() {
            guard mask <= 7, mask & 4 == (index % 2 == 0 ? 4 : 0) else { return false }
            byte = (byte << 2) | (mask & 3)
            if index % 4 == 3 { bytes.append(byte); byte = 0 }
        }
        guard Array(bytes.prefix(4)) == [0x4b, 0x52, 0x47, 0x42],
              crc16(Array(bytes.dropLast(2))) == (UInt16(bytes[bytes.count - 2]) << 8 | UInt16(bytes.last!)) else { return false }
        if bytes.count == 11, bytes[4] == 1 {
            return bytes[5] == 1 || (bytes[5] == 2 && bytes[6...8].allSatisfy { $0 == 0 })
        }
        let validCommand = (bytes[4] == 2 && bytes[5] == 3) ||
            (bytes[4] == 3 && [UInt8(3), 4].contains(bytes[5]))
        return bytes.count == 13 && validCommand && bytes[6] <= 22
            && (bytes[6] != 0 || bytes[7...10].allSatisfy { $0 == 0 })
    }

    /// First mask establishes clock low; remaining masks carry 2 bits per edge.
    /// The transport must preserve the other LED bits and restore the original mask.
    static func masks(for packet: [UInt8]) -> [UInt8] {
        var result: [UInt8] = [0]
        var clock: UInt8 = 4
        for byte in packet {
            for shift in stride(from: 6, through: 0, by: -2) {
                result.append(((byte >> shift) & 3) | clock)
                clock ^= 4
            }
        }
        return result
    }
}
