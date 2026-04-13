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

_coda_run_hooks() {
    local event="$1"
    shift

    local -a hook_dirs=("$CODA_HOOKS_DIR/$event" "$_CODA_DIR/hooks/$event")

    for dir in "${hook_dirs[@]}"; do
        [ -d "$dir" ] || continue
        local hook
        while IFS= read -r hook; do
            [ -f "$hook" ] && [ -x "$hook" ] || continue
            if ! "$hook" "$@" 2>&1; then
                echo "  hook warning: $(basename "$hook") exited non-zero" >&2
            fi
        done < <(printf '%s\n' "$dir"/* | LC_ALL=C sort)
    done

    return 0
}
