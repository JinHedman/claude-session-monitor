//go:build !integration

package main

import (
	"errors"
	"fmt"
	"testing"
	"time"
)

// ---------------------------------------------------------------------------
// Phase 1 tests — focusTab (merged osascript search+click)
// ---------------------------------------------------------------------------

func TestFocusGhosttyTab_MatchByPrefix(t *testing.T) {
	clicked := ""
	activateCalled := false
	deps := focusDeps{
		focusTab: func(cwdBasename string) error {
			clicked = cwdBasename
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
	if clicked != "osc_project" {
		t.Errorf("want focusTab(%q), got focusTab(%q)", "osc_project", clicked)
	}
	if activateCalled {
		t.Error("activateApp should NOT have been called on success")
	}
}

func TestFocusGhosttyTab_MatchByFolder(t *testing.T) {
	clicked := ""
	deps := focusDeps{
		focusTab: func(cwdBasename string) error {
			clicked = cwdBasename
			return nil
		},
		activateApp: func() error { return nil },
	}
	err := focusGhosttyTab(deps, "", "/home/user/my-folder")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if clicked != "my-folder" {
		t.Errorf("want focusTab(%q), got focusTab(%q)", "my-folder", clicked)
	}
}

func TestFocusGhosttyTab_NoMatch(t *testing.T) {
	activateCalled := false
	deps := focusDeps{
		focusTab: func(cwdBasename string) error {
			return errors.New("tab not found: unknown")
		},
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
		focusTab: func(cwdBasename string) error {
			return errors.New("osascript failed")
		},
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
		t.Error("activateApp should have been called on focusTab error")
	}
}

func TestFocusGhosttyTab_ClickFails(t *testing.T) {
	activateCalled := false
	deps := focusDeps{
		focusTab: func(cwdBasename string) error {
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
		t.Error("activateApp should have been called when focusTab fails")
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
		focusTab: func(cwdBasename string) error {
			callOrder = append(callOrder, "focus")
			clicked = cwdBasename
			return nil
		},
		activateApp: func() error { return nil },
	}
	_ = focusGhosttyTab(deps, "ttys005", "/Users/filip/myproject")
	if len(callOrder) < 2 || callOrder[0] != "write" || callOrder[1] != "focus" {
		t.Errorf("expected [write focus], got %v", callOrder)
	}
	if clicked != "myproject" {
		t.Errorf("want focusTab %q, got %q", "myproject", clicked)
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
		focusTab:    func(cwdBasename string) error { return nil },
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
		focusTab: func(cwdBasename string) error {
			clicked = cwdBasename
			return nil
		},
		activateApp: func() error { return nil },
	}
	_ = focusGhosttyTab(deps, "ttys005", "/Users/filip/myproject")
	if clicked != "myproject" {
		t.Errorf("should still focus even after writeTitle error, got %q", clicked)
	}
}

// ---------------------------------------------------------------------------
// TestLastPathComponent — unchanged
// ---------------------------------------------------------------------------

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

// ---------------------------------------------------------------------------
// Phase 2 tests — findGhosttyTabIndexFromPS + Strategy 1
// ---------------------------------------------------------------------------

const fakePSHeader = "  PID  PPID TT\n"

func TestFindGhosttyTabIndex_Found(t *testing.T) {
	// ghosttyPID=100, one child with pid=200.
	// ps TT field uses the short form (without /dev/), e.g. "ttys001".
	// bare tty after stripping /dev/ = "ttys001"
	psOutput := fakePSHeader +
		"  200   100 ttys001\n" +
		"  300   999 ttys002\n"
	idx := findGhosttyTabIndexFromPS(100, "/dev/ttys001", psOutput)
	if idx != 1 {
		t.Errorf("want 1, got %d", idx)
	}
}

func TestFindGhosttyTabIndex_NotFound(t *testing.T) {
	psOutput := fakePSHeader +
		"  200   100 ttys001\n"
	idx := findGhosttyTabIndexFromPS(100, "/dev/ttys999", psOutput)
	if idx != 0 {
		t.Errorf("want 0, got %d", idx)
	}
}

func TestFindGhosttyTabIndex_EmptyTTY(t *testing.T) {
	psOutput := fakePSHeader +
		"  200   100 ttys001\n"
	idx := findGhosttyTabIndexFromPS(100, "", psOutput)
	if idx != 0 {
		t.Errorf("want 0 for empty tty, got %d", idx)
	}
}

func TestFindGhosttyTabIndex_MultipleChildren(t *testing.T) {
	// Three children of ghosttyPID=50, sorted by PID:
	// pid=10 → tab 1, pid=20 → tab 2, pid=30 → tab 3
	psOutput := fakePSHeader +
		"   30    50 ttys003\n" +
		"   10    50 ttys001\n" +
		"   20    50 ttys002\n" +
		"  999   999 ttys004\n"
	// tty "ttys002" (no /dev/ prefix) → bare = "ttys002" → tab 2
	idx := findGhosttyTabIndexFromPS(50, "ttys002", psOutput)
	if idx != 2 {
		t.Errorf("want 2, got %d", idx)
	}
}

func TestFocusGhosttyTab_Strategy1UsedFirst(t *testing.T) {
	writeCalled := false
	focusTabCalled := false
	keysSent := []int{}

	deps := focusDeps{
		getGhosttyPID: func() (int, error) { return 1234, nil },
		findTabIndex:  func(pid int, tty string) int { return 3 },
		sendKeyNToTab: func(idx int) error { keysSent = append(keysSent, idx); return nil },
		writeTitle:    func(tty, basename string) error { writeCalled = true; return nil },
		focusTab:      func(cwdBasename string) error { focusTabCalled = true; return nil },
		activateApp:   func() error { return nil },
		waitAfterWrite: 0,
	}
	err := focusGhosttyTab(deps, "ttys005", "/Users/filip/myproject")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(keysSent) != 1 || keysSent[0] != 3 {
		t.Errorf("expected sendKeyNToTab(3), got %v", keysSent)
	}
	if writeCalled {
		t.Error("writeTitle should NOT be called when Strategy 1 succeeds")
	}
	if focusTabCalled {
		t.Error("focusTab should NOT be called when Strategy 1 succeeds")
	}
}

func TestFocusGhosttyTab_Strategy1FallsBackToStrategy2(t *testing.T) {
	writeCalled := false
	focusTabCalled := false

	deps := focusDeps{
		getGhosttyPID: func() (int, error) { return 1234, nil },
		findTabIndex:  func(pid int, tty string) int { return 0 }, // not found
		sendKeyNToTab: func(idx int) error { t.Error("sendKeyNToTab should not be called"); return nil },
		writeTitle:    func(tty, basename string) error { writeCalled = true; return nil },
		focusTab:      func(cwdBasename string) error { focusTabCalled = true; return nil },
		activateApp:   func() error { return nil },
		waitAfterWrite: 0,
	}
	err := focusGhosttyTab(deps, "ttys005", "/Users/filip/myproject")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !writeCalled {
		t.Error("writeTitle should be called in Strategy 2 fallback")
	}
	if !focusTabCalled {
		t.Error("focusTab should be called in Strategy 2 fallback")
	}
}

func TestFocusGhosttyTab_Strategy1FailsFallsBack(t *testing.T) {
	writeCalled := false
	focusTabCalled := false

	deps := focusDeps{
		getGhosttyPID: func() (int, error) { return 1234, nil },
		findTabIndex:  func(pid int, tty string) int { return 2 },
		sendKeyNToTab: func(idx int) error { return fmt.Errorf("osascript failed") },
		writeTitle:    func(tty, basename string) error { writeCalled = true; return nil },
		focusTab:      func(cwdBasename string) error { focusTabCalled = true; return nil },
		activateApp:   func() error { return nil },
		waitAfterWrite: 0,
	}
	err := focusGhosttyTab(deps, "ttys005", "/Users/filip/myproject")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !writeCalled {
		t.Error("writeTitle should be called when Strategy 1 fails and falls back")
	}
	if !focusTabCalled {
		t.Error("focusTab should be called when Strategy 1 fails and falls back")
	}
}

// ---------------------------------------------------------------------------
// Session staleness tests (Bug 4)
// ---------------------------------------------------------------------------

func TestGetStatus_StaleActiveBecomesIdle(t *testing.T) {
	s := Session{
		HookEventName: "PreToolUse",
		Timestamp:     float64(time.Now().Add(-31 * time.Second).Unix()),
	}
	if s.GetStatus() != StatusIdle {
		t.Errorf("stale PreToolUse session should be StatusIdle, got %v", s.GetStatus())
	}
}

func TestGetStatus_FreshActiveStaysActive(t *testing.T) {
	s := Session{
		HookEventName: "PreToolUse",
		Timestamp:     float64(time.Now().Unix()),
	}
	if s.GetStatus() != StatusActive {
		t.Errorf("fresh PreToolUse session should be StatusActive, got %v", s.GetStatus())
	}
}
