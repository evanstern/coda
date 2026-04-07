#!/usr/bin/env bash
#
# four-pane.sh — tmux layout: git status (left), file explorer (center),
#                opencode (right), shell (bottom)
#
# Called by _coda_attach / coda layout apply with:
#   $1 = session name
#   $2 = working directory
#   $3 = (unused in this layout)
#
# Layout:
#   ┌──────────┬──────────────────┬──────────────────┐
#   │   git    │  file explorer   │    opencode       │  80% height
#   │  status  │    /preview      │                   │
#   │  (20%)   │     (40%)        │     (40%)         │
#   ├──────────┴──────────────────┴──────────────────┤
#   │  $ shell                                        │  20% height
#   └────────────────────────────────────────────────┘
#
# Sidebar tools (first available wins):
#   File explorer:  yazi > nnn > lf > ranger > plain shell
#   Git status:     lazygit > gitui > tig > watch git status
#
# Note: tmux 3.4 split-window -p (percentage) is broken — use -l (lines/cols).

_four_pane_explorer_cmd() {
    local cmd="ls -la"
    command -v ranger &>/dev/null && cmd="ranger"
    command -v lf     &>/dev/null && cmd="lf"
    command -v nnn    &>/dev/null && cmd="nnn"
    command -v yazi   &>/dev/null && cmd="yazi"
    printf '%s' "$cmd"
}

_four_pane_git_cmd() {
    local cmd="watch -n 5 git status"
    command -v tig     &>/dev/null && cmd="tig status"
    command -v gitui   &>/dev/null && cmd="gitui"
    command -v lazygit &>/dev/null && cmd="lazygit"
    printf '%s' "$cmd"
}

_layout_init() {
    local session="$1" dir="$2"
    local cols="${COLUMNS:-200}" rows="${LINES:-50}"

    local explorer_cmd; explorer_cmd=$(_four_pane_explorer_cmd)
    local git_cmd;      git_cmd=$(_four_pane_git_cmd)

    tmux new-session -d -s "$session" -x "$cols" -y "$rows" -c "$dir" \
        "$git_cmd; exec \$SHELL"
    tmux set-environment -t "$session" EDITOR nvim
    tmux select-pane -t "$session" -T "Git"

    local avail=$(( rows - 1 ))
    local bottom=$(( avail * 20 / 100 ))
    local git_w=$(( cols * 20 / 100 ))
    local right_area=$(( cols - git_w ))
    local opencode_w=$(( right_area / 2 ))

    tmux split-window -v -t "$session" -c "$dir" -l "$bottom"
    tmux select-pane -t "$session" -T "Shell"
    tmux select-pane -t "$session" -U
    tmux split-window -h -t "$session" -c "$dir" -l "$right_area" \
        "$explorer_cmd; exec \$SHELL"
    tmux select-pane -t "$session" -T "Explorer"
    tmux split-window -h -t "$session" -c "$dir" -l "$opencode_w" \
        "opencode; exec \$SHELL"
    tmux select-pane -t "$session" -T "OpenCode"

    tmux set-option -t "$session" pane-border-status top
    tmux set-option -t "$session" pane-border-lines heavy
    tmux set-option -t "$session" pane-border-style 'fg=colour245'
    tmux set-option -t "$session" pane-active-border-style 'fg=green,bold'
    tmux set-option -t "$session" pane-border-format \
        ' #{?pane_active,▸ ,  }#{pane_title} '
}

_layout_spawn() {
    local session="$1" dir="$2"

    local script
    script=$(mktemp "${TMPDIR:-/tmp}/coda-layout.XXXXXX")
    cat > "$script" <<SETUP
#!/usr/bin/env bash
rm -f "\$0"
tmux set-environment EDITOR nvim

explorer_cmd="ls -la"
command -v ranger &>/dev/null && explorer_cmd="ranger"
command -v lf     &>/dev/null && explorer_cmd="lf"
command -v nnn    &>/dev/null && explorer_cmd="nnn"
command -v yazi   &>/dev/null && explorer_cmd="yazi"

git_cmd="watch -n 5 git status"
command -v tig     &>/dev/null && git_cmd="tig status"
command -v gitui   &>/dev/null && git_cmd="gitui"
command -v lazygit &>/dev/null && git_cmd="lazygit"

ph=\$(tmux display-message -p '#{pane_height}')
pw=\$(tmux display-message -p '#{pane_width}')
bottom=\$(( ph * 20 / 100 ))
git_w=\$(( pw * 20 / 100 ))
right_area=\$(( pw - git_w ))
opencode_w=\$(( right_area / 2 ))

tmux split-window -v -c "$dir" -l "\$bottom"
tmux select-pane -T "Shell"
tmux select-pane -U
tmux select-pane -T "Git"
tmux split-window -h -c "$dir" -l "\$right_area" "\$explorer_cmd; exec \\\$SHELL"
tmux select-pane -T "Explorer"
tmux split-window -h -c "$dir" -l "\$opencode_w" "opencode; exec \\\$SHELL"
tmux select-pane -T "OpenCode"

tmux set-option pane-border-status top
tmux set-option pane-border-lines heavy
tmux set-option pane-border-style 'fg=colour245'
tmux set-option pane-active-border-style 'fg=green,bold'
tmux set-option pane-border-format ' #{?pane_active,▸ ,  }#{pane_title} '

\$git_cmd; exec "\$SHELL"
SETUP
    chmod +x "$script"
    tmux new-window -t "$session" -c "$dir" "$script"
}

_layout_apply() { _layout_init "$@"; }
