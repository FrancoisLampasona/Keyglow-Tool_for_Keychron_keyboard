// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

final class MockIO: BluetoothOTAChannelIO {
    var now: TimeInterval = 0
    var transportFailures: [OTAIOFailure] = []
    var original: UInt8 = 0x1b
    var writes: [UInt8] = []
    var opened = false, closed = false, monitoring = false
    var requestMasks = 0
    var replyReports: [[UInt8]] = []
    var replyReportIDs: [UInt32] = []
    var nextReport = 0
    var nextReportAt = Double.infinity
    var monitorEnd = 0.0
    var failWrite: Int?
    var input: ((UInt32, UnsafeBufferPointer<UInt8>) -> Void)?
    var removed: (() -> Void)?
    var hook: (() -> Void)?
    func openAndSnapshot() throws -> UInt8 { opened = true; return original }
    func monitor(until deadline: TimeInterval, input: @escaping (UInt32, UnsafeBufferPointer<UInt8>) -> Void, removed: @escaping () -> Void) {
        monitoring = true; monitorEnd = deadline; self.input = input; self.removed = removed
    }
    func stopMonitoring() { monitoring = false; input = nil; removed = nil }
    func close() { closed = true; stopMonitoring() }
    func writeLED(_ mask: UInt8, deadline: TimeInterval) throws {
        writes.append(mask); now += 0.026
        if writes.count == requestMasks { nextReportAt = now + 0.6 }
        if writes.count == failWrite { throw OTAChannelFailure.writeFailed }
        hook?()
    }
    func pump(until deadline: TimeInterval, keepRunning: () -> Bool) {
        while now < deadline && keepRunning() {
            now = min(deadline, now + 0.005)
            if monitoring && now >= monitorEnd { stopMonitoring() }
            if monitoring, now >= nextReportAt, nextReport < replyReports.count {
                let bytes = replyReports[nextReport]
                let reportID = replyReportIDs.indices.contains(nextReport) ? replyReportIDs[nextReport] : 1
                nextReport += 1; nextReportAt += 0.1
                bytes.withUnsafeBufferPointer { input?(reportID, $0) }
            }
        }
    }
}
@main enum Tests {
    static func main() throws {
        var count = 0
        func check(_ condition: @autoclosure () -> Bool, _ label: String) { precondition(condition(), label); count += 1 }
        let frame = try BluetoothOTAWire.request(operation: 3, requestID: 0x12345678)
        let masks = try BluetoothOTAWire.ledMasks(for: frame)
        func io(replyID: UInt32 = 0x12345678, payload: [UInt8] = []) throws -> MockIO {
            let io = MockIO(); io.requestMasks = masks.count
            io.replyReports = try BluetoothOTAWire.replyReports(for: BluetoothOTAWire.reply(operation: 3, requestID: replyID, result: 0, flags: 1, payload: payload))
            return io
        }
        for pause in [0.02, 0.04, 0.08] {
            let io = try io()
            let result = try BluetoothOTAChannel().exchange(frame: frame, pause: pause, io: io, cancellation: OTAUpdateCancellation())
            check(result.reply.requestID == 0x12345678 && result.receiptSubmitted, "correlated reply and receipt")
            check(io.closed && !io.monitoring, "bounded listener cleanup")
            check(io.writes[masks.count] == io.original && io.writes.last == io.original, "restore request and receipt")
            check(io.writes.prefix(masks.count).allSatisfy { $0 & 0x18 == io.original & 0x18 }, "preserve unrelated LEDs")
            let expected = try BluetoothOTAWire.ledMasks(for: BluetoothOTAWire.acknowledgementReceipt(for: result.reply)).map { (io.original & 0x18) | $0 }
            check(Array(io.writes.dropFirst(masks.count + 1).dropLast()) == expected, "receipt uses exact validated result")
        }
        let long = try io(payload: Array(repeating: 0xab, count: 128))
        _ = try BluetoothOTAChannel().exchange(frame: frame, io: long, cancellation: OTAUpdateCancellation())
        check(long.closed && long.nextReport >= 286, "maximum long status accepted within bounded window")
        // Real descriptor release reports can accompany a long HELLO and its
        // receipt. An ID prefix alone is not a pressed key or mouse activity.
        let hello = try BluetoothOTAWire.request(operation: 8, requestID: 0x12345678, payload: Array(repeating: 0x31, count: 16))
        let helloMasks = try BluetoothOTAWire.ledMasks(for: hello)
        let helloReply = try BluetoothOTAWire.reply(operation: 8, requestID: 0x12345678, result: 0, flags: 0, payload: Array(repeating: 0xab, count: 96))
        let releaseReports: [(UInt32, [UInt8])] = [(2, [0, 0]), (2, [2, 0, 0]), (6, [0]), (6, [6, 0]), (3, Array(repeating: 0, count: 7)), (3, [3] + Array(repeating: 0, count: 7))]
        func helloIO() throws -> MockIO {
            let result = MockIO(); result.requestMasks = helloMasks.count
            result.replyReports = try BluetoothOTAWire.replyReports(for: helloReply)
            return result
        }
        let releases = try helloIO(); let originalReports = releases.replyReports
        releases.replyReports = []; releases.replyReportIDs = []
        for (index, report) in originalReports.enumerated() {
            releases.replyReports.append(report); releases.replyReportIDs.append(1)
            if index % 20 == 0 {
                let (id, idle) = releaseReports[(index / 20) % releaseReports.count]
                releases.replyReports.append(idle); releases.replyReportIDs.append(id)
            }
        }
        var receiptReleases = 0
        releases.hook = {
            let index = releases.writes.count - helloMasks.count - 2
            if releaseReports.indices.contains(index) {
                let (id, idle) = releaseReports[index]
                idle.withUnsafeBufferPointer { releases.input?(id, $0) }
                receiptReleases += 1
            }
        }
        let releaseResult = try BluetoothOTAChannel().exchange(frame: hello, io: releases, cancellation: OTAUpdateCancellation())
        check(releaseResult.reply.operation == 8 && releaseResult.reply.payload.count == 96 && releaseResult.receiptSubmitted, "HELLO accepts interleaved valid zero release reports")
        check(receiptReleases == releaseReports.count && releases.closed && !releases.monitoring, "all prefixed and unprefixed releases accepted through ACK_ACK")
        check(releases.writes.last == releases.original, "release traffic retains indicator restoration")
        for (id, length) in [(UInt32(2), 2), (UInt32(6), 1), (UInt32(3), 7)] {
            for prefixed in [false, true] {
                var active = [UInt8](repeating: 0, count: length); active[0] = 1
                if prefixed { active.insert(UInt8(id), at: 0) }
                let responseActivity = try helloIO()
                responseActivity.replyReports.insert(active, at: 5)
                responseActivity.replyReportIDs = Array(repeating: 1, count: responseActivity.replyReports.count)
                responseActivity.replyReportIDs[5] = id
                do { _ = try BluetoothOTAChannel().exchange(frame: hello, io: responseActivity, cancellation: OTAUpdateCancellation()); fatalError("ignored non-keyboard activity in HELLO") }
                catch { check(error as? BluetoothOTAWire.Failure == .inputActivity && responseActivity.writes.count == helloMasks.count + 1 && responseActivity.closed, "active consumer/system/mouse during HELLO blocks receipt") }
                let receiptActivity = try helloIO()
                receiptActivity.hook = {
                    if receiptActivity.writes.count == helloMasks.count + 3 { active.withUnsafeBufferPointer { receiptActivity.input?(id, $0) } }
                }
                do { _ = try BluetoothOTAChannel().exchange(frame: hello, io: receiptActivity, cancellation: OTAUpdateCancellation()); fatalError("ignored non-keyboard activity during ACK_ACK") }
                catch { check(error as? BluetoothOTAWire.Failure == .inputActivity && receiptActivity.writes.last == receiptActivity.original && receiptActivity.closed, "active consumer/system/mouse during receipt aborts and restores") }
            }
        }
        let absent = try io(); absent.replyReports = []
        do { _ = try BluetoothOTAChannel().exchange(frame: frame, io: absent, cancellation: OTAUpdateCancellation()); fatalError("accepted no reply") }
        catch { check(absent.now <= 181 && absent.closed && absent.writes.last == absent.original, "timeout restores and releases") }
        let wrong = try io(replyID: 0x87654321)
        do { _ = try BluetoothOTAChannel().exchange(frame: frame, io: wrong, cancellation: OTAUpdateCancellation()); fatalError("accepted wrong ID") }
        catch { check(wrong.writes.count == masks.count + 1 && wrong.closed, "wrong reply gets no receipt") }
        let interrupted = try io(); let cancellation = OTAUpdateCancellation()
        interrupted.hook = { if interrupted.writes.count == 4 { cancellation.cancel() } }
        do { _ = try BluetoothOTAChannel().exchange(frame: frame, io: interrupted, cancellation: cancellation); fatalError("ignored cancel") }
        catch { check(interrupted.writes.count == 5 && interrupted.writes.last == interrupted.original && interrupted.closed, "cancel restores") }
        let failed = try io(); failed.failWrite = 1
        do { _ = try BluetoothOTAChannel().exchange(frame: frame, io: failed, cancellation: OTAUpdateCancellation()); fatalError("ignored write failure") }
        catch { check(failed.writes.count == 2 && failed.writes.last == failed.original && failed.closed, "first write failure still restores") }
        let receiptFailed = try io(); receiptFailed.failWrite = masks.count + 3
        do { _ = try BluetoothOTAChannel().exchange(frame: frame, io: receiptFailed, cancellation: OTAUpdateCancellation()); fatalError("ignored receipt failure") }
        catch { check(receiptFailed.writes.last == receiptFailed.original && receiptFailed.closed, "failed receipt still restores, never claims success") }
        let restoreFailed = try io(); restoreFailed.failWrite = masks.count + 1
        do { _ = try BluetoothOTAChannel().exchange(frame: frame, io: restoreFailed, cancellation: OTAUpdateCancellation()); fatalError("ignored restore failure") }
        catch { check(error as? OTAChannelFailure == .restoreFailed && restoreFailed.closed, "restore failure reported and closed") }
        let disconnected = try io()
        disconnected.hook = { if disconnected.writes.count == 4 { disconnected.removed?() } }
        do { _ = try BluetoothOTAChannel().exchange(frame: frame, io: disconnected, cancellation: OTAUpdateCancellation()); fatalError("ignored removal") }
        catch { check(error as? OTAChannelFailure == .disconnected && disconnected.writes.last == disconnected.original && disconnected.closed, "removal restores and closes") }
        let typedReceipt = try io()
        typedReceipt.hook = {
            if typedReceipt.writes.count == masks.count + 3 {
                [UInt8](arrayLiteral: 0, 0, 4, 0, 0, 0, 0, 0).withUnsafeBufferPointer { typedReceipt.input?(1, $0) }
            }
        }
        do { _ = try BluetoothOTAChannel().exchange(frame: frame, io: typedReceipt, cancellation: OTAUpdateCancellation()); fatalError("ignored typing during receipt") }
        catch { check(error as? BluetoothOTAWire.Failure == .inputActivity && typedReceipt.writes.last == typedReceipt.original && typedReceipt.closed, "receipt typing aborts, restores and closes") }
        let lastWriteCancelled = try io(); let lateCancellation = OTAUpdateCancellation()
        let receiptCount = try BluetoothOTAWire.ledMasks(for: BluetoothOTAWire.acknowledgementReceipt(for: BluetoothOTAWire.reply(operation: 3, requestID: 0x12345678, result: 0, flags: 1))).count
        lastWriteCancelled.hook = {
            if lastWriteCancelled.writes.count == masks.count + 1 + receiptCount { lateCancellation.cancel() }
        }
        do { _ = try BluetoothOTAChannel().exchange(frame: frame, io: lastWriteCancelled, cancellation: lateCancellation); fatalError("ignored final cancellation") }
        catch { check(error as? OTAChannelFailure == .cancelled && lastWriteCancelled.writes.last == lastWriteCancelled.original && lastWriteCancelled.closed, "final receipt cancellation cannot claim success") }
        let typed = try io(); typed.replyReports = [[0, 0, 4, 0, 0, 0, 0, 0]]
        do { _ = try BluetoothOTAChannel().exchange(frame: frame, io: typed, cancellation: OTAUpdateCancellation()); fatalError("ignored activity") }
        catch { check(typed.writes.count == masks.count + 1 && typed.closed, "typing stops without receipt") }
        for pause in [Double.nan, Double.infinity, 0, 0.01, 0.081, -1] {
            let unopened = try io()
            do { _ = try BluetoothOTAChannel().exchange(frame: frame, pause: pause, io: unopened, cancellation: OTAUpdateCancellation()); fatalError("invalid pause") }
            catch { check(!unopened.opened && unopened.writes.isEmpty, "reject timing before hardware") }
        }
        var corrupt = frame; corrupt[12] ^= 1
        let unopened = try io()
        do { _ = try BluetoothOTAChannel().exchange(frame: corrupt, io: unopened, cancellation: OTAUpdateCancellation()); fatalError("invalid frame") }
        catch { check(!unopened.opened, "CRC before hardware") }
        print("Bluetooth OTA session: \(count) failure/success checks passed; simulated IO only.")
    }
}
