package feature

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

// HookRunner runs lifecycle hook scripts for a named event. The
// localHookRunner in this package scans the user's hook directory.
// #171 will replace this with a plugin-aware implementation; the
// interface keeps the call sites stable.
type HookRunner interface {
	Run(ctx context.Context, event string, env HookEnv) error
}

// localHookRunner runs scripts from $XDG_CONFIG_HOME/coda/hooks/<event>/.
// Failures are warnings: the runner logs to stderr and continues.
type localHookRunner struct {
	dir    string
	stderr io.Writer
}

// NewLocalHookRunner returns a HookRunner that reads hook scripts from
// the given hooks directory. If hooksDir is empty, it defaults to
// $XDG_CONFIG_HOME/coda/hooks (or $HOME/.config/coda/hooks).
func NewLocalHookRunner(hooksDir string, stderr io.Writer) HookRunner {
	if stderr == nil {
		stderr = os.Stderr
	}
	if hooksDir == "" {
		hooksDir = defaultHooksDir()
	}
	return &localHookRunner{dir: hooksDir, stderr: stderr}
}

func defaultHooksDir() string {
	if x := os.Getenv("XDG_CONFIG_HOME"); x != "" {
		return filepath.Join(x, "coda", "hooks")
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return filepath.Join(home, ".config", "coda", "hooks")
}

// Run executes every executable regular file under <dir>/<event>/ in
// sorted filename order, with env merged into os.Environ. Per the
// warn-only contract, Run always returns nil; failures are logged.
func (h *localHookRunner) Run(ctx context.Context, event string, env HookEnv) error {
	if h.dir == "" {
		return nil
	}
	eventDir := filepath.Join(h.dir, event)
	entries, err := os.ReadDir(eventDir)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil
		}
		fmt.Fprintf(h.stderr, "warn: read hooks dir %s: %v\n", eventDir, err)
		return nil
	}
	names := make([]string, 0, len(entries))
	for _, e := range entries {
		names = append(names, e.Name())
	}
	sort.Strings(names)

	merged := mergedEnv(env)

	for _, name := range names {
		path := filepath.Join(eventDir, name)
		info, err := os.Lstat(path)
		if err != nil {
			fmt.Fprintf(h.stderr, "warn: lstat hook %s: %v\n", path, err)
			continue
		}
		if !info.Mode().IsRegular() {
			continue
		}
		if info.Mode().Perm()&0o111 == 0 {
			continue
		}
		cmd := exec.CommandContext(ctx, path)
		cmd.Env = merged
		cmd.Stdout = h.stderr
		cmd.Stderr = h.stderr
		if err := cmd.Run(); err != nil {
			fmt.Fprintf(h.stderr, "warn: hook %s/%s failed: %v\n", event, name, err)
		}
	}
	return nil
}

func mergedEnv(env HookEnv) []string {
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
