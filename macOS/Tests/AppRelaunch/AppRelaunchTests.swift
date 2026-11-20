// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

@main @MainActor struct AppRelaunchTests {
    private static var checks = 0
    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        guard condition() else { fatalError("FAIL: \(message)") }
    }
    /// A stand-in for the old app process: lives until terminated.
    private static func sleeper(_ seconds: String) -> Process {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/sleep"); process.arguments = [seconds]
        try! process.run(); return process
    }
    static func main() {
        // Single instance. No app is launched by this suite.
        expect(!AppRelaunch.shouldYield(current: 10, others: []), "the only copy keeps running")
        expect(!AppRelaunch.shouldYield(current: 10, others: [(10, false)]), "a copy does not yield to itself")
        expect(AppRelaunch.shouldYield(current: 10, others: [(10, false), (7, false)]), "a second copy yields to the one already running")
        expect(!AppRelaunch.shouldYield(current: 10, others: [(7, true)]), "a copy that has already terminated does not count")
        expect(AppRelaunch.shouldYield(current: 10, others: [(7, true), (8, false)]), "any live copy is enough")

        // The helper: the "opener" here only creates a marker file in a temporary folder.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("keyglow-relaunch-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

        let arguments = AppRelaunch.helperArguments(waitingFor: 4242, bundlePath: "/Applications/Key glow's \"copy\".app")
        expect(arguments == ["-c", AppRelaunch.waitThenOpen, "keyglow-relaunch", "4242", "/Applications/Key glow's \"copy\".app", "/usr/bin/open", "100"], "values travel as arguments")
        expect(!AppRelaunch.waitThenOpen.contains("4242") && !AppRelaunch.waitThenOpen.contains("Applications"), "nothing is pasted into the script text")

        // 1. The bundle is opened only after the old process has exited.
        let old = sleeper("30")
        let marker = root.appendingPathComponent("opened after exit; with 'quotes' & spaces")
        let helper = try! AppRelaunch.startHelper(waitingFor: old.processIdentifier, bundlePath: marker.path, opener: "/usr/bin/touch", waitTenths: 100)
        Thread.sleep(forTimeInterval: 0.8)
        expect(old.isRunning && helper.isRunning && !exists(marker), "while the old process lives, nothing is opened")
        old.terminate(); old.waitUntilExit(); helper.waitUntilExit()
        expect(helper.terminationStatus == 0 && exists(marker), "after it exits, the bundle is opened once, with its path intact")

        // 2. If the old process never exits, no second copy is opened.
        let stuck = sleeper("30")
        let never = root.appendingPathComponent("must-not-exist")
        let timeout = try! AppRelaunch.startHelper(waitingFor: stuck.processIdentifier, bundlePath: never.path, opener: "/usr/bin/touch", waitTenths: 5)
        timeout.waitUntilExit()
        expect(timeout.terminationStatus == 3 && !exists(never) && stuck.isRunning, "a process that does not quit never gets a second copy")
        stuck.terminate(); stuck.waitUntilExit()

        // 3. The app cancels the helper when quitting was refused.
        let refused = sleeper("30")
        let cancelled = root.appendingPathComponent("cancelled")
        let pending = try! AppRelaunch.startHelper(waitingFor: refused.processIdentifier, bundlePath: cancelled.path, opener: "/usr/bin/touch", waitTenths: 100)
        Thread.sleep(forTimeInterval: 0.3); pending.terminate(); pending.waitUntilExit()
        refused.terminate(); refused.waitUntilExit(); Thread.sleep(forTimeInterval: 0.4)
        expect(!exists(cancelled), "a cancelled helper opens nothing, even when the process exits later")

        // 4. A process that is already gone: open at once.
        let gone = sleeper("0"); gone.waitUntilExit()
        let immediate = root.appendingPathComponent("immediate")
        let quick = try! AppRelaunch.startHelper(waitingFor: gone.processIdentifier, bundlePath: immediate.path, opener: "/usr/bin/touch")
        quick.waitUntilExit()
        expect(quick.terminationStatus == 0 && exists(immediate), "nothing to wait for opens immediately")
        print("App relaunch: \(checks) checks passed (stand-in processes and a temporary folder; no app launched).")
    }
}
