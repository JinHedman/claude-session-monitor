import AppKit

/// Injectable dependencies for testable Ghostty focus logic.
struct GhosttyFocusDeps {
    var writeTitle: (_ tty: String, _ basename: String) -> Void
    var getMenuItems: () -> [String]
    var clickItem: (_ name: String) -> Bool
    var activateApp: () -> Void
    var waitAfterWrite: TimeInterval

    static func real() -> GhosttyFocusDeps {
        GhosttyFocusDeps(
            writeTitle: { tty, basename in
                let dev = tty.hasPrefix("/dev/") ? tty : "/dev/\(tty)"
                guard let fh = FileHandle(forWritingAtPath: dev) else { return }
                let osc = "\u{1B}]0;claude:\(basename)\u{07}"
                fh.write(osc.data(using: .utf8) ?? Data())
                fh.closeFile()
            },
            getMenuItems: {
                let script = """
                tell application "System Events"
                  tell process "Ghostty"
                    set winMenu to menu "Window" of menu bar 1
                    set result to ""
                    repeat with i from 1 to count of menu items of winMenu
                      try
                        set result to result & (name of menu item i of winMenu) & linefeed
                      on error
                        set result to result & "missing value" & linefeed
                      end try
                    end repeat
                    return result
                  end tell
                end tell
                """
                var error: NSDictionary?
                guard let val = NSAppleScript(source: script)?
                    .executeAndReturnError(&error).stringValue,
                      error == nil else { return [] }
                return val.components(separatedBy: "\n")
            },
            clickItem: { name in
                let safe = name.replacingOccurrences(of: "\"", with: "\\\"")
                let script = """
                tell application "Ghostty" to activate
                tell application "System Events"
                    tell process "Ghostty"
                        set frontmost to true
                        try
                            click menu item "\(safe)" of menu "Window" of menu bar 1
                            return true
                        end try
                    end tell
                end tell
                return false
                """
                var error: NSDictionary?
                let d = NSAppleScript(source: script)?.executeAndReturnError(&error)
                return error == nil && d?.booleanValue == true
            },
            activateApp: {
                NSWorkspace.shared.runningApplications
                    .first { $0.bundleIdentifier == "com.mitchellh.ghostty" }?
                    .activate(options: .activateIgnoringOtherApps)
            },
            waitAfterWrite: 0.2
        )
    }
}

// Mirror of tui/focus.go's systemMenuItems — keep in sync
private let systemMenuItemsSet: Set<String> = [
    "Minimize", "Minimize All", "Zoom", "Zoom All", "Fill", "Center",
    "Move & Resize", "Full Screen Tile", "Toggle Full Screen",
    "Show/Hide All Terminals", "Show Previous Tab", "Show Next Tab",
    "Move Tab to New Window", "Merge All Windows", "Zoom Split",
    "Select Previous Split", "Select Next Split", "Select Split",
    "Resize Split", "Return To Default Size", "Float on Top",
    "Use as Default", "Bring All to Front", "Arrange in Front",
    "Remove Window from Set", "missing value", ""
]

func isSystemMenuItem(_ name: String) -> Bool {
    systemMenuItemsSet.contains(name)
}

func filterTabItems(_ items: [String]) -> [String] {
    items.compactMap { item -> String? in
        // Strip trailing \r\n only (mirrors TrimRight in Go — preserves leading whitespace)
        let trimmed = item.trimmingCharacters(in: CharacterSet(charactersIn: "\r\n"))
        return isSystemMenuItem(trimmed) ? nil : trimmed
    }
}

/// Pass 1: item contains "claude:<cwdBasename>".
/// Pass 2: item contains bare cwdBasename.
/// Returns nil if no match.
func matchTab(items: [String], cwdBasename: String) -> String? {
    guard !cwdBasename.isEmpty else { return nil }
    if let match = items.first(where: { $0.contains("claude:\(cwdBasename)") }) {
        return match
    }
    return items.first(where: { $0.contains(cwdBasename) })
}

/// Testable core of Ghostty tab focusing.
/// Called from TerminalFocus.focusGhostty() with real deps, and from tests with mocks.
func focusGhosttyWithDeps(_ deps: GhosttyFocusDeps, ghosttyTTY: String, projectPath: String) {
    let basename = (projectPath as NSString).lastPathComponent

    // Write-then-click: set the OSC title right before querying the menu.
    // Claude Code overrides the tab title while active; writing at click time
    // (when the user has just tapped the focus button) means Claude is likely idle.
    if !ghosttyTTY.isEmpty && !basename.isEmpty {
        deps.writeTitle(ghosttyTTY, basename)
        if deps.waitAfterWrite > 0 {
            Thread.sleep(forTimeInterval: deps.waitAfterWrite)
        }
    }

    let items = deps.getMenuItems()
    let tabs = filterTabItems(items)
    if let matched = matchTab(items: tabs, cwdBasename: basename) {
        if deps.clickItem(matched) { return }
    }

    deps.activateApp()
}

/// Brings to front the terminal window/tab whose session is running in `projectPath`.
/// Supports iTerm2, Terminal.app, and Ghostty (including multi-tab).
enum TerminalFocus {

    private static let ghosttyBundleId  = "com.mitchellh.ghostty"
    private static let iterm2BundleId   = "com.googlecode.iterm2"
    private static let terminalBundleId = "com.apple.Terminal"

    static func focus(projectPath: String, sessionId: String? = nil, transcriptPath: String? = nil, tty: String? = nil, ghosttyTTY: String? = nil) {
        DispatchQueue.global(qos: .userInitiated).async {
            // If we already have a TTY from the hook event, skip expensive discovery
            let resolvedTTY: String?
            if let knownTTY = tty, !knownTTY.isEmpty {
                resolvedTTY = knownTTY
            } else {
                resolvedTTY = findTTY(forPath: projectPath, sessionId: sessionId, transcriptPath: transcriptPath)
            }
            DispatchQueue.main.async {
                doFocus(tty: resolvedTTY, ghosttyTTY: ghosttyTTY, projectPath: projectPath)
            }
        }
    }

    private static func doFocus(tty: String?, ghosttyTTY: String?, projectPath: String) {
        // Try Ghostty first if it's running (most common for users who use it)
        if isRunning(ghosttyBundleId) {
            focusGhostty(tty: tty, ghosttyTTY: ghosttyTTY, projectPath: projectPath)
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

    private static func focusGhostty(tty: String?, ghosttyTTY: String?, projectPath: String) {
        guard let app = NSWorkspace.shared.runningApplications
                .first(where: { $0.bundleIdentifier == ghosttyBundleId }) else { return }

        // Strategy 1: TTY → process-tree tab index → Cmd+<number> via key code
        // Prefer ghosttyTTY (outer Ghostty TTY) over tty (may be inner tmux PTY)
        let outerTTY = (ghosttyTTY?.isEmpty == false) ? ghosttyTTY : tty
        if let outer = outerTTY, !outer.isEmpty,
           let tabIndex = findGhosttyTabIndex(ghosttyPid: app.processIdentifier, tty: outer),
           tabIndex >= 1 && tabIndex <= 9 {
            let keyCodes = [0, 18, 19, 20, 21, 23, 22, 26, 28, 25]
            let script = """
            tell application "Ghostty" to activate
            delay 0.15
            tell application "System Events"
                key code \(keyCodes[tabIndex]) using command down
            end tell
            """
            var error: NSDictionary?
            NSAppleScript(source: script)?.executeAndReturnError(&error)
            if error == nil { return }
        }

        // Strategy 2: Write-then-click via deps injection
        focusGhosttyWithDeps(GhosttyFocusDeps.real(), ghosttyTTY: outerTTY ?? "", projectPath: projectPath)
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
