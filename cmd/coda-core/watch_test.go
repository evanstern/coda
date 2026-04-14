package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestIsOpenCodePane(t *testing.T) {
	tests := []struct {
		name    string
		content string
		want    bool
	}{
		{"version 0.x", "some text OpenCode 0.1.2 more text", true},
		{"version 1.x", "OpenCode 1.0.0", true},
		{"version 2.x", "OpenCode 2.5.3", true},
		{"version 3.x", "OpenCode 3.99.1", true},
		{"version 4.x", "OpenCode 4.0.0", true},
		{"version 10.x", "OpenCode 10.2.3", true},
		{"version 99.x", "OpenCode 99.0.0", true},
		{"embedded in status bar", "\x1b[1m OpenCode 2.1.0 \x1b[0m  esc interrupt", true},
		{"empty string", "", false},
		{"no opencode", "SomethingElse", false},
		{"lowercase", "opencode 1.0", false},
		{"partial match no digit", "OpenCode ", false},
		{"partial match no dot", "OpenCode 1", false},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := isOpenCodePane(tt.content)
			if got != tt.want {
				t.Errorf("isOpenCodePane(%q) = %v, want %v", tt.content, got, tt.want)
			}
		})
	}
}

func TestFindNotificationScripts(t *testing.T) {
	tmpDir := t.TempDir()

	script := filepath.Join(tmpDir, "01-test.sh")
	if err := os.WriteFile(script, []byte("#!/bin/sh\necho hi"), 0755); err != nil {
		t.Fatal(err)
	}
	noexec := filepath.Join(tmpDir, "02-noexec.sh")
	if err := os.WriteFile(noexec, []byte("#!/bin/sh\necho hi"), 0644); err != nil {
		t.Fatal(err)
	}

	w := &watcher{notificationsDir: tmpDir}
	scripts := w.findNotificationScripts()

	if len(scripts) != 1 {
		t.Fatalf("expected 1 script, got %d: %v", len(scripts), scripts)
	}
	if scripts[0] != script {
		t.Errorf("expected %s, got %s", script, scripts[0])
	}
}

func TestFindNotificationScriptsEmptyDir(t *testing.T) {
	w := &watcher{notificationsDir: "/nonexistent-dir-xyz"}
	scripts := w.findNotificationScripts()
	if len(scripts) != 0 {
		t.Fatalf("expected 0 scripts, got %d", len(scripts))
	}
}

func TestFindNotificationScriptsUserShadowsBuiltin(t *testing.T) {
	builtinDir := t.TempDir()
	userDir := t.TempDir()

	os.WriteFile(filepath.Join(builtinDir, "bell.sh"), []byte("#!/bin/sh\necho builtin"), 0755)
	os.WriteFile(filepath.Join(builtinDir, "extra.sh"), []byte("#!/bin/sh\necho extra"), 0755)

	userBell := filepath.Join(userDir, "bell.sh")
	os.WriteFile(userBell, []byte("#!/bin/sh\necho user-bell"), 0755)

	w := &watcher{notificationsDir: builtinDir, userNotificationsDir: userDir}
	scripts := w.findNotificationScripts()

	if len(scripts) != 2 {
		t.Fatalf("expected 2 scripts (user bell.sh shadows builtin bell.sh, plus builtin extra.sh), got %d: %v", len(scripts), scripts)
	}
	if scripts[0] != userBell {
		t.Errorf("expected user bell.sh first, got %s", scripts[0])
	}
}

func TestDetectState(t *testing.T) {
	tests := []struct {
		name    string
		content string
		want    string
	}{
		{"processing", "OpenCode 2.1.0  esc interrupt", "processing"},
		{"idle", "OpenCode 2.1.0  ready", "idle"},
		{"empty", "", "idle"},
		{"no indicator", "just some text", "idle"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := detectState(tt.content)
			if got != tt.want {
				t.Errorf("detectState(%q) = %q, want %q", tt.content, got, tt.want)
			}
		})
	}
}
