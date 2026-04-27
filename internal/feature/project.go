// Package feature implements the v3 worktree lifecycle: project
// resolution, worktree start/finish/list, and a local hook runner.
package feature

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// Project identifies a coda project on disk. The project layout is
// the v2-compatible bare-repo pattern:
//
//	<Root>/
//	  .bare/        # bare git repository
//	  .git          # text file: "gitdir: ./.bare"
//	  <branch>/     # one directory per checked-out worktree
type Project struct {
	Name string
	Root string // absolute path to the project root (parent of .bare/)
}

// FindProject resolves a project from cwd or by explicit name.
//
// nameHint == "": walk up from cwd looking for the .bare/ + .git
// text-file layout. Errors at filesystem root if none found.
//
// nameHint != "": resolve PROJECTS_DIR/<nameHint>/ (default
// $HOME/projects). The directory must exist and contain .bare/.
func FindProject(cwd, nameHint string) (*Project, error) {
	if nameHint != "" {
		return findByName(nameHint)
	}
	return findFromCwd(cwd)
}

func findByName(name string) (*Project, error) {
	base := os.Getenv("PROJECTS_DIR")
	if base == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			return nil, fmt.Errorf("resolve projects dir: %w", err)
		}
		base = filepath.Join(home, "projects")
	}
	root := filepath.Join(base, name)
	info, err := os.Stat(root)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, fmt.Errorf("project %q not found at %s", name, root)
		}
		return nil, fmt.Errorf("stat project: %w", err)
	}
	if !info.IsDir() {
		return nil, fmt.Errorf("project path %s is not a directory", root)
	}
	if err := validateProjectDir(root); err != nil {
		return nil, err
	}
	return &Project{Name: name, Root: root}, nil
}

func findFromCwd(cwd string) (*Project, error) {
	if cwd == "" {
		return nil, fmt.Errorf("cwd is empty")
	}
	abs, err := filepath.Abs(cwd)
	if err != nil {
		return nil, fmt.Errorf("absolute cwd: %w", err)
	}
	dir := abs
	for {
		if err := validateProjectDir(dir); err == nil {
			return &Project{Name: filepath.Base(dir), Root: dir}, nil
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			return nil, fmt.Errorf("no coda project found above %s", abs)
		}
		dir = parent
	}
}

// validateProjectDir checks that dir has the bare-repo project layout:
// a .bare/ directory and a .git text-file pointing at ./.bare.
func validateProjectDir(dir string) error {
	bare := filepath.Join(dir, ".bare")
	info, err := os.Stat(bare)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return fmt.Errorf("%s: missing .bare directory", dir)
		}
		return fmt.Errorf("%s: stat .bare: %w", dir, err)
	}
	if !info.IsDir() {
		return fmt.Errorf("%s: .bare is not a directory", dir)
	}
	gitFile := filepath.Join(dir, ".git")
	contents, err := os.ReadFile(gitFile)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return fmt.Errorf("%s: missing .git text-file", dir)
		}
		return fmt.Errorf("%s: read .git: %w", dir, err)
	}
	body := strings.TrimSpace(string(contents))
	// Accept either "gitdir: ./.bare" or "gitdir: .bare" or absolute
	// gitdir pointing at <dir>/.bare.
	if !strings.HasPrefix(body, "gitdir:") {
		return fmt.Errorf("%s: .git is not a gitdir pointer", dir)
	}
	target := strings.TrimSpace(strings.TrimPrefix(body, "gitdir:"))
	if !pointsAtBare(dir, target) {
		return fmt.Errorf("%s: .git does not point at ./.bare (got %q)", dir, target)
	}
	return nil
}

// pointsAtBare returns true if target (the value after "gitdir:")
// resolves to <dir>/.bare. target may be relative or absolute.
func pointsAtBare(dir, target string) bool {
	resolved := target
	if !filepath.IsAbs(resolved) {
		resolved = filepath.Join(dir, target)
	}
	a, err := filepath.Abs(resolved)
	if err != nil {
		return false
	}
	b, err := filepath.Abs(filepath.Join(dir, ".bare"))
	if err != nil {
		return false
	}
	return filepath.Clean(a) == filepath.Clean(b)
}
