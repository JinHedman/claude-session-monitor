import AppKit

/// Brings to front the terminal window/tab whose session is running in `projectPath`.
/// Supports iTerm2, Terminal.app, and Ghostty (including multi-tab).
enum TerminalFocus {

    private static let ghosttyBundleId  = "com.mitchellh.ghostty"
    private static let iterm2BundleId   = "com.googlecode.iterm2"
    private static let terminalBundleId = "com.apple.Terminal"

    static func focus(projectPath: String, sessionId: String? = nil, transcriptPath: String? = nil, tty: String? = nil) {
        DispatchQueue.global(qos: .userInitiated).async {
            // If we already have a TTY from the hook event, skip expensive discovery
            let resolvedTTY: String?
            if let knownTTY = tty, !knownTTY.isEmpty {
                resolvedTTY = knownTTY
            } else {
                resolvedTTY = findTTY(forPath: projectPath, sessionId: sessionId, transcriptPath: transcriptPath)
            }
            DispatchQueue.main.async {
                doFocus(tty: resolvedTTY, projectPath: projectPath)
            }
        }
    }

    private static func doFocus(tty: String?, projectPath: String) {
        // Try Ghostty first if it's running (most common for users who use it)
        if isRunning(ghosttyBundleId) {
            focusGhostty(tty: tty, projectPath: projectPath)
            return
        }
        if let tty {
            if isRunning(iterm2BundleId)   && focusiTerm(tty: tty)      { return }
            if isRunning(terminalBundleId) && focusTerminalApp(tty: tty) { return }
        }
        activateAnyTerminal()
    }

    // MARK: - TTY discovery

    private static func findTTY(forPath projectPath: String, sessionId: String? = nil, transcriptPath: String? = nil) -> String? {
        let task = Process()
        task.launchPath = "/bin/bash"
        // Strategy A: transcript file → lsof → pid → tty
        //   Claude keeps the transcript JSONL open during the session.
        //   This is the most reliable method since we know the exact file.
        // Strategy B: sessionId → task dir → lsof → pid → tty
        // Strategy C: scan shell/claude processes by CWD matching
        task.arguments = ["-c", """
            # Strategy A: transcript file → pid → tty
            if [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ]; then
                pid=$(lsof "$TRANSCRIPT_PATH" 2>/dev/null | awk 'NR>1 && $4~/[0-9]/{print $2; exit}')
                if [ -n "$pid" ]; then
                    tty=$(ps -p "$pid" -o tty= 2>/dev/null | tr -d ' ')
                    if [ -n "$tty" ] && [ "$tty" != "??" ]; then
                        printf '%s' "$tty"
                        exit 0
                    fi
                    # Claude's own process might not have a TTY, try its parent
                    ppid=$(ps -p "$pid" -o ppid= 2>/dev/null | tr -d ' ')
                    if [ -n "$ppid" ]; then
                        tty=$(ps -p "$ppid" -o tty= 2>/dev/null | tr -d ' ')
                        if [ -n "$tty" ] && [ "$tty" != "??" ]; then
                            printf '%s' "$tty"
                            exit 0
                        fi
                    fi
                fi
            fi
            # Strategy B: sessionId -> task dir -> pid -> tty
            if [ -n "$SESSION_ID" ]; then
                task_dir="$HOME/.claude/tasks/$SESSION_ID"
                if [ -d "$task_dir" ]; then
                    pid=$(lsof "$task_dir" 2>/dev/null | awk 'NR>1 && $5=="DIR" {print $2; exit}')
                    if [ -n "$pid" ]; then
                        tty=$(ps -p "$pid" -o tty= 2>/dev/null | tr -d ' ')
                        if [ -n "$tty" ] && [ "$tty" != "??" ]; then
                            printf '%s' "$tty"
                            exit 0
                        fi
                    fi
                fi
            fi
            # Strategy C: scan claude/shell processes for OS CWD match
            for pid in \
                $(pgrep -a -x claude 2>/dev/null) \
                $(pgrep -a -x bash   2>/dev/null) \
                $(pgrep -a -x zsh    2>/dev/null) \
                $(pgrep -a -x fish   2>/dev/null) \
                $(pgrep -a -x sh     2>/dev/null) \
                $(pgrep -a -x node   2>/dev/null); do
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
        env["SESSION_ID"]  = sessionId ?? ""
        env["TRANSCRIPT_PATH"] = transcriptPath ?? ""
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

        // Strategy 1: TTY → process-tree tab index → Cmd+<number> keyboard shortcut
        // Uses keyboard shortcuts (Cmd+1, Cmd+2, ...) which target visual tab position,
        // immune to Window menu MRU reordering that caused reversed navigation.
        if let tty,
           let tabIndex = findGhosttyTabIndex(ghosttyPid: app.processIdentifier, tty: tty),
           tabIndex >= 1 && tabIndex <= 9 {
            app.activate(options: .activateIgnoringOtherApps)
            let script = """
            tell application "System Events"
                tell process "Ghostty"
                    keystroke "\(tabIndex)" using command down
                end tell
            end tell
            """
            var error: NSDictionary?
            NSAppleScript(source: script)?.executeAndReturnError(&error)
            if error == nil { return }
        }

        // Strategy 2: AXWindows — each native macOS tab is a separate AXWindow.
        // Match by AXDocument (CWD file URL) or window title containing the folder name.
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
            if let target = best {
                AXUIElementPerformAction(target, "AXRaise" as CFString)
                app.activate(options: .activateIgnoringOtherApps)
                return
            }
        }

        // Fallback: just activate Ghostty
        app.activate(options: .activateIgnoringOtherApps)
    }

    /// Find Ghostty tab index for a given TTY.
    /// Uses ONLY direct children of Ghostty (one login process per tab).
    /// Their PID order matches tab creation order, giving reliable Window menu indices.
    private static func findGhosttyTabIndex(ghosttyPid: pid_t, tty: String) -> Int? {
        let task = Process()
        task.launchPath = "/bin/bash"
        // Only look at direct children — deep descendants have unreliable PID ordering.
        // Each direct child (login process) has a unique TTY matching one Ghostty tab.
        // PID order of direct children = tab creation order = Window menu order.
        let pyScript = """
        import sys, subprocess
        ghostty_pid = int(sys.argv[1])
        target_tty = sys.argv[2]
        ps = subprocess.run(['ps', '-eo', 'pid,ppid,tty'], capture_output=True, text=True)
        direct = []
        for line in ps.stdout.strip().split(chr(10))[1:]:
            parts = line.split()
            if len(parts) >= 3:
                pid, ppid, tty = int(parts[0]), int(parts[1]), parts[2]
                if ppid == ghostty_pid and tty not in ('??', 'TTY'):
                    direct.append((pid, tty))
        direct.sort()
        ttys = [t for _, t in direct]
        if target_tty in ttys:
            print(ttys.index(target_tty) + 1)
        else:
            sys.exit(1)
        """
        task.arguments = ["-c", "python3 -c '\(pyScript.replacingOccurrences(of: "'", with: "'\\''"))' \(ghosttyPid) \"$TARGET_TTY\""]
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
