//go:build !integration

package main

import (
	"errors"
	"fmt"
	"strings"
	"testing"
)

func TestIsSystemMenuItem(t *testing.T) {
	systemItems := []string{
		"Minimize", "Minimize All", "Zoom", "Zoom All", "Fill", "Center",
		"Move & Resize", "Full Screen Tile", "Toggle Full Screen",
		"Show/Hide All Terminals", "Show Previous Tab", "Show Next Tab",
		"Move Tab to New Window", "Merge All Windows", "Zoom Split",
		"Select Previous Split", "Select Next Split", "Select Split",
		"Resize Split", "Return To Default Size", "Float on Top",
		"Use as Default", "Bring All to Front", "Arrange in Front",
		"missing value", "",
	}
	for _, item := range systemItems {
		if !isSystemMenuItem(item) {
			t.Errorf("expected %q to be a system item", item)
		}
	}

	tabLike := []string{"claude:osc_project", "⠂ Claude Code", "tmux attach", "my-folder"}
	for _, item := range tabLike {
		if isSystemMenuItem(item) {
			t.Errorf("expected %q NOT to be a system item", item)
		}
	}
}

func TestFilterTabItems(t *testing.T) {
	// Full production-style menu with system items mixed in
	menu := []string{
		"Minimize",
		"Minimize All",
		"Zoom",
		"claude:osc_project",
		"Show Previous Tab",
		"Show Next Tab",
		"⠂ Claude Code",
		"Toggle Full Screen",
		"tmux attach",
		"missing value",
		"",
	}
	tabs := filterTabItems(menu)
	if len(tabs) != 3 {
		t.Fatalf("expected 3 tabs, got %d: %v", len(tabs), tabs)
	}
	expected := []string{"claude:osc_project", "⠂ Claude Code", "tmux attach"}
	for i, e := range expected {
		if tabs[i] != e {
			t.Errorf("tab[%d]: want %q, got %q", i, e, tabs[i])
		}
	}
}

func TestMatchTab_ClaudePrefix(t *testing.T) {
	tabs := []string{"claude:osc_project", "⠂ Claude Code", "tmux attach"}
	got := matchTab(tabs, "osc_project")
	if got != "claude:osc_project" {
		t.Errorf("want %q, got %q", "claude:osc_project", got)
	}
}

func TestMatchTab_FolderFallback(t *testing.T) {
	tabs := []string{"⠂ Claude Code", "tmux attach", "my-folder"}
	got := matchTab(tabs, "my-folder")
	if got != "my-folder" {
		t.Errorf("want %q, got %q", "my-folder", got)
	}
}

func TestMatchTab_NoMatch(t *testing.T) {
	tabs := []string{"claude:osc_project", "⠂ Claude Code", "tmux attach"}
	got := matchTab(tabs, "unknown-folder")
	if got != "" {
		t.Errorf("want empty string, got %q", got)
	}
}

func TestMatchTab_EmptyCWD(t *testing.T) {
	tabs := []string{"claude:osc_project", "⠂ Claude Code"}
	got := matchTab(tabs, "")
	if got != "" {
		t.Errorf("want empty string for empty cwdBasename, got %q", got)
	}
}

func TestFocusGhosttyTab_MatchByPrefix(t *testing.T) {
	clicked := ""
	activateCalled := false
	deps := focusDeps{
		getMenuItems: func() ([]string, error) {
			return []string{"Minimize", "claude:osc_project", "Show Next Tab"}, nil
		},
		clickItem: func(name string) error {
			clicked = name
			return nil
		},
		activateApp: func() error {
			activateCalled = true
			return nil
		},
	}
	err := focusGhosttyTab(deps, "ttys001", "/Users/filip/osc_project")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if clicked != "claude:osc_project" {
		t.Errorf("want clickItem(%q), got clickItem(%q)", "claude:osc_project", clicked)
	}
	if activateCalled {
		t.Error("activateApp should NOT have been called on success")
	}
}

func TestFocusGhosttyTab_MatchByFolder(t *testing.T) {
	clicked := ""
	deps := focusDeps{
		getMenuItems: func() ([]string, error) {
			return []string{"Minimize", "my-folder", "Show Next Tab"}, nil
		},
		clickItem: func(name string) error {
			clicked = name
			return nil
		},
		activateApp: func() error { return nil },
	}
	err := focusGhosttyTab(deps, "", "/home/user/my-folder")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if clicked != "my-folder" {
		t.Errorf("want clickItem(%q), got clickItem(%q)", "my-folder", clicked)
	}
}

func TestFocusGhosttyTab_NoMatch(t *testing.T) {
	activateCalled := false
	deps := focusDeps{
		getMenuItems: func() ([]string, error) {
			return []string{"Minimize", "claude:osc_project"}, nil
		},
		clickItem: func(name string) error { return nil },
		activateApp: func() error {
			activateCalled = true
			return nil
		},
	}
	err := focusGhosttyTab(deps, "", "/home/user/unknown")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !activateCalled {
		t.Error("activateApp should have been called when no match")
	}
}

func TestFocusGhosttyTab_GetMenuError(t *testing.T) {
	activateCalled := false
	deps := focusDeps{
		getMenuItems: func() ([]string, error) {
			return nil, errors.New("osascript failed")
		},
		clickItem: func(name string) error { return nil },
		activateApp: func() error {
			activateCalled = true
			return nil
		},
	}
	err := focusGhosttyTab(deps, "", "/home/user/project")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !activateCalled {
		t.Error("activateApp should have been called on getMenuItems error")
	}
}

func TestFocusGhosttyTab_ClickFails(t *testing.T) {
	activateCalled := false
	deps := focusDeps{
		getMenuItems: func() ([]string, error) {
			return []string{"claude:osc_project"}, nil
		},
		clickItem: func(name string) error {
			return errors.New("click failed")
		},
		activateApp: func() error {
			activateCalled = true
			return nil
		},
	}
	err := focusGhosttyTab(deps, "", "/home/user/osc_project")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !activateCalled {
		t.Error("activateApp should have been called when click fails")
	}
}

// TestFilterTabItems_CarriageReturn verifies that menu items with \r (from CRLF line
// endings) are handled correctly: system items are still filtered and tab items are
// returned without the \r. Fails with TrimRight(item, "\n"), passes with TrimSpace.
func TestFilterTabItems_CarriageReturn(t *testing.T) {
	menu := []string{"Minimize\r", "claude:myproject\r", "Zoom\r"}
	tabs := filterTabItems(menu)
	if len(tabs) != 1 {
		t.Fatalf("want 1 tab, got %d: %v", len(tabs), tabs)
	}
	if tabs[0] != "claude:myproject" {
		t.Errorf("want %q (no \\r), got %q", "claude:myproject", tabs[0])
	}
}

// TestFocusGhosttyTab_CRLFMenuItems is an end-to-end regression test for the tmux
// CRLF scenario: when getMenuItems returns items with trailing \r, the click must
// be called with the clean name (no \r), otherwise the AppleScript lookup fails.
func TestFocusGhosttyTab_CRLFMenuItems(t *testing.T) {
	clicked := ""
	activateCalled := false
	deps := focusDeps{
		getMenuItems: func() ([]string, error) {
			// Simulate AppleScript output split on \n with leftover \r
			return []string{"Minimize\r", "claude:myproject\r", "Show Next Tab\r"}, nil
		},
		clickItem: func(name string) error {
			clicked = name
			// Real AppleScript rejects names containing \r — simulate that.
			if strings.HasSuffix(name, "\r") {
				return fmt.Errorf("item not found (name contains \\r): %q", name)
			}
			return nil
		},
		activateApp: func() error {
			activateCalled = true
			return nil
		},
	}
	err := focusGhosttyTab(deps, "", "/home/user/myproject")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if clicked != "claude:myproject" {
		t.Errorf("want clickItem(%q), got clickItem(%q)", "claude:myproject", clicked)
	}
	if activateCalled {
		t.Error("activateApp should NOT be called when tab is matched and clicked successfully")
	}
}

func TestFocusGhosttyTab_WritesTitleBeforeMenuLookup(t *testing.T) {
	var callOrder []string
	clicked := ""
	deps := focusDeps{
		writeTitle: func(tty, basename string) error {
			if tty != "ttys005" || basename != "myproject" {
				t.Errorf("writeTitle called with tty=%q basename=%q", tty, basename)
			}
			callOrder = append(callOrder, "write")
			return nil
		},
		waitAfterWrite: 0,
		getMenuItems: func() ([]string, error) {
			callOrder = append(callOrder, "menu")
			return []string{"claude:myproject"}, nil
		},
		clickItem: func(name string) error {
			clicked = name
			return nil
		},
		activateApp: func() error { return nil },
	}
	_ = focusGhosttyTab(deps, "ttys005", "/Users/filip/myproject")
	if len(callOrder) < 2 || callOrder[0] != "write" || callOrder[1] != "menu" {
		t.Errorf("expected [write menu], got %v", callOrder)
	}
	if clicked != "claude:myproject" {
		t.Errorf("want click %q, got %q", "claude:myproject", clicked)
	}
}

func TestFocusGhosttyTab_EmptyTTYSkipsWrite(t *testing.T) {
	writeCalled := false
	deps := focusDeps{
		writeTitle: func(tty, basename string) error {
			writeCalled = true
			return nil
		},
		waitAfterWrite: 0,
		getMenuItems: func() ([]string, error) {
			return []string{"myproject"}, nil
		},
		clickItem:   func(name string) error { return nil },
		activateApp: func() error { return nil },
	}
	_ = focusGhosttyTab(deps, "", "/Users/filip/myproject")
	if writeCalled {
		t.Error("writeTitle should NOT be called when tty is empty")
	}
}

func TestFocusGhosttyTab_WriteTitleFailsStillMatches(t *testing.T) {
	clicked := ""
	deps := focusDeps{
		writeTitle: func(tty, basename string) error {
			return errors.New("permission denied")
		},
		waitAfterWrite: 0,
		getMenuItems: func() ([]string, error) {
			return []string{"claude:myproject"}, nil
		},
		clickItem: func(name string) error {
			clicked = name
			return nil
		},
		activateApp: func() error { return nil },
	}
	_ = focusGhosttyTab(deps, "ttys005", "/Users/filip/myproject")
	if clicked != "claude:myproject" {
		t.Errorf("should still click even after writeTitle error, got %q", clicked)
	}
}

func TestIsSystemMenuItem_RemoveWindowFromSet(t *testing.T) {
	if !isSystemMenuItem("Remove Window from Set") {
		t.Error(`"Remove Window from Set" should be a system item`)
	}
}

func TestLastPathComponent(t *testing.T) {
	cases := []struct {
		input string
		want  string
	}{
		{"/a/b/c", "c"},
		{"/a/b/c/", "c"},
		{"/", ""},
		{"", ""},
		{"single", "single"},
		{"/foo/bar", "bar"},
	}
	for _, c := range cases {
		got := lastPathComponent(c.input)
		if got != c.want {
			t.Errorf("lastPathComponent(%q) = %q, want %q", c.input, got, c.want)
		}
	}
}
