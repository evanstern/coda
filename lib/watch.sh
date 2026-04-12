#!/usr/bin/env bash
#
# watch.sh — coda watch commands (start/stop/status)
#

_coda_watch() {
    local subcmd="${1:-start}"
    local watcher_session="coda-watcher"

    case "$subcmd" in
        start)  _coda_watch_start "$watcher_session" ;;
        stop)   _coda_watch_stop "$watcher_session" ;;
        status) _coda_watch_status "$watcher_session" ;;
        ""|help) echo "Usage: coda watch <start|stop|status>" ;;
        *)    echo "Unknown watch subcommand: $subcmd"; echo "Usage: coda watch <start|stop|status>"; return 1 ;;
    esac
}

_coda_watch_start() {
    local watcher_session="$1"

    if tmux has-session -t "$watcher_session" 2>/dev/null; then
        echo "Watcher already running."
        echo "  View:  tmux attach -t $watcher_session"
        echo "  Stop:  coda watch stop"
        return 0
    fi

    local watcher_cmd
    if command -v coda-core &>/dev/null; then
        watcher_cmd="coda-core watch --interval ${CODA_WATCH_INTERVAL:-5} --cooldown ${CODA_WATCH_COOLDOWN:-60} --prefix ${SESSION_PREFIX}"
    else
        watcher_cmd="$_CODA_DIR/coda-watcher.sh"
    fi

    tmux new-session -d -s "$watcher_session" "$watcher_cmd"
    echo "Watcher started."
    echo "  View:  tmux attach -t $watcher_session"
    echo "  Stop:  coda watch stop"
}

_coda_watch_stop() {
    local watcher_session="$1"

    if ! tmux has-session -t "$watcher_session" 2>/dev/null; then
        echo "Watcher is not running."
        return 0
    fi

    tmux kill-session -t "$watcher_session"
    echo "Watcher stopped."
}

_coda_watch_status() {
    local watcher_session="$1"

    if tmux has-session -t "$watcher_session" 2>/dev/null; then
        local created
        created=$(tmux display-message -t "$watcher_session" -p '#{t:session_created}' 2>/dev/null)
        echo "Watcher: running (since $created)"
        echo "  View:  tmux attach -t $watcher_session"
        echo "  Stop:  coda watch stop"
    else
        echo "Watcher: stopped"
        echo "  Start: coda watch"
    fi
}
