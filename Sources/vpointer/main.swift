import AppKit

// If another vpointer instance is already running, ask it to show the menu bar icon and exit.
if let bundleID = Bundle.main.bundleIdentifier {
    let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
    if running.contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
        DistributedNotificationCenter.default().postNotificationName(
            AppDelegate.showMenuBarNotification,
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
        exit(0)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let delegate = AppDelegate()
app.delegate = delegate
app.run()
