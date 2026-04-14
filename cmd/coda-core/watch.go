package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"os/signal"
	"regexp"
	"strings"
	"syscall"
	"time"
)

func runWatch(args []string) error {
	fs := flag.NewFlagSet("watch", flag.ExitOnError)
	interval := fs.Int("interval", 5, "Poll interval in seconds")
	cooldown := fs.Int("cooldown", 60, "Min seconds between repeat notifications per pane")
	prefix := fs.String("prefix", "coda-", "Session name prefix")
	notificationsDir := fs.String("notifications-dir", "", "Notifications plugin directory (builtin)")
	userNotificationsDir := fs.String("user-notifications-dir", "", "User notifications directory")
	if err := fs.Parse(args); err != nil {
		return err
	}

	w := &watcher{
		interval:             time.Duration(*interval) * time.Second,
		cooldown:             time.Duration(*cooldown) * time.Second,
		prefix:               *prefix,
		notificationsDir:     *notificationsDir,
		userNotificationsDir: *userNotificationsDir,
		states:               make(map[string]string),
		notified:             make(map[string]time.Time),
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
	interval             time.Duration
	cooldown             time.Duration
	prefix               string
	notificationsDir     string
	userNotificationsDir string
	states               map[string]string
	notified             map[string]time.Time
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
		if strings.HasPrefix(name, w.prefix) && name != w.prefix+"watcher" {
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

var openCodeVersionRe = regexp.MustCompile(`OpenCode \d+\.`)

func isOpenCodePane(content string) bool {
	return openCodeVersionRe.MatchString(content)
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

	paneID := ""
	if parts := strings.SplitN(key, ":", 2); len(parts) == 2 {
		paneID = parts[1]
	}

	scripts := w.findNotificationScripts()
	if len(scripts) > 0 {
		w.runNotificationScripts(scripts, session, paneID)
	} else {
		w.notifyBellFallback(session)
	}

	w.notified[key] = now
}

func (w *watcher) findNotificationScripts() []string {
	var scripts []string
	seen := make(map[string]bool)
	for _, dir := range []string{w.userNotificationsDir, w.notificationsDir} {
		if dir == "" {
			continue
		}
		entries, err := os.ReadDir(dir)
		if err != nil {
			continue
		}
		for _, e := range entries {
			if e.IsDir() {
				continue
			}
			name := e.Name()
			if seen[name] {
				continue
			}
			path := dir + "/" + name
			info, err := os.Stat(path)
			if err != nil || info.Mode()&0111 == 0 {
				continue
			}
			seen[name] = true
			scripts = append(scripts, path)
		}
	}
	return scripts
}

func (w *watcher) runNotificationScripts(scripts []string, session, paneID string) {
	env := append(os.Environ(),
		"CODA_SESSION_NAME="+session,
		"CODA_PANE_ID="+paneID,
		"CODA_NOTIFICATION_EVENT=idle",
		"SESSION_PREFIX="+w.prefix,
	)
	for _, script := range scripts {
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		cmd := exec.CommandContext(ctx, script)
		cmd.Env = env
		if err := cmd.Run(); err != nil {
			fmt.Fprintf(os.Stderr, "notification warning: %s: %v\n", script, err)
		}
		cancel()
	}
}

func (w *watcher) notifyBellFallback(session string) {
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
}
