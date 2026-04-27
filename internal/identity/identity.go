// Package identity scaffolds and reads agent identity directories.
//
// Each agent owns a directory under $XDG_CONFIG_HOME/coda/agents/<name>
// containing PURPOSE.md (role/scope/boundaries), MEMORY.md, PROJECT.md,
// and per-day memory/ and learnings/ subdirectories. The personality
// layer (SOUL.md, dreams) is the coda-soul plugin's territory; this
// package is the core scaffolding only.
package identity

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

// Layout describes the on-disk layout of an agent's identity dir.
type Layout struct {
	Root         string // ~/.config/coda/agents/<name>
	PurposeMD    string // <Root>/PURPOSE.md
	MemoryMD     string // <Root>/MEMORY.md
	ProjectMD    string // <Root>/PROJECT.md
	MemoryDir    string // <Root>/memory
	LearningsDir string // <Root>/learnings
}

// DefaultRoot returns the base directory holding all identity dirs:
// $XDG_CONFIG_HOME/coda/agents (default ~/.config/coda/agents).
func DefaultRoot() (string, error) {
	if x := os.Getenv("XDG_CONFIG_HOME"); x != "" {
		return filepath.Join(x, "coda", "agents"), nil
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return "", fmt.Errorf("user home: %w", err)
	}
	return filepath.Join(home, ".config", "coda", "agents"), nil
}

// Resolve returns the Layout for an agent without touching disk.
func Resolve(root, agentName string) Layout {
	return LayoutAt(filepath.Join(root, agentName))
}

// LayoutAt returns the Layout rooted at the given absolute path. Use
// this when you already have the agent's config_dir (e.g. from a DB
// row) and don't want to split/rejoin it.
func LayoutAt(root string) Layout {
	return Layout{
		Root:         root,
		PurposeMD:    filepath.Join(root, "PURPOSE.md"),
		MemoryMD:     filepath.Join(root, "MEMORY.md"),
		ProjectMD:    filepath.Join(root, "PROJECT.md"),
		MemoryDir:    filepath.Join(root, "memory"),
		LearningsDir: filepath.Join(root, "learnings"),
	}
}

const purposeTemplate = `# PURPOSE.md — {{.Name}}

> The role, scope, and boundaries of this agent. Edit this file
> to make the agent specific to its purpose.

## Role

(What is this agent's job?)

## Scope

(What does it own? What does it touch?)

## Boundaries

(What does it NOT do? When does it escalate? To whom?)
`

// Scaffold creates the layout on disk and writes the PURPOSE.md
// template. Idempotent: re-running on an existing dir is a no-op
// for files that already exist (does NOT overwrite).
func Scaffold(layout Layout) error {
	for _, d := range []string{layout.Root, layout.MemoryDir, layout.LearningsDir} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			return fmt.Errorf("mkdir %s: %w", d, err)
		}
	}
	name := filepath.Base(layout.Root)
	purpose := strings.Replace(purposeTemplate, "{{.Name}}", name, 1)
	if err := writeIfMissing(layout.PurposeMD, []byte(purpose)); err != nil {
		return err
	}
	if err := writeIfMissing(layout.MemoryMD, nil); err != nil {
		return err
	}
	if err := writeIfMissing(layout.ProjectMD, nil); err != nil {
		return err
	}
	return nil
}

func writeIfMissing(path string, content []byte) error {
	if _, err := os.Stat(path); err == nil {
		return nil
	} else if !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("stat %s: %w", path, err)
	}
	if err := os.WriteFile(path, content, 0o644); err != nil {
		return fmt.Errorf("write %s: %w", path, err)
	}
	return nil
}

// BootPayload is what `coda agent boot` produces: enough metadata
// for a provider to deliver identity into a session.
type BootPayload struct {
	AgentName string            `json:"agent_name"`
	ConfigDir string            `json:"config_dir"`
	Files     []string          `json:"files"`
	EnvVars   map[string]string `json:"env_vars"`
}

// Boot validates the on-disk layout and builds a BootPayload for the
// given agent name. Returns an error if PURPOSE.md is missing (the
// only required file). The agent name is used verbatim in the payload
// and env vars; it is the caller's responsibility to pass the
// authoritative name (e.g. from the DB row).
func Boot(agentName string, layout Layout) (BootPayload, error) {
	info, err := os.Stat(layout.PurposeMD)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return BootPayload{}, fmt.Errorf("PURPOSE.md missing at %s", layout.PurposeMD)
		}
		return BootPayload{}, fmt.Errorf("stat purpose: %w", err)
	}
	if !info.Mode().IsRegular() {
		return BootPayload{}, fmt.Errorf("PURPOSE.md at %s is not a regular file", layout.PurposeMD)
	}
	files := []string{layout.PurposeMD}
	for _, p := range []string{layout.MemoryMD, layout.ProjectMD} {
		if _, err := os.Stat(p); err == nil {
			files = append(files, p)
		}
	}
	return BootPayload{
		AgentName: agentName,
		ConfigDir: layout.Root,
		Files:     files,
		EnvVars: map[string]string{
			"CODA_AGENT_NAME":       agentName,
			"CODA_AGENT_CONFIG_DIR": layout.Root,
		},
	}, nil
}

// AppendMemory appends a dated entry to memory/<YYYY-MM-DD>.md, creating
// the file if needed. Date is UTC, format YYYY-MM-DD. The entry is
// written verbatim with one trailing newline.
func AppendMemory(layout Layout, when time.Time, entry string) error {
	return appendDated(layout.MemoryDir, when, entry)
}

// AppendLearning appends to learnings/<YYYY-MM-DD>.md the same way.
func AppendLearning(layout Layout, when time.Time, entry string) error {
	return appendDated(layout.LearningsDir, when, entry)
}

func appendDated(dir string, when time.Time, entry string) error {
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return fmt.Errorf("mkdir %s: %w", dir, err)
	}
	name := when.UTC().Format("2006-01-02") + ".md"
	path := filepath.Join(dir, name)
	f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		return fmt.Errorf("open %s: %w", path, err)
	}
	defer f.Close()
	if !strings.HasSuffix(entry, "\n") {
		entry += "\n"
	}
	if _, err := f.WriteString(entry); err != nil {
		return fmt.Errorf("write %s: %w", path, err)
	}
	return nil
}

// MemoryEntry is one daily memory file.
type MemoryEntry struct {
	Date    time.Time
	Path    string
	Content string
}

// ReadRecentMemory returns the contents of the N most recent files in
// memory/, ordered newest first. Files that fail to read are skipped
// (not fatal).
func ReadRecentMemory(layout Layout, n int) ([]MemoryEntry, error) {
	return readRecent(layout.MemoryDir, n)
}

// ReadRecentLearnings is the same shape as ReadRecentMemory but for
// learnings/.
func ReadRecentLearnings(layout Layout, n int) ([]MemoryEntry, error) {
	return readRecent(layout.LearningsDir, n)
}

func readRecent(dir string, n int) ([]MemoryEntry, error) {
	if n <= 0 {
		return nil, nil
	}
	ents, err := os.ReadDir(dir)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, nil
		}
		return nil, fmt.Errorf("read dir %s: %w", dir, err)
	}
	type dated struct {
		date time.Time
		path string
	}
	var dates []dated
	for _, e := range ents {
		if e.IsDir() {
			continue
		}
		base := strings.TrimSuffix(e.Name(), ".md")
		if base == e.Name() {
			continue
		}
		t, err := time.ParseInLocation("2006-01-02", base, time.UTC)
		if err != nil {
			continue
		}
		dates = append(dates, dated{date: t, path: filepath.Join(dir, e.Name())})
	}
	sort.Slice(dates, func(i, j int) bool { return dates[i].date.After(dates[j].date) })
	if len(dates) > n {
		dates = dates[:n]
	}
	out := make([]MemoryEntry, 0, len(dates))
	for _, d := range dates {
		b, err := os.ReadFile(d.path)
		if err != nil {
			continue
		}
		out = append(out, MemoryEntry{Date: d.date, Path: d.path, Content: string(b)})
	}
	return out, nil
}
