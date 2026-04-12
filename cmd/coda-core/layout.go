package main

import (
	"flag"
	"fmt"
	"os"
	"os/exec"
	"regexp"
	"strconv"
	"strings"
)

func runLayout(args []string) error {
	if len(args) == 0 {
		return fmt.Errorf("usage: coda-core layout snapshot --name <name> --output <file>")
	}
	switch args[0] {
	case "snapshot":
		return runLayoutSnapshot(args[1:])
	default:
		return fmt.Errorf("unknown layout subcommand: %s", args[0])
	}
}

func runLayoutSnapshot(args []string) error {
	fs := flag.NewFlagSet("layout-snapshot", flag.ExitOnError)
	name := fs.String("name", "", "Layout name")
	output := fs.String("output", "", "Output file path")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *name == "" || *output == "" {
		return fmt.Errorf("both --name and --output are required")
	}

	snap, err := captureSnapshot()
	if err != nil {
		return err
	}

	script := generateLayoutScript(*name, snap)
	if err := os.WriteFile(*output, []byte(script), 0755); err != nil {
		return fmt.Errorf("writing layout file: %w", err)
	}

	fmt.Printf("Snapshot saved: %s\n", *output)
	fmt.Printf("  Captured %d panes from %dx%d window\n", snap.PaneCount, snap.WinW, snap.WinH)
	fmt.Printf("  Apply with: coda layout %s\n", *name)
	return nil
}

type paneInfo struct {
	ID    string
	Cmd   string
	Start string
	Title string
}

type snapshot struct {
	WinW       int
	WinH       int
	LayoutStr  string
	PaneCount  int
	Panes      []paneInfo
	LayoutTmpl string
	LeafIDs    []string
}

func tmuxCmd(args ...string) (string, error) {
	cmd := exec.Command("tmux", args...)
	out, err := cmd.Output()
	if err != nil {
		return "", fmt.Errorf("tmux %s: %w", strings.Join(args, " "), err)
	}
	return strings.TrimRight(string(out), "\n"), nil
}

func captureSnapshot() (*snapshot, error) {
	if os.Getenv("TMUX") == "" {
		return nil, fmt.Errorf("--snapshot requires being inside a tmux session")
	}

	winW, err := tmuxCmd("display-message", "-p", "#{window_width}")
	if err != nil {
		return nil, err
	}
	winH, err := tmuxCmd("display-message", "-p", "#{window_height}")
	if err != nil {
		return nil, err
	}
	layoutStr, err := tmuxCmd("display-message", "-p", "#{window_layout}")
	if err != nil {
		return nil, err
	}

	paneData, err := tmuxCmd("list-panes", "-F", "#{pane_id}\t#{pane_current_command}\t#{?pane_start_command,#{pane_start_command},-}\t#{pane_title}")
	if err != nil {
		return nil, err
	}

	lines := strings.Split(paneData, "\n")
	if len(lines) < 2 {
		return nil, fmt.Errorf("only one pane -- nothing to snapshot")
	}

	var panes []paneInfo
	for _, line := range lines {
		if line == "" {
			continue
		}
		parts := strings.SplitN(line, "\t", 4)
		if len(parts) < 4 {
			continue
		}
		p := paneInfo{
			ID:    strings.TrimPrefix(parts[0], "%"),
			Cmd:   parts[1],
			Start: parts[2],
			Title: parts[3],
		}
		if p.Start == "-" {
			p.Start = ""
		}
		panes = append(panes, p)
	}

	w, _ := strconv.Atoi(winW)
	h, _ := strconv.Atoi(winH)

	tmpl, leafIDs := parseLayoutString(layoutStr)

	if len(leafIDs) != len(panes) {
		return nil, fmt.Errorf("layout string has %d panes but window has %d", len(leafIDs), len(panes))
	}

	return &snapshot{
		WinW:       w,
		WinH:       h,
		LayoutStr:  layoutStr,
		PaneCount:  len(panes),
		Panes:      panes,
		LayoutTmpl: tmpl,
		LeafIDs:    leafIDs,
	}, nil
}

// parseLayoutString takes a tmux layout string like "abcd,80x24,0,0{40x24,0,0,0,39x24,41,0,1}"
// and returns a templatized version with __P0__, __P1__, etc. replacing leaf pane IDs,
// plus the extracted leaf IDs in order.
func parseLayoutString(layout string) (string, []string) {
	// Strip the checksum prefix (everything up to and including the first comma)
	idx := strings.Index(layout, ",")
	if idx < 0 {
		return layout, nil
	}
	body := layout[idx+1:]

	// The layout body grammar: WxH,X,Y followed by either ,ID (leaf) or {children} or [children]
	// We need to find all leaf pane IDs: they appear as ,<digits> after WxH,X,Y
	var leafIDs []string
	var result strings.Builder
	n := 0

	// Regex: match WxH,X,Y,ID pattern where ID is the leaf
	// Walk character by character to handle the nested grammar
	i := 0
	for i < len(body) {
		// Try to match a dimension spec: digits 'x' digits ',' digits ',' digits
		if m := matchDimSpec(body[i:]); m > 0 {
			result.WriteString(body[i : i+m])
			i += m
			// After dimension spec, check for ,ID (leaf pane)
			if i < len(body) && body[i] == ',' {
				result.WriteByte(',')
				i++
				// Read the ID digits
				start := i
				for i < len(body) && body[i] >= '0' && body[i] <= '9' {
					i++
				}
				if i > start {
					leafIDs = append(leafIDs, body[start:i])
					result.WriteString(fmt.Sprintf("__P%d__", n))
					n++
				}
			}
		} else {
			result.WriteByte(body[i])
			i++
		}
	}

	return result.String(), leafIDs
}

var dimSpecRe = regexp.MustCompile(`^\d+x\d+,\d+,\d+`)

func matchDimSpec(s string) int {
	loc := dimSpecRe.FindStringIndex(s)
	if loc == nil || loc[0] != 0 {
		return 0
	}
	return loc[1]
}

func resolveCmd(start, cur string) string {
	if start != "" {
		s := strings.Trim(start, "\"")
		s = strings.ReplaceAll(s, "\\$", "$")
		s = strings.TrimSuffix(s, "; exec $SHELL")
		s = strings.TrimSuffix(s, `; exec "$SHELL"`)
		if strings.HasPrefix(s, "/tmp/") {
			s = ""
		}
		switch s {
		case "bash", "zsh", "sh", "fish":
			s = ""
		}
		if s != "" {
			return s
		}
	}

	switch cur {
	case "lazygit", "gitui", "tig":
		return cur
	case "opencode":
		return "opencode"
	case "yazi", "nnn", "lf", "ranger":
		return cur
	case "nvim", "vim", "vi":
		return cur
	}
	return ""
}

func resolveTitle(title string) string {
	if len(title) > 20 {
		return ""
	}
	matched, _ := regexp.MatchString(`^[A-Za-z][A-Za-z0-9_-]*$`, title)
	if matched {
		return title
	}
	return ""
}

// tmuxLayoutChecksum computes the 16-bit LFSR checksum tmux uses for layout strings.
func tmuxLayoutChecksum(s string) uint16 {
	var csum uint16
	for i := 0; i < len(s); i++ {
		csum = (csum >> 1) + (csum&1)*32768
		csum += uint16(s[i])
	}
	return csum
}

func generateLayoutScript(name string, snap *snapshot) string {
	var b strings.Builder

	cmds := make([]string, snap.PaneCount)
	titles := make([]string, snap.PaneCount)
	hasTitles := false

	for i := 0; i < snap.PaneCount; i++ {
		nid := snap.LeafIDs[i]
		var pi paneInfo
		for _, p := range snap.Panes {
			if p.ID == nid {
				pi = p
				break
			}
		}
		cmds[i] = resolveCmd(pi.Start, pi.Cmd)
		titles[i] = resolveTitle(pi.Title)
		if titles[i] != "" {
			hasTitles = true
		}
	}

	b.WriteString("#!/usr/bin/env bash\n")
	b.WriteString(fmt.Sprintf("#\n# %s.sh -- tmux layout (captured from live session)\n#\n", name))
	b.WriteString("# $1 = session name    $2 = working directory    $3 = NVIM_APPNAME\n#\n")
	b.WriteString(fmt.Sprintf("# Snapshot: %d panes from %dx%d window\n", snap.PaneCount, snap.WinW, snap.WinH))
	for i := 0; i < snap.PaneCount; i++ {
		desc := cmds[i]
		if desc == "" {
			desc = "shell"
		}
		if titles[i] != "" {
			b.WriteString(fmt.Sprintf("#   pane %d: %s [%s]\n", i, desc, titles[i]))
		} else {
			b.WriteString(fmt.Sprintf("#   pane %d: %s\n", i, desc))
		}
	}
	b.WriteString("\n")

	writeLayoutInit(&b, snap, cmds, titles, hasTitles)
	b.WriteString("\n")
	writeLayoutSpawn(&b, snap, cmds, titles, hasTitles)
	b.WriteString("\n")
	b.WriteString("_layout_apply() { _layout_init \"$@\"; }\n")

	return b.String()
}

func writeLayoutInit(b *strings.Builder, snap *snapshot, cmds, titles []string, hasTitles bool) {
	b.WriteString("_layout_init() {\n")
	b.WriteString("    local session=\"$1\" dir=\"$2\" nvim_appname=\"${3:-nvim}\"\n")
	b.WriteString(fmt.Sprintf("    local cols=\"${COLUMNS:-%d}\" rows=\"${LINES:-%d}\"\n", snap.WinW, snap.WinH))
	b.WriteString("\n")

	if cmds[0] != "" {
		b.WriteString(fmt.Sprintf("    tmux new-session -d -s \"$session\" -x \"$cols\" -y \"$rows\" -c \"$dir\" \\\n"))
		b.WriteString(fmt.Sprintf("        \"%s; exec \\$SHELL\"\n", cmds[0]))
	} else {
		b.WriteString("    tmux new-session -d -s \"$session\" -x \"$cols\" -y \"$rows\" -c \"$dir\"\n")
	}
	if titles[0] != "" {
		b.WriteString(fmt.Sprintf("    tmux select-pane -t \"$session\" -T \"%s\"\n", titles[0]))
	}

	if snap.PaneCount > 1 {
		b.WriteString("\n")
		b.WriteString("    local pids=()\n")
		b.WriteString("    pids+=(\"$(tmux display-message -t \"$session\" -p '#{pane_id}')\")\n")

		for i := 1; i < snap.PaneCount; i++ {
			if cmds[i] != "" {
				b.WriteString(fmt.Sprintf("    pids+=(\"$(tmux split-window -t \"$session\" -c \"$dir\" -P -F '#{pane_id}' \\\n"))
				b.WriteString(fmt.Sprintf("        \"%s; exec \\$SHELL\")\")\n", cmds[i]))
			} else {
				b.WriteString("    pids+=(\"$(tmux split-window -t \"$session\" -c \"$dir\" -P -F '#{pane_id}')\")\n")
			}
			if titles[i] != "" {
				b.WriteString(fmt.Sprintf("    tmux select-pane -t \"${pids[-1]}\" -T \"%s\"\n", titles[i]))
			}
		}

		b.WriteString("\n")
		b.WriteString(fmt.Sprintf("    local body='%s'\n", snap.LayoutTmpl))
		for i := 0; i < snap.PaneCount; i++ {
			b.WriteString(fmt.Sprintf("    body=\"${body/__P%d__/${pids[%d]#%%}}\"\n", i, i))
		}
		b.WriteString("    local csum=$(printf '%%s' \"$body\" | awk 'BEGIN{for(i=0;i<256;i++)_o[sprintf(\"%c\",i)]=i}{c=0;for(i=1;i<=length($0);i++){c=int(c/2)+(c%2)*32768;c=(c+_o[substr($0,i,1)])%65536}printf\"%04x\",c}')\n")
		b.WriteString("    tmux select-layout -t \"$session\" \"${csum},${body}\"\n")
	}

	if hasTitles {
		b.WriteString("\n")
		b.WriteString("    tmux set-option -t \"$session\" pane-border-status top\n")
		b.WriteString("    tmux set-option -t \"$session\" pane-border-lines heavy\n")
		b.WriteString("    tmux set-option -t \"$session\" pane-border-style 'fg=colour245'\n")
		b.WriteString("    tmux set-option -t \"$session\" pane-active-border-style 'fg=green,bold'\n")
		b.WriteString("    tmux set-option -t \"$session\" pane-border-format ' #{?pane_active,\u25b8 ,  }#{pane_title} '\n")
	}
	b.WriteString("    tmux select-pane -t \"$session\" -t 0\n")
	b.WriteString("}\n")
}

func writeLayoutSpawn(b *strings.Builder, snap *snapshot, cmds, titles []string, hasTitles bool) {
	b.WriteString("_layout_spawn() {\n")
	b.WriteString("    local session=\"$1\" dir=\"$2\" nvim_appname=\"${3:-nvim}\"\n")
	b.WriteString("\n")
	b.WriteString("    local script\n")
	b.WriteString("    script=$(mktemp \"${TMPDIR:-/tmp}/coda-layout.XXXXXX\")\n")
	b.WriteString("    cat > \"$script\" <<'SETUP'\n")
	b.WriteString("#!/usr/bin/env bash\n")
	b.WriteString("rm -f \"$0\"\n")
	b.WriteString("dir=\"$1\"\n")
	b.WriteString("\n")

	if titles[0] != "" {
		b.WriteString(fmt.Sprintf("tmux select-pane -T \"%s\"\n", titles[0]))
	}

	b.WriteString("pids=()\n")
	b.WriteString("pids+=(\"$(tmux display-message -p '#{pane_id}')\")\n")

	for i := 1; i < snap.PaneCount; i++ {
		if cmds[i] != "" {
			b.WriteString(fmt.Sprintf("pids+=(\"$(tmux split-window -c \"$dir\" -P -F '#{pane_id}' \\\n"))
			b.WriteString(fmt.Sprintf("    \"%s; exec $SHELL\")\")\n", cmds[i]))
		} else {
			b.WriteString("pids+=(\"$(tmux split-window -c \"$dir\" -P -F '#{pane_id}')\")\n")
		}
		if titles[i] != "" {
			b.WriteString(fmt.Sprintf("tmux select-pane -t \"${pids[-1]}\" -T \"%s\"\n", titles[i]))
		}
	}

	b.WriteString("\n")
	b.WriteString(fmt.Sprintf("body='%s'\n", snap.LayoutTmpl))
	for i := 0; i < snap.PaneCount; i++ {
		b.WriteString(fmt.Sprintf("body=\"${body/__P%d__/${pids[%d]#%%}}\"\n", i, i))
	}
	b.WriteString("csum=$(printf '%%s' \"$body\" | awk 'BEGIN{for(i=0;i<256;i++)_o[sprintf(\"%c\",i)]=i}{c=0;for(i=1;i<=length($0);i++){c=int(c/2)+(c%2)*32768;c=(c+_o[substr($0,i,1)])%65536}printf\"%04x\",c}')\n")
	b.WriteString("tmux select-layout \"${csum},${body}\"\n")

	if hasTitles {
		b.WriteString("\n")
		b.WriteString("tmux set-option pane-border-status top\n")
		b.WriteString("tmux set-option pane-border-lines heavy\n")
		b.WriteString("tmux set-option pane-border-style 'fg=colour245'\n")
		b.WriteString("tmux set-option pane-active-border-style 'fg=green,bold'\n")
		b.WriteString("tmux set-option pane-border-format ' #{?pane_active,\u25b8 ,  }#{pane_title} '\n")
	}

	b.WriteString("\n")
	b.WriteString("tmux select-pane -t \"${pids[0]}\"\n")
	if cmds[0] != "" {
		b.WriteString(fmt.Sprintf("%s; exec \"$SHELL\"\n", cmds[0]))
	}

	b.WriteString("SETUP\n")
	b.WriteString("    chmod +x \"$script\"\n")
	b.WriteString("    tmux new-window -t \"$session\" -c \"$dir\" \"$script\" \"$dir\"\n")
	b.WriteString("}\n")
}
