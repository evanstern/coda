#!/usr/bin/env bash
#
# default.sh u2014 tmux layout: opencode (top 80%) + shell (bottom 20%)
#
# Called by _coda_attach / coda layout apply with:
#   $1 = session name
#   $2 = working directory
#   $3 = NVIM_APPNAME (unused in this layout)
#
# Layout:
#   u250cu2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2510
#   u2502                                       u2502
#   u2502              opencode                 u2502
#   u2502              (80%)                    u2502
#   u2502                                       u2502
#   u251cu2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2524
#   u2502              shell (20%)              u2502
#   u2514u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2500u2518

_layout_init() {
    local session="$1" dir="$2"
    tmux new-session -d -s "$session" -x "${COLUMNS:-200}" -y "${LINES:-50}" -c "$dir" "opencode; exec \$SHELL"
    tmux split-window -t "$session" -v -l 20% -c "$dir"
    tmux select-pane -t "$session:.0"
}

_layout_spawn() {
    local session="$1" dir="$2"
    tmux new-window -t "$session" -c "$dir" "opencode; exec \$SHELL"
    tmux split-window -t "$session" -v -l 20% -c "$dir"
    tmux select-pane -t "${session}:.0"
}
