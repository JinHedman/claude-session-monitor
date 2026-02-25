package main

import (
	"fmt"
	"os"
	"os/exec"
	"strings"
	"time"
)

// focusDeps holds injectable dependencies for testability.
type focusDeps struct {
	getMenuItems   func() ([]string, error)
	clickItem      func(name string) error
	activateApp    func() error
	writeTitle     func(tty, basename string) error
	waitAfterWrite time.Duration
}

// scriptGetMenuItems returns newline-separated Window menu item names.
const scriptGetMenuItems = `
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
`

// scriptClickMenuItem clicks a named Window menu item.
const scriptClickMenuItem = `
on run argv
  set targetName to item 1 of argv
  tell application "Ghostty" to activate
  tell application "System Events"
    tell process "Ghostty"
      set frontmost to true
      try
        click menu item targetName of menu "Window" of menu bar 1
        return "found"
      end try
    end tell
  end tell
  return "not_found"
end run
`

// systemMenuItems is the set of known Ghostty UI menu items to filter out.
var systemMenuItems = map[string]bool{
	"Minimize":                true,
	"Minimize All":            true,
	"Zoom":                    true,
	"Zoom All":                true,
	"Fill":                    true,
	"Center":                  true,
	"Move & Resize":           true,
	"Full Screen Tile":        true,
	"Toggle Full Screen":      true,
	"Show/Hide All Terminals": true,
	"Show Previous Tab":       true,
	"Show Next Tab":           true,
	"Move Tab to New Window":  true,
	"Merge All Windows":       true,
	"Zoom Split":              true,
	"Select Previous Split":   true,
	"Select Next Split":       true,
	"Select Split":            true,
	"Resize Split":            true,
	"Return To Default Size":  true,
	"Float on Top":            true,
	"Use as Default":          true,
	"Bring All to Front":      true,
	"Arrange in Front":        true,
	"Remove Window from Set":  true,
	"missing value":           true,
	"":                        true,
}

// isSystemMenuItem returns true if the item is a known Ghostty UI element.
func isSystemMenuItem(name string) bool {
	return systemMenuItems[name]
}

// filterTabItems returns only non-system menu items (i.e. actual tabs).
// TrimRight strips only trailing \r and \n so CRLF osascript output is handled
// without disturbing any leading whitespace that AppleScript preserves in item names.
func filterTabItems(items []string) []string {
	var tabs []string
	for _, item := range items {
		item = strings.TrimRight(item, "\r\n")
		if !isSystemMenuItem(item) {
			tabs = append(tabs, item)
		}
	}
	return tabs
}

// matchTab finds the best-matching tab item for the given cwd basename.
// Pass 1: item contains "claude:<cwdBasename>".
// Pass 2: item contains bare cwdBasename.
// Returns "" if no match.
func matchTab(tabItems []string, cwdBasename string) string {
	if cwdBasename == "" {
		return ""
	}
	// Pass 1: claude: prefix
	for _, item := range tabItems {
		if strings.Contains(item, "claude:"+cwdBasename) {
			return item
		}
	}
	// Pass 2: bare folder name
	for _, item := range tabItems {
		if strings.Contains(item, cwdBasename) {
			return item
		}
	}
	return ""
}

// realDeps returns production wiring using osascript.
func realDeps() focusDeps {
	return focusDeps{
		getMenuItems: func() ([]string, error) {
			out, err := runOsascript(scriptGetMenuItems)
			if err != nil {
				return nil, err
			}
			return strings.Split(out, "\n"), nil
		},
		clickItem: func(name string) error {
			out, err := runOsascript(scriptClickMenuItem, name)
			if err != nil {
				return err
			}
			if strings.TrimSpace(out) != "found" {
				return fmt.Errorf("menu item not found: %s", name)
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
		waitAfterWrite: 200 * time.Millisecond,
	}
}

// focusGhosttyTab is the testable core logic.
func focusGhosttyTab(deps focusDeps, tty, cwd string) error {
	cwdBasename := lastPathComponent(cwd)

	// Write the OSC title to the session's TTY right before menu lookup.
	// At click time, Claude is likely idle and won't immediately override.
	if tty != "" && cwdBasename != "" && deps.writeTitle != nil {
		_ = deps.writeTitle(tty, cwdBasename)
		if deps.waitAfterWrite > 0 {
			time.Sleep(deps.waitAfterWrite)
		}
	}

	items, err := deps.getMenuItems()
	if err != nil {
		_ = deps.activateApp()
		return nil
	}

	tabs := filterTabItems(items)
	matched := matchTab(tabs, cwdBasename)
	if matched != "" {
		if err := deps.clickItem(matched); err != nil {
			_ = deps.activateApp()
			return nil
		}
		return nil
	}

	_ = deps.activateApp()
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
