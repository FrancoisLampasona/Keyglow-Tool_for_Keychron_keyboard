// SPDX-License-Identifier: GPL-2.0-or-later
// Bounded explicit-update session. No hardware access occurs during construction.
import Foundation
import IOKit
import IOKit.hid

private final class BluetoothOTAOperation {
    let device: IOHIDDevice
    let bytes = UnsafeMutablePointer<UInt8>.allocate(capacity: 2)
    let length = UnsafeMutablePointer<CFIndex>.allocate(capacity: 1)
    var result: IOReturn?
    var receivedLength = 0
    init(device: IOHIDDevice, mask: UInt8) {
        self.device = device
        bytes.initialize(repeating: 0, count: 2); bytes[0] = 1; bytes[1] = mask
        length.initialize(to: 2)
    }
    deinit { bytes.deinitialize(count: 2); bytes.deallocate(); length.deinitialize(count: 1); length.deallocate() }
}

final class BluetoothOTAIO: BluetoothOTAChannelIO {
    private var device: IOHIDDevice?
    private let loop: CFRunLoop = CFRunLoopGetCurrent()
    private let inputBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
    private var inputHandler: ((UInt32, UnsafeBufferPointer<UInt8>) -> Void)?
    private var removalHandler: (() -> Void)?
    private var monitoring = false
    private var monitorDeadline: TimeInterval = 0
    private(set) var transportFailures: [OTAIOFailure] = []
    var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    init() { inputBuffer.initialize(repeating: 0, count: 64) }
    deinit { close(); inputBuffer.deinitialize(count: 64); inputBuffer.deallocate() }

    func openAndSnapshot() throws -> UInt8 {
        guard IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted else { throw OTAChannelFailure.permissionDenied }
        let selected = try Self.selectDevice()
        let openStatus = IOHIDDeviceOpen(selected, IOOptionBits(kIOHIDOptionsTypeNone))
        guard openStatus == kIOReturnSuccess else {
            transportFailures.append(.init(stage: "open", code: openStatus)); throw OTAChannelFailure.openFailed
        }
        device = selected
        IOHIDDeviceScheduleWithRunLoop(selected, loop, CFRunLoopMode.defaultMode.rawValue)
        let operation = BluetoothOTAOperation(device: selected, mask: 0)
        let context = Unmanaged.passRetained(operation).toOpaque()
        let status = IOHIDDeviceGetReportWithCallback(selected, kIOHIDReportTypeOutput, 1, operation.bytes, operation.length, 500, { context, result, _, _, _, _, length in
            guard let context else { return }
            let operation = Unmanaged<BluetoothOTAOperation>.fromOpaque(context).takeRetainedValue()
            operation.receivedLength = length
            operation.result = result
        }, context)
        guard status == kIOReturnSuccess else {
            Unmanaged<BluetoothOTAOperation>.fromOpaque(context).release()
            transportFailures.append(.init(stage: "snapshot_enqueue", code: status)); throw OTAChannelFailure.snapshotFailed
        }
        pump(until: now + 1) { operation.result == nil }
        guard operation.result == kIOReturnSuccess else {
            transportFailures.append(.init(stage: operation.result == nil ? "snapshot_deadline" : "snapshot_callback", code: operation.result ?? kIOReturnTimeout))
            throw OTAChannelFailure.snapshotFailed
        }
        guard operation.receivedLength == 2, operation.bytes[0] == 1, operation.bytes[1] & 0xe0 == 0 else {
            transportFailures.append(.init(stage: "snapshot_format_length_\(operation.receivedLength)", code: kIOReturnSuccess))
            throw OTAChannelFailure.invalidSnapshot
        }
        return operation.bytes[1]
    }

    func monitor(until deadline: TimeInterval, input: @escaping (UInt32, UnsafeBufferPointer<UInt8>) -> Void, removed: @escaping () -> Void) {
        guard let device else { return }
        inputHandler = input; removalHandler = removed
        monitoring = true; monitorDeadline = min(deadline, now + 180)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(device, inputBuffer, 64, { context, result, _, type, reportID, report, length in
            guard let context else { return }
            let channel = Unmanaged<BluetoothOTAIO>.fromOpaque(context).takeUnretainedValue()
            defer { channel.inputBuffer.update(repeating: 0, count: 64) }
            guard channel.monitoring else { return }
            guard channel.now < channel.monitorDeadline else { channel.stopMonitoring(); return }
            guard result == kIOReturnSuccess else {
                if channel.transportFailures.count < 8 { channel.transportFailures.append(.init(stage: "input_callback", code: result)) }
                channel.removalHandler?(); return
            }
            guard type == kIOHIDReportTypeInput else { return }
            guard length >= 0, length <= 64 else {
                channel.inputHandler?(1, UnsafeBufferPointer(start: channel.inputBuffer, count: 0)); return
            }
            channel.inputHandler?(reportID, UnsafeBufferPointer(start: report, count: length))
        }, context)
        IOHIDDeviceRegisterRemovalCallback(device, { context, _, _ in
            guard let context else { return }
            let channel = Unmanaged<BluetoothOTAIO>.fromOpaque(context).takeUnretainedValue()
            if channel.monitoring { channel.removalHandler?() }
        }, context)
    }

    func stopMonitoring() {
        guard let device, monitoring else { return }
        monitoring = false
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(device, inputBuffer, 64, nil, context)
        IOHIDDeviceRegisterRemovalCallback(device, nil, context)
        inputHandler = nil; removalHandler = nil
        inputBuffer.update(repeating: 0, count: 64)
    }

    func writeLED(_ mask: UInt8, deadline: TimeInterval) throws {
        guard let device, now < deadline, mask & 0xe0 == 0 else { throw OTAChannelFailure.writeFailed }
        let operation = BluetoothOTAOperation(device: device, mask: mask)
        let context = Unmanaged.passRetained(operation).toOpaque()
        // Numbered IOKit reports include the ID in their buffer. SDK timeout is milliseconds.
        let timeout = max(1, min(500, (deadline - now) * 1000))
        let status = IOHIDDeviceSetReportWithCallback(device, kIOHIDReportTypeOutput, 1, operation.bytes, 2, timeout, { context, result, _, _, _, _, _ in
            guard let context else { return }
            let operation = Unmanaged<BluetoothOTAOperation>.fromOpaque(context).takeRetainedValue()
            operation.result = result
        }, context)
        guard status == kIOReturnSuccess else {
            Unmanaged<BluetoothOTAOperation>.fromOpaque(context).release()
            transportFailures.append(.init(stage: "write_enqueue", code: status)); throw OTAChannelFailure.writeFailed
        }
        pump(until: min(deadline, now + 0.75)) { operation.result == nil }
        guard operation.result == kIOReturnSuccess else {
            transportFailures.append(.init(stage: operation.result == nil ? "write_deadline" : "write_callback", code: operation.result ?? kIOReturnTimeout))
            throw OTAChannelFailure.writeFailed
        }
        // The callback owns the operation until IOKit completes, including on timeout.
        // Thus a delayed callback never accesses a freed output buffer.
    }

    func pump(until deadline: TimeInterval, keepRunning: () -> Bool) {
        while now < deadline && keepRunning() {
            if monitoring && now >= monitorDeadline { stopMonitoring() }
            CFRunLoopRunInMode(.defaultMode, min(0.005, deadline - now), true)
        }
    }

    func close() {
        stopMonitoring()
        guard let device else { return }
        IOHIDDeviceUnscheduleFromRunLoop(device, loop, CFRunLoopMode.defaultMode.rawValue)
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        self.device = nil
    }

    private static func selectDevice() throws -> IOHIDDevice {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: 0x3434, kIOHIDProductIDKey: 0x0861,
            kIOHIDPrimaryUsagePageKey: 1, kIOHIDPrimaryUsageKey: 6] as CFDictionary)
        var devices: [UInt64: IOHIDDevice] = [:]
        for device in (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> ?? []) {
            func number(_ key: String) -> Int { (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.intValue ?? -1 }
            let transport = IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String ?? ""
            let name = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? ""
            guard number(kIOHIDVendorIDKey) == 0x3434, number(kIOHIDProductIDKey) == 0x0861,
                  number(kIOHIDPrimaryUsagePageKey) == 1, number(kIOHIDPrimaryUsageKey) == 6,
                  transport.lowercased().contains("bluetooth"), name == "Keychron Q6 Max" else { continue }
            var entry: UInt64 = 0
            let service = IOHIDDeviceGetService(device)
            guard service != 0, IORegistryEntryGetRegistryEntryID(service, &entry) == KERN_SUCCESS else { continue }
            devices[entry] = device
        }
        guard !devices.isEmpty else { throw OTAChannelFailure.noDevice }
        guard devices.count == 1, let device = devices.values.first else { throw OTAChannelFailure.ambiguousDevice }
        let maximumInput = (IOHIDDeviceGetProperty(device, kIOHIDMaxInputReportSizeKey as CFString) as? NSNumber)?.intValue ?? 0
        guard let descriptor = IOHIDDeviceGetProperty(device, kIOHIDReportDescriptorKey as CFString) as? Data,
              HIDTransport.hasExpectedLEDOutput(descriptor),
              (21...64).contains(maximumInput) else {
            throw OTAChannelFailure.incompatibleDescriptor
        }
        return device
    }
}
