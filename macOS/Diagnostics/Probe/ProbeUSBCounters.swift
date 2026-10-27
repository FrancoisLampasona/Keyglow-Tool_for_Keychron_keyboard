import Foundation

struct ProbeUSBCounters: Encodable, Sendable {
    let schema = 1
    let status = "usb_counters"
    let expectedFirmwareVerified = true
    let state: UInt8
    let abortReason: UInt8
    let responseSymbols: UInt8
    let attempts: UInt32
    let challenges: UInt32
    let reportsSubmitted: UInt32
    let completions: UInt32
    let aborts: UInt32
    let invalidFrames: UInt32

    init(response: [UInt8]) throws {
        guard response.count == 32, Array(response.prefix(4)) == [8, 0x4b, 0x50, 1],
              response[4] <= 7, response[5] <= 7, response[6] <= 26, response[7] == 0 else {
            throw VIAError.malformedResponse
        }
        func number(_ offset: Int) -> UInt32 {
            response[offset..<(offset + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        }
        state = response[4]; abortReason = response[5]; responseSymbols = response[6]
        attempts = number(8); challenges = number(12); reportsSubmitted = number(16)
        completions = number(20); aborts = number(24); invalidFrames = number(28)
    }

    static func read(expectedFirmware: String) throws -> ProbeUSBCounters {
        let devices = try VIAUSBTransport.enumerate().filter { $0.productID == 0x0861 }
        guard devices.count == 1, let device = devices.first else {
            throw VIAError.invalid("Collega una sola Q6 Max ISO via USB e seleziona Cable.")
        }
        return try VIAUSBTransport.withSession(deviceID: device.id) { try query($0, expectedFirmware: expectedFirmware) }
    }

    static func query(_ session: any VIAExchange, expectedFirmware: String) throws -> ProbeUSBCounters {
        func read(_ bytes: [UInt8]) throws -> [UInt8] {
            let packet = try VIAProtocol.packet(bytes)
            let response = try session.exchange(packet)
            try VIAProtocol.checkResponse(response, request: packet)
            return response
        }
        let version = try read([1])
        guard VIAProtocol.uint16(version, 1) == 12 else { throw VIAError.invalid("Versione VIA inattesa; lettura contatori annullata.") }
        let build = try read([0xa1]).dropFirst().prefix { $0 != 0 }
        guard !expectedFirmware.isEmpty, build.allSatisfy({ (32..<127).contains($0) }),
              String(decoding: build, as: UTF8.self) == expectedFirmware else {
            throw VIAError.invalid("Il firmware USB non corrisponde alla build diagnostica attesa; contatori non letti.")
        }
        return try ProbeUSBCounters(response: read([8, 0x4b, 0x50]))
    }
}
