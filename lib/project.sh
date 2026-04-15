#!/usr/bin/env bash
#
# project.sh — coda project management (start/add/workon/close/ls)
#

_coda_project() {
    local subcmd="${1:-}"
    case "$subcmd" in
        start)  shift; _coda_project_start "$@" ;;
        add)    shift; _coda_project_add "$@" ;;
        workon) shift; _coda_project_workon "$@" ;;
        close)  shift; _coda_project_close "$@" ;;
        ls)     _coda_project_ls ;;
        ""|help) echo "Usage: coda project <start|workon|close|ls>" ;;
        *)    echo "Unknown project subcommand: $subcmd"; echo "Usage: coda project <start|workon|close|ls>"; return 1 ;;
    esac
}

_coda_project_start() {
    local repo="" new_name="" message=""
    local positional=()

    while [ $# -gt 0 ]; do
        case "$1" in
            --repo)      repo="$2"; shift 2 ;;
            --repo=*)    repo="${1#--repo=}"; shift ;;
            --new)       new_name="$2"; shift 2 ;;
            --new=*)     new_name="${1#--new=}"; shift ;;
            --message)   message="$2"; shift 2 ;;
            --message=*) message="${1#--message=}"; shift ;;
            -m)          message="$2"; shift 2 ;;
            *)           positional+=("$1"); shift ;;
        esac
    done

    if [ -n "$new_name" ]; then
        _coda_project_start_new "$new_name" "$message"
    elif [ -n "$repo" ]; then
        _coda_project_add "$repo" "${positional[0]:-}"
    else
        _coda_project_start_reconnect
    fi
}

_coda_project_start_reconnect() {
    local project_root
    project_root=$(_coda_find_project_root)
    if [ -z "$project_root" ]; then
        echo "Not inside a coda project directory."
        echo ""
        echo "Usage:"
        echo "  coda project start                           Reconnect (from inside a project)"
        echo "  coda project start --repo <url> [name]       Clone an existing repo"
        echo "  coda project start --new <name> [-m \"...\"]   Create a new repo"
        return 1
    fi

    local project_name
    project_name=$(basename "$project_root")
    local branch
    branch=$(_coda_detect_default_branch "$project_root")
    local sanitized
    sanitized=$(_coda_sanitize_session_name "$project_name")

    local session="${SESSION_PREFIX}${sanitized}"
    if tmux has-session -t "$session" 2>/dev/null; then
        if [ -n "${TMUX:-}" ]; then
            tmux switch-client -t "$session"
        else
            tmux attach -t "$session"
        fi
        return 0
    fi

    local session_branch="${SESSION_PREFIX}${sanitized}--${branch}"
    if tmux has-session -t "$session_branch" 2>/dev/null; then
        if [ -n "${TMUX:-}" ]; then
            tmux switch-client -t "$session_branch"
        else
            tmux attach -t "$session_branch"
        fi
        return 0
    fi

    echo "No active session found for project: $project_name"
    echo ""
    echo "Start one with:"
    echo "  coda project workon $project_name"
    echo "  coda                                (from within the project)"
    return 1
}

_coda_project_start_new() {
    local name="$1"
    local message="$2"
    local project_dir="$PROJECTS_DIR/$name"
    local branch="$DEFAULT_BRANCH"
    local worktree_dir="$project_dir/$branch"

    if [ -z "$name" ]; then
        echo "Usage: coda project start --new <repo-name> [--message \"...\"]"
        return 1
    fi

    if [ -z "$NEW_PROJECT_GITHUB_OWNER" ]; then
        if command -v gh &>/dev/null; then
            NEW_PROJECT_GITHUB_OWNER=$(gh api user --jq '.login' 2>/dev/null) || true
        fi
        if [ -n "$NEW_PROJECT_GITHUB_OWNER" ]; then
            echo "Auto-detected GitHub owner: $NEW_PROJECT_GITHUB_OWNER"
        else
            echo "NEW_PROJECT_GITHUB_OWNER is not set."
            echo "Add it to your .env: NEW_PROJECT_GITHUB_OWNER=yourgithubuser"
            echo "Tip: run 'gh api user --jq .login' to find your GitHub username."
            return 1
        fi
    fi

    local repo_url="git@github.com:${NEW_PROJECT_GITHUB_OWNER}/${name}.git"

    if ! command -v gh &>/dev/null; then
        echo "GitHub CLI (gh) is required for --new."
        echo "Install: https://cli.github.com/"
        return 1
    fi

    if [ -d "$project_dir" ]; then
        echo "Directory already exists: $project_dir"
        return 1
    fi

    echo "Creating repository: ${NEW_PROJECT_GITHUB_OWNER}/${name}"
    if ! gh repo create "${NEW_PROJECT_GITHUB_OWNER}/${name}" --private; then
        echo "Failed to create repository on GitHub."
        return 1
    fi

    mkdir -p "$project_dir" "$worktree_dir"
    if ! git init --bare --initial-branch="$branch" "$project_dir/.bare" --quiet; then
        rm -rf "$project_dir"
        echo "Failed to create local bare repository."
        return 1
    fi

    printf 'gitdir: ./.bare\n' > "$project_dir/.git"
    git -C "$project_dir" config worktree.useRelativePaths true

    if ! git --git-dir="$project_dir/.bare" --work-tree="$worktree_dir" \
        checkout --orphan "$branch" >/dev/null 2>&1; then
        rm -rf "$project_dir"
        echo "Failed to create initial worktree."
        return 1
    fi

    echo "# $name" > "$worktree_dir/README.md"
    if [ -n "$message" ]; then
        printf '%s\n' "$message" > "$worktree_dir/AGENTS.md"
    fi

    if ! git --git-dir="$project_dir/.bare" --work-tree="$worktree_dir" add -A ||
        ! git --git-dir="$project_dir/.bare" --work-tree="$worktree_dir" commit -m "Initial commit" --quiet ||
        ! git --git-dir="$project_dir/.bare" --work-tree="$worktree_dir" remote add "$GIT_REMOTE" "$repo_url" ||
        ! git -C "$project_dir" config remote."$GIT_REMOTE".fetch \
            "+refs/heads/*:refs/remotes/${GIT_REMOTE}/*" ||
        ! git --git-dir="$project_dir/.bare" --work-tree="$worktree_dir" push -u "$GIT_REMOTE" "$branch" --quiet; then
        rm -rf "$project_dir"
        echo "Failed to bootstrap the new repository."
        return 1
    fi

    rm -rf "$worktree_dir"
    if ! git -C "$project_dir" worktree add "$worktree_dir" "$branch" >/dev/null 2>&1; then
        rm -rf "$project_dir"
        echo "Failed to register the initial worktree."
        return 1
    fi

    echo ""
    echo "Project ready: $project_dir"
    CODA_PROJECT_NAME="$name" CODA_PROJECT_DIR="$project_dir" \
        _coda_run_hooks post-project-create
    echo "Opening session in $worktree_dir"
    _coda_attach "$name" "$worktree_dir"
}

_coda_project_add() {
    local repo="${1:-}"
    local name="${2:-$(basename "${repo%.git}")}"

    if [ -z "$repo" ]; then
        echo "Usage: coda project start --repo <repo-url> [name]"
        return 1
    fi

    local project_dir="$PROJECTS_DIR/$name"

    if [ -d "$project_dir/.bare" ]; then
        echo "Project already set up: $project_dir"
        echo "Fetching latest..."
        git -C "$project_dir" fetch --all --quiet
        echo "Worktrees:"
        git -C "$project_dir" worktree list 2>/dev/null | sed 's/^/  /'

        local branch
        branch=$(_coda_detect_default_branch "$project_dir")

        if [ ! -d "$project_dir/$branch" ]; then
            git -C "$project_dir" worktree add \
                "$project_dir/$branch" "$branch"
        fi

        echo ""
        echo "Opening session in $project_dir/$branch"
        _coda_attach "$name" "$project_dir/$branch"
        return $?
    fi

    if [ -d "$project_dir" ]; then
        echo "Directory exists but is not a coda project: $project_dir"
        echo "Remove it first or choose a different name."
        return 1
    fi

    echo "Cloning $repo..."
    mkdir -p "$project_dir"
    git clone --bare "$repo" "$project_dir/.bare"
    echo "gitdir: ./.bare" > "$project_dir/.git"

    git -C "$project_dir" config remote."$GIT_REMOTE".fetch \
        "+refs/heads/*:refs/remotes/${GIT_REMOTE}/*"
    git -C "$project_dir" config worktree.useRelativePaths true
    git -C "$project_dir" fetch --all --quiet

    local branch
    branch=$(_coda_detect_default_branch "$project_dir")

    if [ ! -d "$project_dir/$branch" ]; then
        git -C "$project_dir" worktree add \
            "$project_dir/$branch" "$branch"
    fi

    echo ""
    echo "Project ready: $project_dir"
    CODA_PROJECT_NAME="$name" CODA_PROJECT_DIR="$project_dir" \
        _coda_run_hooks post-project-create
    CODA_PROJECT_NAME="$name" CODA_PROJECT_DIR="$project_dir" \
    CODA_REPO_URL="$repo" \
        _coda_run_hooks post-project-clone
    echo "Opening session in $project_dir/$branch"
    _coda_attach "$name" "$project_dir/$branch"
}

_coda_project_workon() {
    local name="${1:-}"
    local branch="${2:-}"

    if [ -z "$name" ]; then
        echo "Usage: coda project workon <name> [branch]"
        return 1
    fi

    local project_dir="$PROJECTS_DIR/$name"

    if [ ! -d "$project_dir/.bare" ]; then
        echo "Not a coda project: $name"
        echo "Add it first: coda project start --repo <repo-url>"
        return 1
    fi

    if [ -z "$branch" ]; then
        branch=$(_coda_detect_default_branch "$project_dir")
    fi

    local worktree_dir="$project_dir/$branch"

    if [ ! -d "$worktree_dir" ]; then
        echo "Creating worktree: $branch"
        if git -C "$project_dir" show-ref --verify --quiet "refs/heads/$branch" 2>/dev/null ||
           git -C "$project_dir" show-ref --verify --quiet "refs/remotes/${GIT_REMOTE}/$branch" 2>/dev/null; then
            git -C "$project_dir" worktree add "$worktree_dir" "$branch"
        else
            git -C "$project_dir" worktree add -b "$branch" "$worktree_dir" \
                "$(_coda_detect_default_branch "$project_dir")"
        fi
    fi

    _coda_attach "${name}--${branch}" "$worktree_dir"
}

_coda_project_ls() {
    if [ ! -d "$PROJECTS_DIR" ]; then
        echo "No projects directory: $PROJECTS_DIR"
        return 1
    fi

    local found=0
    for d in "$PROJECTS_DIR"/*/; do
        if [ -d "${d}.bare" ] || [ -f "${d}.git" ]; then
            echo "  $(basename "$d")  →  $d"
            found=1
        fi
    done

    if [ "$found" -eq 0 ]; then
        echo "No projects found in $PROJECTS_DIR"
        echo "Add one with: coda project start --repo <repo-url>"
    fi
}

_coda_project_close() {
    local delete=false

    while [ $# -gt 0 ]; do
        case "$1" in
            --delete) delete=true; shift ;;
            *) echo "Usage: coda project close [--delete]"; return 1 ;;
        esac
    done

    local project_root
    project_root=$(_coda_find_project_root)
    if [ -z "$project_root" ]; then
        echo "Not inside a coda project directory."
        return 1
    fi

    local requested_project_root="$project_root"

    local physical_project_root
    physical_project_root=$(cd "$project_root" 2>/dev/null && pwd -P)
    if [ -z "$physical_project_root" ]; then
        echo "Could not resolve project path: $project_root"
        return 1
    fi
    project_root="$physical_project_root"

    local physical_projects_dir=""
    if [ "$delete" = true ]; then
        physical_projects_dir=$(cd "$PROJECTS_DIR" 2>/dev/null && pwd -P)
        if [ -z "$physical_projects_dir" ]; then
            echo "Could not resolve PROJECTS_DIR: $PROJECTS_DIR"
            return 1
        fi

        case "$project_root" in
            "$physical_projects_dir"|"$physical_projects_dir"/*) ;;
            *)
                echo "Refusing to delete project outside PROJECTS_DIR: $project_root"
                return 1
                ;;
        esac
    fi

    local project_name
    project_name=$(basename "$project_root")

    local sanitized
    sanitized=$(_coda_sanitize_session_name "$project_name")

    local -a sessions=()
    local session_name
    while IFS= read -r session_name; do
        case "$session_name" in
            "${SESSION_PREFIX}${sanitized}"|"${SESSION_PREFIX}${sanitized}"--*)
                sessions+=("$session_name")
                ;;
        esac
    done < <(tmux list-sessions -F '#{session_name}' 2>/dev/null || true)

    CODA_PROJECT_NAME="$project_name" CODA_PROJECT_DIR="$project_root" \
        _coda_run_hooks pre-project-close

    if [ "$delete" = true ]; then
        echo "Closing project: $project_name"
        echo "  Teardown backgrounded (sessions + project folder)."
    else
        echo "Closing project: $project_name"
        echo "  Teardown backgrounded (sessions only)."
    fi

    (
        sleep 1

        local session
        for session in "${sessions[@]}"; do
            if tmux has-session -t "$session" 2>/dev/null; then
                tmux kill-session -t "$session"
            fi
        done

        if [ "$delete" = true ] && [ -d "$project_root" ]; then
            rm -rf "$project_root"
            if [ "$requested_project_root" != "$project_root" ] && [ -L "$requested_project_root" ]; then
                rm -f "$requested_project_root"
            fi
        fi
    ) &
    disown 2>/dev/null || true
    return 0
}
