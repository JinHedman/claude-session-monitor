package main

import (
	"fmt"
	"os"
	"os/exec"
	"sort"
	"strconv"
	"strings"
	"time"
)

// focusDeps holds injectable dependencies for testability.
type focusDeps struct {
	// Strategy 2: single merged osascript search+click
	focusTab       func(cwdBasename string) error
	activateApp    func() error
	writeTitle     func(tty, basename string) error
	waitAfterWrite time.Duration
	// Strategy 1: tab index lookup + Cmd+N keystroke
	getGhosttyPID func() (int, error)
	sendKeyNToTab func(tabIndex int) error
	// findTabIndex is injectable for testing; nil means use findGhosttyTabIndexFromPS via real ps
	findTabIndex func(pid int, tty string) int
}

// scriptFocusTab finds a Window menu tab matching targetName and clicks it.
// argv[1] = cwdBasename (e.g. "myproject")
// Returns "found" if clicked, "not_found" otherwise.
const scriptFocusTab = `
on run argv
  set targetName to item 1 of argv
  tell application "Ghostty" to activate
  tell application "System Events"
    tell process "Ghostty"
      set frontmost to true
      set winMenu to menu "Window" of menu bar 1
      -- Pass 1: claude:<targetName> prefix match
      repeat with i from 1 to count of menu items of winMenu
        try
          set n to name of menu item i of winMenu
          if n contains ("claude:" & targetName) then
            click menu item i of winMenu
            return "found"
          end if
        end try
      end repeat
      -- Pass 2: bare targetName substring match
      repeat with i from 1 to count of menu items of winMenu
        try
          set n to name of menu item i of winMenu
          if n contains targetName then
            click menu item i of winMenu
            return "found"
          end if
        end try
      end repeat
    end tell
  end tell
  return "not_found"
end run
`

// scriptSendCmdN sends Cmd+<N> to switch to tab N in Ghostty.
const scriptSendCmdN = `
on run argv
  set tabNum to (item 1 of argv) as integer
  -- macOS key codes for 1-9: 18,19,20,21,23,22,26,28,25
  set keyCodes to {18, 19, 20, 21, 23, 22, 26, 28, 25}
  set kc to item tabNum of keyCodes
  tell application "Ghostty" to activate
  tell application "System Events"
    key code kc using command down
  end tell
end run
`

// getGhosttyPID returns the PID of the running Ghostty process.
// pgrep -x doesn't work for macOS GUI apps because ps comm shows the full executable
// path. We scan ps output instead.
func getGhosttyPID() (int, error) {
	out, err := exec.Command("ps", "-eo", "pid,comm").Output()
	if err != nil {
		return 0, err
	}
	for _, line := range strings.Split(string(out), "\n")[1:] {
		fields := strings.Fields(line)
		if len(fields) >= 2 &&
			strings.Contains(fields[1], "Ghostty.app") &&
			strings.HasSuffix(fields[1], "/ghostty") {
			pid, err := strconv.Atoi(fields[0])
			if err != nil {
				continue
			}
			return pid, nil
		}
	}
	return 0, fmt.Errorf("Ghostty not running")
}

// findGhosttyTabIndexFromPS returns the 1-based tab index of tty among direct
// children of ghosttyPID, determined by sorting child PIDs ascending.
// psOutput is the raw output of "ps -eo pid,ppid,tty" (passed in for testability).
// Returns 0 if not found or inputs are invalid.
func findGhosttyTabIndexFromPS(ghosttyPID int, tty string, psOutput string) int {
	if tty == "" || ghosttyPID == 0 {
		return 0
	}
	// Strip /dev/ prefix for comparison with ps tty field (e.g. "ttys001" → "s001" is NOT right;
	// ps uses "s001" but the tty string may be "ttys001". Normalise: strip /dev/ then use as-is.
	bare := strings.TrimPrefix(tty, "/dev/")

	type entry struct {
		pid int
		tty string
	}
	var direct []entry

	lines := strings.Split(psOutput, "\n")
	if len(lines) > 0 {
		lines = lines[1:] // skip header
	}
	for _, line := range lines {
		fields := strings.Fields(line)
		if len(fields) < 3 {
			continue
		}
		pid, err1 := strconv.Atoi(fields[0])
		ppid, err2 := strconv.Atoi(fields[1])
		ttyField := fields[2]
		if err1 != nil || err2 != nil || ppid != ghosttyPID || ttyField == "??" || ttyField == "TTY" {
			continue
		}
		direct = append(direct, entry{pid, ttyField})
	}
	sort.Slice(direct, func(i, j int) bool { return direct[i].pid < direct[j].pid })
	for i, e := range direct {
		if e.tty == bare {
			return i + 1 // 1-based
		}
	}
	return 0
}

// realFindTabIndex runs real ps and calls findGhosttyTabIndexFromPS.
func realFindTabIndex(pid int, tty string) int {
	out, err := exec.Command("ps", "-eo", "pid,ppid,tty").Output()
	if err != nil {
		return 0
	}
	return findGhosttyTabIndexFromPS(pid, tty, string(out))
}

// realDeps returns production wiring using osascript.
func realDeps() focusDeps {
	return focusDeps{
		focusTab: func(cwdBasename string) error {
			out, err := runOsascript(scriptFocusTab, cwdBasename)
			if err != nil {
				return err
			}
			if strings.TrimSpace(out) != "found" {
				return fmt.Errorf("tab not found: %s", cwdBasename)
			}
			return nil
		},
		activateApp: func() error {
			_, err := runOsascript(`tell application "Ghostty" to activate`)
			return err
		},
		writeTitle: func(tty, basename string) error {
			if tty == "" {
				return nil
			}
			dev := tty
			if !strings.HasPrefix(dev, "/dev/") {
				dev = "/dev/" + tty
			}
			f, err := os.OpenFile(dev, os.O_WRONLY, 0)
			if err != nil {
				return err
			}
			defer f.Close()
			_, err = fmt.Fprintf(f, "\033]0;claude:%s\007", basename)
			return err
		},
		waitAfterWrite: 75 * time.Millisecond,
		getGhosttyPID: getGhosttyPID,
		sendKeyNToTab: func(tabIndex int) error {
			_, err := runOsascript(scriptSendCmdN, strconv.Itoa(tabIndex))
			return err
		},
		findTabIndex: realFindTabIndex,
	}
}

// focusGhosttyTab is the testable core logic.
func focusGhosttyTab(deps focusDeps, tty, cwd string) error {
	cwdBasename := lastPathComponent(cwd)

	// Strategy 1: TTY → tab index → Cmd+N (fast path, no sleep needed)
	if deps.getGhosttyPID != nil && deps.sendKeyNToTab != nil && tty != "" {
		if pid, err := deps.getGhosttyPID(); err == nil && pid > 0 {
			var idx int
			if deps.findTabIndex != nil {
				idx = deps.findTabIndex(pid, tty)
			} else {
				idx = realFindTabIndex(pid, tty)
			}
			if idx >= 1 && idx <= 9 {
				if err := deps.sendKeyNToTab(idx); err == nil {
					return nil
				}
			}
		}
	}

	// Strategy 2: write OSC title, wait for Ghostty to process it, then search+click.
	if tty != "" && cwdBasename != "" && deps.writeTitle != nil {
		_ = deps.writeTitle(tty, cwdBasename)
		if deps.waitAfterWrite > 0 {
			time.Sleep(deps.waitAfterWrite)
		}
	}
	if err := deps.focusTab(cwdBasename); err != nil {
		_ = deps.activateApp()
		return nil
	}
	return nil
}

// FocusGhosttyTab is the public entry point. Called by model.go.
func FocusGhosttyTab(tty string, cwd string) error {
	return focusGhosttyTab(realDeps(), tty, cwd)
}

// runOsascript runs an AppleScript string with optional arguments.
func runOsascript(script string, args ...string) (string, error) {
	cmdArgs := []string{"-e", script}
	cmdArgs = append(cmdArgs, args...)
	cmd := exec.Command("osascript", cmdArgs...)
	out, err := cmd.Output()
	return string(out), err
}

// lastPathComponent returns the last non-empty component of a file path.
func lastPathComponent(path string) string {
	parts := strings.Split(strings.TrimRight(path, "/"), "/")
	for i := len(parts) - 1; i >= 0; i-- {
		if parts[i] != "" {
			return parts[i]
		}
	}
	return ""
}
