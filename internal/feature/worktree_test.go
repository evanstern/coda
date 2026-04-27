package feature

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestStart_Clean(t *testing.T) {
	p := newTestProject(t)
	wt, err := Start(context.Background(), p, "feat-x", "main", nil)
	if err != nil {
		t.Fatalf("Start: %v", err)
	}
	if wt.Branch != "feat-x" {
		t.Fatalf("Branch=%q", wt.Branch)
	}
	if wt.Path != filepath.Join(p.Root, "feat-x") {
		t.Fatalf("Path=%q", wt.Path)
	}
	if wt.Base != "main" {
		t.Fatalf("Base=%q", wt.Base)
	}
	if _, err := os.Stat(wt.Path); err != nil {
		t.Fatalf("worktree path missing: %v", err)
	}
}

func TestStart_BranchAlreadyExists(t *testing.T) {
	p := newTestProject(t)
	if _, err := Start(context.Background(), p, "dup", "main", nil); err != nil {
		t.Fatalf("first Start: %v", err)
	}
	if err := os.RemoveAll(filepath.Join(p.Root, "dup")); err != nil {
		t.Fatal(err)
	}
	mustGit(t, p.Root, "worktree", "prune")
	_, err := Start(context.Background(), p, "dup", "main", nil)
	if err == nil {
		t.Fatalf("expected error when branch already exists")
	}
}

func TestStart_PathOccupied(t *testing.T) {
	p := newTestProject(t)
	occupied := filepath.Join(p.Root, "feat-occupied")
	if err := os.MkdirAll(occupied, 0o755); err != nil {
		t.Fatal(err)
	}
	if _, err := Start(context.Background(), p, "feat-occupied", "main", nil); err == nil {
		t.Fatalf("expected error when path occupied")
	}
}

func TestStart_DefaultBranchDetection(t *testing.T) {
	p := newTestProject(t)
	wt, err := Start(context.Background(), p, "feat-default", "", nil)
	if err != nil {
		t.Fatalf("Start: %v", err)
	}
	if wt.Base != "main" {
		t.Fatalf("Base=%q want main", wt.Base)
	}
}

func TestFinish_Clean(t *testing.T) {
	p := newTestProject(t)
	wt, err := Start(context.Background(), p, "feat-fin", "main", nil)
	if err != nil {
		t.Fatal(err)
	}
	if err := Finish(context.Background(), p, "feat-fin", false, nil); err != nil {
		t.Fatalf("Finish: %v", err)
	}
	if _, err := os.Stat(wt.Path); !os.IsNotExist(err) {
		t.Fatalf("worktree path still present: %v", err)
	}
}

func TestFinish_UncommittedNoForce(t *testing.T) {
	p := newTestProject(t)
	wt, err := Start(context.Background(), p, "feat-dirty", "main", nil)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(wt.Path, "scratch.txt"), []byte("dirty"), 0o644); err != nil {
		t.Fatal(err)
	}
	err = Finish(context.Background(), p, "feat-dirty", false, nil)
	if err == nil {
		t.Fatalf("expected error for uncommitted changes")
	}
	if !strings.Contains(err.Error(), "uncommitted") {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestFinish_UncommittedForce(t *testing.T) {
	p := newTestProject(t)
	wt, err := Start(context.Background(), p, "feat-force", "main", nil)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(wt.Path, "scratch.txt"), []byte("dirty"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := Finish(context.Background(), p, "feat-force", true, nil); err != nil {
		t.Fatalf("Finish --force: %v", err)
	}
	if _, err := os.Stat(wt.Path); !os.IsNotExist(err) {
		t.Fatalf("worktree path still present: %v", err)
	}
}

func TestFinish_Nonexistent(t *testing.T) {
	p := newTestProject(t)
	err := Finish(context.Background(), p, "ghost", false, nil)
	if err == nil {
		t.Fatalf("expected error for nonexistent worktree")
	}
}

func TestList_Empty(t *testing.T) {
	p := newTestProject(t)
	wts, err := List(context.Background(), p)
	if err != nil {
		t.Fatalf("List: %v", err)
	}
	if len(wts) != 0 {
		t.Fatalf("expected 0 worktrees, got %d: %+v", len(wts), wts)
	}
}

func TestList_WithWorktreesExcludesMain(t *testing.T) {
	p := newTestProject(t)
	if _, err := Start(context.Background(), p, "alpha", "main", nil); err != nil {
		t.Fatal(err)
	}
	if _, err := Start(context.Background(), p, "beta", "main", nil); err != nil {
		t.Fatal(err)
	}
	wts, err := List(context.Background(), p)
	if err != nil {
		t.Fatalf("List: %v", err)
	}
	if len(wts) != 2 {
		t.Fatalf("expected 2 worktrees, got %d: %+v", len(wts), wts)
	}
	branches := map[string]bool{}
	for _, w := range wts {
		branches[w.Branch] = true
	}
	if !branches["alpha"] || !branches["beta"] {
		t.Fatalf("expected alpha+beta, got %+v", wts)
	}
}

func TestParseWorktreeList_DetachedSkippedByList(t *testing.T) {
	p := newTestProject(t)
	mustGit(t, p.Root, "worktree", "add", "--detach", filepath.Join(p.Root, "detached-wt"), "main")
	if _, err := Start(context.Background(), p, "branched", "main", nil); err != nil {
		t.Fatal(err)
	}
	wts, err := List(context.Background(), p)
	if err != nil {
		t.Fatalf("List: %v", err)
	}
	if len(wts) != 1 || wts[0].Branch != "branched" {
		t.Fatalf("expected only branched, got %+v", wts)
	}
}

func TestParseWorktreeList_ReturnsErrorOnNoData(t *testing.T) {
	entries, err := parseWorktreeList("")
	if err != nil {
		t.Fatalf("parse empty: %v", err)
	}
	if len(entries) != 0 {
		t.Fatalf("expected no entries, got %+v", entries)
	}
}
