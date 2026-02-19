import AppKit

/// Brings to front the terminal window/tab whose session is running in `projectPath`.
/// Supports iTerm2, Terminal.app, and Ghostty (including multi-tab).
enum TerminalFocus {

    private static let ghosttyBundleId  = "com.mitchellh.ghostty"
    private static let iterm2BundleId   = "com.googlecode.iterm2"
    private static let terminalBundleId = "com.apple.Terminal"

    static func focus(projectPath: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            let tty = findTTY(forPath: projectPath)
            DispatchQueue.main.async {
                doFocus(tty: tty, projectPath: projectPath)
            }
        }
    }

    private static func doFocus(tty: String?, projectPath: String) {
        if let tty {
            if isRunning(iterm2BundleId)   && focusiTerm(tty: tty)      { return }
            if isRunning(terminalBundleId) && focusTerminalApp(tty: tty) { return }
        }
        // Pass tty to Ghostty focus so we can use process-tree matching
        if isRunning(ghosttyBundleId) { focusGhostty(tty: tty, projectPath: projectPath); return }
        activateAnyTerminal()
    }

    // MARK: - TTY discovery

    private static func findTTY(forPath projectPath: String) -> String? {
        let task = Process()
        task.launchPath = "/bin/bash"
        task.arguments = ["-c", """
            for pid in \
                $(pgrep -x bash   2>/dev/null) \
                $(pgrep -x zsh    2>/dev/null) \
                $(pgrep -x fish   2>/dev/null) \
                $(pgrep -x sh     2>/dev/null) \
                $(pgrep -x node   2>/dev/null) \
                $(pgrep -x claude 2>/dev/null); do
                cwd=$(lsof -p "$pid" 2>/dev/null | awk '$4=="cwd"{print $NF; exit}')
                if [ "$cwd" = "$TARGET_PATH" ]; then
                    tty=$(ps -p "$pid" -o tty= 2>/dev/null | tr -d ' ')
                    if [ -n "$tty" ] && [ "$tty" != "??" ]; then
                        printf '%s' "$tty"
                        exit 0
                    fi
                fi
            done
            exit 1
        """]
        var env = ProcessInfo.processInfo.environment
        env["TARGET_PATH"] = projectPath
        task.environment = env
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError  = Pipe()
        try? task.run()
        task.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let tty = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return tty.isEmpty || tty == "??" ? nil : tty
    }

    // MARK: - iTerm2

    @discardableResult
    private static func focusiTerm(tty: String) -> Bool {
        let ttyPath = tty.hasPrefix("/dev/") ? tty : "/dev/\(tty)"
        let script = """
        tell application "iTerm2"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        try
                            if tty of s is "\(ttyPath)" then
                                select w
                                select t
                                activate
                                return true
                            end if
                        end try
                    end repeat
                end repeat
            end repeat
        end tell
        return false
        """
        return scriptReturnedTrue(script)
    }

    // MARK: - Terminal.app

    @discardableResult
    private static func focusTerminalApp(tty: String) -> Bool {
        let ttyPath = tty.hasPrefix("/dev/") ? tty : "/dev/\(tty)"
        let script = """
        tell application "Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    try
                        if tty of t is "\(ttyPath)" then
                            set selected of t to true
                            set frontmost of w to true
                            activate
                            return true
                        end if
                    end try
                end repeat
            end repeat
        end tell
        return false
        """
        return scriptReturnedTrue(script)
    }

    // MARK: - Ghostty

    private static func focusGhostty(tty: String?, projectPath: String) {
        guard let app = NSWorkspace.shared.runningApplications
                .first(where: { $0.bundleIdentifier == ghosttyBundleId }) else { return }

        let folderName = (projectPath as NSString).lastPathComponent

        // Strategy 1: Process-tree tab index → click the Nth tab entry in Window menu.
        // Tab entries appear after "Arrange in Front" in Ghostty's Window menu.
        if let tty,
           let tabIndex = findGhosttyTabIndex(ghosttyPid: app.processIdentifier, tty: tty) {
            let script = """
            tell application "System Events"
                tell process "Ghostty"
                    try
                        set windowMenu to menu "Window" of menu bar 1
                        set tabEntries to {}
                        set pastArrange to false
                        repeat with mi in menu items of windowMenu
                            try
                                set n to name of mi
                                if n is "Arrange in Front" then
                                    set pastArrange to true
                                else if pastArrange and n is not missing value and n is not "" then
                                    set end of tabEntries to mi
                                end if
                            end try
                        end repeat
                        if (count of tabEntries) >= \(tabIndex) then
                            click item \(tabIndex) of tabEntries
                            set frontmost to true
                            return true
                        end if
                    end try
                end tell
            end tell
            return false
            """
            if scriptReturnedTrue(script) {
                app.activate(options: .activateIgnoringOtherApps)
                return
            }
        }

        // Strategy 2: Search tab entries in Window menu for one containing the folder name.
        let menuScript = """
        tell application "System Events"
            tell process "Ghostty"
                try
                    set windowMenu to menu "Window" of menu bar 1
                    set pastArrange to false
                    repeat with mi in menu items of windowMenu
                        try
                            set n to name of mi
                            if n is "Arrange in Front" then
                                set pastArrange to true
                            else if pastArrange and n contains "\(folderName)" then
                                click mi
                                set frontmost to true
                                return true
                            end if
                        end try
                    end repeat
                end try
            end tell
        end tell
        return false
        """
        if scriptReturnedTrue(menuScript) {
            app.activate(options: .activateIgnoringOtherApps)
            return
        }

        // Strategy 3: AXWindows — each native macOS tab is a separate AXWindow.
        // Match by AXDocument (CWD file URL) or window title.
        let pid = app.processIdentifier
        let axApp = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(axApp, "AXWindows" as CFString, &windowsRef) == .success,
           let windows = windowsRef as? [AXUIElement], !windows.isEmpty {
            var best: AXUIElement? = nil
            for win in windows {
                var docRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(win, "AXDocument" as CFString, &docRef) == .success,
                   let doc = docRef as? String,
                   doc.contains(projectPath) || doc.contains(folderName) {
                    best = win; break
                }
                var titleRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(win, "AXTitle" as CFString, &titleRef) == .success,
                   let title = titleRef as? String, title.contains(folderName) {
                    best = win
                }
            }
            AXUIElementPerformAction(best ?? windows[0], "AXRaise" as CFString)
        }

        app.activate(options: .activateIgnoringOtherApps)
    }

    /// Walk Ghostty's child processes (sorted by PID = creation/tab order),
    /// find the one whose TTY (or grandchild's TTY) matches, return 1-based index.
    private static func findGhosttyTabIndex(ghosttyPid: pid_t, tty: String) -> Int? {
        let task = Process()
        task.launchPath = "/bin/bash"
        task.arguments = ["-c", """
            index=1
            for child_pid in $(pgrep -P \(ghosttyPid) 2>/dev/null | sort -n); do
                child_tty=$(ps -p "$child_pid" -o tty= 2>/dev/null | tr -d ' ')
                if [ "$child_tty" = "$TARGET_TTY" ] && [ "$child_tty" != "??" ]; then
                    echo $index; exit 0
                fi
                for gc_pid in $(pgrep -P "$child_pid" 2>/dev/null | sort -n); do
                    gc_tty=$(ps -p "$gc_pid" -o tty= 2>/dev/null | tr -d ' ')
                    if [ "$gc_tty" = "$TARGET_TTY" ] && [ "$gc_tty" != "??" ]; then
                        echo $index; exit 0
                    fi
                done
                index=$((index + 1))
            done
            exit 1
        """]
        var env = ProcessInfo.processInfo.environment
        env["TARGET_TTY"] = tty
        task.environment = env
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError  = Pipe()
        try? task.run()
        task.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return Int(out.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: - Helpers

    /// Returns true only if the AppleScript itself returned `true`.
    /// An error-free script that found nothing returns `false` via the descriptor.
    private static func scriptReturnedTrue(_ source: String) -> Bool {
        var error: NSDictionary?
        let descriptor = NSAppleScript(source: source)?.executeAndReturnError(&error)
        guard error == nil else { return false }
        return descriptor?.booleanValue == true
    }

    private static func activateAnyTerminal() {
        for id in [ghosttyBundleId, iterm2BundleId, terminalBundleId] {
            if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == id }) {
                app.activate(options: .activateIgnoringOtherApps)
                return
            }
        }
    }

    private static func isRunning(_ bundleId: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleId }
    }
}
