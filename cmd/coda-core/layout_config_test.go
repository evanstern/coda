package main

import (
	"testing"
)

func TestParseLayoutConfig_SinglePane(t *testing.T) {
	yaml := `
direction: horizontal
panes:
  - command: opencode
`
	cfg, err := parseLayoutConfigBytes([]byte(yaml))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if cfg.Direction != "horizontal" {
		t.Errorf("expected horizontal, got %s", cfg.Direction)
	}
	if len(cfg.Panes) != 1 {
		t.Fatalf("expected 1 pane, got %d", len(cfg.Panes))
	}
	if cfg.Panes[0].Command != "opencode" {
		t.Errorf("expected opencode command, got %s", cfg.Panes[0].Command)
	}
}

func TestParseLayoutConfig_TwoPanes(t *testing.T) {
	yaml := `
direction: vertical
panes:
  - command: opencode
    title: OpenCode
    size: "80%"
  - command: "$SHELL"
    size: "20%"
`
	cfg, err := parseLayoutConfigBytes([]byte(yaml))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(cfg.Panes) != 2 {
		t.Fatalf("expected 2 panes, got %d", len(cfg.Panes))
	}
	if cfg.Panes[0].Title != "OpenCode" {
		t.Errorf("expected title OpenCode, got %s", cfg.Panes[0].Title)
	}
	if cfg.Panes[0].Size != "80%" {
		t.Errorf("expected 80%%, got %s", cfg.Panes[0].Size)
	}
}

func TestParseLayoutConfig_NestedSplits(t *testing.T) {
	yaml := `
direction: vertical
panes:
  - direction: horizontal
    size: "65%"
    panes:
      - command: opencode
        title: OpenCode
        size: "50%"
      - command: "nvim ."
        title: Editor
        size: "50%"
  - command: "$SHELL"
    title: Shell
    size: "35%"
`
	cfg, err := parseLayoutConfigBytes([]byte(yaml))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(cfg.Panes) != 2 {
		t.Fatalf("expected 2 top-level panes, got %d", len(cfg.Panes))
	}
	if !cfg.Panes[0].IsLeaf() {
		t.Log("first pane is a split (expected)")
	} else {
		t.Error("first pane should be a split, not a leaf")
	}
	if cfg.Panes[0].Direction != "horizontal" {
		t.Errorf("expected nested horizontal, got %s", cfg.Panes[0].Direction)
	}
	if len(cfg.Panes[0].Panes) != 2 {
		t.Fatalf("expected 2 nested panes, got %d", len(cfg.Panes[0].Panes))
	}
}

func TestParseLayoutConfig_Prefer(t *testing.T) {
	yaml := `
direction: horizontal
panes:
  - prefer:
      - yazi
      - nnn
      - lf
    title: Explorer
`
	cfg, err := parseLayoutConfigBytes([]byte(yaml))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(cfg.Panes[0].Prefer) != 3 {
		t.Errorf("expected 3 prefer entries, got %d", len(cfg.Panes[0].Prefer))
	}
}

func TestParseLayoutConfig_WithBorder(t *testing.T) {
	yaml := `
direction: horizontal
panes:
  - command: opencode
    title: OpenCode
border:
  status: top
  lines: heavy
  style: "fg=colour245"
`
	cfg, err := parseLayoutConfigBytes([]byte(yaml))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if cfg.Border == nil {
		t.Fatal("expected border config")
	}
	if cfg.Border.Status != "top" {
		t.Errorf("expected top, got %s", cfg.Border.Status)
	}
}

func TestParseLayoutConfig_Validation_NoPanes(t *testing.T) {
	yaml := `
direction: horizontal
panes: []
`
	_, err := parseLayoutConfigBytes([]byte(yaml))
	if err == nil {
		t.Fatal("expected error for empty panes")
	}
}

func TestParseLayoutConfig_Validation_BadDirection(t *testing.T) {
	yaml := `
direction: diagonal
panes:
  - command: opencode
`
	_, err := parseLayoutConfigBytes([]byte(yaml))
	if err == nil {
		t.Fatal("expected error for bad direction")
	}
}

func TestParseLayoutConfig_Validation_CommandAndPrefer(t *testing.T) {
	yaml := `
direction: horizontal
panes:
  - command: opencode
    prefer:
      - yazi
`
	_, err := parseLayoutConfigBytes([]byte(yaml))
	if err == nil {
		t.Fatal("expected error for both command and prefer")
	}
}

func TestParseLayoutConfig_Validation_BadSize(t *testing.T) {
	yaml := `
direction: horizontal
panes:
  - command: opencode
    size: "150%"
`
	_, err := parseLayoutConfigBytes([]byte(yaml))
	if err == nil {
		t.Fatal("expected error for size > 99%")
	}
}

func TestParseLayoutConfig_Validation_SplitWithCommand(t *testing.T) {
	yaml := `
direction: horizontal
panes:
  - command: opencode
    direction: vertical
    panes:
      - command: "$SHELL"
`
	_, err := parseLayoutConfigBytes([]byte(yaml))
	if err == nil {
		t.Fatal("expected error for split with command")
	}
}

func TestParseLayoutConfig_ShorthandDirection(t *testing.T) {
	yaml := `
direction: h
panes:
  - command: opencode
`
	cfg, err := parseLayoutConfigBytes([]byte(yaml))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if cfg.Direction != "horizontal" {
		t.Errorf("expected horizontal from 'h', got %s", cfg.Direction)
	}
}

func TestParseLayoutConfig_EnvVars(t *testing.T) {
	yaml := `
direction: horizontal
panes:
  - command: "nvim ."
    env:
      NVIM_APPNAME: nvim-custom
`
	cfg, err := parseLayoutConfigBytes([]byte(yaml))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if cfg.Panes[0].Env["NVIM_APPNAME"] != "nvim-custom" {
		t.Errorf("expected nvim-custom, got %s", cfg.Panes[0].Env["NVIM_APPNAME"])
	}
}

func TestParseLayoutConfig_BarePaneDefaultsToShell(t *testing.T) {
	yaml := `
direction: horizontal
panes:
  - title: Shell
`
	cfg, err := parseLayoutConfigBytes([]byte(yaml))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !cfg.Panes[0].IsLeaf() {
		t.Error("bare pane should be a leaf")
	}
	if cfg.Panes[0].Command != "" {
		t.Errorf("bare pane should have empty command, got %s", cfg.Panes[0].Command)
	}
}
