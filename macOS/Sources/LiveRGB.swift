// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

struct LiveRGBColor: Equatable, Sendable {
    let effect: Int
    let hue, saturation, value, speed: UInt8
    init(effect: Int, hue: Double, saturation: Double, value: Double, brightness: Double, speed: Double) {
        func byte(_ value: Double) -> UInt8 { UInt8(min(255, max(0, value.isFinite ? value.rounded() : 0))) }
        self.effect = effect; self.hue = byte(hue * 255); self.saturation = byte(saturation * 255)
        self.value = byte(value * brightness / 100 * 255); self.speed = byte(speed)
    }
    func packet(save: Bool) throws -> [UInt8] {
        try RGBProtocol.directStatePacket(effect: effect, hue: hue, saturation: saturation, value: value, speed: speed, save: save)
    }
}

/// Clock-driven state machine: no HID, timer, preference or device side effects.
/// Each completed send still lacks a device acknowledgement on the RGB v3 path.
struct LiveRGBCoordinator {
    struct Job: Equatable, Sendable { let id: UInt64; let color: LiveRGBColor; let save: Bool }
    private(set) var enabled = false
    private(set) var allowed = false
    private(set) var saveEnabled = false
    private(set) var active: Job?
    private(set) var pending: LiveRGBColor?
    private(set) var saveDue: TimeInterval?
    private var pendingDue: TimeInterval?
    private var latest: LiveRGBColor?
    private var lastTemporary: LiveRGBColor?
    private var lastSaved: LiveRGBColor?
    private var nextID: UInt64 = 0
    private var editedAt: TimeInterval = 0
    static let debounce: TimeInterval = 0.4
    static let saveIdle: TimeInterval = 1.5

    var hasQueuedChange: Bool { pending != nil }
    var waitingToSave: Bool { saveDue != nil }
    var nextDeadline: TimeInterval? {
        guard enabled, allowed, active == nil else { return nil }
        return pendingDue ?? saveDue
    }

    mutating func configure(enabled: Bool, allowed: Bool, save: Bool, now: TimeInterval) {
        let changedSave = saveEnabled != save
        self.enabled = enabled; self.allowed = allowed; saveEnabled = save
        if !enabled || !allowed { cancelUnsent(); return }
        if !save { saveDue = nil }
        else if changedSave, active == nil, pending == nil, let latest, latest == lastTemporary, latest != lastSaved {
            saveDue = now + Self.saveIdle
        }
    }
    mutating func edit(_ color: LiveRGBColor, now: TimeInterval) {
        guard enabled, allowed, (0...22).contains(color.effect), color != latest else { return }
        latest = color; editedAt = now; saveDue = nil
        if active?.color == color && active?.save == false {
            pending = nil; pendingDue = nil
        } else {
            pending = color; pendingDue = now + Self.debounce
        }
    }
    /// Only work not yet submitted can be cancelled. In-flight writes must
    /// finish and restore the original indicators, even after opting out.
    mutating func cancelUnsent() {
        pending = nil; pendingDue = nil; saveDue = nil; latest = nil
        lastTemporary = nil; lastSaved = nil
    }
    mutating func takeReady(now: TimeInterval) -> Job? {
        guard enabled, allowed, active == nil else { return nil }
        if let pending, let pendingDue, now >= pendingDue {
            self.pending = nil; self.pendingDue = nil
            if pending != lastTemporary { return start(pending, save: false) }
            if saveEnabled, pending != lastSaved { saveDue = max(now, editedAt + Self.saveIdle) }
        }
        if let due = saveDue, now >= due, saveEnabled, pending == nil, let latest, latest == lastTemporary, latest != lastSaved {
            saveDue = nil; return start(latest, save: true)
        }
        return nil
    }
    private mutating func start(_ color: LiveRGBColor, save: Bool) -> Job {
        nextID &+= 1
        let job = Job(id: nextID, color: color, save: save); active = job; return job
    }
    mutating func complete(_ job: Job, succeeded: Bool, now: TimeInterval) {
        guard active == job else { return }
        active = nil
        guard succeeded else { cancelUnsent(); return }
        if job.save { lastSaved = job.color }
        else { lastTemporary = job.color }
        guard enabled, allowed, latest == job.color, pending == nil else { return }
        if saveEnabled, !job.save, lastSaved != job.color { saveDue = max(editedAt + Self.saveIdle, now + Self.saveIdle) }
    }
}
