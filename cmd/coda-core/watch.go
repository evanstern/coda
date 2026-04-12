package main

import (
	"flag"
	"fmt"
	"os"
	"os/exec"
	"os/signal"
	"strings"
	"syscall"
	"time"
)

func runWatch(args []string) error {
	fs := flag.NewFlagSet("watch", flag.ExitOnError)
	interval := fs.Int("interval", 5, "Poll interval in seconds")
	cooldown := fs.Int("cooldown", 60, "Min seconds between repeat notifications per pane")
	prefix := fs.String("prefix", "coda-", "Session name prefix")
	if err := fs.Parse(args); err != nil {
		return err
	}

	w := &watcher{
		interval: time.Duration(*interval) * time.Second,
		cooldown: time.Duration(*cooldown) * time.Second,
		prefix:   *prefix,
		states:   make(map[string]string),
		notified: make(map[string]time.Time),
	}

	fmt.Println("coda-watcher: monitoring OpenCode sessions")
	fmt.Printf("  interval=%ds  cooldown=%ds\n", *interval, *cooldown)
	fmt.Println("  Stop with: coda watch stop (or Ctrl-C)")
	fmt.Println()

	sigs := make(chan os.Signal, 1)
	signal.Notify(sigs, syscall.SIGINT, syscall.SIGTERM)

	ticker := time.NewTicker(w.interval)
	defer ticker.Stop()

	for {
		w.poll()
		select {
		case <-sigs:
			fmt.Println("\ncoda-watcher: stopped")
			return nil
		case <-ticker.C:
		}
	}
}

type watcher struct {
	interval time.Duration
	cooldown time.Duration
	prefix   string
	states   map[string]string
	notified map[string]time.Time
}

func (w *watcher) poll() {
	sessions, err := w.listSessions()
	if err != nil {
		return
	}

	activeKeys := make(map[string]bool)

	for _, session := range sessions {
		panes, err := w.listPanes(session)
		if err != nil {
			continue
		}

		for _, paneID := range panes {
			content, err := w.capturePane(paneID)
			if err != nil || content == "" {
				continue
			}

			if !isOpenCodePane(content) {
				continue
			}

			key := session + ":" + paneID
			activeKeys[key] = true

			prevState := w.states[key]
			currState := detectState(content)

			if prevState == "processing" && currState == "idle" {
				w.notify(session, key)
			}

			w.states[key] = currState
		}
	}

	for key := range w.states {
		if !activeKeys[key] {
			delete(w.states, key)
			delete(w.notified, key)
		}
	}
}

func (w *watcher) listSessions() ([]string, error) {
	out, err := exec.Command("tmux", "list-sessions", "-F", "#{session_name}").Output()
	if err != nil {
		return nil, err
	}

	var sessions []string
	for _, name := range strings.Split(strings.TrimSpace(string(out)), "\n") {
		if strings.HasPrefix(name, w.prefix) && name != "coda-watcher" {
			sessions = append(sessions, name)
		}
	}
	return sessions, nil
}

func (w *watcher) listPanes(session string) ([]string, error) {
	out, err := exec.Command("tmux", "list-panes", "-s", "-t", session, "-F", "#{pane_id}").Output()
	if err != nil {
		return nil, err
	}

	var panes []string
	for _, id := range strings.Split(strings.TrimSpace(string(out)), "\n") {
		if id != "" {
			panes = append(panes, id)
		}
	}
	return panes, nil
}

func (w *watcher) capturePane(paneID string) (string, error) {
	out, err := exec.Command("tmux", "capture-pane", "-t", paneID, "-p", "-S", "-5").Output()
	if err != nil {
		return "", err
	}
	return string(out), nil
}

func isOpenCodePane(content string) bool {
	return strings.Contains(content, "OpenCode ") &&
		(strings.Contains(content, "OpenCode 0.") ||
			strings.Contains(content, "OpenCode 1.") ||
			strings.Contains(content, "OpenCode 2.") ||
			strings.Contains(content, "OpenCode 3."))
}

func detectState(content string) string {
	if strings.Contains(content, "esc interrupt") {
		return "processing"
	}
	return "idle"
}

func (w *watcher) notify(session, key string) {
	now := time.Now()
	if last, ok := w.notified[key]; ok && now.Sub(last) < w.cooldown {
		return
	}

	displayName := strings.TrimPrefix(session, w.prefix)

	clientOutput, err := exec.Command("tmux", "list-clients", "-F", "#{client_tty}").Output()
	if err != nil {
		return
	}

	for _, clientTTY := range strings.Split(strings.TrimSpace(string(clientOutput)), "\n") {
		if clientTTY == "" {
			continue
		}

		paneTTYOut, err := exec.Command("tmux", "display-message", "-p", "-c", clientTTY, "#{pane_tty}").Output()
		if err == nil {
			paneTTY := strings.TrimSpace(string(paneTTYOut))
			if paneTTY != "" {
				if f, err := os.OpenFile(paneTTY, os.O_WRONLY, 0); err == nil {
					f.WriteString("\a")
					f.Close()
				}
			}
		}

		exec.Command("tmux", "display-message", "-c", clientTTY,
			fmt.Sprintf("coda: %s needs attention", displayName)).Run()
	}

	w.notified[key] = now
}
