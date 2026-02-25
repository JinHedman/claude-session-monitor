package main

import (
	"fmt"
	"io"
	"os"
	"strings"
	"sync"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

// programRef is a thread-safe holder for a *tea.Program.
// It breaks the initialization cycle: we create the model before the program,
// but the watcher needs to send to the program after it starts.
type programRef struct {
	mu sync.Mutex
	p  *tea.Program
}

// Set stores the program reference.
func (r *programRef) Set(p *tea.Program) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.p = p
}

// Send sends a message to the program if it is set.
func (r *programRef) Send(msg tea.Msg) {
	r.mu.Lock()
	p := r.p
	r.mu.Unlock()
	if p != nil {
		p.Send(msg)
	}
}

// sessionsChangedMsg is sent by the file watcher when sessions change.
type sessionsChangedMsg struct{}

// watcherReadyMsg carries the watcher closer back to the model after init.
type watcherReadyMsg struct {
	watcher io.Closer
}

// sessionsLoadedMsg carries loaded sessions to the model.
type sessionsLoadedMsg struct {
	sessions []Session
}

// Colors.
var (
	colorOrange = lipgloss.Color("#FF8C00")
	colorGreen  = lipgloss.Color("#00CC66")
	colorRed    = lipgloss.Color("#FF3333")
	colorGray   = lipgloss.Color("#666666")
	colorWhite  = lipgloss.Color("#FFFFFF")
	colorDim    = lipgloss.Color("#888888")
	colorAccent = lipgloss.Color("#7D56F4")
)

// Styles.
var (
	styleBorder = lipgloss.NewStyle().
			Border(lipgloss.RoundedBorder()).
			BorderForeground(colorAccent).
			Padding(0, 1)

	styleTitle = lipgloss.NewStyle().
			Foreground(colorAccent).
			Bold(true)

	styleSessionTitle = lipgloss.NewStyle().
				Foreground(colorWhite).
				Bold(true)

	styleSessionTitleSelected = lipgloss.NewStyle().
					Foreground(colorAccent).
					Bold(true)

	styleStatus = lipgloss.NewStyle().
			Foreground(colorDim)

	styleMeta = lipgloss.NewStyle().
			Foreground(colorDim)

	styleSelected = lipgloss.NewStyle().
			Background(lipgloss.Color("#1A1A2E"))

	styleCursor = lipgloss.NewStyle().
			Foreground(colorAccent).
			Bold(true)

	styleFooter = lipgloss.NewStyle().
			Foreground(colorDim)

	styleDotActive = lipgloss.NewStyle().
			Foreground(colorOrange)

	styleDotWaiting = lipgloss.NewStyle().
			Foreground(colorGreen)

	styleDotPermission = lipgloss.NewStyle().
				Foreground(colorRed)

	styleDotIdle = lipgloss.NewStyle().
			Foreground(colorGray)
)

// Model is the Bubble Tea model for the session monitor.
type Model struct {
	sessions    []Session
	cursor      int
	sessionsDir string
	watcher     io.Closer
	pRef        *programRef
	width       int
	height      int
}

// NewModel creates a new Model with the given sessions directory and program reference.
func NewModel(sessionsDir string, pRef *programRef) Model {
	return Model{
		sessionsDir: sessionsDir,
		pRef:        pRef,
		width:       80,
		height:      24,
	}
}

// Init initializes the model: loads sessions and starts the file watcher.
func (m Model) Init() tea.Cmd {
	return tea.Batch(
		m.cmdLoadSessions(),
		m.cmdStartWatcher(),
	)
}

// cmdLoadSessions returns a Cmd that loads sessions from disk.
func (m Model) cmdLoadSessions() tea.Cmd {
	sessionsDir := m.sessionsDir
	return func() tea.Msg {
		sessions, _ := LoadSessions(sessionsDir)
		return sessionsLoadedMsg{sessions: sessions}
	}
}

// cmdStartWatcher returns a Cmd that starts the file watcher.
func (m Model) cmdStartWatcher() tea.Cmd {
	pRef := m.pRef
	sessionsDir := m.sessionsDir
	return func() tea.Msg {
		if pRef == nil {
			return nil
		}
		watcher, err := WatchSessions(sessionsDir, func() {
			pRef.Send(sessionsChangedMsg{})
		})
		if err != nil {
			return nil
		}
		return watcherReadyMsg{watcher: watcher}
	}
}

// Update handles messages and key events.
func (m Model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width = msg.Width
		m.height = msg.Height
		return m, nil

	case sessionsLoadedMsg:
		m.sessions = msg.sessions
		m.clampCursor()
		return m, nil

	case watcherReadyMsg:
		m.watcher = msg.watcher
		return m, nil

	case sessionsChangedMsg:
		sessions, err := LoadSessions(m.sessionsDir)
		if err == nil {
			m.sessions = sessions
			m.clampCursor()
		}
		return m, nil

	case tea.KeyMsg:
		switch msg.String() {
		case "up", "j":
			if m.cursor > 0 {
				m.cursor--
			}
		case "down", "k":
			if m.cursor < len(m.sessions)-1 {
				m.cursor++
			}
		case "enter", "f":
			if m.cursor < len(m.sessions) {
				s := m.sessions[m.cursor]
				ghosttyTTY := s.GhosttyTTY
				if ghosttyTTY == "" {
					ghosttyTTY = s.TTY
				}
				return m, func() tea.Msg {
					_ = FocusGhosttyTab(ghosttyTTY, s.CWD)
					return nil
				}
			}
		case "d":
			if m.cursor < len(m.sessions) {
				s := m.sessions[m.cursor]
				if s.GetStatus() == StatusIdle && s.FileName != "" {
					_ = os.Remove(s.FileName)
					sessions, err := LoadSessions(m.sessionsDir)
					if err == nil {
						m.sessions = sessions
						m.clampCursor()
					}
				}
			}
		case "q", "ctrl+c":
			if m.watcher != nil {
				_ = m.watcher.Close()
			}
			return m, tea.Quit
		}
	}

	return m, nil
}

// clampCursor ensures cursor is within valid range.
func (m *Model) clampCursor() {
	if len(m.sessions) == 0 {
		m.cursor = 0
		return
	}
	if m.cursor >= len(m.sessions) {
		m.cursor = len(m.sessions) - 1
	}
	if m.cursor < 0 {
		m.cursor = 0
	}
}

// View renders the TUI.
func (m Model) View() string {
	// Calculate inner width (account for border + padding).
	innerWidth := m.width - 6
	if innerWidth < 20 {
		innerWidth = 20
	}

	var sb strings.Builder

	// Build session rows.
	for i, s := range m.sessions {
		selected := i == m.cursor
		sb.WriteString(renderSession(s, selected, innerWidth))
		if i < len(m.sessions)-1 {
			sb.WriteString("\n")
		}
	}

	if len(m.sessions) == 0 {
		sb.WriteString(styleStatus.Render("No sessions found."))
	}

	// Footer.
	footer := styleFooter.Render("↑/j ↓/k Navigate · Enter/f Focus · d Dismiss · q Quit")

	// Title with session count.
	count := fmt.Sprintf("%d session", len(m.sessions))
	if len(m.sessions) != 1 {
		count += "s"
	}
	titleLeft := styleTitle.Render("Claude Monitor")
	titleRight := styleTitle.Render(count)

	// Pad title line.
	titlePadding := innerWidth - lipgloss.Width(titleLeft) - lipgloss.Width(titleRight)
	if titlePadding < 1 {
		titlePadding = 1
	}
	titleLine := titleLeft + strings.Repeat(" ", titlePadding) + titleRight

	body := titleLine + "\n\n" + sb.String() + "\n\n" + footer

	box := styleBorder.
		Width(innerWidth).
		Render(body)

	return box
}

// renderSession renders a single session as 3 lines.
func renderSession(s Session, selected bool, width int) string {
	status := s.GetStatus()

	// Dot indicator.
	var dot string
	var statusText string
	switch status {
	case StatusActive:
		dot = styleDotActive.Render("●")
		statusText = "Working..."
	case StatusWaiting:
		dot = styleDotWaiting.Render("●")
		statusText = "Waiting for input"
	case StatusPermission:
		dot = styleDotPermission.Render("●")
		statusText = "Permission required"
	case StatusIdle:
		dot = styleDotIdle.Render("·")
		statusText = "Idle"
	}

	// Cursor indicator.
	cursor := "  "
	if selected {
		cursor = styleCursor.Render("▶ ")
	}

	// Title line.
	var titleStyle lipgloss.Style
	if selected {
		titleStyle = styleSessionTitleSelected
	} else {
		titleStyle = styleSessionTitle
	}
	title := cursor + dot + " " + titleStyle.Render(s.Title())

	// Status + agents line.
	agentTypes := s.ActiveAgentTypes()
	statusLine := "     " + styleStatus.Render(statusText)
	if len(agentTypes) > 0 {
		statusLine += styleStatus.Render(" · " + strings.Join(agentTypes, " · "))
	}

	// TTY + time line.
	ttyPart := s.TTY
	if ttyPart == "" {
		ttyPart = "unknown"
	}
	metaLine := "     " + styleMeta.Render(ttyPart+" · "+timeAgo(s.Time()))

	lines := []string{title, statusLine, metaLine}

	if selected {
		result := make([]string, len(lines))
		for i, line := range lines {
			padded := line + strings.Repeat(" ", clampMin(0, width-lipgloss.Width(line)))
			result[i] = styleSelected.Render(padded)
		}
		return strings.Join(result, "\n")
	}

	return strings.Join(lines, "\n")
}

// timeAgo returns a human-readable relative time string.
func timeAgo(t time.Time) string {
	d := time.Since(t)
	if d < 0 {
		d = 0
	}
	switch {
	case d < 10*time.Second:
		return "just now"
	case d < time.Minute:
		return fmt.Sprintf("%ds ago", int(d.Seconds()))
	case d < time.Hour:
		return fmt.Sprintf("%dm ago", int(d.Minutes()))
	case d < 24*time.Hour:
		return fmt.Sprintf("%dh ago", int(d.Hours()))
	default:
		return fmt.Sprintf("%dd ago", int(d.Hours()/24))
	}
}

// clampMin returns a if a >= minVal, else minVal.
func clampMin(minVal, a int) int {
	if a < minVal {
		return minVal
	}
	return a
}
