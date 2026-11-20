import AppKit

// Only one copy of Keyglow runs. A second launch brings the first one forward
// and ends before it creates a window or touches the keyboard.
let runningCopies = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
if AppRelaunch.shouldYield(current: getpid(), others: runningCopies.map { ($0.processIdentifier, $0.isTerminated) }) {
    runningCopies.first { $0.processIdentifier != getpid() && !$0.isTerminated }?.activate(options: [.activateAllWindows])
    DistributedNotificationCenter.default().postNotificationName(AppRelaunch.showWindowNotification, object: nil, userInfo: nil, deliverImmediately: true)
    exit(0)
}
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
