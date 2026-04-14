package main

import (
	"strings"
	"testing"

	"gopkg.in/yaml.v3"
)

func TestParseLayoutTree_TwoPanes(t *testing.T) {
	layout := "a1b2,200x50,0,0{100x50,0,0,0,99x50,101,0,1}"
	node := parseLayoutTree(layout)

	if node.direction != "horizontal" {
		t.Errorf("expected horizontal, got %s", node.direction)
	}
	if len(node.children) != 2 {
		t.Fatalf("expected 2 children, got %d", len(node.children))
	}
	if node.children[0].paneID != "0" {
		t.Errorf("first child paneID = %q, want 0", node.children[0].paneID)
	}
	if node.children[1].paneID != "1" {
		t.Errorf("second child paneID = %q, want 1", node.children[1].paneID)
	}
}

func TestParseLayoutTree_ThreePaneNested(t *testing.T) {
	layout := "c3d4,160x40,0,0[160x30,0,0{80x30,0,0,5,79x30,81,0,6},160x9,0,31,7]"
	node := parseLayoutTree(layout)

	if node.direction != "vertical" {
		t.Errorf("expected vertical, got %s", node.direction)
	}
	if len(node.children) != 2 {
		t.Fatalf("expected 2 children, got %d", len(node.children))
	}
	if node.children[0].subNode == nil {
		t.Fatal("first child should be a sub-node")
	}
	if node.children[0].subNode.direction != "horizontal" {
		t.Errorf("sub-node direction = %s, want horizontal", node.children[0].subNode.direction)
	}
	if node.children[1].paneID != "7" {
		t.Errorf("bottom pane ID = %q, want 7", node.children[1].paneID)
	}
}

func TestSnapshotToConfig_TwoPanes(t *testing.T) {
	snap := &snapshot{
		WinW:      200,
		WinH:      50,
		LayoutStr: "a1b2,200x50,0,0{100x50,0,0,0,99x50,101,0,1}",
		PaneCount: 2,
		Panes: []paneInfo{
			{ID: "0", Cmd: "opencode", Title: "OpenCode"},
			{ID: "1", Cmd: "nvim", Title: "Editor"},
		},
		LayoutTmpl: "200x50,0,0{100x50,0,0,__P0__,99x50,101,0,__P1__}",
		LeafIDs:    []string{"0", "1"},
	}

	cfg := snapshotToConfig(snap)
	if cfg.Direction != "horizontal" {
		t.Errorf("expected horizontal, got %s", cfg.Direction)
	}
	if len(cfg.Panes) != 2 {
		t.Fatalf("expected 2 panes, got %d", len(cfg.Panes))
	}
	if cfg.Panes[0].Command != "opencode" {
		t.Errorf("first pane command = %q, want opencode", cfg.Panes[0].Command)
	}
	if cfg.Panes[0].Title != "OpenCode" {
		t.Errorf("first pane title = %q, want OpenCode", cfg.Panes[0].Title)
	}
}

func TestGenerateLayoutYAML_RoundTrip(t *testing.T) {
	snap := &snapshot{
		WinW:      200,
		WinH:      50,
		LayoutStr: "a1b2,200x50,0,0{100x50,0,0,0,99x50,101,0,1}",
		PaneCount: 2,
		Panes: []paneInfo{
			{ID: "0", Cmd: "opencode", Title: "OpenCode"},
			{ID: "1", Cmd: "nvim", Title: "Editor"},
		},
		LayoutTmpl: "200x50,0,0{100x50,0,0,__P0__,99x50,101,0,__P1__}",
		LeafIDs:    []string{"0", "1"},
	}

	yamlData, err := generateLayoutYAML(snap)
	if err != nil {
		t.Fatalf("generateLayoutYAML failed: %v", err)
	}

	var cfg LayoutConfig
	if err := yaml.Unmarshal(yamlData, &cfg); err != nil {
		t.Fatalf("round-trip parse failed: %v", err)
	}

	if cfg.Direction != "horizontal" {
		t.Errorf("round-trip direction = %s, want horizontal", cfg.Direction)
	}
	if len(cfg.Panes) != 2 {
		t.Fatalf("round-trip pane count = %d, want 2", len(cfg.Panes))
	}
}

func TestGenerateLayoutYAML_ContainsExpectedFields(t *testing.T) {
	snap := &snapshot{
		WinW:      200,
		WinH:      50,
		LayoutStr: "a1b2,200x50,0,0{100x50,0,0,0,99x50,101,0,1}",
		PaneCount: 2,
		Panes: []paneInfo{
			{ID: "0", Cmd: "opencode", Title: "OpenCode"},
			{ID: "1", Cmd: "bash", Title: ""},
		},
		LayoutTmpl: "200x50,0,0{100x50,0,0,__P0__,99x50,101,0,__P1__}",
		LeafIDs:    []string{"0", "1"},
	}

	yamlData, err := generateLayoutYAML(snap)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	str := string(yamlData)
	if !strings.Contains(str, "direction:") {
		t.Error("YAML missing direction field")
	}
	if !strings.Contains(str, "command: opencode") {
		t.Error("YAML missing opencode command")
	}
	if !strings.Contains(str, "title: OpenCode") {
		t.Error("YAML missing OpenCode title")
	}
}
