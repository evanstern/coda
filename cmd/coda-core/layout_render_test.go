package main

import (
	"bytes"
	"strings"
	"testing"
)

func TestRenderLayoutBash_SinglePane(t *testing.T) {
	cfg := &LayoutConfig{
		Direction: "horizontal",
		Panes:     []PaneConfig{{Command: "opencode"}},
	}

	var buf bytes.Buffer
	if err := renderLayoutBash(&buf, cfg); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	out := buf.String()
	if !strings.Contains(out, "_layout_init()") {
		t.Error("missing _layout_init")
	}
	if !strings.Contains(out, "_layout_spawn()") {
		t.Error("missing _layout_spawn")
	}
	if !strings.Contains(out, "opencode") {
		t.Error("missing opencode command")
	}
	if strings.Contains(out, "split-window") {
		t.Error("single pane should not have split-window")
	}
}

func TestRenderLayoutBash_TwoPanes(t *testing.T) {
	cfg := &LayoutConfig{
		Direction: "vertical",
		Panes: []PaneConfig{
			{Command: "opencode", Title: "OpenCode", Size: "80%"},
			{Title: "Shell", Size: "20%"},
		},
	}

	var buf bytes.Buffer
	if err := renderLayoutBash(&buf, cfg); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	out := buf.String()
	if !strings.Contains(out, "split-window -v") {
		t.Error("expected vertical split")
	}
	if !strings.Contains(out, "-p 20") {
		t.Error("expected percentage size flag")
	}
	if !strings.Contains(out, "pane-border-status") {
		t.Error("expected border setup (titles present)")
	}
	if !strings.Contains(out, `"OpenCode"`) {
		t.Error("expected OpenCode title")
	}
	if !strings.Contains(out, `"Shell"`) {
		t.Error("expected Shell title")
	}
}

func TestRenderLayoutBash_HorizontalSplit(t *testing.T) {
	cfg := &LayoutConfig{
		Direction: "horizontal",
		Panes: []PaneConfig{
			{Command: "opencode", Size: "50%"},
			{Command: "nvim .", Size: "50%"},
		},
	}

	var buf bytes.Buffer
	if err := renderLayoutBash(&buf, cfg); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	out := buf.String()
	if !strings.Contains(out, "split-window -h") {
		t.Error("expected horizontal split")
	}
}

func TestRenderLayoutBash_NestedLayout(t *testing.T) {
	cfg := &LayoutConfig{
		Direction: "vertical",
		Panes: []PaneConfig{
			{
				Direction: "horizontal",
				Size:      "65%",
				Panes: []PaneConfig{
					{Command: "opencode", Title: "OpenCode", Size: "50%"},
					{Command: "nvim .", Title: "Editor", Size: "50%"},
				},
			},
			{Title: "Shell", Size: "35%"},
		},
	}

	var buf bytes.Buffer
	if err := renderLayoutBash(&buf, cfg); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	out := buf.String()
	if !strings.Contains(out, "split-window -v") {
		t.Error("expected vertical split for bottom pane")
	}
	if !strings.Contains(out, "split-window -h") {
		t.Error("expected horizontal split for top nested panes")
	}
	if !strings.Contains(out, "opencode") {
		t.Error("missing opencode")
	}
	if !strings.Contains(out, "nvim") {
		t.Error("missing nvim")
	}
}

func TestRenderLayoutBash_PreferCommands(t *testing.T) {
	cfg := &LayoutConfig{
		Direction: "horizontal",
		Panes: []PaneConfig{
			{
				Prefer: []string{"yazi", "nnn", "lf"},
				Title:  "Explorer",
			},
			{Command: "opencode"},
		},
	}

	var buf bytes.Buffer
	if err := renderLayoutBash(&buf, cfg); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	out := buf.String()
	if !strings.Contains(out, "_prefer_0()") {
		t.Error("missing prefer function")
	}
	if !strings.Contains(out, "command -v yazi") {
		t.Error("missing yazi check")
	}
	if !strings.Contains(out, "command -v nnn") {
		t.Error("missing nnn check")
	}
	if !strings.Contains(out, "command -v lf") {
		t.Error("missing lf check")
	}
}

func TestRenderLayoutBash_EnvVars(t *testing.T) {
	cfg := &LayoutConfig{
		Direction: "horizontal",
		Panes: []PaneConfig{
			{
				Command: "nvim .",
				Env:     map[string]string{"NVIM_APPNAME": "$nvim_appname"},
			},
		},
	}

	var buf bytes.Buffer
	if err := renderLayoutBash(&buf, cfg); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	out := buf.String()
	if !strings.Contains(out, "NVIM_APPNAME=$nvim_appname") {
		t.Errorf("expected env var in command, got:\n%s", out)
	}
}

func TestRenderLayoutBash_NoBordersWithoutTitles(t *testing.T) {
	cfg := &LayoutConfig{
		Direction: "horizontal",
		Panes: []PaneConfig{
			{Command: "opencode"},
			{Command: "nvim ."},
		},
	}

	var buf bytes.Buffer
	if err := renderLayoutBash(&buf, cfg); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	out := buf.String()
	if strings.Contains(out, "pane-border-status") {
		t.Error("should not have border setup without titles")
	}
}

func TestRenderLayoutBash_SpawnFuncHasHeredoc(t *testing.T) {
	cfg := &LayoutConfig{
		Direction: "horizontal",
		Panes: []PaneConfig{
			{Command: "opencode"},
			{Command: "nvim ."},
		},
	}

	var buf bytes.Buffer
	if err := renderLayoutBash(&buf, cfg); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	out := buf.String()
	if !strings.Contains(out, "<<'SETUP'") {
		t.Error("spawn func should use heredoc")
	}
	if !strings.Contains(out, "SETUP") {
		t.Error("spawn func should have SETUP delimiter")
	}
	if !strings.Contains(out, "mktemp") {
		t.Error("spawn func should use mktemp")
	}
}

func TestRenderLayoutBash_FixedSize(t *testing.T) {
	cfg := &LayoutConfig{
		Direction: "vertical",
		Panes: []PaneConfig{
			{Command: "opencode"},
			{Size: "10"},
		},
	}

	var buf bytes.Buffer
	if err := renderLayoutBash(&buf, cfg); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	out := buf.String()
	if !strings.Contains(out, "-l 10") {
		t.Error("expected fixed size flag -l")
	}
}

func TestFlattenPanes(t *testing.T) {
	panes := []PaneConfig{
		{Command: "a"},
		{
			Direction: "horizontal",
			Panes: []PaneConfig{
				{Command: "b"},
				{Command: "c"},
			},
		},
		{Command: "d"},
	}

	flat := flattenPanes(panes)
	if len(flat) != 4 {
		t.Fatalf("expected 4 flat panes, got %d", len(flat))
	}
	expected := []string{"a", "b", "c", "d"}
	for i, e := range expected {
		if flat[i].command != e {
			t.Errorf("flat[%d].command = %q, want %q", i, flat[i].command, e)
		}
	}
}
