package feature

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

func newTestProject(t *testing.T) *Project {
	t.Helper()
	root := t.TempDir()
	bare := filepath.Join(root, ".bare")
	mustGit(t, root, "init", "--bare", "--initial-branch=main", ".bare")
	if err := os.WriteFile(filepath.Join(root, ".git"), []byte("gitdir: ./.bare\n"), 0o644); err != nil {
		t.Fatalf("write .git: %v", err)
	}
	mustGit(t, bare, "symbolic-ref", "HEAD", "refs/heads/main")
	mustGit(t, root, "worktree", "add", filepath.Join(root, "main"))

	mainWT := filepath.Join(root, "main")
	mustGit(t, mainWT, "config", "user.email", "test@example.com")
	mustGit(t, mainWT, "config", "user.name", "Test")
	if err := os.WriteFile(filepath.Join(mainWT, "README.md"), []byte("# test\n"), 0o644); err != nil {
		t.Fatalf("write README: %v", err)
	}
	mustGit(t, mainWT, "add", "README.md")
	mustGit(t, mainWT, "commit", "-m", "init")

	return &Project{Name: filepath.Base(root), Root: root}
}

func mustGit(t *testing.T, dir string, args ...string) string {
	t.Helper()
	cmd := exec.CommandContext(context.Background(), "git", append([]string{"-C", dir}, args...)...)
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("git %v in %s: %v\n%s", args, dir, err, out)
	}
	return string(out)
}
