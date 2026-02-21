import AppKit

// Single-instance guard: exit if another ClaudeMonitor is already running.
// Match by bundle identifier (when running as .app) or executable name (bare binary).
let myPID = ProcessInfo.processInfo.processIdentifier
let runningInstances = NSWorkspace.shared.runningApplications.filter {
    $0.processIdentifier != myPID && (
        $0.bundleIdentifier == "com.jinhedman.claude-monitor" ||
        $0.executableURL?.lastPathComponent == "ClaudeMonitor"
    )
}
if !runningInstances.isEmpty {
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // No Dock icon or app switcher entry
app.run()
