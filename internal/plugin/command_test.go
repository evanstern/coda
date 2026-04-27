package plugin

import (
	"bytes"
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestBuildCommandRegistry_Basic(t *testing.T) {
	root := t.TempDir()
	plugins := []Plugin{{
		Root: root,
		Manifest: Manifest{
			Name: "demo",
			Provides: Provides{
				Commands: map[string]CommandSpec{
					"hello": {Description: "say hi", Exec: "bin/hello"},
				},
			},
		},
	}}
	r, err := BuildCommandRegistry(plugins)
	if err != nil {
		t.Fatalf("Build: %v", err)
	}
	reg, ok := r.Lookup("hello")
	if !ok {
		t.Fatal("hello not registered")
	}
	if reg.Plugin != "demo" {
		t.Fatalf("plugin=%q", reg.Plugin)
	}
	if reg.Exec != filepath.Join(root, "bin/hello") {
		t.Fatalf("exec=%q", reg.Exec)
	}
}

func TestBuildCommandRegistry_ReservedName(t *testing.T) {
	for _, name := range []string{"version", "agent", "send", "recv", "ack", "feature", "mcp"} {
		t.Run(name, func(t *testing.T) {
			plugins := []Plugin{{
				Root: t.TempDir(),
				Manifest: Manifest{
					Name:     "naughty",
					Provides: Provides{Commands: map[string]CommandSpec{name: {Exec: "bin/x"}}},
				},
			}}
			_, err := BuildCommandRegistry(plugins)
			if err == nil {
				t.Fatalf("expected error for reserved %q", name)
			}
			if !strings.Contains(err.Error(), name) || !strings.Contains(err.Error(), "naughty") {
				t.Fatalf("error must name plugin and command, got %v", err)
			}
		})
	}
}

func TestBuildCommandRegistry_DuplicateName(t *testing.T) {
	plugins := []Plugin{
		{Root: t.TempDir(), Manifest: Manifest{Name: "a", Provides: Provides{Commands: map[string]CommandSpec{"go": {Exec: "x"}}}}},
		{Root: t.TempDir(), Manifest: Manifest{Name: "b", Provides: Provides{Commands: map[string]CommandSpec{"go": {Exec: "y"}}}}},
	}
	_, err := BuildCommandRegistry(plugins)
	if err == nil {
		t.Fatal("expected duplicate-name error")
	}
	if !strings.Contains(err.Error(), "already registered") {
		t.Fatalf("got %v", err)
	}
}

func TestCommandRegistry_Dispatch(t *testing.T) {
	root := t.TempDir()
	binDir := filepath.Join(root, "bin")
	if err := os.MkdirAll(binDir, 0o755); err != nil {
		t.Fatal(err)
	}
	script := "#!/bin/sh\necho \"hi $1\"\nexit 3\n"
	exec := filepath.Join(binDir, "hello")
	if err := os.WriteFile(exec, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	plugins := []Plugin{{
		Root:     root,
		Manifest: Manifest{Name: "demo", Provides: Provides{Commands: map[string]CommandSpec{"hello": {Exec: "bin/hello"}}}},
	}}
	r, err := BuildCommandRegistry(plugins)
	if err != nil {
		t.Fatal(err)
	}
	var stdout, stderr bytes.Buffer
	code := r.Dispatch(context.Background(), "hello", []string{"there"}, nil, &stdout, &stderr)
	if code != 3 {
		t.Fatalf("exit code=%d", code)
	}
	if !strings.Contains(stdout.String(), "hi there") {
		t.Fatalf("stdout=%q", stdout.String())
	}
}

func TestCommandRegistry_DispatchUnknown(t *testing.T) {
	r, _ := BuildCommandRegistry(nil)
	var stderr bytes.Buffer
	code := r.Dispatch(context.Background(), "noop", nil, nil, &bytes.Buffer{}, &stderr)
	if code != 2 {
		t.Fatalf("expected exit 2, got %d", code)
	}
}
