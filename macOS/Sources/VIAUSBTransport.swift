import Foundation
import IOKit
import IOKit.hid

/// The stock USB Raw HID channel. This class never opens Bluetooth HID devices.
/// Enumeration reads only metadata. Sessions open only through an explicit caller action.
enum VIAUSBTransport {
    private static let sessionLock = NSLock()
    private struct Candidate { let device: IOHIDDevice; let summary: VIADevice }

    static func enumerate() throws -> [VIADevice] { candidates().map(\.summary) }

    static func withSession<T>(deviceID: UInt64, _ body: (any VIAExchange) throws -> T) throws -> T {
        guard !Thread.isMainThread else { throw VIAError.onMainThread }
        guard sessionLock.try() else { throw VIAError.invalid("Un’altra operazione USB è in corso.") }
        defer { sessionLock.unlock() }
        guard let candidate = candidates().first(where: { $0.summary.id == deviceID }) else { throw VIAError.missingDevice }
        let session = Session(device: candidate.device)
        defer { session.close() }
        try session.open()
        return try body(session)
    }

    private static func candidates() -> [Candidate] {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: 0x3434, kIOHIDPrimaryUsagePageKey: 0xFF60, kIOHIDPrimaryUsageKey: 0x61] as CFDictionary)
        let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> ?? []
        var unique = [UInt64: Candidate]()
        for device in devices {
            func number(_ key: String) -> Int { (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.intValue ?? -1 }
            let productID = number(kIOHIDProductIDKey)
            let transport = IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String ?? ""
            let name = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? ""
            guard [0x0860, 0x0861].contains(productID), transport.caseInsensitiveCompare("USB") == .orderedSame,
                  name == "Keychron Q6 Max", number(kIOHIDPrimaryUsagePageKey) == 0xFF60,
                  number(kIOHIDPrimaryUsageKey) == 0x61,
                  number(kIOHIDMaxInputReportSizeKey) == 32, number(kIOHIDMaxOutputReportSizeKey) == 32,
                  let descriptor = IOHIDDeviceGetProperty(device, kIOHIDReportDescriptorKey as CFString) as? Data,
                  hasExpectedRawReport(descriptor) else { continue }
            var id: UInt64 = 0
            let service = IOHIDDeviceGetService(device)
            guard service != 0, IORegistryEntryGetRegistryEntryID(service, &id) == KERN_SUCCESS else { continue }
            unique[id] = Candidate(device: device, summary: VIADevice(id: id, name: name, transport: transport, productID: productID))
        }
        return unique.values.sorted { $0.summary.id < $1.summary.id }
    }

    static func hasExpectedRawReport(_ descriptor: Data) -> Bool {
        let bytes = Array(descriptor)
        var cursor = 0, size = 0, count = 0, reportID = 0, page = 0, inputBits = 0, outputBits = 0
        var stack: [(Int, Int, Int, Int)] = []
        while cursor < bytes.count {
            let prefix = bytes[cursor]; cursor += 1
            if prefix == 0xFE { return false }
            let length = [0, 1, 2, 4][Int(prefix & 3)]
            guard cursor + length <= bytes.count else { return false }
            var value = 0
            for index in 0..<length { value |= Int(bytes[cursor + index]) << (index * 8) }
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
            } else if type == 0 && (tag == 8 || tag == 9) {
                guard reportID == 0, page == 0xFF60, size == 8, count == 32, value & 1 == 0 else { return false }
                if tag == 8 { inputBits += size * count } else { outputBits += size * count }
            }
        }
        return inputBits == 256 && outputBits == 256
    }

    private final class Session: VIAExchange {
        private let device: IOHIDDevice
        private let runLoop: CFRunLoop
        private let input: UnsafeMutablePointer<UInt8>
        private var opened = false
        private var scheduled = false
        private var invalid = false
        private var reports: [[UInt8]] = []
        private var callbackError: IOReturn?

        init(device: IOHIDDevice) {
            self.device = device
            runLoop = CFRunLoopGetCurrent()
            input = .allocate(capacity: VIAProtocol.reportLength)
            input.initialize(repeating: 0, count: VIAProtocol.reportLength)
        }
        deinit { input.deinitialize(count: VIAProtocol.reportLength); input.deallocate() }

        func open() throws {
            let result = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
            guard result == kIOReturnSuccess else { throw VIAError.io("Apertura", result) }
            opened = true
            let context = Unmanaged.passUnretained(self).toOpaque()
            IOHIDDeviceRegisterInputReportCallback(device, input, VIAProtocol.reportLength, { context, result, _, type, reportID, report, length in
                guard let context else { return }
                let session = Unmanaged<Session>.fromOpaque(context).takeUnretainedValue()
                if result != kIOReturnSuccess { session.callbackError = result; return }
                guard type == kIOHIDReportTypeInput, reportID == 0, length == VIAProtocol.reportLength else { return }
                if session.reports.count < 128 { session.reports.append(Array(UnsafeBufferPointer(start: report, count: length))) }
            }, context)
            IOHIDDeviceScheduleWithRunLoop(device, runLoop, CFRunLoopMode.defaultMode.rawValue)
            scheduled = true
        }
        func close() {
            guard opened else { return }
            IOHIDDeviceRegisterInputReportCallback(device, input, VIAProtocol.reportLength, nil, nil)
            if scheduled { IOHIDDeviceUnscheduleFromRunLoop(device, runLoop, CFRunLoopMode.defaultMode.rawValue) }
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
            scheduled = false; opened = false; invalid = true
        }
        func exchange(_ request: [UInt8]) throws -> [UInt8] {
            guard !Thread.isMainThread, CFEqual(CFRunLoopGetCurrent(), runLoop), opened, !invalid else { throw VIAError.invalid("Sessione USB chiusa o usata dal thread errato.") }
            guard request.count == VIAProtocol.reportLength else { throw VIAError.invalid("Il report USB deve contenere esattamente 32 byte.") }
            // Discard old unsolicited reports before issuing one request at a time.
            CFRunLoopRunInMode(.defaultMode, 0.001, false)
            reports.removeAll(keepingCapacity: true)
            callbackError = nil
            let code = request.withUnsafeBufferPointer { IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0, $0.baseAddress!, $0.count) }
            guard code == kIOReturnSuccess else { invalid = true; throw VIAError.io("Invio", code) }
            let deadline = ProcessInfo.processInfo.systemUptime + 1.5
            while ProcessInfo.processInfo.systemUptime < deadline {
                CFRunLoopRunInMode(.defaultMode, 0.005, true)
                if let code = callbackError { invalid = true; throw VIAError.io("Ricezione", code) }
                while !reports.isEmpty {
                    let response = reports.removeFirst()
                    if VIAProtocol.responseMatches(response, request: request) {
                        try VIAProtocol.checkResponse(response, request: request)
                        return response
                    }
                }
            }
            invalid = true // A late reply must never satisfy the next request.
            throw VIAError.timeout(request[0])
        }
    }
}
