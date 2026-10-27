// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

struct BatteryReading: Equatable {
    let percent: Int
    let date: Date
    func isFresh(at now: Date) -> Bool { (0...180).contains(now.timeIntervalSince(date)) }
    var isLow: Bool { percent <= 20 }
    var symbol: String {
        switch percent {
        case ...10: return "battery.0percent"
        case ...35: return "battery.25percent"
        case ...60: return "battery.50percent"
        case ...85: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
}

struct BatteryRefreshContext: Equatable {
    var connected: Bool
    var active: Bool
    var paused: Bool
    // Discovery must also run when disconnected, so a newly connected keyboard
    // can become eligible without a manual scan or app restart.
    var shouldRefreshConnection: Bool { active && !paused }
    var canRead: Bool { connected && active && !paused }
    func shouldRefresh(authorized: Bool, running: Bool, lastAttempt: Date?, now: Date) -> Bool {
        canRead && authorized && !running && (lastAttempt.map { now.timeIntervalSince($0) >= 60 } ?? true)
    }
}
