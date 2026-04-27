package identity

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestScaffold_CreatesLayout(t *testing.T) {
	root := t.TempDir()
	layout := Resolve(root, "ash")
	if err := Scaffold(layout); err != nil {
		t.Fatalf("scaffold: %v", err)
	}
	for _, p := range []string{layout.PurposeMD, layout.MemoryMD, layout.ProjectMD} {
		if _, err := os.Stat(p); err != nil {
			t.Fatalf("expected file %s: %v", p, err)
		}
	}
	for _, d := range []string{layout.MemoryDir, layout.LearningsDir} {
		st, err := os.Stat(d)
		if err != nil {
			t.Fatalf("expected dir %s: %v", d, err)
		}
		if !st.IsDir() {
			t.Fatalf("%s is not a dir", d)
		}
	}
	b, err := os.ReadFile(layout.PurposeMD)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(b), "PURPOSE.md — ash") {
		t.Fatalf("PURPOSE.md missing template name: %q", string(b))
	}
	if !strings.Contains(string(b), "## Role") {
		t.Fatalf("PURPOSE.md missing Role heading")
	}
	mem, err := os.ReadFile(layout.MemoryMD)
	if err != nil {
		t.Fatalf("read MEMORY.md: %v", err)
	}
	if len(mem) != 0 {
		t.Fatalf("MEMORY.md should be empty, got %d bytes", len(mem))
	}
	proj, err := os.ReadFile(layout.ProjectMD)
	if err != nil {
		t.Fatalf("read PROJECT.md: %v", err)
	}
	if len(proj) != 0 {
		t.Fatalf("PROJECT.md should be empty, got %d bytes", len(proj))
	}
}

func TestScaffold_Idempotent(t *testing.T) {
	root := t.TempDir()
	layout := Resolve(root, "ash")
	if err := Scaffold(layout); err != nil {
		t.Fatal(err)
	}
	const custom = "# PURPOSE.md — ash\n\nUser-edited content.\n"
	if err := os.WriteFile(layout.PurposeMD, []byte(custom), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := Scaffold(layout); err != nil {
		t.Fatalf("rerun scaffold: %v", err)
	}
	got, err := os.ReadFile(layout.PurposeMD)
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != custom {
		t.Fatalf("Scaffold overwrote user edits.\nwant:\n%s\ngot:\n%s", custom, got)
	}
}

func TestScaffold_PreservesUserEdits(t *testing.T) {
	root := t.TempDir()
	layout := Resolve(root, "ash")
	if err := Scaffold(layout); err != nil {
		t.Fatal(err)
	}
	const note = "user note\n"
	if err := os.WriteFile(layout.MemoryMD, []byte(note), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := Scaffold(layout); err != nil {
		t.Fatal(err)
	}
	got, err := os.ReadFile(layout.MemoryMD)
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != note {
		t.Fatalf("MEMORY.md was overwritten: got %q", got)
	}
}

func TestBoot_RequiresPurpose(t *testing.T) {
	root := t.TempDir()
	layout := Resolve(root, "ash")
	if err := Scaffold(layout); err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(layout.PurposeMD); err != nil {
		t.Fatal(err)
	}
	if _, err := Boot("ash", layout); err == nil {
		t.Fatalf("expected error when PURPOSE.md missing")
	}
}

func TestBoot_UsesExplicitAgentName(t *testing.T) {
	base := t.TempDir()
	weirdConfigDir := filepath.Join(base, "not-the-agent-name")
	layout := LayoutAt(weirdConfigDir)
	if err := Scaffold(layout); err != nil {
		t.Fatalf("scaffold: %v", err)
	}
	payload, err := Boot("ash", layout)
	if err != nil {
		t.Fatalf("boot: %v", err)
	}
	if payload.AgentName != "ash" {
		t.Errorf("AgentName = %q, want %q", payload.AgentName, "ash")
	}
	if payload.EnvVars["CODA_AGENT_NAME"] != "ash" {
		t.Errorf("CODA_AGENT_NAME = %q, want %q", payload.EnvVars["CODA_AGENT_NAME"], "ash")
	}
}

func TestBoot_RejectsNonRegularPurposeMD(t *testing.T) {
	root := t.TempDir()
	layout := Resolve(root, "ash")
	if err := Scaffold(layout); err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(layout.PurposeMD); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(layout.PurposeMD, 0o755); err != nil {
		t.Fatal(err)
	}
	_, err := Boot("ash", layout)
	if err == nil {
		t.Fatalf("expected error when PURPOSE.md is a directory")
	}
	if !strings.Contains(err.Error(), "regular file") {
		t.Errorf("error %q does not mention 'regular file'", err.Error())
	}
}

func TestBoot_BuildsPayload(t *testing.T) {
	root := t.TempDir()
	layout := Resolve(root, "ash")
	if err := Scaffold(layout); err != nil {
		t.Fatal(err)
	}
	p, err := Boot("ash", layout)
	if err != nil {
		t.Fatalf("boot: %v", err)
	}
	if p.AgentName != "ash" {
		t.Fatalf("AgentName=%q", p.AgentName)
	}
	if p.ConfigDir != layout.Root {
		t.Fatalf("ConfigDir=%q want %q", p.ConfigDir, layout.Root)
	}
	if len(p.Files) != 3 {
		t.Fatalf("expected 3 files (PURPOSE, MEMORY, PROJECT), got %v", p.Files)
	}
	if p.Files[0] != layout.PurposeMD {
		t.Fatalf("first file should be PURPOSE.md, got %q", p.Files[0])
	}
	if p.EnvVars["CODA_AGENT_NAME"] != "ash" {
		t.Fatalf("env CODA_AGENT_NAME=%q", p.EnvVars["CODA_AGENT_NAME"])
	}
	if p.EnvVars["CODA_AGENT_CONFIG_DIR"] != layout.Root {
		t.Fatalf("env CODA_AGENT_CONFIG_DIR=%q want %q", p.EnvVars["CODA_AGENT_CONFIG_DIR"], layout.Root)
	}
}

func TestAppendMemory(t *testing.T) {
	root := t.TempDir()
	layout := Resolve(root, "ash")
	if err := Scaffold(layout); err != nil {
		t.Fatal(err)
	}
	when := time.Date(2026, 4, 24, 10, 0, 0, 0, time.UTC)
	if err := AppendMemory(layout, when, "first entry"); err != nil {
		t.Fatal(err)
	}
	if err := AppendMemory(layout, when, "second entry\n"); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(layout.MemoryDir, "2026-04-24.md")
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	got := string(b)
	if !strings.Contains(got, "first entry") || !strings.Contains(got, "second entry") {
		t.Fatalf("missing entries in %q", got)
	}
	if !strings.HasSuffix(got, "\n") {
		t.Fatalf("file does not end with newline: %q", got)
	}
}

func TestReadRecentMemory_OrderingAndLimit(t *testing.T) {
	root := t.TempDir()
	layout := Resolve(root, "ash")
	if err := Scaffold(layout); err != nil {
		t.Fatal(err)
	}
	dates := []time.Time{
		time.Date(2026, 4, 22, 0, 0, 0, 0, time.UTC),
		time.Date(2026, 4, 23, 0, 0, 0, 0, time.UTC),
		time.Date(2026, 4, 24, 0, 0, 0, 0, time.UTC),
	}
	for _, d := range dates {
		if err := AppendMemory(layout, d, "entry for "+d.Format("2006-01-02")); err != nil {
			t.Fatal(err)
		}
	}
	got, err := ReadRecentMemory(layout, 2)
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 2 {
		t.Fatalf("expected 2 entries, got %d", len(got))
	}
	if !got[0].Date.Equal(dates[2]) {
		t.Fatalf("first entry date=%v want %v", got[0].Date, dates[2])
	}
	if !got[1].Date.Equal(dates[1]) {
		t.Fatalf("second entry date=%v want %v", got[1].Date, dates[1])
	}
	if !strings.Contains(got[0].Content, "2026-04-24") {
		t.Fatalf("content mismatch: %q", got[0].Content)
	}
}
