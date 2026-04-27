package feature

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestFindProject_CwdInsideProject(t *testing.T) {
	p := newTestProject(t)
	subdir := filepath.Join(p.Root, "main", "deep", "nested")
	if err := os.MkdirAll(subdir, 0o755); err != nil {
		t.Fatal(err)
	}
	got, err := FindProject(subdir, "")
	if err != nil {
		t.Fatalf("FindProject: %v", err)
	}
	if got.Root != p.Root {
		t.Fatalf("Root=%q want %q", got.Root, p.Root)
	}
	if got.Name != filepath.Base(p.Root) {
		t.Fatalf("Name=%q want %q", got.Name, filepath.Base(p.Root))
	}
}

func TestFindProject_CwdOutsideProject(t *testing.T) {
	dir := t.TempDir()
	if _, err := FindProject(dir, ""); err == nil {
		t.Fatalf("expected error, got nil")
	}
}

func TestFindProject_NameHintExists(t *testing.T) {
	p := newTestProject(t)
	parent := filepath.Dir(p.Root)
	t.Setenv("PROJECTS_DIR", parent)
	got, err := FindProject("/", filepath.Base(p.Root))
	if err != nil {
		t.Fatalf("FindProject: %v", err)
	}
	if got.Name != filepath.Base(p.Root) {
		t.Fatalf("Name=%q", got.Name)
	}
	if got.Root != p.Root {
		t.Fatalf("Root=%q want %q", got.Root, p.Root)
	}
}

func TestFindProject_NameHintMissing(t *testing.T) {
	t.Setenv("PROJECTS_DIR", t.TempDir())
	_, err := FindProject("/", "nope")
	if err == nil {
		t.Fatalf("expected error")
	}
	if !strings.Contains(err.Error(), "not found") {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestFindProject_NameHintNotACodaProject(t *testing.T) {
	projects := t.TempDir()
	bad := filepath.Join(projects, "bad")
	if err := os.MkdirAll(bad, 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PROJECTS_DIR", projects)
	_, err := FindProject("/", "bad")
	if err == nil {
		t.Fatalf("expected error")
	}
	if !strings.Contains(err.Error(), ".bare") {
		t.Fatalf("expected .bare error, got: %v", err)
	}
}
