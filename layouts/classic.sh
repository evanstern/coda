#!/usr/bin/env bash
#
# classic.sh — tmux layout: single pane running opencode (original behavior)
#
# Called by _coda_attach / coda layout apply with:
#   $1 = session name
#   $2 = working directory
#   $3 = NVIM_APPNAME (unused in this layout)
#
# Layout:
#   ┌──────────────────────────────────────┐
#   │                                       │
#   │              opencode                 │
#   │          (falls back to $SHELL)       │
#   │                                       │
#   └──────────────────────────────────────┘

_layout_init() {
    local session="$1" dir="$2"
    tmux new-session -d -s "$session" -x "${COLUMNS:-200}" -y "${LINES:-50}" -c "$dir" "opencode; exec \$SHELL"
}

_layout_spawn() {
    local session="$1" dir="$2"
    local target="${CODA_LAYOUT_TARGET:-$session}"
    local window_flag=()
    case "$target" in
        *:*) window_flag=(-n "${target##*:}") ;;
    esac
    tmux new-window -t "${target%%:*}" "${window_flag[@]}" -c "$dir" "opencode; exec \$SHELL"
}

# Legacy alias
_layout_apply() { _layout_init "$@"; }
