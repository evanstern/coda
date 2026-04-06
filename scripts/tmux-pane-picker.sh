#!/usr/bin/env bash
#
# tmux-pane-picker.sh — fzf pane switcher using a hidden staging window.
#
# Uses swap-pane to exchange the current pane's content with a background
# pane, so no splits or new windows ever appear. Background panes live
# in a staging window named _terminals (hidden from the status bar via
# window-status-format in tmux.conf).
#
# Args (expanded by tmux run-shell before the popup spawns):
#   $1 = session name
#   $2 = window index
#   $3 = current pane id
#   $4 = current pane path

session="${1:-}"
window="${2:-}"
current_pane="${3:-}"
current_path="${4:-}"
staging="${session}:_terminals"

staging_exists() {
    tmux list-windows -t "$session" -F '#{window_name}' 2>/dev/null | grep -q '^_terminals$'
}

entries=""
if staging_exists; then
    while IFS='|' read -r id cmd path; do
        short_path="${path/#$HOME/\~}"
        entries="${entries}${id}|${cmd} [${short_path}]
"
    done < <(tmux list-panes -t "$staging" -F '#{pane_id}|#{pane_current_command}|#{pane_current_path}' 2>/dev/null)
fi

entries="${entries}__NEW|+ new terminal"

selected=$(printf '%s' "$entries" \
    | fzf --reverse --no-sort --header="Switch Terminal" --prompt="  " \
          --delimiter='|' --with-nth=2 \
    | cut -d'|' -f1) || true

[ -z "$selected" ] && exit 0

if [ "$selected" = "__NEW" ]; then
    if ! staging_exists; then
        tmux new-window -t "$session" -n _terminals -d -c "$current_path"
        new_pane=$(tmux list-panes -t "$staging" -F '#{pane_id}' | head -1)
    else
        tmux split-window -t "$staging" -c "$current_path" -d
        new_pane=$(tmux list-panes -t "$staging" -F '#{pane_id}' | tail -1)
    fi
    tmux swap-pane -s "$new_pane" -t "$current_pane"
else
    tmux swap-pane -s "$selected" -t "$current_pane"
fi
