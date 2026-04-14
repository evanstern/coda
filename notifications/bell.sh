#!/usr/bin/env bash
#
# bell.sh -- default notification: send BEL to all connected tmux clients
#
# Env vars available:
#   CODA_PANE_ID         -- pane that transitioned to idle
#   CODA_SESSION_NAME    -- tmux session name
#   CODA_NOTIFICATION_EVENT -- event type (e.g., "idle")

local_session="${CODA_SESSION_NAME:-unknown}"
local_prefix="${SESSION_PREFIX:-coda-}"
display_name="${local_session#"$local_prefix"}"

while IFS= read -r client_tty; do
    [ -z "$client_tty" ] && continue
    pane_tty=$(tmux display-message -p -c "$client_tty" '#{pane_tty}' 2>/dev/null || true)
    if [ -n "$pane_tty" ]; then
        printf '\a' > "$pane_tty" 2>/dev/null || true
    fi
    tmux display-message -c "$client_tty" \
        "coda: ${display_name} needs attention" 2>/dev/null || true
done < <(tmux list-clients -F '#{client_tty}' 2>/dev/null)
