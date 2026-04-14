package main

import (
	"flag"
	"fmt"
	"io"
	"os"
	"strings"
)

func runLayoutRender(args []string) error {
	fs := flag.NewFlagSet("layout-render", flag.ExitOnError)
	configPath := fs.String("config", "", "Path to YAML layout config file")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *configPath == "" {
		return fmt.Errorf("--config is required")
	}

	cfg, err := parseLayoutConfig(*configPath)
	if err != nil {
		return err
	}

	return renderLayoutBash(os.Stdout, cfg)
}

type flatPane struct {
	command string
	prefer  []string
	title   string
	env     map[string]string
}

type renderCtx struct {
	cfg         *LayoutConfig
	flat        []flatPane
	hasTitles   bool
	preferFuncs []preferFunc
	preferIndex map[string]int
}

type preferFunc struct {
	cmds []string
}

func newRenderCtx(cfg *LayoutConfig) *renderCtx {
	flat := flattenPanes(cfg.Panes)
	rc := &renderCtx{
		cfg:         cfg,
		flat:        flat,
		preferIndex: make(map[string]int),
	}
	for _, p := range flat {
		if p.title != "" {
			rc.hasTitles = true
		}
		if len(p.prefer) > 0 {
			key := strings.Join(p.prefer, "|")
			if _, ok := rc.preferIndex[key]; !ok {
				rc.preferIndex[key] = len(rc.preferFuncs)
				rc.preferFuncs = append(rc.preferFuncs, preferFunc{cmds: p.prefer})
			}
		}
	}
	return rc
}

func renderLayoutBash(w io.Writer, cfg *LayoutConfig) error {
	rc := newRenderCtx(cfg)

	var b strings.Builder
	rc.writeInitFunc(&b)
	b.WriteString("\n")
	rc.writeSpawnFunc(&b)

	_, err := fmt.Fprint(w, b.String())
	return err
}

func flattenPanes(panes []PaneConfig) []flatPane {
	var result []flatPane
	for _, p := range panes {
		if p.IsLeaf() {
			result = append(result, flatPane{
				command: p.Command,
				prefer:  p.Prefer,
				title:   p.Title,
				env:     p.Env,
			})
		} else {
			result = append(result, flattenPanes(p.Panes)...)
		}
	}
	return result
}

func (rc *renderCtx) paneCmd(p flatPane) string {
	if p.command != "" {
		cmd := p.command
		if len(p.env) > 0 {
			var parts []string
			for k, v := range p.env {
				parts = append(parts, fmt.Sprintf("%s=%s", k, v))
			}
			cmd = strings.Join(parts, " ") + " " + cmd
		}
		return cmd
	}
	if len(p.prefer) > 0 {
		key := strings.Join(p.prefer, "|")
		return fmt.Sprintf("$(_prefer_%d)", rc.preferIndex[key])
	}
	return ""
}

func shellFirstWord(cmd string) string {
	parts := strings.Fields(cmd)
	if len(parts) > 0 {
		return parts[0]
	}
	return cmd
}

func (rc *renderCtx) writePreferBlock(b *strings.Builder, indent string) {
	for i, pf := range rc.preferFuncs {
		b.WriteString(fmt.Sprintf("%s_prefer_%d() {\n", indent, i))
		for _, cmd := range pf.cmds {
			if cmd == "$SHELL" || cmd == "\"$SHELL\"" {
				b.WriteString(fmt.Sprintf("%s    printf '%%s' \"%s\"\n", indent, cmd))
			} else {
				b.WriteString(fmt.Sprintf("%s    command -v %s &>/dev/null && { printf '%%s' '%s'; return; }\n", indent, shellFirstWord(cmd), cmd))
			}
		}
		b.WriteString(fmt.Sprintf("%s    printf '%%s' \"$SHELL\"\n", indent))
		b.WriteString(fmt.Sprintf("%s}\n", indent))
	}
	if len(rc.preferFuncs) > 0 {
		b.WriteString("\n")
	}
}

func (rc *renderCtx) writeInitFunc(b *strings.Builder) {
	b.WriteString("_layout_init() {\n")
	b.WriteString("    local session=\"$1\" dir=\"$2\" nvim_appname=\"${3:-nvim}\"\n")
	b.WriteString("    local cols=\"${COLUMNS:-200}\" rows=\"${LINES:-50}\"\n")
	b.WriteString("\n")

	rc.writePreferBlock(b, "    ")

	firstCmd := rc.paneCmd(rc.flat[0])
	if firstCmd != "" {
		b.WriteString(fmt.Sprintf("    tmux new-session -d -s \"$session\" -x \"$cols\" -y \"$rows\" -c \"$dir\" \\" + "\n"))
		b.WriteString(fmt.Sprintf("        \"%s; exec \\$SHELL\"\n", firstCmd))
	} else {
		b.WriteString("    tmux new-session -d -s \"$session\" -x \"$cols\" -y \"$rows\" -c \"$dir\"\n")
	}
	if rc.flat[0].title != "" {
		b.WriteString(fmt.Sprintf("    tmux select-pane -t \"$session\" -T \"%s\"\n", rc.flat[0].title))
	}
	writeEnvVars(b, rc.flat[0].env, "    ", "\"$session\"")

	if len(rc.flat) > 1 {
		b.WriteString("\n")
		leafIdx := 0
		rc.emitSplits(b, rc.cfg.Direction, rc.cfg.Panes, "    ", true, &leafIdx, true)
	}

	if rc.hasTitles {
		b.WriteString("\n")
		writeBorderSetup(b, rc.cfg.Border, "    ", "\"$session\"")
	}

	b.WriteString("    tmux select-pane -t \"$session\" -t 0\n")
	b.WriteString("}\n")
}

func (rc *renderCtx) writeSpawnFunc(b *strings.Builder) {
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

	rc.writePreferBlock(b, "")

	if rc.flat[0].title != "" {
		b.WriteString(fmt.Sprintf("tmux select-pane -T \"%s\"\n", rc.flat[0].title))
	}
	writeEnvVars(b, rc.flat[0].env, "", "")

	if len(rc.flat) > 1 {
		leafIdx := 0
		rc.emitSplits(b, rc.cfg.Direction, rc.cfg.Panes, "", false, &leafIdx, true)
	}

	if rc.hasTitles {
		b.WriteString("\n")
		writeBorderSetup(b, rc.cfg.Border, "", "")
	}

	b.WriteString("\n")
	b.WriteString("tmux select-pane -t 0\n")
	firstCmd := rc.paneCmd(rc.flat[0])
	if firstCmd != "" {
		b.WriteString(fmt.Sprintf("%s; exec \"$SHELL\"\n", firstCmd))
	}

	b.WriteString("SETUP\n")
	b.WriteString("    chmod +x \"$script\"\n")
	b.WriteString("    tmux new-window -t \"$session\" -c \"$dir\" \"$script\" \"$dir\"\n")
	b.WriteString("}\n")
}

func (rc *renderCtx) emitSplits(b *strings.Builder, direction string, panes []PaneConfig, indent string, isInit bool, leafIdx *int, isRoot bool) {
	var splitFlag string
	if direction == "vertical" {
		splitFlag = "-v"
	} else {
		splitFlag = "-h"
	}

	for i, p := range panes {
		if i == 0 && isRoot {
			if p.IsLeaf() {
				*leafIdx++
			} else {
				rc.emitSplits(b, p.Direction, p.Panes, indent, isInit, leafIdx, true)
			}
			continue
		}

		var targetArg string
		if isInit {
			targetArg = " -t \"$session\""
		}

		sizeArg := sizeFlag(p.Size)

		if p.IsLeaf() {
			fp := rc.flat[*leafIdx]
			cmd := rc.paneCmd(fp)
			if cmd != "" {
				b.WriteString(fmt.Sprintf("%stmux split-window %s%s%s -c \"$dir\" \"%s; exec \\$SHELL\"\n",
					indent, splitFlag, targetArg, sizeArg, cmd))
			} else {
				b.WriteString(fmt.Sprintf("%stmux split-window %s%s%s -c \"$dir\"\n",
					indent, splitFlag, targetArg, sizeArg))
			}
			if fp.title != "" {
				if isInit {
					b.WriteString(fmt.Sprintf("%stmux select-pane -t \"$session\" -T \"%s\"\n", indent, fp.title))
				} else {
					b.WriteString(fmt.Sprintf("%stmux select-pane -T \"%s\"\n", indent, fp.title))
				}
			}
			*leafIdx++
		} else {
			firstLeafIdx := rc.firstLeafIndex(p.Panes)
			if firstLeafIdx >= 0 {
				fp := rc.flat[*leafIdx+firstLeafIdx]
				cmd := rc.paneCmd(fp)
				if cmd != "" {
					b.WriteString(fmt.Sprintf("%stmux split-window %s%s%s -c \"$dir\" \"%s; exec \\$SHELL\"\n",
						indent, splitFlag, targetArg, sizeArg, cmd))
				} else {
					b.WriteString(fmt.Sprintf("%stmux split-window %s%s%s -c \"$dir\"\n",
						indent, splitFlag, targetArg, sizeArg))
				}
				if fp.title != "" {
					if isInit {
						b.WriteString(fmt.Sprintf("%stmux select-pane -t \"$session\" -T \"%s\"\n", indent, fp.title))
					} else {
						b.WriteString(fmt.Sprintf("%stmux select-pane -T \"%s\"\n", indent, fp.title))
					}
				}
			}
			rc.emitSplits(b, p.Direction, p.Panes, indent, isInit, leafIdx, true)
		}
	}
}

func (rc *renderCtx) firstLeafIndex(panes []PaneConfig) int {
	for _, p := range panes {
		if p.IsLeaf() {
			return 0
		}
		return rc.firstLeafIndex(p.Panes)
	}
	return -1
}

func sizeFlag(size string) string {
	if size == "" {
		return ""
	}
	if strings.HasSuffix(size, "%") {
		return fmt.Sprintf(" -p %s", strings.TrimSuffix(size, "%"))
	}
	return fmt.Sprintf(" -l %s", size)
}

func writeEnvVars(b *strings.Builder, env map[string]string, indent, target string) {
	for k, v := range env {
		if target != "" {
			b.WriteString(fmt.Sprintf("%stmux set-environment -t %s %s \"%s\"\n", indent, target, k, v))
		} else {
			b.WriteString(fmt.Sprintf("%stmux set-environment %s \"%s\"\n", indent, k, v))
		}
	}
}

func writeBorderSetup(b *strings.Builder, border *BorderConfig, indent, target string) {
	status := "top"
	lines := "heavy"
	style := "fg=colour245"
	activeStyle := "fg=green,bold"
	borderFormat := " #{?pane_active,\u25b8 ,  }#{pane_title} "

	if border != nil {
		if border.Status != "" {
			status = border.Status
		}
		if border.Lines != "" {
			lines = border.Lines
		}
		if border.Style != "" {
			style = border.Style
		}
		if border.ActiveStyle != "" {
			activeStyle = border.ActiveStyle
		}
		if border.Format != "" {
			borderFormat = border.Format
		}
	}

	var targetArg string
	if target != "" {
		targetArg = fmt.Sprintf(" -t %s", target)
	}

	b.WriteString(fmt.Sprintf("%stmux set-option%s pane-border-status %s\n", indent, targetArg, status))
	b.WriteString(fmt.Sprintf("%stmux set-option%s pane-border-lines %s\n", indent, targetArg, lines))
	b.WriteString(fmt.Sprintf("%stmux set-option%s pane-border-style '%s'\n", indent, targetArg, style))
	b.WriteString(fmt.Sprintf("%stmux set-option%s pane-active-border-style '%s'\n", indent, targetArg, activeStyle))
	b.WriteString(fmt.Sprintf("%stmux set-option%s pane-border-format '%s'\n", indent, targetArg, borderFormat))
}
