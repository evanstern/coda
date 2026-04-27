package plugin

import (
	"bytes"
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/evanstern/coda/internal/feature"
)

func TestHookRunner_SatisfiesFeatureInterface(t *testing.T) {
	var _ feature.HookRunner = (*HookRunner)(nil)
}

func writeHook(t *testing.T, dir, name, body string, mode os.FileMode) {
	t.Helper()
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, name), []byte("#!/bin/sh\n"+body), mode); err != nil {
		t.Fatal(err)
	}
}

func TestHookRunner_UserOnly(t *testing.T) {
	userDir := t.TempDir()
	out := filepath.Join(t.TempDir(), "log.txt")
	writeHook(t, filepath.Join(userDir, "pre-feature-create"), "10-a", "echo user-a >> "+out+"\n", 0o755)
	r := NewHookRunner(userDir, nil, &bytes.Buffer{})
	if err := r.Run(context.Background(), "pre-feature-create", nil); err != nil {
		t.Fatal(err)
	}
	got, _ := os.ReadFile(out)
	if string(got) != "user-a\n" {
		t.Fatalf("got %q", got)
	}
}

func TestHookRunner_PluginOnly(t *testing.T) {
	pluginRoot := t.TempDir()
	out := filepath.Join(t.TempDir(), "log.txt")
	writeHook(t, filepath.Join(pluginRoot, "hooks", "pre-feature-create"), "10-a", "echo plugin-a >> "+out+"\n", 0o755)
	plugins := []Plugin{{Root: pluginRoot, Manifest: Manifest{Name: "p1"}}}
	r := NewHookRunner(t.TempDir(), plugins, &bytes.Buffer{})
	if err := r.Run(context.Background(), "pre-feature-create", nil); err != nil {
		t.Fatal(err)
	}
	got, _ := os.ReadFile(out)
	if string(got) != "plugin-a\n" {
		t.Fatalf("got %q", got)
	}
}

func TestHookRunner_BothLayered(t *testing.T) {
	userDir := t.TempDir()
	pluginRoot := t.TempDir()
	out := filepath.Join(t.TempDir(), "log.txt")
	writeHook(t, filepath.Join(userDir, "pre-feature-create"), "10-u", "echo user >> "+out+"\n", 0o755)
	writeHook(t, filepath.Join(pluginRoot, "hooks", "pre-feature-create"), "10-p", "echo plugin >> "+out+"\n", 0o755)
	plugins := []Plugin{{Root: pluginRoot, Manifest: Manifest{Name: "p1"}}}
	r := NewHookRunner(userDir, plugins, &bytes.Buffer{})
	if err := r.Run(context.Background(), "pre-feature-create", nil); err != nil {
		t.Fatal(err)
	}
	got, _ := os.ReadFile(out)
	if string(got) != "user\nplugin\n" {
		t.Fatalf("layer order wrong: %q", got)
	}
}

func TestHookRunner_SortOrder(t *testing.T) {
	userDir := t.TempDir()
	out := filepath.Join(t.TempDir(), "log.txt")
	dir := filepath.Join(userDir, "post-feature-create")
	for _, n := range []string{"30-c", "10-a", "20-b"} {
		writeHook(t, dir, n, "echo "+n+" >> "+out+"\n", 0o755)
	}
	r := NewHookRunner(userDir, nil, &bytes.Buffer{})
	if err := r.Run(context.Background(), "post-feature-create", nil); err != nil {
		t.Fatal(err)
	}
	got, _ := os.ReadFile(out)
	if string(got) != "10-a\n20-b\n30-c\n" {
		t.Fatalf("got %q", got)
	}
}

func TestHookRunner_NonExecutableSkipped(t *testing.T) {
	userDir := t.TempDir()
	out := filepath.Join(t.TempDir(), "log.txt")
	writeHook(t, filepath.Join(userDir, "pre-feature-create"), "10-skip", "echo skip > "+out+"\n", 0o644)
	r := NewHookRunner(userDir, nil, &bytes.Buffer{})
	if err := r.Run(context.Background(), "pre-feature-create", nil); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(out); !os.IsNotExist(err) {
		t.Fatalf("non-executable hook ran: %v", err)
	}
}

func TestHookRunner_FailureWarnsButContinues(t *testing.T) {
	userDir := t.TempDir()
	out := filepath.Join(t.TempDir(), "log.txt")
	writeHook(t, filepath.Join(userDir, "pre-feature-create"), "10-fail", "exit 1\n", 0o755)
	writeHook(t, filepath.Join(userDir, "pre-feature-create"), "20-ok", "echo ok > "+out+"\n", 0o755)
	var stderr bytes.Buffer
	r := NewHookRunner(userDir, nil, &stderr)
	if err := r.Run(context.Background(), "pre-feature-create", nil); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(stderr.String(), "warn:") {
		t.Fatalf("expected warning: %q", stderr.String())
	}
	if got, _ := os.ReadFile(out); string(got) != "ok\n" {
		t.Fatalf("subsequent hook didn't run: %q", got)
	}
}

func TestHookRunner_ManifestGlob(t *testing.T) {
	pluginRoot := t.TempDir()
	out := filepath.Join(t.TempDir(), "log.txt")
	writeHook(t, filepath.Join(pluginRoot, "myhooks", "pre"), "01-a", "echo glob-a >> "+out+"\n", 0o755)
	writeHook(t, filepath.Join(pluginRoot, "myhooks", "pre"), "02-b", "echo glob-b >> "+out+"\n", 0o755)
	plugins := []Plugin{{
		Root: pluginRoot,
		Manifest: Manifest{
			Name: "p1",
			Provides: Provides{
				Hooks: map[string][]string{"pre-feature-create": {"myhooks/pre/*"}},
			},
		},
	}}
	r := NewHookRunner(t.TempDir(), plugins, &bytes.Buffer{})
	if err := r.Run(context.Background(), "pre-feature-create", nil); err != nil {
		t.Fatal(err)
	}
	got, _ := os.ReadFile(out)
	if string(got) != "glob-a\nglob-b\n" {
		t.Fatalf("got %q", got)
	}
}

func TestHookRunner_EnvPassthrough(t *testing.T) {
	userDir := t.TempDir()
	out := filepath.Join(t.TempDir(), "env.txt")
	body := "printf '%s|%s\\n' \"$CODA_PROJECT_NAME\" \"$CODA_FEATURE_BRANCH\" > " + out + "\n"
	writeHook(t, filepath.Join(userDir, "pre-feature-create"), "10-env", body, 0o755)
	r := NewHookRunner(userDir, nil, &bytes.Buffer{})
	env := map[string]string{
		"CODA_PROJECT_NAME":   "demo",
		"CODA_FEATURE_BRANCH": "feat",
	}
	if err := r.Run(context.Background(), "pre-feature-create", env); err != nil {
		t.Fatal(err)
	}
	got, _ := os.ReadFile(out)
	if string(got) != "demo|feat\n" {
		t.Fatalf("got %q", got)
	}
}
