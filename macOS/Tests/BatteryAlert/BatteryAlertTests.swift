// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

@main @MainActor struct BatteryAlertTests {
    private static var checks = 0
    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        guard condition() else { fatalError("FAIL: \(message)") }
    }
    static func main() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        var clock = start
        /// Feeds fresh readings one minute apart and returns the notices raised.
        func run(_ policy: inout BatteryAlertPolicy, _ levels: [Int]) -> [Int?] {
            levels.map { level in clock += 60; return policy.evaluate(percent: level, readAt: clock, now: clock) }
        }
        var policy = BatteryAlertPolicy()
        expect(run(&policy, [100, 60, 21, 20]) == [nil, nil, nil, nil], "20% itself is not below the threshold")
        expect(run(&policy, [19]) == [20], "falling below 20% notifies once")
        expect(run(&policy, [19, 18, 15, 11, 10]) == [nil, nil, nil, nil, nil], "no repeat while the level keeps falling, and 10% is not below 10%")
        expect(run(&policy, [9]) == [10], "falling below 10% notifies once")
        expect(run(&policy, [9, 5, 1, 0]) == [nil, nil, nil, nil], "no repeat below 10%")
        expect(run(&policy, [12, 9, 14, 9]) == [nil, nil, nil, nil], "small recoveries do not notify again for 10%")
        expect(run(&policy, [15, 9]) == [nil, 10], "after rising to 15% the 10% notice can fire again")
        expect(run(&policy, [22, 24, 19]) == [nil, nil, nil], "rising to 24% does not re-arm the 20% notice")
        expect(run(&policy, [25, 19]) == [nil, 20], "after rising to 25% the 20% notice can fire again")
        expect(run(&policy, [100, 8]) == [nil, 10], "a drop straight below both thresholds is a single notice for 10%")
        expect(run(&policy, [18, 12, 19]) == [nil, nil, nil], "that single notice also covers 20%")

        var first = BatteryAlertPolicy()
        expect(run(&first, [14]) == [20], "a first reading already below 20% notifies")
        var firstLow = BatteryAlertPolicy()
        expect(run(&firstLow, [4, 4]) == [10, nil], "a first reading below 10% notifies once, for 10%")

        var guarded = BatteryAlertPolicy()
        for invalid in [-1, 101, 255, Int.min, Int.max] {
            expect(guarded.evaluate(percent: invalid, readAt: clock, now: clock) == nil, "an out-of-range level never notifies")
        }
        expect(guarded.evaluate(percent: 5, readAt: clock, now: clock + 181) == nil, "an old reading never notifies")
        expect(guarded.evaluate(percent: 5, readAt: clock + 30, now: clock) == nil, "a reading dated in the future never notifies")
        expect(guarded.notified.isEmpty, "rejected readings leave no trace")
        expect(guarded.evaluate(percent: 5, readAt: clock, now: clock + 180) == 10, "a reading at the edge of freshness counts")
        expect(guarded.evaluate(percent: 90, readAt: clock, now: clock + 600) == nil && guarded.evaluate(percent: 5, readAt: clock, now: clock) == nil,
               "a stale high reading does not re-arm the notice")
        expect(guarded.evaluate(percent: 255, readAt: clock, now: clock) == nil && guarded.evaluate(percent: 5, readAt: clock, now: clock) == nil,
               "an invalid reading does not re-arm the notice")
        guarded.reset()
        expect(guarded.evaluate(percent: 5, readAt: clock, now: clock) == 10, "another keyboard or re-enabling starts from scratch")

        var count = 0, noisy = BatteryAlertPolicy()
        for step in 0..<500 { clock += 60; if noisy.evaluate(percent: 17 + (step % 5), readAt: clock, now: clock) != nil { count += 1 } }
        expect(count == 1, "a level hovering around 20% notifies once, not at every reading")
        print("Battery alert: \(checks) checks passed (pure thresholds; no notifications, timers or device access).")
    }
}
