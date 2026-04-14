#!/usr/bin/env bash
#
# hooks.sh — coda lifecycle hook runner
#
# Hook directories (user overrides first):
#   $CODA_HOOKS_DIR/<event>/   (~/.config/coda/hooks/<event>/)
#   $_CODA_DIR/hooks/<event>/  (repo built-in hooks)
#
# Scripts run in sorted order. Each receives event-specific
# environment variables. Failures are reported but do not
# block core operations.

CODA_HOOKS_DIR="${CODA_HOOKS_DIR:-$HOME/.config/coda/hooks}"

_coda_hooks() {
    local subcmd="${1:-}"
    case "$subcmd" in
        ls)     shift; _coda_hooks_ls "$@" ;;
        events) _coda_hooks_events ;;
        create) shift; _coda_hooks_create "$@" ;;
        run)    shift; _coda_hooks_run "$@" ;;
        ""|help) cat <<'EOF'
Usage: coda hooks <ls|events|create|run>

  coda hooks ls [event]              List hook scripts
  coda hooks events                  List all supported events
  coda hooks create <event> <name>   Create a new hook
  coda hooks run <event>             Manually trigger hooks for an event
EOF
        ;;
        *) echo "Unknown hooks subcommand: $subcmd"; return 1 ;;
    esac
}

_coda_hooks_events() {
    cat <<'EOF'
Supported hook events:

  pre-session-create     Before tmux session is created
  post-session-create    After session + layout created
  post-session-attach    After tmux attach or switch-client
  post-project-create    After project setup (clone or new)
  post-project-clone     After clone specifically (has CODA_REPO_URL)
  pre-project-close      Before project sessions are killed
  post-feature-create    After worktree created, before attach
  pre-feature-teardown   Before feature done kills session
  post-feature-finish    After backgrounded feature finish completes
  post-layout-apply      After coda layout apply succeeds
EOF
}

_coda_hooks_ls() {
    local filter_event="${1:-}"
    local seen=""

    local -a events
    if [ -n "$filter_event" ]; then
        events=("$filter_event")
    else
        events=(pre-session-create post-session-create post-session-attach
                post-project-create post-project-clone pre-project-close
                post-feature-create pre-feature-teardown post-feature-finish
                post-layout-apply)
    fi

    local found=0
    for event in "${events[@]}"; do
        for dir in "$CODA_HOOKS_DIR/$event" "$_CODA_DIR/hooks/$event"; do
            [ -d "$dir" ] || continue
            for hook in "$dir"/*; do
                [ -f "$hook" ] || continue
                local name
                name=$(basename "$hook")
                local key="$event|$name"
                case "$seen" in *"|$key|"*) continue ;; esac
                seen="$seen|$key|"

                local source="builtin"
                [ -d "$CODA_HOOKS_DIR/$event" ] && [ -f "$CODA_HOOKS_DIR/$event/$name" ] && source="user"

                local exec_status="executable"
                [ -x "$hook" ] || exec_status="not-executable"

                echo "  $event/$name  ($source, $exec_status)"
                found=1
            done
        done
    done

    if [ "$found" -eq 0 ]; then
        if [ -n "$filter_event" ]; then
            echo "No hooks for event '$filter_event'."
            echo "Create one: coda hooks create $filter_event my-hook"
        else
            echo "No hooks installed."
            echo "Create one: coda hooks create <event> <name>"
            echo "See events: coda hooks events"
        fi
    fi
}

_coda_hooks_create() {
    local event="${1:-}" name="${2:-}"

    if [ -z "$event" ] || [ -z "$name" ]; then
        echo "Usage: coda hooks create <event> <name>"
        echo "See events: coda hooks events"
        return 1
    fi

    mkdir -p "$CODA_HOOKS_DIR/$event"
    local hook_file="$CODA_HOOKS_DIR/$event/$name"

    if [ -f "$hook_file" ]; then
        echo "Hook already exists: $hook_file"
        return 1
    fi

    cat > "$hook_file" <<TMPL
#!/usr/bin/env bash
#
# Hook: $event/$name
#
# Available env vars (see: coda hooks events):
TMPL

    case "$event" in
        pre-session-create)
            printf '#   CODA_SESSION_NAME, CODA_SESSION_DIR\n' >> "$hook_file" ;;
        post-session-create)
            printf '#   CODA_SESSION_NAME, CODA_SESSION_DIR, CODA_SESSION_LAYOUT\n' >> "$hook_file" ;;
        post-session-attach)
            printf '#   CODA_SESSION_NAME\n' >> "$hook_file" ;;
        post-project-create)
            printf '#   CODA_PROJECT_NAME, CODA_PROJECT_DIR\n' >> "$hook_file" ;;
        post-project-clone)
            printf '#   CODA_PROJECT_NAME, CODA_PROJECT_DIR, CODA_REPO_URL\n' >> "$hook_file" ;;
        pre-project-close)
            printf '#   CODA_PROJECT_NAME, CODA_PROJECT_DIR\n' >> "$hook_file" ;;
        post-feature-create)
            printf '#   CODA_PROJECT_NAME, CODA_PROJECT_DIR, CODA_FEATURE_BRANCH, CODA_WORKTREE_DIR\n' >> "$hook_file" ;;
        pre-feature-teardown)
            printf '#   CODA_PROJECT_NAME, CODA_PROJECT_DIR, CODA_FEATURE_BRANCH, CODA_WORKTREE_DIR, CODA_SESSION_NAME\n' >> "$hook_file" ;;
        post-feature-finish)
            printf '#   CODA_PROJECT_NAME, CODA_FEATURE_BRANCH\n' >> "$hook_file" ;;
        post-layout-apply)
            printf '#   CODA_SESSION_NAME, CODA_SESSION_LAYOUT\n' >> "$hook_file" ;;
    esac

    printf '\necho "Hook %s/%s ran"\n' "$event" "$name" >> "$hook_file"
    chmod +x "$hook_file"

    echo "Created: $hook_file"
    echo "Edit it, then it will run automatically on '$event'."
}

_coda_hooks_run() {
    local event="${1:-}"
    if [ -z "$event" ]; then
        echo "Usage: coda hooks run <event>"
        echo "See events: coda hooks events"
        return 1
    fi
    echo "Running hooks for: $event"
    _coda_run_hooks "$event"
    echo "Done."
}

_coda_run_hooks() {
    local event="$1"
    shift

    local -a hook_dirs=("$CODA_HOOKS_DIR/$event" "$_CODA_DIR/hooks/$event")
    local found=0

    for dir in "${hook_dirs[@]}"; do
        [ -d "$dir" ] || continue
        local hook
        while IFS= read -r hook; do
            [ -f "$hook" ] && [ -x "$hook" ] || continue
            found=1
            if ! "$hook" "$@" 2>&1; then
                echo "  hook warning: $(basename "$hook") exited non-zero" >&2
            fi
        done < <(printf '%s\n' "$dir"/* | LC_ALL=C sort)
    done

    # Plugin hooks
    local key
    for key in "${!_CODA_PLUGIN_HOOKS[@]}"; do
        local key_event="${key%%:*}"
        [ "$key_event" = "$event" ] || continue
        local glob_pattern="${_CODA_PLUGIN_HOOKS[$key]}"
        IFS='|' read -ra patterns <<< "$glob_pattern"
        for pattern in "${patterns[@]}"; do
            local hook
            for hook in $pattern; do
                [ -f "$hook" ] && [ -x "$hook" ] || continue
                found=1
                if ! "$hook" "$@" 2>&1; then
                    echo "  hook warning: $(basename "$hook") exited non-zero" >&2
                fi
            done
        done
    done

    return 0
}
