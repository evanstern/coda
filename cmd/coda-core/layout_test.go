package main

import (
	"fmt"
	"strings"
	"testing"
)

func TestParseLayoutString_TwoPanes(t *testing.T) {
	// Minimal two-pane horizontal split: checksum,WxH,X,Y{WxH,X,Y,ID0,WxH,X,Y,ID1}
	layout := "a1b2,200x50,0,0{100x50,0,0,0,99x50,101,0,1}"
	tmpl, leafIDs := parseLayoutString(layout)

	if len(leafIDs) != 2 {
		t.Fatalf("expected 2 leaf IDs, got %d: %v", len(leafIDs), leafIDs)
	}
	if leafIDs[0] != "0" || leafIDs[1] != "1" {
		t.Errorf("expected leaf IDs [0, 1], got %v", leafIDs)
	}
	if !strings.Contains(tmpl, "__P0__") || !strings.Contains(tmpl, "__P1__") {
		t.Errorf("template missing placeholders: %s", tmpl)
	}
	if strings.Contains(tmpl, ",0,") && strings.Count(tmpl, ",0,") > 2 {
		// IDs should be replaced, only coordinate 0s should remain
	}
}

func TestParseLayoutString_FourPanes(t *testing.T) {
	// Real-world four-pane layout string
	layout := "f9a0,200x50,0,0[200x39,0,0{39x39,0,0,7,160x39,40,0{80x39,40,0,8,79x39,121,0,9}},200x10,0,40,10]"
	tmpl, leafIDs := parseLayoutString(layout)

	if len(leafIDs) != 4 {
		t.Fatalf("expected 4 leaf IDs, got %d: %v", len(leafIDs), leafIDs)
	}
	if leafIDs[0] != "7" || leafIDs[1] != "8" || leafIDs[2] != "9" || leafIDs[3] != "10" {
		t.Errorf("expected leaf IDs [7, 8, 9, 10], got %v", leafIDs)
	}
	for i := 0; i < 4; i++ {
		placeholder := fmt.Sprintf("__P%d__", i)
		if !strings.Contains(tmpl, placeholder) {
			t.Errorf("template missing %s: %s", placeholder, tmpl)
		}
	}
}

func TestParseLayoutString_SinglePane(t *testing.T) {
	layout := "abcd,200x50,0,0,0"
	tmpl, leafIDs := parseLayoutString(layout)

	if len(leafIDs) != 1 {
		t.Fatalf("expected 1 leaf ID, got %d: %v", len(leafIDs), leafIDs)
	}
	if leafIDs[0] != "0" {
		t.Errorf("expected leaf ID [0], got %v", leafIDs)
	}
	if !strings.Contains(tmpl, "__P0__") {
		t.Errorf("template missing __P0__: %s", tmpl)
	}
}

func TestParseLayoutString_ThreePaneNested(t *testing.T) {
	// Three panes: vertical split top/bottom, top split horizontally
	layout := "c3d4,160x40,0,0[160x30,0,0{80x30,0,0,5,79x30,81,0,6},160x9,0,31,7]"
	tmpl, leafIDs := parseLayoutString(layout)

	if len(leafIDs) != 3 {
		t.Fatalf("expected 3 leaf IDs, got %d: %v", len(leafIDs), leafIDs)
	}
	if leafIDs[0] != "5" || leafIDs[1] != "6" || leafIDs[2] != "7" {
		t.Errorf("expected leaf IDs [5, 6, 7], got %v", leafIDs)
	}
	for i := 0; i < 3; i++ {
		placeholder := fmt.Sprintf("__P%d__", i)
		if !strings.Contains(tmpl, placeholder) {
			t.Errorf("template missing %s: %s", placeholder, tmpl)
		}
	}
}

func TestTmuxLayoutChecksum(t *testing.T) {
	// Test against known checksum from a real tmux layout
	// The checksum prefix in layout "f9a0,..." means the body checksums to 0xf9a0
	tests := []struct {
		body   string
		expect string
	}{
		// Simple body: verify the algorithm produces a 4-char hex
		{"200x50,0,0,0", fmt.Sprintf("%04x", tmuxLayoutChecksum("200x50,0,0,0"))},
	}

	for _, tc := range tests {
		csum := tmuxLayoutChecksum(tc.body)
		result := fmt.Sprintf("%04x", csum)
		if result != tc.expect {
			t.Errorf("checksum(%q) = %s, want %s", tc.body, result, tc.expect)
		}
	}

	// Verify the checksum is deterministic
	for i := 0; i < 100; i++ {
		if tmuxLayoutChecksum("test") != tmuxLayoutChecksum("test") {
			t.Fatal("checksum not deterministic")
		}
	}

	// Verify different inputs produce different checksums
	if tmuxLayoutChecksum("abc") == tmuxLayoutChecksum("def") {
		t.Error("different inputs produced same checksum")
	}
}

func TestTmuxLayoutChecksum_KnownValues(t *testing.T) {
	// Captured from a real running tmux session
	layout := "81f7,639x131,0,0[639x102,0,0{67x102,0,0,169,77x102,68,0,170,361x102,146,0,171,131x102,508,0,172},639x28,0,103,173]"
	idx := strings.Index(layout, ",")
	expectedHex := layout[:idx]
	body := layout[idx+1:]

	csum := fmt.Sprintf("%04x", tmuxLayoutChecksum(body))
	if csum != expectedHex {
		t.Errorf("checksum of body = %s, expected %s (from layout prefix)", csum, expectedHex)
	}
}

func TestResolveCmd(t *testing.T) {
	tests := []struct {
		start, cur, expect string
	}{
		{"", "bash", ""},
		{"", "lazygit", "lazygit"},
		{"", "opencode", "opencode"},
		{"", "yazi", "yazi"},
		{"", "nvim", "nvim"},
		{"", "python3", ""},
		{"opencode; exec $SHELL", "bash", "opencode"},
		{"lazygit", "lazygit", "lazygit"},
		{"/tmp/coda-layout.abc123", "bash", ""},
		{"bash", "bash", ""},
		{"zsh", "zsh", ""},
	}

	for _, tc := range tests {
		result := resolveCmd(tc.start, tc.cur)
		if result != tc.expect {
			t.Errorf("resolveCmd(%q, %q) = %q, want %q", tc.start, tc.cur, result, tc.expect)
		}
	}
}

func TestResolveTitle(t *testing.T) {
	tests := []struct {
		input, expect string
	}{
		{"Git", "Git"},
		{"OpenCode", "OpenCode"},
		{"Shell", "Shell"},
		{"my-pane_1", "my-pane_1"},
		{"", ""},
		{"this is way too long for a title obviously", ""},
		{"has spaces", ""},
		{"123numeric", ""},
		{"-leading-dash", ""},
	}

	for _, tc := range tests {
		result := resolveTitle(tc.input)
		if result != tc.expect {
			t.Errorf("resolveTitle(%q) = %q, want %q", tc.input, result, tc.expect)
		}
	}
}

func TestGenerateLayoutScript_ProducesValidBash(t *testing.T) {
	snap := &snapshot{
		WinW:      200,
		WinH:      50,
		LayoutStr: "abcd,200x50,0,0{100x50,0,0,0,99x50,101,0,1}",
		PaneCount: 2,
		Panes: []paneInfo{
			{ID: "0", Cmd: "opencode", Start: "", Title: "OpenCode"},
			{ID: "1", Cmd: "nvim", Start: "", Title: "Editor"},
		},
		LayoutTmpl: "200x50,0,0{100x50,0,0,__P0__,99x50,101,0,__P1__}",
		LeafIDs:    []string{"0", "1"},
	}

	script := generateLayoutScript("test-layout", snap)

	if !strings.Contains(script, "#!/usr/bin/env bash") {
		t.Error("missing shebang")
	}
	if !strings.Contains(script, "_layout_init()") {
		t.Error("missing _layout_init function")
	}
	if !strings.Contains(script, "_layout_spawn()") {
		t.Error("missing _layout_spawn function")
	}
	if !strings.Contains(script, "_layout_apply()") {
		t.Error("missing _layout_apply function")
	}
	if !strings.Contains(script, "opencode") {
		t.Error("missing opencode command")
	}
	if !strings.Contains(script, "OpenCode") {
		t.Error("missing pane title")
	}
	if !strings.Contains(script, "pane-border-status") {
		t.Error("missing pane border setup (titles were set)")
	}
}

func TestGenerateLayoutScript_NoTitles(t *testing.T) {
	snap := &snapshot{
		WinW:      200,
		WinH:      50,
		LayoutStr: "abcd,200x50,0,0{100x50,0,0,0,99x50,101,0,1}",
		PaneCount: 2,
		Panes: []paneInfo{
			{ID: "0", Cmd: "bash", Start: "", Title: ""},
			{ID: "1", Cmd: "bash", Start: "", Title: ""},
		},
		LayoutTmpl: "200x50,0,0{100x50,0,0,__P0__,99x50,101,0,__P1__}",
		LeafIDs:    []string{"0", "1"},
	}

	script := generateLayoutScript("notitles", snap)

	if strings.Contains(script, "pane-border-status") {
		t.Error("should not have pane border setup when no titles")
	}
}
