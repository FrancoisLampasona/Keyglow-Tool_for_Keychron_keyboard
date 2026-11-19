// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// Decides when a low-battery notice is due. Pure state: no notifications,
/// timers, preferences or device access.
struct BatteryAlertPolicy: Equatable, Sendable {
    /// A notice is due when a reading is below one of these percentages.
    static let thresholds = [20, 10]
    /// A threshold can notify again only after the level rose this far above it.
    static let rearmMargin = 5
    /// Same freshness window as the battery display.
    static let freshness: ClosedRange<TimeInterval> = 0...180
    private(set) var notified: Set<Int> = []

    /// Returns the threshold to announce for this reading, or nil.
    /// Invalid, old or future-dated readings never notify and never re-arm.
    mutating func evaluate(percent: Int, readAt: Date, now: Date) -> Int? {
        guard (0...100).contains(percent), Self.freshness.contains(now.timeIntervalSince(readAt)) else { return nil }
        notified = notified.filter { percent < $0 + Self.rearmMargin }
        let due = Self.thresholds.filter { percent < $0 && !notified.contains($0) }
        // A drop straight below both thresholds is one notice, for the lower one.
        guard let lowest = due.min() else { return nil }
        notified.formUnion(Self.thresholds.filter { percent < $0 })
        return lowest
    }
    /// Another keyboard, or the option was switched off.
    mutating func reset() { notified.removeAll() }
}
