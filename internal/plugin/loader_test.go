package plugin

import (
	"bytes"
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func writeManifest(t *testing.T, dir, name, json string) string {
	t.Helper()
	root := filepath.Join(dir, name)
	if err := os.MkdirAll(root, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "plugin.json"), []byte(json), 0o644); err != nil {
		t.Fatal(err)
	}
	return root
}

func TestLoader_EmptyDir(t *testing.T) {
	dir := t.TempDir()
	l := NewLoader(dir, nil)
	plugins, err := l.Load(context.Background())
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if len(plugins) != 0 {
		t.Fatalf("expected 0 plugins, got %d", len(plugins))
	}
}

func TestLoader_MissingDir(t *testing.T) {
	l := NewLoader(filepath.Join(t.TempDir(), "does-not-exist"), nil)
	plugins, err := l.Load(context.Background())
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if len(plugins) != 0 {
		t.Fatalf("expected 0 plugins, got %d", len(plugins))
	}
}

func TestLoader_Multiple(t *testing.T) {
	dir := t.TempDir()
	writeManifest(t, dir, "alpha", `{"name":"alpha","version":"0.1","coda":"^0.1"}`)
	writeManifest(t, dir, "beta", `{"name":"beta","version":"0.1","coda":"^0.1"}`)
	l := NewLoader(dir, nil)
	plugins, err := l.Load(context.Background())
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if len(plugins) != 2 {
		t.Fatalf("expected 2 plugins, got %d", len(plugins))
	}
	if plugins[0].Manifest.Name != "alpha" || plugins[1].Manifest.Name != "beta" {
		t.Fatalf("plugins not sorted: %s, %s", plugins[0].Manifest.Name, plugins[1].Manifest.Name)
	}
}

func TestLoader_OneMalformedOthersSucceed(t *testing.T) {
	dir := t.TempDir()
	writeManifest(t, dir, "good", `{"name":"good","version":"0.1","coda":"^0.1"}`)
	writeManifest(t, dir, "bad", `{not json`)
	var warn bytes.Buffer
	l := NewLoader(dir, &warn)
	plugins, err := l.Load(context.Background())
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if len(plugins) != 1 || plugins[0].Manifest.Name != "good" {
		t.Fatalf("expected only good plugin, got %+v", plugins)
	}
	if !strings.Contains(warn.String(), "warn: parse") {
		t.Fatalf("expected parse warning: %q", warn.String())
	}
}

func TestLoader_NoManifestSkipped(t *testing.T) {
	dir := t.TempDir()
	if err := os.MkdirAll(filepath.Join(dir, "no-manifest"), 0o755); err != nil {
		t.Fatal(err)
	}
	writeManifest(t, dir, "ok", `{"name":"ok","version":"0.1","coda":"^0.1"}`)
	l := NewLoader(dir, nil)
	plugins, err := l.Load(context.Background())
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if len(plugins) != 1 || plugins[0].Manifest.Name != "ok" {
		t.Fatalf("got %+v", plugins)
	}
}

func TestDefaultDir_EnvOverride(t *testing.T) {
	t.Setenv("CODA_PLUGINS_DIR", "/custom/plugins")
	if got := DefaultDir(); got != "/custom/plugins" {
		t.Fatalf("DefaultDir=%q", got)
	}
}
