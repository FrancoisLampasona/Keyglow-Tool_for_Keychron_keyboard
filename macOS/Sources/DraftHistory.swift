// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// Undo and redo for a value-type draft. Pure state: no timers, preferences,
/// UI or device access. The owner passes the clock and applies returned states.
struct DraftHistory<State: Equatable> {
    private(set) var undoStates: [State] = []
    private(set) var redoStates: [State] = []
    let limit: Int
    /// Edits closer together than this belong to one step (a drag, a slider, typing).
    let groupingWindow: TimeInterval
    private var lastEdit: TimeInterval?

    init(limit: Int = 50, groupingWindow: TimeInterval = 0.7) {
        self.limit = max(1, limit); self.groupingWindow = groupingWindow
    }
    var canUndo: Bool { !undoStates.isEmpty }
    var canRedo: Bool { !redoStates.isEmpty }

    /// Call after the draft changed from `previous` to `current`.
    mutating func record(previous: State, current: State, now: TimeInterval) {
        guard previous != current else { return }
        redoStates.removeAll()
        let continues = lastEdit.map { now >= $0 && now - $0 < groupingWindow } ?? false
        // A continuing gesture keeps the state from before its first change.
        if !(continues && canUndo) {
            undoStates.append(previous)
            if undoStates.count > limit { undoStates.removeFirst(undoStates.count - limit) }
        }
        lastEdit = now
    }
    /// The next edit starts a new step even if it follows immediately.
    mutating func endGroup() { lastEdit = nil }

    /// Returns the state to restore, or nil when there is nothing to undo.
    mutating func undo(current: State) -> State? {
        guard let state = undoStates.popLast() else { return nil }
        redoStates.append(current); lastEdit = nil
        return state
    }
    mutating func redo(current: State) -> State? {
        guard let state = redoStates.popLast() else { return nil }
        undoStates.append(current); lastEdit = nil
        if undoStates.count > limit { undoStates.removeFirst(undoStates.count - limit) }
        return state
    }
    /// Loading, reading or applying a configuration starts a new history.
    mutating func reset() { undoStates.removeAll(); redoStates.removeAll(); lastEdit = nil }
}
