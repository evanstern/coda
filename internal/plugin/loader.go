package plugin

import (
	"context"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
)

// Loader discovers plugins under a single root directory. Each
// immediate subdirectory containing a plugin.json file is treated as
// a plugin. Malformed manifests are reported via Warn but do not
// abort the load.
type Loader struct {
	Dir  string
	Warn io.Writer
}

// NewLoader returns a Loader that reads plugins from dir. If dir is
// empty, DefaultDir is used. Warnings are sent to warn (or
// io.Discard if nil).
func NewLoader(dir string, warn io.Writer) *Loader {
	if warn == nil {
		warn = io.Discard
	}
	if dir == "" {
		dir = DefaultDir()
	}
	return &Loader{Dir: dir, Warn: warn}
}

// DefaultDir returns the default plugins directory. CODA_PLUGINS_DIR
// wins, then $XDG_CONFIG_HOME/coda/plugins, then
// $HOME/.config/coda/plugins. Empty string if no home is detectable.
func DefaultDir() string {
	if d := os.Getenv("CODA_PLUGINS_DIR"); d != "" {
		return d
	}
	if x := os.Getenv("XDG_CONFIG_HOME"); x != "" {
		return filepath.Join(x, "coda", "plugins")
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return filepath.Join(home, ".config", "coda", "plugins")
}

// Load scans Dir for plugins and returns the parsed set. A missing
// Dir is treated as no plugins (returns empty slice, nil error).
// Plugins whose manifest fails to parse are skipped with a warning;
// Load only returns a non-nil error for fundamental I/O issues.
func (l *Loader) Load(ctx context.Context) ([]Plugin, error) {
	if l.Dir == "" {
		return nil, nil
	}
	entries, err := os.ReadDir(l.Dir)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, fmt.Errorf("read plugins dir %s: %w", l.Dir, err)
	}
	names := make([]string, 0, len(entries))
	for _, e := range entries {
		if e.IsDir() {
			names = append(names, e.Name())
		}
	}
	sort.Strings(names)
	plugins := make([]Plugin, 0, len(names))
	for _, name := range names {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		root := filepath.Join(l.Dir, name)
		manifestPath := filepath.Join(root, "plugin.json")
		data, err := os.ReadFile(manifestPath)
		if err != nil {
			if os.IsNotExist(err) {
				continue
			}
			fmt.Fprintf(l.Warn, "warn: read %s: %v\n", manifestPath, err)
			continue
		}
		m, err := Parse(data, l.Warn)
		if err != nil {
			fmt.Fprintf(l.Warn, "warn: parse %s: %v\n", manifestPath, err)
			continue
		}
		absRoot, err := filepath.Abs(root)
		if err != nil {
			absRoot = root
		}
		plugins = append(plugins, Plugin{Manifest: m, Root: absRoot})
	}
	return plugins, nil
}
