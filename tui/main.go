package main

import (
	"fmt"
	"os"

	tea "github.com/charmbracelet/bubbletea"
)

func main() {
	sessionsDir := os.ExpandEnv("$HOME/.claude/monitor/sessions")

	// programRef is a shared pointer to the tea.Program, set before Run() is
	// called. The watcher goroutine uses it to send sessionsChangedMsg.
	programRef := &programRef{}

	m := NewModel(sessionsDir, programRef)
	p := tea.NewProgram(m, tea.WithAltScreen())

	// Set the reference so the watcher can send messages.
	programRef.Set(p)

	if _, err := p.Run(); err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		os.Exit(1)
	}
}
