// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

struct OTAIOFailure: Codable, Sendable { let stage: String; let code: Int32 }

/// Contains only framing metadata and coarse field classifications. Never retains callback memory,
/// key values, modifier values, report payloads or the authorization packet.
struct OTAInputReportFailure: Error, LocalizedError, Equatable, Sendable {
    enum Phase: String, Sendable { case sending = "invio", response = "risposta", receipt = "ricevuta" }
    struct KeyboardFields: Equatable, Sendable {
        enum Active: String, Sendable { case none = "nessuno", modifiers = "modificatori", keys = "tasti", both = "modificatori e tasti" }
        let active: Active
        let keyArrayError: Bool
        /// Pattern match only; this does not establish that a protocol byte
        /// shifted, and must never be used to accept a rejected input report.
        let markerOutsideReserved: Bool
    }
    let cause: BluetoothOTAWire.Failure
    let reportID: UInt32
    let byteCount: Int
    let operation: UInt8
    let phase: Phase
    let keyboardFields: KeyboardFields?
    init(cause: BluetoothOTAWire.Failure, reportID: UInt32, byteCount: Int, operation: UInt8,
         phase: Phase, keyboardFields: KeyboardFields? = nil) {
        self.cause = cause; self.reportID = reportID; self.byteCount = byteCount
        self.operation = operation; self.phase = phase; self.keyboardFields = keyboardFields
    }
    static func keyboardFields(reportID: UInt32, bytes: UnsafeBufferPointer<UInt8>) -> KeyboardFields? {
        guard reportID == 1 else { return nil }
        let offset: Int
        if bytes.count == 8 { offset = 0 }
        else if bytes.count == 9, bytes[0] == 1 { offset = 1 }
        else { return nil }
        let modifiers = bytes[offset] != 0
        var keys = false, keyArrayError = false
        var activeByteCount = modifiers ? 1 : 0
        var markerPattern = bytes[offset] & 0xf0 == 0x80 || bytes[offset] & 0xf0 == 0x90
        for index in (offset + 2)..<bytes.count {
            let value = bytes[index]
            if value != 0 { keys = true; activeByteCount += 1 }
            if (1...3).contains(value) { keyArrayError = true }
            if value & 0xf0 == 0x80 || value & 0xf0 == 0x90 { markerPattern = true }
        }
        let active: KeyboardFields.Active = modifiers ? (keys ? .both : .modifiers) : (keys ? .keys : .none)
        return KeyboardFields(active: active, keyArrayError: keyArrayError,
                              markerOutsideReserved: activeByteCount == 1 && markerPattern && bytes[offset + 1] == 0)
    }
    var errorDescription: String? {
        let reason = cause == .invalidReport ? "un formato di input inatteso" : "attività o dati di input inattesi"
        var detail = "comando \(operation), \(phase.rawValue), report \(reportID), \(byteCount) byte"
        if let keyboardFields {
            detail += ", campi attivi: \(keyboardFields.active.rawValue)"
            if keyboardFields.keyArrayError { detail += ", indicatore di errore HID" }
            if keyboardFields.markerOutsideReserved { detail += ", pattern marcatore fuori posizione" }
        }
        return "Scambio fermato per \(reason). Nessun tasto è stato registrato. Diagnosi: \(detail)."
    }
}

enum OTAChannelFailure: String, Error, LocalizedError {
    case permissionDenied, noDevice, ambiguousDevice, incompatibleDescriptor
    case openFailed, snapshotFailed, invalidSnapshot, writeFailed, restoreFailed
    case disconnected, cancelled, deadline, invalidInterval, earlyReply
    var errorDescription: String? {
        switch self {
        case .permissionDenied: return "Consenti Monitoraggio input a Keyglow per comunicare con la Q6 Max."
        case .noDevice: return "Q6 Max ISO Bluetooth non collegata."
        case .ambiguousDevice: return "Collega una sola Q6 Max ISO per eseguire l’aggiornamento."
        case .incompatibleDescriptor: return "Il formato Bluetooth della tastiera non corrisponde a quello verificato."
        case .openFailed: return "macOS ha rifiutato l’apertura della tastiera."
        case .snapshotFailed, .invalidSnapshot: return "Impossibile leggere gli indicatori iniziali. Nessuna richiesta inviata."
        case .writeFailed: return "Invio Bluetooth interrotto. Il completamento non è confermato."
        case .restoreFailed: return "Ripristino degli indicatori non confermato. Ricollega la tastiera prima di continuare."
        case .disconnected: return "Collegamento Bluetooth interrotto. La sessione può essere verificata e ripresa."
        case .cancelled: return "Trasferimento interrotto. La tastiera deve essere riletta prima di riprendere."
        case .deadline: return "La tastiera non ha restituito una risposta completa entro il limite."
        case .invalidInterval: return "Intervallo di invio non supportato."
        case .earlyReply: return "Risposta ricevuta prima del completamento della richiesta."
        }
    }
}

protocol BluetoothOTAChannelIO: AnyObject {
    var now: TimeInterval { get }
    var transportFailures: [OTAIOFailure] { get }
    func openAndSnapshot() throws -> UInt8
    func monitor(until deadline: TimeInterval,
                 input: @escaping (UInt32, UnsafeBufferPointer<UInt8>) -> Void,
                 removed: @escaping () -> Void)
    func stopMonitoring()
    func writeLED(_ mask: UInt8, deadline: TimeInterval) throws
    func pump(until deadline: TimeInterval, keepRunning: () -> Bool)
    func close()
}

final class OTAUpdateCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func cancel() { lock.lock(); value = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

struct BluetoothOTAExchangeResult: Sendable {
    let reply: BluetoothOTAWire.Reply
    let duration: TimeInterval
    let outputReports: Int
    let receiptSubmitted: Bool
}

/// Runs on a dedicated worker run loop, never the UI thread. The injected IO
/// lets tests prove cancellation, corruption, indicator restoration and ordering.
/// A valid reply proves device processing; receipt submission alone never proves
/// that a reset or installation completed. A later HELLO must establish that.
final class BluetoothOTAChannel {
    private var parser: BluetoothOTAWire.ReplyParser?
    private var reply: BluetoothOTAWire.Reply?
    private var callbackError: Error?
    private var requestSent = false
    private var reports = 0
    private var inputPhase: OTAInputReportFailure.Phase = .sending

    func exchange(frame: [UInt8], pause: TimeInterval = 0.08,
                  io: any BluetoothOTAChannelIO, cancellation: OTAUpdateCancellation,
                  progress: (Int, Int) -> Void = { _, _ in }) throws -> BluetoothOTAExchangeResult {
        // No device opens until the entire request and timing are validated.
        guard [0.02, 0.04, 0.08].contains(pause) else { throw OTAChannelFailure.invalidInterval }
        let request = try BluetoothOTAWire.parseRequest(frame)
        guard request.operation != BluetoothOTAWire.acknowledgementReceiptOperation else {
            throw BluetoothOTAWire.Failure.invalidOperation
        }
        let masks = try BluetoothOTAWire.ledMasks(for: frame)
        parser = try BluetoothOTAWire.ReplyParser(expectedOperation: request.operation, requestID: request.requestID)
        reply = nil; callbackError = nil; requestSent = false; reports = 0
        inputPhase = .sending
        let start = io.now
        defer { io.stopMonitoring(); io.close(); parser = nil }
        let original = try io.openAndSnapshot()
        // At the tested 80ms pause + ~26ms write latency the largest request can
        // take ~117s, followed by a long status reply and its delivery receipt.
        // Never silently permit an unbounded background input listener.
        let deadline = io.now + 180
        io.monitor(until: deadline, input: { [weak self] id, bytes in
            guard let self, self.callbackError == nil else { return }
            do {
                if self.reply != nil {
                    _ = try BluetoothOTAWire.assertIdleInput(reportID: id, bytes: bytes)
                    return
                }
                if let result = try self.parser?.accept(reportID: id, bytes: bytes,
                                                       nowMilliseconds: Self.milliseconds(io.now)) {
                    guard self.requestSent else { throw OTAChannelFailure.earlyReply }
                    self.reply = result
                }
            } catch {
                if let cause = error as? BluetoothOTAWire.Failure,
                   cause == .inputActivity || cause == .invalidReport {
                    self.callbackError = OTAInputReportFailure(cause: cause, reportID: id,
                                                               byteCount: bytes.count, operation: request.operation,
                                                               phase: self.inputPhase,
                                                               keyboardFields: OTAInputReportFailure.keyboardFields(reportID: id, bytes: bytes))
                } else { self.callbackError = error }
            }
        }, removed: { [weak self] in self?.callbackError = OTAChannelFailure.disconnected })

        try send(masks: masks, original: original, pause: pause, deadline: deadline,
                 io: io, cancellation: cancellation, progress: progress)
        requestSent = true
        inputPhase = .response
        while reply == nil {
            try check(io: io, deadline: deadline, cancellation: cancellation)
            try parser?.tick(nowMilliseconds: Self.milliseconds(io.now))
            io.pump(until: min(deadline, io.now + 0.01)) {
                self.reply == nil && self.callbackError == nil && !cancellation.isCancelled
            }
        }
        guard let reply else { throw OTAChannelFailure.deadline }
        inputPhase = .receipt
        // Keep the bounded activity/removal guard through the receipt. The
        // completed reply is not parsed again and no keyboard input is retained.
        // Allow the device's final all-zero reserved-byte report to complete.
        io.pump(until: min(deadline, io.now + 0.2)) { !cancellation.isCancelled }
        let receipt = try BluetoothOTAWire.acknowledgementReceipt(for: reply)
        let receiptMasks = try BluetoothOTAWire.ledMasks(for: receipt)
        try send(masks: receiptMasks, original: original, pause: pause, deadline: deadline,
                 io: io, cancellation: cancellation, progress: { _, _ in })
        // IOKit's write completion is not the controller's receipt consumption.
        // Leave a quiet interval after restoring the indicators before another
        // exchange opens the device. This exceeds the firmware's 400 ms LED
        // parser timeout, with room for radio delivery; it does not prove that
        // ACK_ACK arrived. Keep cancellation/input guards active throughout.
        io.pump(until: min(deadline, io.now + 0.6)) {
            self.callbackError == nil && !cancellation.isCancelled
        }
        try check(io: io, deadline: deadline, cancellation: cancellation)
        return BluetoothOTAExchangeResult(reply: reply, duration: io.now - start,
                                          outputReports: reports, receiptSubmitted: true)
    }

    private func send(masks: [UInt8], original: UInt8, pause: TimeInterval, deadline: TimeInterval,
                      io: any BluetoothOTAChannelIO, cancellation: OTAUpdateCancellation,
                      progress: (Int, Int) -> Void) throws {
        var attempted = false
        var sendError: Error?
        do {
            for (index, mask) in masks.enumerated() {
                try check(io: io, deadline: deadline, cancellation: cancellation)
                attempted = true
                try io.writeLED((original & 0x18) | mask, deadline: deadline)
                reports += 1
                progress(index + 1, masks.count)
                io.pump(until: min(deadline, io.now + pause)) {
                    self.callbackError == nil && !cancellation.isCancelled
                }
            }
        } catch { sendError = error }
        if attempted {
            // Even a reported first-write failure can have partially changed LEDs.
            // Do not suppress restoration because cancellation/disconnection fired.
            do { try io.writeLED(original, deadline: min(deadline + 1, io.now + 1)); reports += 1 }
            catch { throw OTAChannelFailure.restoreFailed }
        }
        if let sendError { throw sendError }
        try check(io: io, deadline: deadline, cancellation: cancellation)
    }

    private func check(io: any BluetoothOTAChannelIO, deadline: TimeInterval,
                       cancellation: OTAUpdateCancellation) throws {
        if let callbackError { throw callbackError }
        if cancellation.isCancelled { throw OTAChannelFailure.cancelled }
        if io.now >= deadline { throw OTAChannelFailure.deadline }
    }
    private static func milliseconds(_ now: TimeInterval) -> UInt32 {
        UInt32(truncatingIfNeeded: UInt64(max(0, now * 1000)))
    }
}
