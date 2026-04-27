package feature

import (
	"bytes"
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestLocalHookRunner_EmptyDir(t *testing.T) {
	dir := t.TempDir()
	var stderr bytes.Buffer
	r := NewLocalHookRunner(dir, &stderr)
	if err := r.Run(context.Background(), "pre-feature-create", nil); err != nil {
		t.Fatalf("Run: %v", err)
	}
	if stderr.Len() != 0 {
		t.Fatalf("stderr=%q", stderr.String())
	}
}

func TestLocalHookRunner_SortOrder(t *testing.T) {
	dir := t.TempDir()
	eventDir := filepath.Join(dir, "pre-feature-create")
	if err := os.MkdirAll(eventDir, 0o755); err != nil {
		t.Fatal(err)
	}
	output := filepath.Join(t.TempDir(), "log.txt")
	for _, name := range []string{"30-c", "10-a", "20-b"} {
		script := "#!/bin/sh\necho " + name + " >> " + output + "\n"
		if err := os.WriteFile(filepath.Join(eventDir, name), []byte(script), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	r := NewLocalHookRunner(dir, &bytes.Buffer{})
	if err := r.Run(context.Background(), "pre-feature-create", nil); err != nil {
		t.Fatalf("Run: %v", err)
	}
	got, err := os.ReadFile(output)
	if err != nil {
		t.Fatal(err)
	}
	want := "10-a\n20-b\n30-c\n"
	if string(got) != want {
		t.Fatalf("order=%q want %q", got, want)
	}
}

func TestLocalHookRunner_EnvPassthrough(t *testing.T) {
	dir := t.TempDir()
	eventDir := filepath.Join(dir, "post-feature-create")
	if err := os.MkdirAll(eventDir, 0o755); err != nil {
		t.Fatal(err)
	}
	output := filepath.Join(t.TempDir(), "env.txt")
	script := "#!/bin/sh\nprintf '%s|%s|%s|%s\\n' \"$CODA_PROJECT_NAME\" \"$CODA_PROJECT_DIR\" \"$CODA_FEATURE_BRANCH\" \"$CODA_WORKTREE_DIR\" > " + output + "\n"
	if err := os.WriteFile(filepath.Join(eventDir, "10-env"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	r := NewLocalHookRunner(dir, &bytes.Buffer{})
	env := HookEnv{
		"CODA_PROJECT_NAME":   "demo",
		"CODA_PROJECT_DIR":    "/tmp/demo",
		"CODA_FEATURE_BRANCH": "feat-x",
		"CODA_WORKTREE_DIR":   "/tmp/demo/feat-x",
	}
	if err := r.Run(context.Background(), "post-feature-create", env); err != nil {
		t.Fatalf("Run: %v", err)
	}
	got, err := os.ReadFile(output)
	if err != nil {
		t.Fatal(err)
	}
	want := "demo|/tmp/demo|feat-x|/tmp/demo/feat-x\n"
	if string(got) != want {
		t.Fatalf("env=%q want %q", got, want)
	}
}

func TestLocalHookRunner_NonExecutableSkipped(t *testing.T) {
	dir := t.TempDir()
	eventDir := filepath.Join(dir, "pre-feature-create")
	if err := os.MkdirAll(eventDir, 0o755); err != nil {
		t.Fatal(err)
	}
	output := filepath.Join(t.TempDir(), "out.txt")
	if err := os.WriteFile(filepath.Join(eventDir, "10-skip"), []byte("#!/bin/sh\necho skip > "+output+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	r := NewLocalHookRunner(dir, &bytes.Buffer{})
	if err := r.Run(context.Background(), "pre-feature-create", nil); err != nil {
		t.Fatalf("Run: %v", err)
	}
	if _, err := os.Stat(output); !os.IsNotExist(err) {
		t.Fatalf("non-executable hook ran: %v", err)
	}
}

func TestLocalHookRunner_FailureWarnsButContinues(t *testing.T) {
	dir := t.TempDir()
	eventDir := filepath.Join(dir, "pre-feature-create")
	if err := os.MkdirAll(eventDir, 0o755); err != nil {
		t.Fatal(err)
	}
	output := filepath.Join(t.TempDir(), "ran.txt")
	if err := os.WriteFile(filepath.Join(eventDir, "10-fail"), []byte("#!/bin/sh\nexit 1\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(eventDir, "20-ok"), []byte("#!/bin/sh\necho ran > "+output+"\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	var stderr bytes.Buffer
	r := NewLocalHookRunner(dir, &stderr)
	if err := r.Run(context.Background(), "pre-feature-create", nil); err != nil {
		t.Fatalf("Run should warn-only: %v", err)
	}
	if !strings.Contains(stderr.String(), "warn:") {
		t.Fatalf("expected warning in stderr: %q", stderr.String())
	}
	if got, err := os.ReadFile(output); err != nil || string(got) != "ran\n" {
		t.Fatalf("subsequent hook didn't run: out=%q err=%v", got, err)
	}
}
