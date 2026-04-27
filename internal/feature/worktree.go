package feature

import (
	"bufio"
	"bytes"
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

// Worktree describes a single feature worktree on disk.
type Worktree struct {
	Branch string
	Path   string
	Base   string
}

// HookEnv is the v2-compatible env-var set passed to hook scripts. Keep
// the keys in sync with v2 plugin contracts.
type HookEnv = map[string]string

// Hook event names. v2-compatible.
const (
	EventPreCreate   = "pre-feature-create"
	EventPostCreate  = "post-feature-create"
	EventPreTeardown = "pre-feature-teardown"
	EventPostFinish  = "post-feature-finish"
)

// Start creates a new worktree at <project.Root>/<branch>/ from base.
// If base == "", the project's default branch is detected. Hooks fire
// at pre-feature-create and post-feature-create.
func Start(ctx context.Context, project *Project, branch, base string, runner HookRunner) (*Worktree, error) {
	if project == nil {
		return nil, errors.New("project is nil")
	}
	if branch == "" {
		return nil, errors.New("branch is required")
	}
	worktreePath := filepath.Join(project.Root, branch)

	if _, err := os.Stat(worktreePath); err == nil {
		return nil, fmt.Errorf("worktree path already exists: %s", worktreePath)
	} else if !errors.Is(err, os.ErrNotExist) {
		return nil, fmt.Errorf("stat worktree path: %w", err)
	}

	if base == "" {
		detected, err := detectDefaultBranch(ctx, project.Root)
		if err != nil {
			return nil, err
		}
		base = detected
	}

	env := HookEnv{
		"CODA_PROJECT_NAME":   project.Name,
		"CODA_PROJECT_DIR":    project.Root,
		"CODA_FEATURE_BRANCH": branch,
		"CODA_WORKTREE_DIR":   worktreePath,
	}

	if runner != nil {
		_ = runner.Run(ctx, EventPreCreate, env)
	}

	out, err := runGit(ctx, project.Root, "worktree", "add", "-b", branch, worktreePath, base)
	if err != nil {
		return nil, fmt.Errorf("git worktree add: %w: %s", err, strings.TrimSpace(out))
	}

	wt := &Worktree{Branch: branch, Path: worktreePath, Base: base}

	if runner != nil {
		_ = runner.Run(ctx, EventPostCreate, env)
	}
	return wt, nil
}

// Finish removes the worktree for branch and deletes the branch.
// Refuses if the worktree has uncommitted changes unless force is true.
// Hooks fire at pre-feature-teardown and post-feature-finish.
func Finish(ctx context.Context, project *Project, branch string, force bool, runner HookRunner) error {
	if project == nil {
		return errors.New("project is nil")
	}
	if branch == "" {
		return errors.New("branch is required")
	}
	worktreePath := filepath.Join(project.Root, branch)

	if _, err := os.Stat(worktreePath); err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return fmt.Errorf("worktree does not exist: %s", worktreePath)
		}
		return fmt.Errorf("stat worktree path: %w", err)
	}

	status, err := runGit(ctx, worktreePath, "status", "--porcelain")
	if err != nil {
		return fmt.Errorf("git status: %w: %s", err, strings.TrimSpace(status))
	}
	if strings.TrimSpace(status) != "" && !force {
		return fmt.Errorf("worktree %s has uncommitted changes; pass --force to discard", worktreePath)
	}

	env := HookEnv{
		"CODA_PROJECT_NAME":   project.Name,
		"CODA_PROJECT_DIR":    project.Root,
		"CODA_FEATURE_BRANCH": branch,
		"CODA_WORKTREE_DIR":   worktreePath,
	}

	if runner != nil {
		_ = runner.Run(ctx, EventPreTeardown, env)
	}

	args := []string{"worktree", "remove"}
	if force {
		args = append(args, "--force")
	}
	args = append(args, worktreePath)
	if out, err := runGit(ctx, project.Root, args...); err != nil {
		return fmt.Errorf("git worktree remove: %w: %s", err, strings.TrimSpace(out))
	}

	if out, err := runGit(ctx, project.Root, "branch", "-D", branch); err != nil {
		return fmt.Errorf("git branch -D: %w: %s", err, strings.TrimSpace(out))
	}

	if runner != nil {
		_ = runner.Run(ctx, EventPostFinish, env)
	}
	return nil
}

// List returns active feature worktrees, excluding the bare repo's
// internal worktree and the project's default-branch worktree.
// Detached worktrees (no branch ref) are also skipped.
func List(ctx context.Context, project *Project) ([]Worktree, error) {
	if project == nil {
		return nil, errors.New("project is nil")
	}
	out, err := runGit(ctx, project.Root, "worktree", "list", "--porcelain")
	if err != nil {
		return nil, fmt.Errorf("git worktree list: %w: %s", err, strings.TrimSpace(out))
	}
	// Default-branch detection is best-effort here: some projects (e.g.
	// freshly inited bare repo with no remote and no branches) won't have
	// one yet. If we can't resolve it, skip the default-path filter
	// rather than fail the whole listing.
	defaultBranch, _ := detectDefaultBranch(ctx, project.Root)
	defaultPath := ""
	if defaultBranch != "" {
		defaultPath = filepath.Clean(filepath.Join(project.Root, defaultBranch))
	}
	barePath := filepath.Clean(filepath.Join(project.Root, ".bare"))

	entries, err := parseWorktreeList(out)
	if err != nil {
		return nil, fmt.Errorf("parse worktree list: %w", err)
	}
	result := make([]Worktree, 0, len(entries))
	for _, e := range entries {
		if e.bare || e.detached {
			continue
		}
		if e.branch == "" {
			continue
		}
		clean := filepath.Clean(e.path)
		if clean == barePath || (defaultPath != "" && clean == defaultPath) {
			continue
		}
		result = append(result, Worktree{Branch: e.branch, Path: clean})
	}
	return result, nil
}

type worktreeEntry struct {
	path     string
	branch   string
	bare     bool
	detached bool
}

// parseWorktreeList parses the output of `git worktree list --porcelain`.
// Blocks are separated by blank lines; each block has lines like
// "worktree <path>", "HEAD <sha>", "branch <ref>", "bare", "detached".
func parseWorktreeList(s string) ([]worktreeEntry, error) {
	var entries []worktreeEntry
	var cur worktreeEntry
	flush := func() {
		if cur.path != "" {
			entries = append(entries, cur)
		}
		cur = worktreeEntry{}
	}
	scanner := bufio.NewScanner(strings.NewReader(s))
	scanner.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for scanner.Scan() {
		line := scanner.Text()
		if line == "" {
			flush()
			continue
		}
		switch {
		case strings.HasPrefix(line, "worktree "):
			cur.path = strings.TrimPrefix(line, "worktree ")
		case strings.HasPrefix(line, "branch "):
			ref := strings.TrimPrefix(line, "branch ")
			cur.branch = strings.TrimPrefix(ref, "refs/heads/")
		case line == "bare":
			cur.bare = true
		case line == "detached":
			cur.detached = true
		}
	}
	flush()
	if err := scanner.Err(); err != nil {
		return nil, err
	}
	return entries, nil
}

// detectDefaultBranch resolves origin/HEAD or falls back to main, then master.
func detectDefaultBranch(ctx context.Context, gitDir string) (string, error) {
	out, err := runGit(ctx, gitDir, "symbolic-ref", "refs/remotes/origin/HEAD")
	if err == nil {
		ref := strings.TrimSpace(out)
		name := strings.TrimPrefix(ref, "refs/remotes/origin/")
		if name != "" {
			return name, nil
		}
	}
	for _, candidate := range []string{"main", "master"} {
		if _, err := runGit(ctx, gitDir, "show-ref", "--verify", "--quiet", "refs/heads/"+candidate); err == nil {
			return candidate, nil
		}
	}
	return "", fmt.Errorf("could not detect default branch in %s", gitDir)
}

// runGit invokes git -C dir with args and returns combined stdout+stderr.
func runGit(ctx context.Context, dir string, args ...string) (string, error) {
	full := append([]string{"-C", dir}, args...)
	cmd := exec.CommandContext(ctx, "git", full...)
	var buf bytes.Buffer
	cmd.Stdout = &buf
	cmd.Stderr = &buf
	err := cmd.Run()
	return buf.String(), err
}
