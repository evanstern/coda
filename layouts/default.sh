#!/usr/bin/env bash
#
# default.sh -- tmux layout: opencode (top 80%) + shell (bottom 20%)
#
#   $1 = session name
#   $2 = working directory
#   $3 = NVIM_APPNAME (unused in this layout)
#
#   +--------------------------------------+
#   |                                      |
#   |            opencode (80%)            |
#   |                                      |
#   +--------------------------------------+
#   |            shell (20%)               |
#   +--------------------------------------+

_layout_init() {
    local session="$1" dir="$2"
    tmux new-session -d -s "$session" -x "${COLUMNS:-200}" -y "${LINES:-50}" -c "$dir" "opencode; exec \$SHELL"
    tmux split-window -t "$session" -v -l 20% -c "$dir"
    tmux select-pane -t "$session:.0"
}

_layout_spawn() {
    local session="$1" dir="$2"
    local target="${CODA_LAYOUT_TARGET:-$session}"
    local window_flag=()
    case "$target" in
        *:*) window_flag=(-n "${target##*:}") ;;
    esac
    tmux new-window -t "${target%%:*}" "${window_flag[@]}" -c "$dir" "opencode; exec \$SHELL"
    tmux split-window -t "$target" -v -l 20% -c "$dir"
    tmux select-pane -t "${target}.0"
}
