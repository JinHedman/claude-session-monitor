package main

import (
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"sort"
	"sync"
	"time"

	"github.com/fsnotify/fsnotify"
)

// Agent represents an agent entry in the session JSON.
type Agent struct {
	AgentID   string  `json:"agent_id"`
	AgentName string  `json:"agent_name"`
	AgentType string  `json:"agent_type"`
	Status    string  `json:"status"`
	StartedAt float64 `json:"started_at"`
	StoppedAt float64 `json:"stopped_at"`
}

// Session represents a single Claude session from a JSON file.
type Session struct {
	SessionID        string             `json:"session_id"`
	HookEventName    string             `json:"hook_event_name"`
	Timestamp        float64            `json:"timestamp"`
	CWD              string             `json:"cwd"`
	NotificationType string             `json:"notification_type"`
	Message          string             `json:"message"`
	ToolName         string             `json:"tool_name"`
	AgentName        string             `json:"agent_name"`
	AgentID          string             `json:"agent_id"`
	AgentType        string             `json:"agent_type"`
	TranscriptPath   string             `json:"transcript_path"`
	UserPrompt       string             `json:"user_prompt"`
	Reason           string             `json:"reason"`
	IsPermission     bool               `json:"is_permission"`
	IsInterrupt      bool               `json:"is_interrupt"`
	TTY              string             `json:"tty"`
	GhosttyTTY       string             `json:"ghostty_tty"`
	Agents           map[string]Agent   `json:"agents"`

	// FileName is set to the JSON file path for deletion support.
	FileName string `json:"-"`
}

// Status returns the display status of the session.
type Status int

const (
	StatusActive Status = iota
	StatusWaiting
	StatusPermission
	StatusIdle
)

// GetStatus derives the status from session fields.
func (s *Session) GetStatus() Status {
	if s.IsPermission {
		return StatusPermission
	}
	switch s.HookEventName {
	case "PreToolUse", "PostToolUse", "UserPromptSubmit":
		if time.Since(s.Time()) > 30*time.Second {
			return StatusIdle
		}
		return StatusActive
	case "Notification":
		if s.NotificationType == "idle_prompt" {
			return StatusWaiting
		}
	}
	return StatusIdle
}

// Title returns a display title for the session.
func (s *Session) Title() string {
	if s.UserPrompt != "" {
		r := []rune(s.UserPrompt)
		if len(r) > 40 {
			return string(r[:40]) + "…"
		}
		return string(r)
	}
	// Use last 2 path components of CWD.
	if s.CWD == "" {
		if len(s.SessionID) >= 8 {
			return s.SessionID[:8]
		}
		return s.SessionID
	}
	dir := filepath.Clean(s.CWD)
	base := filepath.Base(dir)
	parent := filepath.Base(filepath.Dir(dir))
	if parent == "." || parent == "/" || parent == "" {
		return base
	}
	return parent + "/" + base
}

// ActiveAgentTypes returns a slice of active/running agent types.
func (s *Session) ActiveAgentTypes() []string {
	var types []string
	seen := make(map[string]bool)
	for _, a := range s.Agents {
		if a.Status != "completed" && a.AgentType != "" && !seen[a.AgentType] {
			types = append(types, a.AgentType)
			seen[a.AgentType] = true
		}
	}
	sort.Strings(types)
	return types
}

// Time returns the session timestamp as time.Time.
func (s *Session) Time() time.Time {
	sec := int64(s.Timestamp)
	nsec := int64((s.Timestamp - float64(sec)) * 1e9)
	return time.Unix(sec, nsec)
}

// LoadSessions reads all *.json files from dir and returns parsed sessions.
func LoadSessions(dir string) ([]Session, error) {
	entries, err := filepath.Glob(filepath.Join(dir, "*.json"))
	if err != nil {
		return nil, err
	}

	var sessions []Session
	for _, path := range entries {
		data, err := os.ReadFile(path)
		if err != nil {
			continue
		}
		var s Session
		if err := json.Unmarshal(data, &s); err != nil {
			continue
		}
		s.FileName = path
		sessions = append(sessions, s)
	}

	// Sort by timestamp descending.
	sort.Slice(sessions, func(i, j int) bool {
		return sessions[i].Timestamp > sessions[j].Timestamp
	})

	return sessions, nil
}

// watchCloser wraps an fsnotify.Watcher to implement io.Closer.
type watchCloser struct {
	watcher *fsnotify.Watcher
	done    chan struct{}
}

func (w *watchCloser) Close() error {
	close(w.done)
	return w.watcher.Close()
}

// WatchSessions watches dir for file changes and calls onChange (debounced ~300ms).
// Returns an io.Closer to stop watching.
func WatchSessions(dir string, onChange func()) (io.Closer, error) {
	watcher, err := fsnotify.NewWatcher()
	if err != nil {
		return nil, err
	}

	if err := watcher.Add(dir); err != nil {
		watcher.Close()
		return nil, err
	}

	wc := &watchCloser{
		watcher: watcher,
		done:    make(chan struct{}),
	}

	go func() {
		var mu sync.Mutex
		var timer *time.Timer

		for {
			select {
			case <-wc.done:
				return
			case event, ok := <-watcher.Events:
				if !ok {
					return
				}
				if event.Has(fsnotify.Write) || event.Has(fsnotify.Create) || event.Has(fsnotify.Remove) {
					mu.Lock()
					if timer != nil {
						timer.Stop()
					}
					timer = time.AfterFunc(300*time.Millisecond, onChange)
					mu.Unlock()
				}
			case _, ok := <-watcher.Errors:
				if !ok {
					return
				}
				// Ignore watcher errors.
			}
		}
	}()

	return wc, nil
}
