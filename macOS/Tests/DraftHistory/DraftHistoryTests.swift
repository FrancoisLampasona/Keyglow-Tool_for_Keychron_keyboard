// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

@main @MainActor struct DraftHistoryTests {
    private static var checks = 0
    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        guard condition() else { fatalError("FAIL: \(message)") }
    }
    /// Mimics the owner: a draft value whose changes are recorded with a clock.
    private struct Draft {
        var value = 0
        var history = DraftHistory<Int>()
        mutating func edit(_ new: Int, at time: TimeInterval) { let old = value; value = new; history.record(previous: old, current: new, now: time) }
        mutating func undo() -> Bool { guard let state = history.undo(current: value) else { return false }; value = state; return true }
        mutating func redo() -> Bool { guard let state = history.redo(current: value) else { return false }; value = state; return true }
    }
    static func main() {
        var draft = Draft()
        expect(!draft.history.canUndo && !draft.history.canRedo && !draft.undo() && !draft.redo(), "an empty history does nothing")
        draft.edit(0, at: 0)
        expect(!draft.history.canUndo, "an unchanged draft records no step")
        draft.edit(1, at: 10); draft.edit(2, at: 20); draft.edit(3, at: 30)
        expect(draft.history.undoStates == [0, 1, 2], "separate edits are separate steps")
        expect(draft.undo() && draft.value == 2 && draft.undo() && draft.value == 1, "undo walks back one step at a time")
        expect(draft.history.canRedo && draft.redo() && draft.value == 2 && draft.redo() && draft.value == 3 && !draft.redo(), "redo restores undone steps in order")
        expect(draft.undo() && draft.value == 2, "undo after redo")
        draft.edit(9, at: 40)
        expect(!draft.history.canRedo && draft.history.undoStates == [0, 1, 2], "a new edit discards the redo branch")
        expect(draft.undo() && draft.value == 2 && draft.redo() && draft.value == 9, "the new edit is itself undoable")

        // A drag or slider sends many changes: one step, back to the value before it.
        var drag = Draft()
        drag.edit(1, at: 100)
        for step in 0..<40 { drag.edit(10 + step, at: 105 + Double(step) * 0.05) }
        expect(drag.history.undoStates == [0, 1], "continuous changes within the window form one step")
        expect(drag.undo() && drag.value == 1, "undoing a drag returns to the value before the drag")
        expect(drag.redo() && drag.value == 49, "redoing a drag returns to its final value")
        var paused = Draft()
        paused.edit(1, at: 0); paused.edit(2, at: 0.69); paused.edit(3, at: 1.38)
        expect(paused.history.undoStates == [0], "the window is measured from the latest change, not the first")
        paused.edit(4, at: 2.08)
        expect(paused.history.undoStates == [0, 3], "a pause of the window length starts a new step")
        paused.edit(5, at: 2.1); paused.history.endGroup(); paused.edit(6, at: 2.2)
        expect(paused.history.undoStates == [0, 3, 5], "an explicit boundary splits immediate edits")
        expect(paused.undo() && paused.value == 5, "undo to the boundary")
        paused.edit(7, at: 2.3)
        expect(paused.history.undoStates == [0, 3, 5], "an edit right after undo is a new step, not merged into an older one")
        var backwards = Draft()
        backwards.edit(1, at: 50); backwards.edit(2, at: 49.9)
        expect(backwards.history.undoStates == [0, 1], "a clock that goes backwards never merges steps")

        var limited = Draft(); limited.history = DraftHistory<Int>(limit: 50)
        for index in 1...120 { limited.edit(index, at: Double(index) * 5) }
        expect(limited.history.undoStates.count == 50 && limited.history.undoStates.first == 70 && limited.history.undoStates.last == 119, "only the newest 50 steps are kept")
        var undone = 0; while limited.undo() { undone += 1 }
        expect(undone == 50 && limited.value == 70 && limited.history.redoStates.count == 50, "undo stops at the oldest kept step")
        var redone = 0; while limited.redo() { redone += 1 }
        expect(redone == 50 && limited.value == 120 && limited.history.undoStates.count == 50, "redo never grows the history past the limit")
        expect(DraftHistory<Int>(limit: 0).limit == 1, "the limit is at least one step")

        limited.history.reset()
        expect(!limited.history.canUndo && !limited.history.canRedo && !limited.undo() && limited.value == 120, "loading, reading or applying clears the history without changing the draft")
        limited.edit(121, at: 600.1)
        expect(limited.history.undoStates == [120], "history starts again after a reset")
        print("Draft history: \(checks) checks passed (pure value type; no app, preferences or device access).")
    }
}
