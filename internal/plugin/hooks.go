package plugin

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
)

// HookRunner runs lifecycle hook scripts in two layers:
//
//  1. The user dir: $XDG_CONFIG_HOME/coda/hooks/<event>/
//  2. Each plugin's hooks/<event>/ directory
//
// Within each layer, scripts run in LC_ALL=C filename order. Failures
// warn to stderr and don't block subsequent hooks. Non-executable
// regular files are skipped silently.
type HookRunner struct {
	UserDir string
	Plugins []Plugin
	Stderr  io.Writer
}

// NewHookRunner returns a HookRunner. If userDir is empty,
// DefaultHooksDir is used. plugins is the set returned by Loader.Load
// (the runner uses each plugin's Root + "hooks" subdir).
func NewHookRunner(userDir string, plugins []Plugin, stderr io.Writer) *HookRunner {
	if stderr == nil {
		stderr = os.Stderr
	}
	if userDir == "" {
		userDir = DefaultHooksDir()
	}
	return &HookRunner{UserDir: userDir, Plugins: plugins, Stderr: stderr}
}

// DefaultHooksDir mirrors feature.defaultHooksDir(): XDG_CONFIG_HOME
// then $HOME/.config/coda/hooks.
func DefaultHooksDir() string {
	if x := os.Getenv("XDG_CONFIG_HOME"); x != "" {
		return filepath.Join(x, "coda", "hooks")
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return filepath.Join(home, ".config", "coda", "hooks")
}

// Run executes hooks for event in user→plugin layer order. env is
// merged into os.Environ for each subprocess. Always returns nil
// (warn-only contract).
func (h *HookRunner) Run(ctx context.Context, event string, env map[string]string) error {
	merged := mergedEnv(env)
	if h.UserDir != "" {
		h.runDir(ctx, "user", filepath.Join(h.UserDir, event), event, merged)
	}
	for _, p := range h.Plugins {
		dirs, ok := p.Manifest.Provides.Hooks[event]
		if !ok {
			h.runDir(ctx, p.Manifest.Name, filepath.Join(p.Root, "hooks", event), event, merged)
			continue
		}
		for _, pattern := range dirs {
			h.runPattern(ctx, p, pattern, event, merged)
		}
	}
	return nil
}

func (h *HookRunner) runDir(ctx context.Context, layer, dir, event string, env []string) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return
		}
		fmt.Fprintf(h.Stderr, "warn: read hooks dir %s: %v\n", dir, err)
		return
	}
	names := make([]string, 0, len(entries))
	for _, e := range entries {
		names = append(names, e.Name())
	}
	sort.Strings(names)
	for _, name := range names {
		path := filepath.Join(dir, name)
		h.runOne(ctx, path, event, name, env)
	}
}

func (h *HookRunner) runPattern(ctx context.Context, p Plugin, pattern, event string, env []string) {
	full := pattern
	if !filepath.IsAbs(full) {
		full = filepath.Join(p.Root, pattern)
	}
	matches, err := filepath.Glob(full)
	if err != nil {
		fmt.Fprintf(h.Stderr, "warn: hook glob %s: %v\n", full, err)
		return
	}
	sort.Strings(matches)
	for _, path := range matches {
		h.runOne(ctx, path, event, filepath.Base(path), env)
	}
}

func (h *HookRunner) runOne(ctx context.Context, path, event, name string, env []string) {
	info, err := os.Lstat(path)
	if err != nil {
		fmt.Fprintf(h.Stderr, "warn: lstat hook %s: %v\n", path, err)
		return
	}
	if !info.Mode().IsRegular() {
		return
	}
	if info.Mode().Perm()&0o111 == 0 {
		return
	}
	cmd := exec.CommandContext(ctx, path)
	cmd.Env = env
	cmd.Stdout = h.Stderr
	cmd.Stderr = h.Stderr
	if err := cmd.Run(); err != nil {
		fmt.Fprintf(h.Stderr, "warn: hook %s/%s failed: %v\n", event, name, err)
	}
}

func mergedEnv(env map[string]string) []string {
	base := os.Environ()
	if len(env) == 0 {
		return base
	}
	overrides := make(map[string]string, len(env))
	for k, v := range env {
		overrides[k] = v
	}
	out := make([]string, 0, len(base)+len(overrides))
	for _, kv := range base {
		key := kv
		if i := strings.IndexByte(kv, '='); i >= 0 {
			key = kv[:i]
		}
		if _, override := overrides[key]; override {
			continue
		}
		out = append(out, kv)
	}
	keys := make([]string, 0, len(overrides))
	for k := range overrides {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		out = append(out, k+"="+overrides[k])
	}
	return out
}
