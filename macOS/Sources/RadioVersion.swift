import Foundation
import IOKit
import IOKit.hid

// Reusable information query, not a flasher. No firmware updater is linked.
// Protocol evidence: Keychron Launcher module 72281,
// getBluetoothDfuVersion(), and pinned Keychron lkbt51_dfu_rx/tx().
private enum RadioFailure: Error, LocalizedError {
    case invalid(String)
    case io(String, IOReturn)
    var errorDescription: String? {
        switch self {
        case .invalid(let message): return message
        case .io(let stage, let code):
            return "\(stage): IOKit \(String(format: "0x%08X", UInt32(bitPattern: code)))."
        }
    }
}

private enum RadioWire {
    static let reportSize = 32
    // The only output command in this executable. 0x60 queries information;
    // 0x61 is a different handshake and is deliberately absent from the transport.
    static let query: [UInt8] = [0xAA, 0x55, 0x03, 0xFC, 0x01, 0x60, 0x60, 0x00] + Array(repeating: 0, count: 24)
    static func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02X", $0) }.joined() }

    static func expectedDescriptor(_ descriptor: Data) -> Bool {
        let bytes = Array(descriptor)
        var cursor = 0, size = 0, count = 0, reportID = 0, page = 0, inputs = 0, outputs = 0
        var stack: [(Int, Int, Int, Int)] = []
        while cursor < bytes.count {
            let prefix = bytes[cursor]; cursor += 1
            if prefix == 0xFE { return false }
            let length = [0, 1, 2, 4][Int(prefix & 3)]
            guard cursor + length <= bytes.count else { return false }
            var value = 0
            for index in 0..<length { value |= Int(bytes[cursor + index]) << (8 * index) }
            cursor += length
            let type = (prefix >> 2) & 3, tag = prefix >> 4
            if type == 1 {
                switch tag {
                case 0: page = value
                case 7: size = value
                case 8: reportID = value
                case 9: count = value
                case 10: stack.append((size, count, reportID, page))
                case 11:
                    guard let saved = stack.popLast() else { return false }
                    (size, count, reportID, page) = saved
                default: break
                }
            } else if type == 0 && [8, 9, 11].contains(tag) {
                guard tag != 11, reportID == 0, page == 0xFF60, size == 8, count == 32, value & 1 == 0 else { return false }
                if tag == 8 { inputs += size * count } else { outputs += size * count }
            }
        }
        return stack.isEmpty && inputs == 256 && outputs == 256
    }
}

private struct RadioVersion {
    let model: String
    let firmware: String
    let hardware: String
    let launcherFirmware: String
    let modelBytes: [UInt8]
    let firmwareBytes: [UInt8]
    let hardwareBytes: [UInt8]

    init(_ payload: [UInt8]) throws {
        guard payload.count >= 36, payload[0] == 0xA3 else { throw RadioFailure.invalid("Risposta radio incompleta o evento inatteso.") }
        func field(_ range: Range<Int>, required: Bool) throws -> (String, [UInt8]) {
            let raw = Array(payload[range])
            let bytes = Array(raw.prefix { $0 != 0 })
            guard raw.dropFirst(bytes.count).allSatisfy({ $0 == 0 }),
                  bytes.allSatisfy({ (0x20...0x7E).contains($0) }),
                  !required || !bytes.isEmpty,
                  let value = String(bytes: bytes, encoding: .ascii) else {
                throw RadioFailure.invalid("Campo versione radio non ASCII o non valido; nessun dato grezzo sconosciuto pubblicato.")
            }
            return (value, raw)
        }
        (model, modelBytes) = try field(4..<14, required: true)
        (firmware, firmwareBytes) = try field(16..<26, required: true)
        (hardware, hardwareBytes) = try field(26..<36, required: false)
        launcherFirmware = String(bytes: firmwareBytes.prefix(9).prefix { $0 != 0 }, encoding: .ascii)!
        guard firmware.utf8.contains(where: { (48...57).contains($0) }) else {
            throw RadioFailure.invalid("La risposta non contiene una versione firmware riconoscibile.")
        }
    }
}

private struct RadioReplyParser {
    private(set) var frames = 0
    private(set) var payload: [UInt8] = []
    private var targetCount: Int?
    private(set) var complete = false

    // Return true for a completed response, false for unrelated reports or partial data.
    mutating func accept(_ report: [UInt8]) throws -> Bool {
        guard report.count == RadioWire.reportSize else { throw RadioFailure.invalid("Lunghezza report input diversa da 32 byte.") }
        guard !complete else { throw RadioFailure.invalid("Report dopo risposta già completa.") }
        guard report[0] == 0x03 else { return false }
        if targetCount == nil {
            guard report[1] == 0xAA, report[2] == 0x57 else { return false }
            let length = Int(report[3])
            // QMK receives a radio packet of at most 59 bytes and strips 3 bytes.
            guard report[4] == ~report[3], (35...56).contains(length), report[6] == 0xA3 else {
                throw RadioFailure.invalid("Intestazione, evento o lunghezza della risposta radio non validi.")
            }
            targetCount = length + 1 // L excludes the event byte A3 inserted by QMK.
            payload = Array(report[6...])
        } else {
            guard !(report[1] == 0xAA && report[2] == 0x57) else {
                throw RadioFailure.invalid("Nuova intestazione prima del completamento della risposta radio.")
            }
            let remaining = targetCount! - payload.count
            payload += report[1..<(1 + min(remaining, 31))]
        }
        frames += 1
        guard frames <= 2, payload.count <= targetCount! else { throw RadioFailure.invalid("Troppi frammenti della risposta radio.") }
        complete = payload.count == targetCount!
        return complete
    }
}

private final class RadioReadSession {
    let device: IOHIDDevice
    let runLoop: CFRunLoop = CFRunLoopGetCurrent()
    let input = UnsafeMutablePointer<UInt8>.allocate(capacity: RadioWire.reportSize)
    let output = UnsafeMutablePointer<UInt8>.allocate(capacity: RadioWire.reportSize)
    var opened = false
    var scheduled = false
    var awaitingResponse = false
    var sent = false
    var outputCompleted = false
    var failure: Error?
    var parser = RadioReplyParser()

    init(_ device: IOHIDDevice) {
        self.device = device
        input.initialize(repeating: 0, count: RadioWire.reportSize)
        output.initialize(from: RadioWire.query, count: RadioWire.reportSize)
    }
    deinit {
        close()
        input.deinitialize(count: RadioWire.reportSize); input.deallocate()
        output.deinitialize(count: RadioWire.reportSize); output.deallocate()
    }
    func close() {
        awaitingResponse = false
        if opened {
            // IOKit's callback-set equality uses the registration context.
            let context = Unmanaged.passUnretained(self).toOpaque()
            IOHIDDeviceRegisterInputReportCallback(device, input, RadioWire.reportSize, nil, context)
            IOHIDDeviceRegisterRemovalCallback(device, nil, context)
            // Unscheduling aborts pending report callbacks on this same run loop;
            // the session and both buffers remain alive through cancellation.
            if scheduled { IOHIDDeviceUnscheduleFromRunLoop(device, runLoop, CFRunLoopMode.defaultMode.rawValue) }
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        opened = false; scheduled = false
    }

    func read() throws -> RadioVersion {
        guard !sent else { throw RadioFailure.invalid("Una sola query è consentita per sessione.") }
        let result = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)) // Never seize input.
        guard result == kIOReturnSuccess else { throw RadioFailure.io("Apertura HID", result) }
        opened = true
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(device, input, RadioWire.reportSize, { context, result, _, type, reportID, report, length in
            guard let context else { return }
            let session = Unmanaged<RadioReadSession>.fromOpaque(context).takeUnretainedValue()
            guard session.awaitingResponse, session.failure == nil, !session.parser.complete else { return }
            guard result == kIOReturnSuccess else { session.failure = RadioFailure.io("Ricezione HID", result); return }
            guard type == kIOHIDReportTypeInput, reportID == 0 else { return }
            guard length == RadioWire.reportSize else { session.failure = RadioFailure.invalid("Report input fuori formato."); return }
            do { _ = try session.parser.accept(Array(UnsafeBufferPointer(start: report, count: length))) }
            catch { session.failure = error }
        }, context)
        IOHIDDeviceRegisterRemovalCallback(device, { context, _, _ in
            guard let context else { return }
            Unmanaged<RadioReadSession>.fromOpaque(context).takeUnretainedValue().failure = RadioFailure.invalid("Tastiera rimossa durante la query.")
        }, context)
        IOHIDDeviceScheduleWithRunLoop(device, runLoop, CFRunLoopMode.defaultMode.rawValue)
        scheduled = true
        // Drain already queued unsolicited packets before the single request.
        CFRunLoopRunInMode(.defaultMode, 0.02, false)
        if let failure { throw failure }
        awaitingResponse = true; sent = true
        // SDK IOHIDDevice.h documents timeout in milliseconds; the independent
        // monotonic run-loop deadline also bounds reception to 3 seconds.
        let outputContext = Unmanaged.passRetained(self).toOpaque()
        let enqueue = IOHIDDeviceSetReportWithCallback(device, kIOHIDReportTypeOutput, 0, output, RadioWire.reportSize, 1000, { context, result, _, _, _, _, _ in
            guard let context else { return }
            let session = Unmanaged<RadioReadSession>.fromOpaque(context).takeRetainedValue()
            session.outputCompleted = true
            if result != kIOReturnSuccess { session.failure = RadioFailure.io("Query informativa HID", result) }
        }, outputContext)
        guard enqueue == kIOReturnSuccess else {
            Unmanaged<RadioReadSession>.fromOpaque(outputContext).release()
            throw RadioFailure.io("Accodamento query HID", enqueue)
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while ProcessInfo.processInfo.systemUptime < deadline {
            CFRunLoopRunInMode(.defaultMode, 0.005, true)
            if let failure { throw failure }
            if outputCompleted && parser.complete { return try RadioVersion(parser.payload) }
        }
        throw RadioFailure.invalid("Timeout: nessuna risposta radio completa entro 3 secondi. Nessun nuovo tentativo eseguito.")
    }
}

private func candidates() -> [IOHIDDevice] {
    let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: 0x3434, kIOHIDProductIDKey: 0x0861,
        kIOHIDPrimaryUsagePageKey: 0xFF60, kIOHIDPrimaryUsageKey: 0x61] as CFDictionary)
    var devicesByRegistryID: [UInt64: IOHIDDevice] = [:]
    for device in (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> ?? []) {
        func number(_ key: String) -> Int { (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.intValue ?? -1 }
        let transport = IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String ?? ""
        let name = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? ""
        guard number(kIOHIDVendorIDKey) == 0x3434, number(kIOHIDProductIDKey) == 0x0861,
              number(kIOHIDPrimaryUsagePageKey) == 0xFF60, number(kIOHIDPrimaryUsageKey) == 0x61,
              transport.caseInsensitiveCompare("USB") == .orderedSame, name == "Keychron Q6 Max",
              number(kIOHIDMaxInputReportSizeKey) == 32, number(kIOHIDMaxOutputReportSizeKey) == 32,
              let descriptor = IOHIDDeviceGetProperty(device, kIOHIDReportDescriptorKey as CFString) as? Data,
              RadioWire.expectedDescriptor(descriptor) else { continue }
        let service = IOHIDDeviceGetService(device)
        var registryID: UInt64 = 0
        guard service != 0, IORegistryEntryGetRegistryEntryID(service, &registryID) == KERN_SUCCESS else { continue }
        devicesByRegistryID[registryID] = device
    }
    return Array(devicesByRegistryID.values)
}

private func offlineTests() throws -> Int {
    var count = 0
    func check(_ condition: Bool, _ name: String) throws {
        guard condition else { throw RadioFailure.invalid("Self-test fallito: \(name)") }; count += 1
    }
    func rejects(_ name: String, _ block: () throws -> Void) throws {
        do { try block() } catch { count += 1; return }
        throw RadioFailure.invalid("Self-test non ha rifiutato: \(name)")
    }
    func payload(length: Int = 36, firmware: String = "0.2.4") -> [UInt8] {
        var bytes = Array(repeating: UInt8(0), count: length)
        bytes[0] = 0xA3; bytes[1] = 0x60
        for (offset, text) in [(4, "LKBT51"), (16, firmware), (26, "1.0.0")] {
            for (i, byte) in text.utf8.enumerated() { bytes[offset + i] = byte }
        }
        return bytes
    }
    func reports(_ bytes: [UInt8]) -> [[UInt8]] {
        let length = UInt8(bytes.count - 1)
        let first = [UInt8(3), 0xAA, 0x57, length, ~length, 0x47] + Array(bytes.prefix(26))
        let remaining = Array(bytes.dropFirst(26))
        return [first, [3] + remaining + Array(repeating: 0xCC, count: 31 - remaining.count)]
    }
    let request = RadioWire.query
    try check(request.count == 32 && request[5] == 0x60 && request[4] == 1, "fixed query only")
    try check(request[3] == ~request[2] && Int(request[5]) == Int(request[6]) + (Int(request[7]) << 8), "query checksum")
    var parser = RadioReplyParser()
    try check(try !parser.accept(Array(repeating: 0, count: 32)), "ignore non-radio report")
    let pair = reports(payload())
    try check(try !parser.accept(pair[0]), "first fragment remains partial")
    try check(try parser.accept(pair[1]), "final fragment completes")
    let decoded = try RadioVersion(parser.payload)
    try check(decoded.model == "LKBT51" && decoded.firmware == "0.2.4" && decoded.hardware == "1.0.0", "version fields")
    try check(parser.payload.count == 36 && parser.frames == 2, "length excludes A3 and ignores padding")
    var maximum = RadioReplyParser()
    for report in reports(payload(length: 57)) { _ = try maximum.accept(report) }
    try check(maximum.complete && maximum.payload.count == 57, "maximum radio payload")
    let ten = try RadioVersion(payload(firmware: "1234567890"))
    try check(ten.firmware == "1234567890" && ten.launcherFirmware == "123456789", "preserve tenth version byte")
    try rejects("short report") { var p = RadioReplyParser(); _ = try p.accept([3]) }
    try rejects("bad complement") { var p = RadioReplyParser(); var b = pair[0]; b[4] ^= 1; _ = try p.accept(b) }
    try rejects("oversize length") { var p = RadioReplyParser(); var b = pair[0]; b[3] = 57; b[4] = ~b[3]; _ = try p.accept(b) }
    try rejects("short declared payload") { var p = RadioReplyParser(); var b = pair[0]; b[3] = 34; b[4] = ~b[3]; _ = try p.accept(b) }
    try rejects("wrong event") { var p = RadioReplyParser(); var b = pair[0]; b[6] = 0xA1; _ = try p.accept(b) }
    try rejects("repeated header") { var p = RadioReplyParser(); _ = try p.accept(pair[0]); _ = try p.accept(pair[0]) }
    try rejects("extra fragment") { _ = try parser.accept(pair[1]) }
    try rejects("truncated payload decode") { _ = try RadioVersion(Array(payload().prefix(35))) }
    try rejects("non-ASCII version") { var p = payload(); p[16] = 0xFF; _ = try RadioVersion(p) }
    try rejects("embedded NUL followed by content") { var p = payload(); p[17] = 0; _ = try RadioVersion(p) }
    try rejects("empty firmware") { var p = payload(); p.replaceSubrange(16..<26, with: Array(repeating: 0, count: 10)); _ = try RadioVersion(p) }
    let descriptor: [UInt8] = [0x06,0x60,0xFF,0x09,0x61,0xA1,0x01,0x09,0x62,0x15,0x00,0x26,0xFF,0x00,0x75,0x08,0x95,0x20,0x81,0x02,0x09,0x63,0x91,0x02,0xC0]
    try check(RadioWire.expectedDescriptor(Data(descriptor)), "QMK raw descriptor")
    var badCount = descriptor; badCount[17] = 31
    try check(!RadioWire.expectedDescriptor(Data(badCount)), "reject report size drift")
    try check(!RadioWire.expectedDescriptor(Data([0x85, 1] + descriptor)), "reject numbered report")
    try check(!RadioWire.expectedDescriptor(Data([0xFE] + descriptor)), "reject long descriptor item")
    try check(!RadioWire.expectedDescriptor(Data([0x06])), "reject truncated descriptor")
    return count
}

// Value-only result can cross from a worker queue to the app's main actor.
struct RadioVersionResult: Sendable {
    let moduleModel: String
    let firmwareVersion: String
    let hardwareVersion: String
    let launcherFirmwareVersion: String
    let rawModelHex: String
    let rawFirmwareHex: String
    let rawHardwareHex: String
    let responseFragments: Int
}

struct RadioVersionReadError: Error, LocalizedError, Sendable {
    let message: String
    let outputRequestsAttempted: Int
    var errorDescription: String? { message }
}

enum RadioVersionReader {
    private static let sessionLock = NSLock()

    /// Performs one informational GET_DFU_VER query on the sole matching ISO USB
    /// device. Call on a worker queue from a GUI; this runs a bounded CFRunLoop.
    /// The caller must serialize it with other USB configurator operations.
    static func readUSB() throws -> RadioVersionResult {
        guard sessionLock.try() else {
            throw RadioVersionReadError(message: "Una lettura della versione radio è già in corso.", outputRequestsAttempted: 0)
        }
        defer { sessionLock.unlock() }
        var session: RadioReadSession?
        defer { session?.close() }
        do {
            // Preflight only: never call IOHIDRequestAccess or reset TCC. Avoid
            // opening a HID session that could trigger an implicit access prompt.
            guard IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted else {
                throw RadioFailure.invalid("Accesso HID non autorizzato per questo processo macOS. Nessuna richiesta di permesso e nessuna query inviata.")
            }
            let devices = candidates()
            guard devices.count == 1 else {
                throw RadioFailure.invalid(devices.isEmpty ? "Nessuna Q6 Max ISO USB 3434:0861 Raw FF60:61 compatibile. Verifica cavo e accesso macOS." : "Più Q6 Max ISO compatibili: nessun dispositivo scelto e nessuna query inviata.")
            }
            let active = RadioReadSession(devices[0]); session = active
            let version = try active.read()
            return RadioVersionResult(moduleModel: version.model, firmwareVersion: version.firmware,
                hardwareVersion: version.hardware, launcherFirmwareVersion: version.launcherFirmware,
                rawModelHex: RadioWire.hex(version.modelBytes), rawFirmwareHex: RadioWire.hex(version.firmwareBytes),
                rawHardwareHex: RadioWire.hex(version.hardwareBytes), responseFragments: active.parser.frames)
        } catch {
            throw RadioVersionReadError(message: error.localizedDescription, outputRequestsAttempted: session?.sent == true ? 1 : 0)
        }
    }

    /// Pure parsing/format checks; deliberately never enumerates or opens HID.
    static func selfTestOffline() throws -> Int { try offlineTests() }
}
