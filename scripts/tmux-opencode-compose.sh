#!/usr/bin/env bash

set -euo pipefail

session="${1:-}"
window="${2:-}"
working_dir="${3:-}"
tmp_file=""
buffer_name=""

resolve_tmux_context() {
    if [ -z "$session" ] || [ "${session#'#{'}" != "$session" ]; then
        session="$(tmux display-message -p '#{session_name}')"
    fi

    if [ -z "$window" ] || [ "${window#'#{'}" != "$window" ]; then
        window="$(tmux display-message -p '#{window_index}')"
    fi

    if [ -z "$working_dir" ] || [ "${working_dir#'#{'}" != "$working_dir" ]; then
        working_dir="$(tmux display-message -p '#{pane_current_path}')"
    fi
}

notify() {
    tmux display-message "$*" >/dev/null 2>&1 || true
}

is_opencode_title() {
    case "$1" in
        "OpenCode"|"OpenCode "*|"OC | "*)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

is_opencode_content() {
    local pane_id="$1"
    local content

    content="$(tmux capture-pane -t "$pane_id" -p -S -5 2>/dev/null || true)"
    printf '%s' "$content" | grep -qE 'OpenCode [0-9]+\.[0-9]+' 
}

die() {
    notify "$*"
    printf 'tmux-opencode-compose: %s\n' "$*" >&2
    exit 1
}

find_target_pane() {
    local scope="$1"
    local pane_id pane_title pane_command pane_path pane_window pane_active window_active
    local best_pane=""
    local best_score=-1
    local score

    while IFS=$'\t' read -r pane_id pane_title pane_command pane_path pane_window pane_active window_active; do
        score=-1

        if is_opencode_title "$pane_title"; then
            score=60
        fi

        if [ "$pane_command" = "opencode" ] && [ "$score" -lt 40 ]; then
            score=40
        fi

        if is_opencode_content "$pane_id" && [ "$score" -lt 35 ]; then
            score=35
        fi

        [ "$score" -ge 0 ] || continue

        if [ "$pane_window" = "$window" ]; then
            score=$(( score + 100 ))
        fi

        if [ "$pane_path" = "$working_dir" ]; then
            score=$(( score + 30 ))
        fi

        if [ "$window_active" = "1" ]; then
            score=$(( score + 20 ))
        fi

        if [ "$pane_active" = "1" ]; then
            score=$(( score + 10 ))
        fi

        if [ "$score" -gt "$best_score" ]; then
            best_score="$score"
            best_pane="$pane_id"
        fi
    done < <(tmux list-panes -t "$scope" -F '#{pane_id}	#{pane_title}	#{pane_current_command}	#{pane_current_path}	#{window_index}	#{pane_active}	#{window_active}')

    [ -n "$best_pane" ] || return 1
    printf '%s\n' "$best_pane"
}

run_editor() {
    local file="$1"

    if [ -n "${OVIM_EDITOR_CMD:-}" ]; then
        bash -c "$OVIM_EDITOR_CMD" tmux-opencode-compose "$file"
        return
    fi

    "${EDITOR:-vim}" "$file"
}

main() {
    local target_pane content

    command -v tmux >/dev/null 2>&1 || die "tmux is required"
    resolve_tmux_context

    [ -n "$session" ] || die "missing tmux session argument"
    [ -n "$window" ] || die "missing tmux window argument"
    [ -n "$working_dir" ] || die "missing working directory"

    target_pane="$(find_target_pane "$session:$window")" || true

    if [ -z "$target_pane" ]; then
        target_pane="$(find_target_pane "$session")" || true
    fi

    [ -n "$target_pane" ] || die "could not find an OpenCode pane in session ${session}"

    if [ "$(tmux display-message -p -t "$target_pane" '#{window_index}')" != "$window" ]; then
        notify "OpenCode compose: targeting $(tmux display-message -p -t "$target_pane" '#{session_name}:#{window_index}.#{pane_index}')"
    fi

    tmp_file="$(mktemp "${TMPDIR:-/tmp}/coda-compose.XXXXXX.txt")"
    buffer_name="coda-compose-$$"
    trap 'rm -f "$tmp_file" >/dev/null 2>&1 || true; tmux delete-buffer -b "$buffer_name" >/dev/null 2>&1 || true' EXIT

    cd "$working_dir"
    run_editor "$tmp_file"

    content="$(tr -d '[:space:]' < "$tmp_file")"
    if [ -z "$content" ]; then
        notify "OpenCode compose: no content submitted"
        printf 'tmux-opencode-compose: no content submitted\n' >&2
        exit 0
    fi

    tmux load-buffer -b "$buffer_name" - < "$tmp_file"
    tmux paste-buffer -d -p -b "$buffer_name" -t "$target_pane"
    tmux send-keys -t "$target_pane" Enter
}

main "$@"
