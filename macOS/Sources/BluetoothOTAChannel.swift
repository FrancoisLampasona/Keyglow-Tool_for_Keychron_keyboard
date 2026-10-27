// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

struct OTAIOFailure: Codable, Sendable { let stage: String; let code: Int32 }

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
            } catch { self.callbackError = error }
        }, removed: { [weak self] in self?.callbackError = OTAChannelFailure.disconnected })

        try send(masks: masks, original: original, pause: pause, deadline: deadline,
                 io: io, cancellation: cancellation, progress: progress)
        requestSent = true
        while reply == nil {
            try check(io: io, deadline: deadline, cancellation: cancellation)
            try parser?.tick(nowMilliseconds: Self.milliseconds(io.now))
            io.pump(until: min(deadline, io.now + 0.01)) {
                self.reply == nil && self.callbackError == nil && !cancellation.isCancelled
            }
        }
        guard let reply else { throw OTAChannelFailure.deadline }
        // Keep the bounded activity/removal guard through the receipt. The
        // completed reply is not parsed again and no keyboard input is retained.
        // Allow the device's final all-zero reserved-byte report to complete.
        io.pump(until: min(deadline, io.now + 0.2)) { !cancellation.isCancelled }
        let receipt = try BluetoothOTAWire.acknowledgementReceipt(for: reply)
        let receiptMasks = try BluetoothOTAWire.ledMasks(for: receipt)
        try send(masks: receiptMasks, original: original, pause: pause, deadline: deadline,
                 io: io, cancellation: cancellation, progress: { _, _ in })
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
