#!/usr/bin/env bash
#
# feature.sh — coda feature branch management (start/done/finish/ls)
#

_coda_feature() {
    local subcmd="${1:-}"
    case "$subcmd" in
        start)  shift; _coda_feature_start "$@" ;;
        done)   shift; _coda_feature_done "$@" ;;
        finish) shift; _coda_feature_finish "$@" ;;
        ls)     _coda_feature_ls ;;
        ""|help) echo "Usage: coda feature <start|done|finish|ls>" ;;
        *)    echo "Unknown feature subcommand: $subcmd"; echo "Usage: coda feature <start|done|finish|ls>"; return 1 ;;
    esac
}

_coda_feature_start() {
    local branch="${1:-}"
    local base="${2:-}"
    local project_name="${3:-}"

    if [ -z "$branch" ]; then
        echo "Usage: coda feature start <branch> [base-branch] [project-name]"
        return 1
    fi

    local project_root
    if [ -n "$project_name" ]; then
        project_root="$PROJECTS_DIR/$project_name"
        if [ ! -d "$project_root/.bare" ]; then
            echo "Not a coda project: $project_name"
            echo "Add it first: coda project start --repo <repo-url>"
            return 1
        fi
    else
        project_root=$(_coda_find_project_root)
        if [ -z "$project_root" ]; then
            echo "Not inside a coda project directory."
            echo "cd into a project first, or run: coda project start --repo <url>"
            return 1
        fi
        project_name=$(basename "$project_root")
    fi

    if [ -z "$base" ]; then
        base=$(_coda_detect_default_branch "$project_root")
    fi

    if ! git -C "$project_root" show-ref --quiet 2>/dev/null | grep -q .; then
        echo "No refs found — fetching from origin..."
        git -C "$project_root" fetch --all --quiet || {
            echo "Fetch failed. Check your remote and network."
            return 1
        }
    fi

    local worktree_dir="$project_root/$branch"

    if [ -d "$worktree_dir" ]; then
        echo "Worktree already exists: $worktree_dir"
        echo "Attaching to existing session..."
        _coda_attach "${project_name}--${branch}" "$worktree_dir"
        return 0
    fi

    if git -C "$project_root" show-ref --verify --quiet "refs/heads/$branch" 2>/dev/null; then
        echo "Attaching worktree for existing branch: $branch"
        git -C "$project_root" worktree add "$worktree_dir" "$branch" || return 1
    elif git -C "$project_root" show-ref --verify --quiet "refs/remotes/origin/$branch" 2>/dev/null; then
        echo "Creating worktree from remote branch: $branch"
        git -C "$project_root" worktree add --track -b "$branch" "$worktree_dir" "origin/$branch" || return 1
    else
        if git -C "$project_root" show-ref --verify --quiet "refs/heads/$base" 2>/dev/null ||
           git -C "$project_root" show-ref --verify --quiet "refs/remotes/origin/$base" 2>/dev/null; then
            echo "Creating worktree: $branch (from $base)"
            git -C "$project_root" worktree add -b "$branch" "$worktree_dir" "$base" || return 1
        else
            echo "Creating worktree: $branch (empty repo, orphan branch)"
            git -C "$project_root" worktree add --orphan -b "$branch" "$worktree_dir" || return 1
        fi
    fi

    CODA_PROJECT_NAME="$project_name" CODA_PROJECT_DIR="$project_root" \
    CODA_FEATURE_BRANCH="$branch" CODA_WORKTREE_DIR="$worktree_dir" \
        _coda_run_hooks post-feature-create
    _coda_attach "${project_name}--${branch}" "$worktree_dir"
}

_coda_feature_done() {
    local branch="${1:-}"
    local project_name="${2:-}"

    if [ -z "$branch" ]; then
        echo "Usage: coda feature done <branch> [project-name]"
        return 1
    fi

    local project_root
    if [ -n "$project_name" ]; then
        project_root="$PROJECTS_DIR/$project_name"
        if [ ! -d "$project_root/.bare" ]; then
            echo "Not a coda project: $project_name"
            echo "Add it first: coda project start --repo <repo-url>"
            return 1
        fi
    else
        project_root=$(_coda_find_project_root)
        if [ -z "$project_root" ]; then
            echo "Not inside a coda project directory."
            return 1
        fi
        project_name=$(basename "$project_root")
    fi

    local session="${SESSION_PREFIX}$(_coda_sanitize_session_name "$project_name")--${branch}"
    local worktree_dir="$project_root/$branch"

    echo "Cleaning up feature: $branch"

    CODA_PROJECT_NAME="$project_name" CODA_PROJECT_DIR="$project_root" \
    CODA_FEATURE_BRANCH="$branch" CODA_WORKTREE_DIR="$worktree_dir" \
    CODA_SESSION_NAME="$session" \
        _coda_run_hooks pre-feature-teardown

    if tmux has-session -t "$session" 2>/dev/null; then
        echo "  Killing session: $session"
        tmux kill-session -t "$session"
    fi

    if [ -d "$worktree_dir" ]; then
        echo "  Removing worktree: $worktree_dir"
        git -C "$project_root" worktree remove "$worktree_dir" --force
    fi

    if git -C "$project_root" show-ref --verify --quiet "refs/heads/$branch" 2>/dev/null; then
        echo "  Deleting branch: $branch"
        git -C "$project_root" branch -D "$branch"
    fi

    # Hard-delete any opencode sessions scoped to this worktree.
    # Silent no-op if the orchestrator plugin isn't loaded.
    _coda_prune_sessions_for_dir "$worktree_dir"

    echo "Done."
}

_coda_feature_finish() {
    local force=false
    while [ $# -gt 0 ]; do
        case "$1" in
            --force|-f) force=true; shift ;;
            *) echo "Usage: coda feature finish [--force]"; return 1 ;;
        esac
    done

    local project_root
    project_root=$(_coda_find_project_root)
    if [ -z "$project_root" ]; then
        echo "Not inside a coda project directory."
        return 1
    fi

    local project_name
    project_name=$(basename "$project_root")

    local branch
    branch=$(git -C "$PWD" rev-parse --abbrev-ref HEAD 2>/dev/null)
    if [ -z "$branch" ]; then
        echo "Could not detect current branch."
        return 1
    fi

    local default_branch
    default_branch=$(_coda_detect_default_branch "$project_root")
    if [ "$branch" = "$default_branch" ]; then
        echo "You are on $default_branch. Switch to a feature branch first."
        return 1
    fi

    if [ "$force" = false ]; then
        if ! git -C "$PWD" diff --quiet 2>/dev/null || ! git -C "$PWD" diff --cached --quiet 2>/dev/null; then
            echo "Uncommitted changes detected. Commit or stash before finishing."
            echo "  git status:"
            git -C "$PWD" status --short
            echo ""
            echo "To discard changes and tear down anyway: coda feature finish --force"
            return 1
        fi

        if [ -n "$(git -C "$PWD" ls-files --others --exclude-standard 2>/dev/null)" ]; then
            echo "Untracked files detected. Commit or remove them before finishing."
            echo "  Untracked:"
            git -C "$PWD" ls-files --others --exclude-standard | sed 's/^/    /'
            echo ""
            echo "To discard and tear down anyway: coda feature finish --force"
            return 1
        fi
    fi

    local session="${SESSION_PREFIX}$(_coda_sanitize_session_name "$project_name")--${branch}"
    local worktree_dir="$project_root/$branch"

    echo "Finishing feature: $branch"

    (
        sleep 1
        if tmux has-session -t "$session" 2>/dev/null; then
            tmux kill-session -t "$session"
        fi
        if [ -d "$worktree_dir" ]; then
            git -C "$project_root" worktree remove "$worktree_dir" --force 2>/dev/null
        fi
        if git -C "$project_root" show-ref --verify --quiet "refs/heads/$branch" 2>/dev/null; then
            git -C "$project_root" branch -D "$branch" 2>/dev/null
        fi
        _coda_prune_sessions_for_dir "$worktree_dir"
        CODA_PROJECT_NAME="$project_name" CODA_FEATURE_BRANCH="$branch" \
            _coda_run_hooks post-feature-finish
    ) &
    disown

    echo "  Teardown backgrounded (session, worktree, branch)."
}

_coda_feature_ls() {
    local project_root
    project_root=$(_coda_find_project_root)
    if [ -z "$project_root" ]; then
        echo "Not inside a coda project directory."
        return 1
    fi

    echo "Worktrees for $(basename "$project_root"):"
    git -C "$project_root" worktree list | while IFS= read -r line; do
        echo "  $line"
    done
}

_coda_prune_sessions_for_dir() {
    local worktree_dir="$1"
    [ -n "$worktree_dir" ] || return 0

    if ! command -v _orch_prune_dir >/dev/null 2>&1; then
        return 0
    fi

    local base_dir="${ORCH_BASE_DIR:-$HOME/.config/coda/orchestrators}"
    [ -d "$base_dir" ] || return 0

    local pf port
    for pf in "$base_dir"/*/port; do
        [ -f "$pf" ] || continue
        port=$(cat "$pf")
        case "$port" in
            ''|*[!0-9]*) continue ;;
        esac
        if ! curl -sf "http://localhost:$port/global/health" >/dev/null 2>&1; then
            continue
        fi
        _orch_prune_dir "$port" "$worktree_dir" --hard --keep 0 --days 0 \
            >/dev/null 2>&1 || true
    done
}
