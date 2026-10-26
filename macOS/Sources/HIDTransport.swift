import Foundation
import IOKit
import IOKit.hid

/// Metadata only. No input report callbacks, key capture, or device open is used
/// by enumeration. registryID is an ephemeral IOKit entry ID, not a serial/MAC.
struct HIDDeviceSummary: Codable, Sendable {
    let registryID: UInt64
    let productName: String
    let productID: Int
    let transport: String
    let supportsExpectedLEDReport: Bool
}

/// A successful IOHID write is not an acknowledgement from the custom firmware.
struct HIDSendReceipt: Sendable {
    let device: HIDDeviceSummary
    let symbolsSubmitted: Int
    let originalLEDMask: UInt8
    let restorationReportAccepted: Bool
}

enum HIDTransportError: LocalizedError, Sendable {
    case invalidFrame
    case invalidInterval
    case busy
    case noBluetoothKeyboard
    case ambiguousDevices(Int)
    case selectedDeviceMissing
    case incompatibleDescriptor
    case accessNotGranted
    case openFailed(Int32)
    case snapshotFailed(Int32)
    case invalidSnapshot
    case sendFailedRestored(String)
    case restorationFailed(transferError: String?, status: Int32)
    case writeFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .invalidFrame:
            return "Pacchetto non valido: sono ammessi soltanto simboli LED da 0 a 7 e una baseline iniziale 0."
        case .invalidInterval:
            return "Intervallo non valido: il prototipo richiede da 50 a 200 ms per simbolo."
        case .busy:
            return "Un invio è già in corso."
        case .noBluetoothKeyboard:
            return "Nessuna Keychron Q6 Max Bluetooth rilevata. Controlla collegamento e selettore BT."
        case .ambiguousDevices(let count):
            return "Rilevate \(count) Q6 Max Bluetooth: seleziona esplicitamente la tastiera."
        case .selectedDeviceMissing:
            return "La tastiera selezionata non è più collegata. Aggiorna l'elenco."
        case .incompatibleDescriptor:
            return "Il report LED Bluetooth non corrisponde al formato verificato. Nessun comando inviato."
        case .accessNotGranted:
            return "L'accesso HID non è autorizzato da macOS (Monitoraggio input). Nessun comando inviato e nessuna autorizzazione richiesta automaticamente."
        case .openFailed(let code):
            return "macOS non consente l'apertura della tastiera (\(Self.hex(code))). Nessun comando inviato."
        case .snapshotFailed(let code):
            return "Non posso leggere lo stato iniziale dei LED (\(Self.hex(code))). Invio annullato per non perdere lo stato degli indicatori."
        case .invalidSnapshot:
            return "La lettura LED ha restituito un formato inatteso. Nessun comando inviato."
        case .sendFailedRestored(let reason):
            return "Invio interrotto: \(reason). macOS ha accettato il report di ripristino degli indicatori; il colore non è confermato."
        case .restorationFailed(let transferError, let status):
            let prefix = transferError.map { "Invio interrotto: \($0). " } ?? "Pacchetto inviato, ma "
            return prefix + "ripristino degli indicatori non confermato (\(Self.hex(status))). Ricollega la tastiera prima di riprovare."
        case .writeFailed(let code):
            return "scrittura HID rifiutata (\(Self.hex(code)))"
        }
    }

    private static func hex(_ code: Int32) -> String {
        String(format: "0x%08X", UInt32(bitPattern: code))
    }
}

/// Experimental LED carrier for the matching custom firmware only.
/// Never used automatically at launch, discovery, or colour selection.
/// `masks` includes the initial zero baseline and already encoded clock/data.
final class HIDTransport: @unchecked Sendable {
    private let queue = DispatchQueue(label: "local.tastiera.ble-output", qos: .userInitiated)
    private let lock = NSLock()
    private var sending = false

    private struct Candidate {
        let device: IOHIDDevice
        let summary: HIDDeviceSummary
    }

    static func enumerate() throws -> [HIDDeviceSummary] {
        candidates().map(\.summary)
    }

    /// Optional read-only preflight. Does not request OS permission or register
    /// input callbacks; opens non-exclusively and only reads output report 1.
    static func readLEDState(deviceID: UInt64? = nil) throws -> UInt8 {
        let selected = try selectCandidate(deviceID: deviceID)
        guard IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted else {
            throw HIDTransportError.accessNotGranted
        }
        let device = selected.device
        let status = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard status == kIOReturnSuccess else { throw HIDTransportError.openFailed(status) }
        defer { IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone)) }
        return try readLEDReport(device)
    }

    /// Callbacks are delivered on the main queue. Only this explicit method
    /// opens a device or writes output reports. It never seizes the keyboard.
    func send(
        masks: [UInt8],
        interval: TimeInterval = 0.08,
        deviceID: UInt64? = nil,
        progress: @escaping @Sendable (Int, Int) -> Void,
        completion: @escaping @Sendable (Result<HIDSendReceipt, Error>) -> Void
    ) {
        lock.lock()
        if sending {
            lock.unlock()
            DispatchQueue.main.async { completion(.failure(HIDTransportError.busy)) }
            return
        }
        sending = true
        lock.unlock()
        queue.async { [self] in
            let result: Result<HIDSendReceipt, Error>
            do {
                result = .success(try Self.performSend(masks: masks, interval: interval, deviceID: deviceID) { done, total in
                    DispatchQueue.main.async { progress(done, total) }
                })
            } catch {
                result = .failure(error)
            }
            lock.lock()
            sending = false
            lock.unlock()
            DispatchQueue.main.async { completion(result) }
        }
    }

    private static func candidates() -> [Candidate] {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: 0x3434] as CFDictionary)
        // CopyDevices discovers matching devices without IOHIDManagerOpen.
        let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> ?? []
        var unique: [UInt64: Candidate] = [:]
        for device in devices {
            let productID = number(device, kIOHIDProductIDKey)
            let name = string(device, kIOHIDProductKey)
            let transport = string(device, kIOHIDTransportKey)
            guard [0x0860, 0x0861].contains(productID),
                  name == "Keychron Q6 Max",
                  transport.lowercased().contains("bluetooth"),
                  number(device, kIOHIDPrimaryUsagePageKey) == 1,
                  number(device, kIOHIDPrimaryUsageKey) == 6 else { continue }
            var registryID: UInt64 = 0
            let service = IOHIDDeviceGetService(device)
            guard service != 0,
                  IORegistryEntryGetRegistryEntryID(service, &registryID) == KERN_SUCCESS else { continue }
            let descriptor = IOHIDDeviceGetProperty(device, kIOHIDReportDescriptorKey as CFString) as? Data
            let valid = descriptor.map(hasExpectedLEDOutput) ?? false
            let summary = HIDDeviceSummary(registryID: registryID, productName: name, productID: productID,
                                           transport: transport, supportsExpectedLEDReport: valid)
            unique[registryID] = Candidate(device: device, summary: summary)
        }
        return unique.values.sorted { $0.summary.registryID < $1.summary.registryID }
    }

    private static func number(_ device: IOHIDDevice, _ key: String) -> Int {
        (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.intValue ?? -1
    }

    private static func string(_ device: IOHIDDevice, _ key: String) -> String {
        IOHIDDeviceGetProperty(device, key as CFString) as? String ?? ""
    }

    private static func performSend(
        masks: [UInt8], interval: TimeInterval, deviceID: UInt64?, progress: (Int, Int) -> Void
    ) throws -> HIDSendReceipt {
        guard RGBProtocol.validMasks(masks) else {
            throw HIDTransportError.invalidFrame
        }
        guard interval.isFinite, (0.05...0.2).contains(interval) else {
            throw HIDTransportError.invalidInterval
        }
        let selected = try selectCandidate(deviceID: deviceID)
        guard IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted else {
            throw HIDTransportError.accessNotGranted
        }
        let device = selected.device
        let status = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard status == kIOReturnSuccess else { throw HIDTransportError.openFailed(status) }
        defer { IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone)) }

        // Require a real successful read. A cached element value or a guessed
        // Caps Lock state is not a sufficient basis for restoring all LEDs.
        let original = try readLEDReport(device)

        var transferError: Error?
        do {
            for (index, mask) in masks.enumerated() {
                // Preserve Compose/Kana. Data and strobe use only Num/Caps/Scroll.
                let payload = (original & 0x18) | mask
                let code = writeLEDReport(device, payload: payload)
                guard code == kIOReturnSuccess else { throw HIDTransportError.writeFailed(code) }
                progress(index + 1, masks.count)
                // Also wait after the final symbol so restore does not overwrite it
                // before the radio/QMK polling loop has consumed it.
                Thread.sleep(forTimeInterval: interval)
            }
        } catch {
            transferError = error
        }
        // Attempt even after a failed first write: failed writes may have partial
        // effects. Do not conceal a second failure during restoration.
        let restoreStatus = writeLEDReport(device, payload: original)
        guard restoreStatus == kIOReturnSuccess else {
            throw HIDTransportError.restorationFailed(transferError: transferError?.localizedDescription, status: restoreStatus)
        }
        if let transferError {
            throw HIDTransportError.sendFailedRestored(transferError.localizedDescription)
        }
        return HIDSendReceipt(device: selected.summary, symbolsSubmitted: masks.count - 1,
                              originalLEDMask: original, restorationReportAccepted: true)
    }

    private static func selectCandidate(deviceID: UInt64?) throws -> Candidate {
        let all = candidates()
        let selected: Candidate
        if let deviceID {
            guard let match = all.first(where: { $0.summary.registryID == deviceID }) else {
                throw HIDTransportError.selectedDeviceMissing
            }
            selected = match
        } else {
            guard !all.isEmpty else { throw HIDTransportError.noBluetoothKeyboard }
            guard all.count == 1 else { throw HIDTransportError.ambiguousDevices(all.count) }
            selected = all[0]
        }
        guard selected.summary.supportsExpectedLEDReport else { throw HIDTransportError.incompatibleDescriptor }
        return selected
    }

    private static func readLEDReport(_ device: IOHIDDevice) throws -> UInt8 {
        var original: [UInt8] = [1, 0]
        var length = CFIndex(original.count)
        let readStatus = original.withUnsafeMutableBufferPointer {
            IOHIDDeviceGetReport(device, kIOHIDReportTypeOutput, 1, $0.baseAddress!, &length)
        }
        guard readStatus == kIOReturnSuccess else { throw HIDTransportError.snapshotFailed(readStatus) }
        guard length == 2, original[0] == 1, original[1] & 0xE0 == 0 else { throw HIDTransportError.invalidSnapshot }
        return original[1]
    }

    private static func writeLEDReport(_ device: IOHIDDevice, payload: UInt8) -> IOReturn {
        // Numbered reports retain the ID in the buffer on macOS. See hidapi's
        // mac/hid.c set_report(): only report ID zero is stripped before IOKit.
        let bytes: [UInt8] = [1, payload]
        return bytes.withUnsafeBufferPointer {
            IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 1, $0.baseAddress!, $0.count)
        }
    }

    /// Parse the declared output fields without inspecting any key input values.
    /// The supported report is ID 1: LEDs usages 1..5 followed by 3 constant bits.
    static func hasExpectedLEDOutput(_ descriptor: Data) -> Bool {
        struct Globals { var page = 0; var reportID = 0; var size = 0; var count = 0 }
        let bytes = Array(descriptor)
        var cursor = 0
        var globals = Globals()
        var stack: [Globals] = []
        var localUsages: [Int] = []
        var minimum: Int?
        var maximum: Int?
        var outputBits = 0
        var ledUsages: [Int] = []
        var valid = true
        while cursor < bytes.count {
            let prefix = bytes[cursor]; cursor += 1
            if prefix == 0xFE {
                guard cursor + 2 <= bytes.count else { return false }
                let size = Int(bytes[cursor]); cursor += 2
                guard cursor + size <= bytes.count else { return false }
                cursor += size
                continue
            }
            let size = [0, 1, 2, 4][Int(prefix & 3)]
            guard cursor + size <= bytes.count else { return false }
            var value = 0
            for byte in 0..<size { value |= Int(bytes[cursor + byte]) << (8 * byte) }
            cursor += size
            let type = (prefix >> 2) & 3
            let tag = prefix >> 4
            if type == 1 {
                switch tag {
                case 0: globals.page = value
                case 7: globals.size = value
                case 8: globals.reportID = value
                case 9: globals.count = value
                case 10: stack.append(globals)
                case 11:
                    guard let previous = stack.popLast() else { return false }
                    globals = previous
                default: break
                }
            } else if type == 2 {
                switch tag {
                case 0: localUsages.append(value)
                case 1: minimum = value
                case 2: maximum = value
                default: break
                }
            } else if type == 0 {
                if tag == 9 && globals.reportID == 1 {
                    guard globals.size <= 32, globals.count <= 256 else { return false }
                    let bits = globals.size * globals.count
                    let constant = value & 1 != 0
                    if constant {
                        valid = valid && outputBits == 5 && bits == 3
                    } else {
                        var usages = localUsages
                        if let lo = minimum, let hi = maximum, hi >= lo, hi - lo < 256 { usages += Array(lo...hi) }
                        valid = valid && globals.page == 8 && globals.size == 1
                            && globals.count == usages.count && value & 2 != 0
                            && outputBits == ledUsages.count
                        ledUsages += usages
                    }
                    outputBits += bits
                }
                localUsages = []; minimum = nil; maximum = nil
            }
        }
        return valid && outputBits == 8 && ledUsages == [1, 2, 3, 4, 5]
    }
}
