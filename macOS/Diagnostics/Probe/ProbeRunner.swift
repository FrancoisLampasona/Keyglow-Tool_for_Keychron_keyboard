import Foundation

protocol ProbeChannel: AnyObject {
    var now: TimeInterval { get }
    var transportFailures: [ProbeTransportFailure] { get }
    func openAndSnapshot() throws -> UInt8
    func monitor(input: @escaping (UInt32, UnsafeBufferPointer<UInt8>) -> Void, removed: @escaping () -> Void)
    func stopMonitoring()
    func writeLED(_ mask: UInt8, deadline: TimeInterval) throws
    func pump(until deadline: TimeInterval, keepRunning: () -> Bool)
    func close()
}
extension ProbeChannel {
    var transportFailures: [ProbeTransportFailure] { [] }
}

final class ProbeCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func cancel() { lock.lock(); value = true; lock.unlock() }
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

/// Lives entirely on one worker run loop. Hardware access is injectable in tests.
final class ProbeRunner {
    private var failure: ProbeFailure?
    private var requestComplete = false
    private var decoder: ProbeDecoder?
    private var firstResponseAt: TimeInterval?
    private var lastResponseAt: TimeInterval?

    func run(channel: any ProbeChannel, nonce: [UInt8], cancellation: ProbeCancellation,
             interval: TimeInterval = ProbeWire.interval) -> ProbeResult {
        failure = nil; requestComplete = false; decoder = nil
        firstResponseAt = nil; lastResponseAt = nil
        var result = ProbeResult()
        let start = channel.now
        var writeDurations: [TimeInterval] = []
        var firstWriteAt: TimeInterval?
        defer { channel.stopMonitoring(); channel.close() }
        do {
            guard interval.isFinite, (0.020...0.080).contains(interval) else { throw ProbeFailure.invalidInterval }
            result.requestedPauseMilliseconds = Int((interval * 1000).rounded())
            decoder = try ProbeDecoder(nonce: nonce)
            let masks = try ProbeWire.masks(nonce: nonce)
            let original = try channel.openAndSnapshot()
            let deadline = channel.now + ProbeWire.duration
            channel.monitor(input: { [weak self] id, bytes in
                guard let self, self.failure == nil, self.decoder?.complete == false else { return }
                do {
                    let previousSymbols = self.decoder?.symbols ?? 0
                    try self.decoder?.accept(reportID: id, bytes: bytes, requestComplete: self.requestComplete)
                    if (self.decoder?.symbols ?? 0) > previousSymbols && self.firstResponseAt == nil { self.firstResponseAt = channel.now }
                    if self.decoder?.complete == true { self.lastResponseAt = channel.now }
                }
                catch { self.failure = error as? ProbeFailure ?? .malformedInput }
            }, removed: { [weak self] in self?.failure = .disconnected })
            var attemptedWrite = false
            do {
                for mask in masks {
                    try check(channel: channel, deadline: deadline, cancellation: cancellation)
                    attemptedWrite = true
                    let writeStarted = channel.now
                    if firstWriteAt == nil {
                        firstWriteAt = writeStarted
                        result.challengeStartElapsedMilliseconds = Int((writeStarted - start) * 1000)
                    }
                    do { try channel.writeLED((original & 0x18) | mask, deadline: deadline) }
                    catch { writeDurations.append(max(0, channel.now - writeStarted)); throw error }
                    writeDurations.append(max(0, channel.now - writeStarted))
                    result.challengeReportsSubmitted += 1
                    result.challengeEndElapsedMilliseconds = Int((channel.now - start) * 1000)
                    // Hold every symbol, including the last, before restoring the indicators.
                    channel.pump(until: min(deadline, channel.now + interval)) { self.failure == nil && !cancellation.cancelled }
                }
                requestComplete = true
                try check(channel: channel, deadline: deadline, cancellation: cancellation)
            } catch { failure = failure ?? (error as? ProbeFailure ?? .writeFailed) }

            // A failed first write can still have effects. Restore after every attempted transfer.
            if attemptedWrite {
                if failure != nil || cancellation.cancelled { channel.stopMonitoring() }
                result.restorationAttempted = true
                do {
                    try channel.writeLED(original, deadline: min(deadline + 1, channel.now + 1))
                    result.restorationAccepted = true
                } catch { failure = .restoreFailed }
            }
            while decoder?.complete == false && failure == nil {
                try check(channel: channel, deadline: deadline, cancellation: cancellation)
                channel.pump(until: min(deadline, channel.now + 0.025)) { self.failure == nil && !cancellation.cancelled && self.decoder?.complete == false }
            }
            if let failure { throw failure }
            guard decoder?.complete == true, result.restorationAccepted else { throw ProbeFailure.deadline }
            result.status = "passed"
        } catch { result.status = (error as? ProbeFailure ?? .openFailed).rawValue }
        channel.stopMonitoring()
        result.responseSymbols = decoder?.symbols ?? 0
        result.idleKeyboardReports = decoder?.idleReports ?? 0
        result.ignoredReports = decoder?.ignoredReports ?? 0
        result.nonceMatched = decoder?.nonceMatched ?? false
        result.crcMatched = decoder?.crcMatched ?? false
        result.inputActivityDetected = failure == .inputActivity || result.status == ProbeFailure.inputActivity.rawValue
        result.durationMilliseconds = Int(max(0, channel.now - start) * 1000)
        result.transportFailures = channel.transportFailures
        if !writeDurations.isEmpty {
            result.meanWriteDurationMilliseconds = 1000 * writeDurations.reduce(0, +) / Double(writeDurations.count)
            result.maxWriteDurationMilliseconds = 1000 * (writeDurations.max() ?? 0)
        }
        if let firstResponseAt { result.firstResponseElapsedMilliseconds = Int((firstResponseAt - start) * 1000) }
        if let lastResponseAt {
            result.lastResponseElapsedMilliseconds = Int((lastResponseAt - start) * 1000)
            if let firstWriteAt { result.roundTripMilliseconds = Int((lastResponseAt - firstWriteAt) * 1000) }
        }
        decoder = nil
        return result
    }

    private func check(channel: any ProbeChannel, deadline: TimeInterval, cancellation: ProbeCancellation) throws {
        if let failure { throw failure }
        if cancellation.cancelled { throw ProbeFailure.cancelled }
        if channel.now >= deadline { throw ProbeFailure.deadline }
    }
}
