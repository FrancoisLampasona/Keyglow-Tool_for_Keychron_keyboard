import Foundation

private let nonce: [UInt8] = [0x12, 0x34, 0x56, 0x78]
private let response: [UInt8] = [0x4b, 0x50, 0x41, 0x4b, 1, 0, 0x12, 0x34, 0x56, 0x78, 0, 0x4b, 0x99]
private func reports(_ packet: [UInt8] = response, includeID: Bool = false) -> [[UInt8]] {
    packet.flatMap { byte in
        [UInt8(0x80 | (byte >> 4)), UInt8(0x90 | (byte & 15))].map {
            (includeID ? [UInt8(1)] : []) + [0, $0, 0, 0, 0, 0, 0, 0]
        }
    }
}

private final class FakeChannel: ProbeChannel {
    var now: TimeInterval = 0
    let original: UInt8 = 0x1b
    var writes: [UInt8] = []
    var writeStarts: [TimeInterval] = []
    var writeLatency: TimeInterval = 0
    var openCalls = 0
    var failWrite: Set<Int> = []
    var openFailure: ProbeFailure?
    var mode = "success"
    var monitorStarted: TimeInterval?
    var monitorStopped: TimeInterval?
    var isMonitoring = false
    var closed = false
    var input: ((UInt32, UnsafeBufferPointer<UInt8>) -> Void)?
    var removed: (() -> Void)?
    var responseStarted: TimeInterval?
    var sent = 0
    var injected = false
    var cancellation: ProbeCancellation?
    func openAndSnapshot() throws -> UInt8 { openCalls += 1; if let openFailure { throw openFailure }; return original }
    func monitor(input: @escaping (UInt32, UnsafeBufferPointer<UInt8>) -> Void, removed: @escaping () -> Void) {
        self.input = input; self.removed = removed; isMonitoring = true; monitorStarted = now
    }
    func stopMonitoring() {
        if isMonitoring { monitorStopped = now }
        isMonitoring = false; input = nil; removed = nil
    }
    func writeLED(_ mask: UInt8, deadline: TimeInterval) throws {
        precondition(monitorStarted != nil, "callback must be registered before writes")
        writeStarts.append(now)
        writes.append(mask)
        now += writeLatency
        if writes.count == 53 { responseStarted = now + 0.6 }
        if failWrite.contains(writes.count) { throw ProbeFailure.writeFailed }
    }
    func pump(until deadline: TimeInterval, keepRunning: () -> Bool) {
        while now < deadline && keepRunning() {
            now = min(deadline, now + 0.005)
            if mode != "success", !injected, writes.count >= 5 {
                injected = true
                switch mode {
                case "typing": deliver(1, [0, 0, 4, 0, 0, 0, 0, 0])
                case "disconnect": removed?()
                case "cancel": cancellation?.cancel()
                default: break
                }
            }
            if mode == "success", let start = responseStarted, now >= start + Double(sent) * 0.1, sent < 26 {
                deliver(1, reports()[sent]); sent += 1
            }
        }
    }
    func deliver(_ id: UInt32, _ bytes: [UInt8]) { bytes.withUnsafeBufferPointer { input?(id, $0) } }
    func close() { closed = true; stopMonitoring() }
}

private final class FakeUSB: VIAExchange {
    var requests: [[UInt8]] = []
    var version: UInt8 = 12
    var build = "v1.1.1 2026-10-26-23:17:58"
    var counters: [UInt8] = [8, 0x4b, 0x50, 1, 6, 0, 26, 0,
        0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 27,
        0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0]
    func exchange(_ request: [UInt8]) throws -> [UInt8] {
        requests.append(request)
        switch request[0] {
        case 1: return try VIAProtocol.packet([1, 0, version])
        case 0xa1: return try VIAProtocol.packet([0xa1] + Array(build.utf8))
        case 8: return counters
        default: fatalError("Unexpected USB command")
        }
    }
}

@main struct ProbeTests {
    nonisolated(unsafe) private static var checks = 0
    private static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        checks += 1; guard value() else { fatalError("FAIL: \(message)") }
    }
    private static func rejects(_ expected: ProbeFailure, _ body: () throws -> Void) {
        do { try body(); fatalError("Expected \(expected.rawValue)") }
        catch { check(error as? ProbeFailure == expected, "expected \(expected), got \(error)") }
    }
    private static func feed(_ decoder: inout ProbeDecoder, _ id: UInt32, _ bytes: [UInt8], requestComplete: Bool = true) throws {
        try bytes.withUnsafeBufferPointer { try decoder.accept(reportID: id, bytes: $0, requestComplete: requestComplete) }
    }
    static func main() throws {
        let challenge = try ProbeWire.challenge(nonce: nonce)
        check(challenge == [0x4b, 0x50, 0x52, 0x42, 1, 1, 0x12, 0x34, 0x56, 0x78, 0, 0x29, 0x8a], "firmware KPRB fixture")
        let masks = try ProbeWire.masks(nonce: nonce)
        check(!RGBProtocol.validMasks(masks), "production RGB sender remains unable to send KPRB")
        check(masks.count == 53 && masks.first == 0 && masks.allSatisfy { $0 <= 7 }, "only 53 bounded LED masks")
        for (index, mask) in masks.dropFirst().enumerated() { check(mask & 4 == (index % 2 == 0 ? 4 : 0), "alternating LED clock") }
        rejects(.invalidNonce) { _ = try ProbeWire.challenge(nonce: [1]) }
        for includeID in [false, true] {
            var decoder = try ProbeDecoder(nonce: nonce)
            try feed(&decoder, 1, (includeID ? [1] : []) + [UInt8](repeating: 0, count: 8), requestComplete: false)
            try feed(&decoder, 4, (includeID ? [4] : []) + [UInt8](repeating: 0, count: 20), requestComplete: false)
            for report in reports(includeID: includeID) { try feed(&decoder, 1, report) }
            check(decoder.complete && decoder.nonceMatched && decoder.crcMatched && decoder.symbols == 26, "valid reply with and without numbered prefix")
        }
        for includeID in [false, true] {
            for index in [0, 2, 3, 4, 5, 6, 7] {
                var decoder = try ProbeDecoder(nonce: nonce), bytes = [UInt8](repeating: 0, count: 8)
                bytes[index] = 1
                rejects(.inputActivity) { try feed(&decoder, 1, (includeID ? [1] : []) + bytes) }
                check(decoder.symbols == 0, "typing never enters diagnostic packet")
            }
            for index in 0..<20 {
                var decoder = try ProbeDecoder(nonce: nonce), bytes = [UInt8](repeating: 0, count: 20)
                bytes[index] = 1
                rejects(.inputActivity) { try feed(&decoder, 4, (includeID ? [4] : []) + bytes) }
            }
        }
        var decoder = try ProbeDecoder(nonce: nonce)
        rejects(.malformedInput) { try feed(&decoder, 1, [0]) }
        rejects(.malformedInput) { try feed(&decoder, 4, [UInt8](repeating: 0, count: 19)) }
        rejects(.malformedInput) { try feed(&decoder, 1, [4] + [UInt8](repeating: 0, count: 8)) }
        rejects(.responseBeforeRequest) { try feed(&decoder, 1, reports()[0], requestComplete: false) }
        rejects(.unexpectedMarker) { try feed(&decoder, 1, reports()[1]) }
        try feed(&decoder, 1, reports()[0])
        rejects(.unexpectedMarker) { try feed(&decoder, 1, reports()[0]) }
        try feed(&decoder, 2, [255, 255])
        check(decoder.ignoredReports == 1, "unrelated reports are not parsed or retained")
        for mutation in [0, 4, 5, 10, 6, 12] {
            var packet = response; packet[mutation] ^= 1
            if mutation == 6 { let crc = ProbeWire.crc16(Array(packet.prefix(11))); packet[11] = UInt8(crc >> 8); packet[12] = UInt8(crc & 255) }
            var parser = try ProbeDecoder(nonce: nonce)
            rejects(mutation == 6 ? .wrongNonce : mutation == 12 ? .wrongCRC : .wrongResponse) {
                for report in reports(packet) { try feed(&parser, 1, report) }
            }
            check(!parser.complete, "invalid response never succeeds")
        }

        let success = FakeChannel()
        let successful = ProbeRunner().run(channel: success, nonce: nonce, cancellation: ProbeCancellation())
        check(successful.status == "passed" && successful.nonceMatched && successful.crcMatched, "complete challenge and live response")
        check(successful.restorationAttempted && successful.restorationAccepted && success.writes.count == 54, "restore follows all 53 challenge writes")
        check(success.writes.last == success.original, "exact original mask restored")
        check(success.writes.dropLast().allSatisfy { $0 & 0x18 == success.original & 0x18 }, "Compose and Kana preserved")
        check(success.monitorStopped! - success.monitorStarted! < 15 && success.closed, "receiver is finite and closed")
        check(successful.requestedPauseMilliseconds == 80, "validated default remains 80ms")
        check(successful.challengeReportsSubmitted == 53 && Array(success.writes.dropLast()) == masks.map { (success.original & 0x18) | $0 }, "default packet and restore path unchanged")

        for interval in [0.080, 0.040, 0.020] {
            let channel = FakeChannel(); channel.writeLatency = 0.007
            let measured = ProbeRunner().run(channel: channel, nonce: nonce, cancellation: ProbeCancellation(), interval: interval)
            check(measured.status == "passed" && measured.requestedPauseMilliseconds == Int(interval * 1000), "preset timing succeeds without changing the nonce protocol")
            check(abs((measured.meanWriteDurationMilliseconds ?? -1) - 7) < 0.0001 && abs((measured.maxWriteDurationMilliseconds ?? -1) - 7) < 0.0001, "telemetry measures actual write duration separately from requested pause")
            for i in 1..<53 { check(channel.writeStarts[i] - channel.writeStarts[i - 1] >= interval + channel.writeLatency - 0.0001, "no pipelining or skipped post-write hold") }
            check(measured.challengeStartElapsedMilliseconds != nil && measured.challengeEndElapsedMilliseconds! > measured.challengeStartElapsedMilliseconds!, "first and final challenge timing recorded")
            check(measured.firstResponseElapsedMilliseconds! >= measured.challengeEndElapsedMilliseconds! + 599, "firmware settling period remains independent of host speed")
            check(abs(measured.lastResponseElapsedMilliseconds! - measured.firstResponseElapsedMilliseconds! - 2500) <= 6, "fixed return timing measured")
            check(measured.roundTripMilliseconds! == measured.lastResponseElapsedMilliseconds! - measured.challengeStartElapsedMilliseconds!, "roundtrip starts at first challenge write")
            check(measured.restorationAccepted && channel.writes.last == channel.original, "all speed presets restore original LED state")
        }
        for interval in [0.0, -0.02, 0.019, 0.081, .infinity, .nan] {
            let channel = FakeChannel()
            let rejected = ProbeRunner().run(channel: channel, nonce: nonce, cancellation: ProbeCancellation(), interval: interval)
            check(rejected.status == "invalidInterval" && channel.openCalls == 0 && channel.writes.isEmpty && channel.monitorStarted == nil, "invalid intervals are rejected before device access")
        }
        for interval in [0.020, 0.040] {
            let channel = FakeChannel(); channel.failWrite = [1]
            let failed = ProbeRunner().run(channel: channel, nonce: nonce, cancellation: ProbeCancellation(), interval: interval)
            check(failed.status == "writeFailed" && failed.restorationAccepted && channel.writes.last == channel.original, "faster preset restores after a failed first write")
        }

        for failingWrite in [1, 25, 53] {
            let channel = FakeChannel(); channel.failWrite = [failingWrite]
            let result = ProbeRunner().run(channel: channel, nonce: nonce, cancellation: ProbeCancellation())
            check(result.status == "writeFailed", "failed transfer reported")
            check(result.restorationAccepted && channel.writes.last == channel.original, "even a failed first write restores original")
            check(channel.writes.count == failingWrite + 1 && channel.closed, "no further challenge reports after failure")
        }
        let badRestore = FakeChannel(); badRestore.failWrite = [1, 2]
        let failed = ProbeRunner().run(channel: badRestore, nonce: nonce, cancellation: ProbeCancellation())
        check(failed.status == "restoreFailed" && failed.restorationAttempted && !failed.restorationAccepted, "restoration error is never hidden")
        for (mode, status) in [("typing", "inputActivity"), ("disconnect", "disconnected"), ("cancel", "cancelled"), ("timeout", "deadline")] {
            let channel = FakeChannel(); channel.mode = mode
            let token = ProbeCancellation(); channel.cancellation = token
            let result = ProbeRunner().run(channel: channel, nonce: nonce, cancellation: token)
            check(result.status == status && result.restorationAccepted && channel.closed, "abort \(mode) restores and closes")
            check((channel.monitorStopped ?? 100) - (channel.monitorStarted ?? 0) <= 15.01, "abort \(mode) remains bounded")
            if mode == "typing" { check(result.inputActivityDetected && result.responseSymbols == 0, "typing captured only as boolean abort") }
        }
        let missing = FakeChannel(); missing.openFailure = .noDevice
        let absent = ProbeRunner().run(channel: missing, nonce: nonce, cancellation: ProbeCancellation())
        check(absent.status == "noDevice" && missing.writes.isEmpty && missing.monitorStarted == nil, "no device means no writes or callbacks")

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("keyglow-probe-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("result.json")
        try ProbeResultStore.save(successful, to: file)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        check((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "results readable only by the user")
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        check(Set(json.keys) == Set(["schema", "status", "challengeReportsSubmitted", "responseSymbols", "idleKeyboardReports", "ignoredReports", "nonceMatched", "crcMatched", "restorationAttempted", "restorationAccepted", "inputActivityDetected", "durationMilliseconds", "transportFailures", "requestedPauseMilliseconds", "challengeStartElapsedMilliseconds", "challengeEndElapsedMilliseconds", "meanWriteDurationMilliseconds", "maxWriteDurationMilliseconds", "firstResponseElapsedMilliseconds", "lastResponseElapsedMilliseconds", "roundTripMilliseconds"]), "output contains only approved summary fields")
        let link = folder.appendingPathComponent("symlink.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        rejects(.resultSaveFailed) { try ProbeResultStore.save(successful, to: link) }

        let expectedBuild = "v1.1.1 2026-10-26-23:17:58"
        let usb = FakeUSB()
        let counters = try ProbeUSBCounters.query(usb, expectedFirmware: expectedBuild)
        check(usb.requests.map { $0[0] } == [1, 0xa1, 8] && Array(usb.requests[2].prefix(3)) == [8, 0x4b, 0x50], "USB queries only protocol, build and counters")
        check(counters.expectedFirmwareVerified && counters.attempts == 1 && counters.challenges == 1 && counters.reportsSubmitted == 27 && counters.completions == 1, "USB counters parsed big endian")
        for wrongBuild in [false, true] {
            let rejected = FakeUSB()
            if wrongBuild { rejected.build = "v1.1.1 2026-10-26-00:00:00" } else { rejected.version = 11 }
            do { _ = try ProbeUSBCounters.query(rejected, expectedFirmware: expectedBuild); fatalError("Unexpected USB identity accepted") }
            catch { check(!rejected.requests.contains { $0[0] == 8 }, "counter query blocked before unverified firmware") }
        }
        var malformed = usb.counters; malformed[3] = 2
        do { _ = try ProbeUSBCounters(response: malformed); fatalError("Unknown counter schema accepted") }
        catch { check(error as? VIAError == .malformedResponse, "unknown USB counter schema rejected") }
        malformed = usb.counters; malformed[7] = 1
        do { _ = try ProbeUSBCounters(response: malformed); fatalError("Reserved counter byte accepted") }
        catch { check(error as? VIAError == .malformedResponse, "nonzero USB reserved byte rejected") }
        print("HID probe host: \(checks) checks passed; mocked channel only, no permissions or device access.")
    }
}
