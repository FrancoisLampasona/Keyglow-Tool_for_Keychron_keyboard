// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// One running copy of Keyglow, and a relaunch that opens the new copy only
/// after the old process has really exited. Two copies would both watch the
/// keyboard and both show the setup guide.
enum AppRelaunch {
    static let showWindowNotification = Notification.Name("local.tastiera.bluetooth-prototype.show-window")

    /// A newly started copy gives way to any other copy that is still running.
    static func shouldYield(current: Int32, others: [(pid: Int32, terminated: Bool)]) -> Bool {
        others.contains { $0.pid != current && !$0.terminated }
    }

    /// `$1` process to wait for, `$2` bundle to open, `$3` opener, `$4` longest wait in tenths of a second.
    /// If the process is still alive when the wait ends, nothing is opened.
    static let waitThenOpen = #"i=0; while kill -0 "$1" 2>/dev/null; do i=$((i+1)); if [ "$i" -ge "$4" ]; then exit 3; fi; sleep 0.1; done; exec "$3" "$2""#

    /// Values are passed as arguments, never pasted into the script text.
    static func helperArguments(waitingFor pid: Int32, bundlePath: String, opener: String = "/usr/bin/open", waitTenths: Int = 100) -> [String] {
        ["-c", waitThenOpen, "keyglow-relaunch", String(pid), bundlePath, opener, String(max(1, waitTenths))]
    }

    /// Starts the detached helper. It outlives this process and opens the bundle once it is gone.
    static func startHelper(waitingFor pid: Int32, bundlePath: String, opener: String = "/usr/bin/open", waitTenths: Int = 100) throws -> Process {
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = helperArguments(waitingFor: pid, bundlePath: bundlePath, opener: opener, waitTenths: waitTenths)
        helper.standardInput = FileHandle.nullDevice; helper.standardOutput = FileHandle.nullDevice; helper.standardError = FileHandle.nullDevice
        try helper.run()
        return helper
    }
}
