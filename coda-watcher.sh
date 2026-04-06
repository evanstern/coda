#!/usr/bin/env bash
#
# coda-watcher.sh — Monitor OpenCode sessions and notify on attention needed
#
# Polls all coda tmux sessions, detects when OpenCode transitions from
# processing (AI working) to idle (waiting for user input), and sends a
# terminal bell (BEL) to every connected tmux client.
#
# The bell propagates: tmux client pty → mosh → your terminal → OS notification.
# Works with Ghostty, iTerm2, Kitty, and any terminal that supports BEL alerts.
#
# Normally started via 'coda watch'. Can also be run directly.
#
# Environment:
#   CODA_WATCH_INTERVAL   Poll interval in seconds (default: 5)
#   CODA_WATCH_COOLDOWN   Min seconds between repeat notifications per pane (default: 60)
#   SESSION_PREFIX        tmux session name prefix (default: coda-)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -f "$SCRIPT_DIR/.env" ]; then
    # shellcheck source=/dev/null
    set -a; source "$SCRIPT_DIR/.env"; set +a
fi

POLL_INTERVAL="${CODA_WATCH_INTERVAL:-5}"
COOLDOWN="${CODA_WATCH_COOLDOWN:-60}"
SESSION_PREFIX="${SESSION_PREFIX:-coda-}"
WATCHER_SESSION="coda-watcher"

STATE_DIR="${XDG_RUNTIME_DIR:-/tmp}/coda-watcher.$$"
mkdir -p "$STATE_DIR"
trap 'rm -rf "$STATE_DIR"' EXIT

# ---------------------------------------------------------------------------
# State tracking — one file per pane, keyed by session:pane_id
# ---------------------------------------------------------------------------

_sanitize_key() {
    echo "${1//[^a-zA-Z0-9_-]/_}"
}

get_state() {
    local file="$STATE_DIR/$(_sanitize_key "$1").state"
    [ -f "$file" ] && cat "$file" || echo "unknown"
}

set_state() {
    echo "$2" > "$STATE_DIR/$(_sanitize_key "$1").state"
}

get_last_notify() {
    local file="$STATE_DIR/$(_sanitize_key "$1").notified"
    [ -f "$file" ] && cat "$file" || echo "0"
}

set_last_notify() {
    date +%s > "$STATE_DIR/$(_sanitize_key "$1").notified"
}

# ---------------------------------------------------------------------------
# Detection — identify OpenCode panes and their processing state
# ---------------------------------------------------------------------------

# OpenCode's status bar contains "OpenCode" followed by a version number.
is_opencode_pane() {
    echo "$1" | grep -qE 'OpenCode [0-9]+\.[0-9]+'
}

# When OpenCode is processing, the status bar shows "esc interrupt" (the key
# hint to cancel the current operation).  When idle/waiting for input, this
# text is absent.
detect_state() {
    if echo "$1" | grep -qF 'esc interrupt'; then
        echo "processing"
    else
        echo "idle"
    fi
}

# ---------------------------------------------------------------------------
# Notification — bell + status-bar message to all connected clients
# ---------------------------------------------------------------------------

notify() {
    local session="$1"
    local key="$2"
    local now
    now=$(date +%s)
    local last
    last=$(get_last_notify "$key")

    # Respect cooldown
    if (( now - last < COOLDOWN )); then
        return
    fi

    local display_name="${session#"$SESSION_PREFIX"}"

    # Send BEL via tmux + display-message to every attached client.
    # We use 'tmux send-keys' to inject the bell character rather than
    # writing directly to the client pty (which requires pty ownership).
    local client_tty
    while IFS= read -r client_tty; do
        [ -z "$client_tty" ] && continue
        tmux send-keys -t "$session" BEL 2>/dev/null || true
        tmux display-message -c "$client_tty" \
            "coda: ${display_name} needs attention" 2>/dev/null || true
    done < <(tmux list-clients -F '#{client_tty}' 2>/dev/null)

    set_last_notify "$key"
}

# ---------------------------------------------------------------------------
# Cleanup — remove stale state for sessions/panes that no longer exist
# ---------------------------------------------------------------------------

cleanup_stale_state() {
    local active_keys="$1"
    for f in "$STATE_DIR"/*.state; do
        [ -f "$f" ] || continue
        local basename
        basename=$(basename "${f%.state}")
        if ! echo "$active_keys" | grep -qF "$basename"; then
            rm -f "$STATE_DIR/${basename}.state" "$STATE_DIR/${basename}.notified"
        fi
    done
}

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------

echo "coda-watcher: monitoring OpenCode sessions"
echo "  interval=${POLL_INTERVAL}s  cooldown=${COOLDOWN}s"
echo "  Stop with: coda watch stop (or Ctrl-C)"
echo ""

while true; do
    active_keys=""

    # All coda sessions except the watcher itself
    sessions=$(tmux list-sessions -F '#{session_name}' 2>/dev/null \
        | grep "^${SESSION_PREFIX}" \
        | grep -v "^${WATCHER_SESSION}$" \
        || true)

    while IFS= read -r session; do
        [ -z "$session" ] && continue

        # Every pane in every window of this session
        panes=$(tmux list-panes -s -t "$session" -F '#{pane_id}' 2>/dev/null || true)

        while IFS= read -r pane_id; do
            [ -z "$pane_id" ] && continue

            # Capture the bottom of the pane (status bar lives here)
            content=$(tmux capture-pane -t "$pane_id" -p -S -5 2>/dev/null || true)
            [ -z "$content" ] && continue

            if ! is_opencode_pane "$content"; then
                continue
            fi

            key="${session}:${pane_id}"
            sanitized=$(_sanitize_key "$key")
            active_keys="${active_keys}${sanitized}\n"

            prev_state=$(get_state "$key")
            curr_state=$(detect_state "$content")

            # Notify on transition: processing → idle
            if [ "$prev_state" = "processing" ] && [ "$curr_state" = "idle" ]; then
                notify "$session" "$key"
            fi

            set_state "$key" "$curr_state"
        done <<< "$panes"
    done <<< "$sessions"

    # Prune state for panes/sessions that vanished
    cleanup_stale_state "$active_keys"

    sleep "$POLL_INTERVAL"
done
