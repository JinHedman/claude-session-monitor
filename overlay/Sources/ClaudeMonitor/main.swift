import AppKit

// Single-instance guard: exit if another ClaudeMonitor is already running.
let runningInstances = NSWorkspace.shared.runningApplications.filter {
    $0.bundleIdentifier == nil &&  // CLI apps have no bundle ID
    $0.processIdentifier != ProcessInfo.processInfo.processIdentifier &&
    ($0.executableURL?.lastPathComponent == "ClaudeMonitor")
}
if !runningInstances.isEmpty {
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // No Dock icon or app switcher entry
app.run()
