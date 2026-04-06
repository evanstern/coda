#!/usr/bin/env bash
#
# shell-functions.sh — coda: OpenCode session and project manager
#
# Source in .bashrc or .zshrc:
#   source ~/coda/shell-functions.sh

_CODA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -f "$_CODA_DIR/.env" ]; then
    # shellcheck source=/dev/null
    set -a; source "$_CODA_DIR/.env"; set +a
fi

PROJECTS_DIR="${PROJECTS_DIR:-$HOME/projects}"
SESSION_PREFIX="${SESSION_PREFIX:-coda-}"
DEFAULT_BRANCH="${DEFAULT_BRANCH:-main}"
GIT_REMOTE="${GIT_REMOTE:-origin}"
OPENCODE_BASE_PORT="${OPENCODE_BASE_PORT:-4096}"
OPENCODE_PORT_RANGE="${OPENCODE_PORT_RANGE:-10}"
AUTO_ATTACH_TMUX="${AUTO_ATTACH_TMUX:-true}"
DEFAULT_TMUX_SESSION="${DEFAULT_TMUX_SESSION:-default}"
DEFAULT_LAYOUT="${DEFAULT_LAYOUT:-default}"
DEFAULT_NVIM_APPNAME="${DEFAULT_NVIM_APPNAME:-nvim}"
CODA_PROFILES_DIR="${CODA_PROFILES_DIR:-$HOME/.config/coda/profiles}"
CODA_LAYOUTS_DIR="${CODA_LAYOUTS_DIR:-$HOME/.config/coda/layouts}"

# ===========================================================================
# coda — main entry point
# ===========================================================================
#
#   coda [name] [dir]             attach or create a session
#   coda ls                       list active sessions
#   coda switch                   fzf session picker
#   coda serve [port]             headless OpenCode server
#   coda auth                     wire Claude Code credentials
#   coda project <cmd>            manage projects
#   coda feature <cmd>            manage feature worktrees
#   coda layout <cmd|name>        manage/apply tmux layouts
#   coda profile <cmd>            manage layout/config profiles
#   coda watch <cmd>              monitor sessions for attention signals
#   coda help                     show this help
#
# Global flags (any position):
#   --profile <name>              use a config profile for this session
#   --layout <name>               override the tmux layout
#
coda() {
    local _coda_profile="" _coda_layout=""
    local args=()

    while [ $# -gt 0 ]; do
        case "$1" in
            --profile)    _coda_profile="$2"; shift 2 ;;
            --profile=*)  _coda_profile="${1#--profile=}"; shift ;;
            --layout)     _coda_layout="$2"; shift 2 ;;
            --layout=*)   _coda_layout="${1#--layout=}"; shift ;;
            *)            args+=("$1"); shift ;;
        esac
    done

    [ -n "$_coda_profile" ] && CODA_PROFILE="$_coda_profile"
    [ -n "$_coda_layout" ] && CODA_LAYOUT="$_coda_layout"

    local subcmd="${args[0]:-}"

    case "$subcmd" in
        ls)               _coda_ls ;;
        switch)           _coda_switch ;;
        attach)           if [ "${#args[@]}" -gt 1 ]; then
                              _coda_attach "${args[1]#"$SESSION_PREFIX"}" "${args[@]:2}"
                          else
                              _coda_attach
                          fi
                          ;;
        auth)             _coda_auth ;;
        serve)            _coda_serve "${args[@]:1}" ;;
        project)          _coda_project "${args[@]:1}" ;;
        feature)          _coda_feature "${args[@]:1}" ;;
        layout)           _coda_layout_cmd "${args[@]:1}" ;;
        profile)          _coda_profile_cmd "${args[@]:1}" ;;
        watch)            _coda_watch "${args[@]:1}" ;;
        help|--help|-h)   _coda_help ;;
        "")               _coda_attach ;;
        *)                _coda_attach "${args[0]#"$SESSION_PREFIX"}" "${args[@]:1}" ;;
    esac

    unset CODA_PROFILE CODA_LAYOUT
}

# ===========================================================================
# coda [name] [dir]
# Attach to an existing session or create a new one running OpenCode.
# ===========================================================================
_coda_attach() {
    local name="${1:-$(basename "$PWD")}"
    local dir="${2:-$PWD}"
    local session="${SESSION_PREFIX}${name}"

    local layout="${CODA_LAYOUT:-$DEFAULT_LAYOUT}"
    local nvim_appname="${CODA_NVIM_APPNAME:-$DEFAULT_NVIM_APPNAME}"
    local profile="${CODA_PROFILE:-}"

    if [ -n "$profile" ]; then
        local profile_file
        profile_file=$(_coda_resolve_profile "$profile")
        if [ -z "$profile_file" ]; then
            echo "Unknown profile: $profile"
            echo "Available: $(_coda_list_profiles | tr '\n' ' ')"
            return 1
        fi
        set -a; source "$profile_file"; set +a
        layout="${CODA_LAYOUT:-$layout}"
        nvim_appname="${CODA_NVIM_APPNAME:-$nvim_appname}"
    fi

    if ! tmux has-session -t "$session" 2>/dev/null; then
        _coda_load_layout "$layout" || return 1

        if declare -f _layout_init &>/dev/null; then
            _layout_init "$session" "$dir" "$nvim_appname"
        elif declare -f _layout_apply &>/dev/null; then
            _layout_apply "$session" "$dir" "$nvim_appname"
        else
            echo "Layout '$layout' has no _layout_init or _layout_apply function."
            return 1
        fi

        tmux set-environment -t "$session" CODA_DIR "$dir"
    fi

    if [ -n "${TMUX:-}" ]; then
        tmux switch-client -t "$session"
    else
        tmux attach -t "$session"
    fi
}

# ===========================================================================
# coda ls
# List all active coda sessions.
# ===========================================================================
_coda_ls() {
    local sessions
    sessions=$(tmux list-sessions \
        -F '#{session_name}  (#{session_windows}w, created #{t:session_created})' \
        2>/dev/null | grep "^${SESSION_PREFIX}" || true)

    if [ -z "$sessions" ]; then
        echo "No active sessions."
        echo "Start one with: coda [name]"
    else
        echo "Active sessions:"
        echo "$sessions" | while IFS= read -r line; do
            echo "  $line"
        done
    fi
}

# ===========================================================================
# coda switch
# fzf-powered session picker with pane preview.
# ===========================================================================
_coda_switch() {
    if ! command -v fzf &>/dev/null; then
        echo "fzf not found. Re-run install.sh to install it."
        return 1
    fi

    local session
    session=$(tmux list-sessions -F '#{session_name}' 2>/dev/null \
        | fzf --preview 'tmux capture-pane -t {} -p -S -30' \
              --preview-window=right:50% \
              --header="Select session  (ESC to cancel)")

    if [ -n "$session" ]; then
        if [ -n "${TMUX:-}" ]; then
            tmux switch-client -t "$session"
        else
            tmux attach -t "$session"
        fi
    fi
}

# ===========================================================================
# coda serve [port]
# Start OpenCode in headless server mode.
# ===========================================================================
_coda_serve() {
    local port="${1:-}"

    if [ -z "$port" ]; then
        port=$(_coda_find_free_port)
        if [ -z "$port" ]; then
            echo "No free ports in range ${OPENCODE_BASE_PORT}-$((OPENCODE_BASE_PORT + OPENCODE_PORT_RANGE))"
            return 1
        fi
    fi

    local _default_permission='{"*":"allow"}'
    local permission="${OPENCODE_HEADLESS_PERMISSION:-$_default_permission}"

    echo "Starting OpenCode server on port $port"
    echo "  Attach with: opencode attach http://localhost:$port"
    echo ""

    OPENCODE_PERMISSION="$permission" opencode serve --port "$port"
}

# ===========================================================================
# coda auth
# Install the opencode-claude-auth plugin to share Claude Code credentials.
# ===========================================================================
_coda_auth() {
    if ! command -v claude &>/dev/null; then
        echo "claude CLI not found. Install Claude Code first (re-run install.sh)."
        return 1
    fi

    if ! command -v opencode &>/dev/null; then
        echo "opencode not found. Re-run install.sh."
        return 1
    fi

    if ! claude auth status >/dev/null 2>&1; then
        echo "Not authenticated. Run: claude auth login"
        return 1
    fi

    if [ ! -f "$HOME/.claude/.credentials.json" ]; then
        echo "Missing $HOME/.claude/.credentials.json"
        echo "Run 'claude' once after login so it writes the credentials file."
        return 1
    fi

    echo "Installing opencode-claude-auth plugin..."
    opencode plugin opencode-claude-auth -g

    echo ""
    echo "Claude auth status:"
    claude auth status
    echo ""
    echo "Available Anthropic models:"
    opencode models anthropic
}

# ===========================================================================
# coda project <add|ls>
# ===========================================================================
_coda_project() {
    local subcmd="${1:-}"
    case "$subcmd" in
        add)    shift; _coda_project_add "$@" ;;
        workon) shift; _coda_project_workon "$@" ;;
        ls)     _coda_project_ls ;;
        ""|help) echo "Usage: coda project <add|workon|ls>" ;;
        *)    echo "Unknown project subcommand: $subcmd"; echo "Usage: coda project <add|workon|ls>"; return 1 ;;
    esac
}

# coda project add <repo-url> [name]
_coda_project_add() {
    local repo="${1:-}"
    local name="${2:-$(basename "${repo%.git}")}"

    if [ -z "$repo" ]; then
        echo "Usage: coda project add <repo-url> [name]"
        return 1
    fi

    local project_dir="$PROJECTS_DIR/$name"

    if [ -d "$project_dir/.bare" ]; then
        echo "Project already set up: $project_dir"
        echo "Fetching latest..."
        git -C "$project_dir" fetch --all --quiet
        echo "Worktrees:"
        git -C "$project_dir" worktree list 2>/dev/null | sed 's/^/  /'

        if [ ! -d "$project_dir/$DEFAULT_BRANCH" ]; then
            git -C "$project_dir" worktree add \
                "$project_dir/$DEFAULT_BRANCH" "$DEFAULT_BRANCH"
        fi

        echo ""
        echo "Opening session in $project_dir/$DEFAULT_BRANCH"
        _coda_attach "$name" "$project_dir/$DEFAULT_BRANCH"
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

    if [ ! -d "$project_dir/$DEFAULT_BRANCH" ]; then
        git -C "$project_dir" worktree add \
            "$project_dir/$DEFAULT_BRANCH" "$DEFAULT_BRANCH"
    fi

    echo ""
    echo "Project ready: $project_dir"
    echo "Opening session in $project_dir/$DEFAULT_BRANCH"
    _coda_attach "$name" "$project_dir/$DEFAULT_BRANCH"
}

# coda project workon <name> [branch]
_coda_project_workon() {
    local name="${1:-}"
    local branch="${2:-$DEFAULT_BRANCH}"

    if [ -z "$name" ]; then
        echo "Usage: coda project workon <name> [branch]"
        return 1
    fi

    local project_dir="$PROJECTS_DIR/$name"

    if [ ! -d "$project_dir/.bare" ]; then
        echo "Not a coda project: $name"
        echo "Add it first: coda project add <repo-url> $name"
        return 1
    fi

    local worktree_dir="$project_dir/$branch"

    if [ ! -d "$worktree_dir" ]; then
        echo "Creating worktree: $branch"
        if git -C "$project_dir" show-ref --verify --quiet "refs/heads/$branch" 2>/dev/null ||
           git -C "$project_dir" show-ref --verify --quiet "refs/remotes/${GIT_REMOTE}/$branch" 2>/dev/null; then
            git -C "$project_dir" worktree add "$worktree_dir" "$branch"
        else
            git -C "$project_dir" worktree add -b "$branch" "$worktree_dir" "$DEFAULT_BRANCH"
        fi
    fi

    _coda_attach "${name}--${branch}" "$worktree_dir"
}

# coda project ls
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
        echo "Add one with: coda project add <repo-url>"
    fi
}

# ===========================================================================
# coda feature <start|done|ls>
# ===========================================================================
_coda_feature() {
    local subcmd="${1:-}"
    case "$subcmd" in
        start) shift; _coda_feature_start "$@" ;;
        done)  shift; _coda_feature_done "$@" ;;
        ls)    _coda_feature_ls ;;
        ""|help) echo "Usage: coda feature <start|done|ls>" ;;
        *)    echo "Unknown feature subcommand: $subcmd"; echo "Usage: coda feature <start|done|ls>"; return 1 ;;
    esac
}

# coda feature start <branch> [base] [project]
_coda_feature_start() {
    local branch="${1:-}"
    local base="${2:-$DEFAULT_BRANCH}"
    local project_name="${3:-}"

    if [ -z "$branch" ]; then
        echo "Usage: coda feature start <branch> [base-branch] [project-name]"
        return 1
    fi

    local project_root
    project_root=$(_coda_find_project_root)
    if [ -z "$project_root" ]; then
        echo "Not inside a coda project directory."
        echo "cd into a project first, or run: coda project add <url>"
        return 1
    fi

    if [ -z "$project_name" ]; then
        project_name=$(basename "$project_root")
    fi

    local worktree_dir="$project_root/$branch"

    if [ -d "$worktree_dir" ]; then
        echo "Worktree already exists: $worktree_dir"
        echo "Attaching to existing session..."
        _coda_attach "${project_name}--${branch}" "$worktree_dir"
        return 0
    fi

    echo "Creating worktree: $branch (from $base)"
    git -C "$project_root" worktree add -b "$branch" "$worktree_dir" "$base"

    _coda_attach "${project_name}--${branch}" "$worktree_dir"
}

# coda feature done <branch> [project]
_coda_feature_done() {
    local branch="${1:-}"
    local project_name="${2:-}"

    if [ -z "$branch" ]; then
        echo "Usage: coda feature done <branch> [project-name]"
        return 1
    fi

    local project_root
    project_root=$(_coda_find_project_root)
    if [ -z "$project_root" ]; then
        echo "Not inside a coda project directory."
        return 1
    fi

    if [ -z "$project_name" ]; then
        project_name=$(basename "$project_root")
    fi

    local session="${SESSION_PREFIX}${project_name}--${branch}"
    local worktree_dir="$project_root/$branch"

    echo "Cleaning up feature: $branch"

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

    echo "Done."
}

# coda feature ls
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

# ===========================================================================
# coda profile <ls|create|show>
# ===========================================================================
_coda_profile_cmd() {
    local subcmd="${1:-}"
    case "$subcmd" in
        ls)     _coda_profile_ls ;;
        create) shift; _coda_profile_create "$@" ;;
        show)   shift; _coda_profile_show "$@" ;;
        ""|help) echo "Usage: coda profile <ls|create|show>" ;;
        *)      echo "Unknown profile subcommand: $subcmd"; return 1 ;;
    esac
}

_coda_profile_ls() {
    echo "Available profiles:"
    local found=0
    local name

    for name in $(_coda_list_profiles); do
        local source="repo"
        [ -f "$CODA_PROFILES_DIR/${name}.env" ] && source="user"
        echo "  $name  ($source)"
        found=1
    done

    if [ "$found" -eq 0 ]; then
        echo "  (none)"
        echo "Create one with: coda profile create <name>"
    fi

    echo ""
    echo "Current defaults: layout=$DEFAULT_LAYOUT  nvim=$DEFAULT_NVIM_APPNAME"
    echo "Run 'coda layout ls' to see available layouts."
}

_coda_profile_create() {
    local name="${1:-}"
    if [ -z "$name" ]; then
        echo "Usage: coda profile create <name>"
        return 1
    fi

    mkdir -p "$CODA_PROFILES_DIR"
    local profile_file="$CODA_PROFILES_DIR/${name}.env"

    if [ -f "$profile_file" ]; then
        echo "Profile already exists: $profile_file"
        return 1
    fi

    cat > "$profile_file" <<TMPL
# Coda profile: $name
# Used with: coda --profile $name [session]

# tmux layout (see available: coda profile ls)
CODA_LAYOUT="$DEFAULT_LAYOUT"

# Neovim config directory name (~/.config/<CODA_NVIM_APPNAME>/)
CODA_NVIM_APPNAME="nvim-${name}"
TMPL

    echo "Created: $profile_file"
    echo "Edit to customize, then use: coda --profile $name [session]"
}

_coda_profile_show() {
    local name="${1:-}"
    if [ -z "$name" ]; then
        echo "Usage: coda profile show <name>"
        return 1
    fi

    local profile_file
    profile_file=$(_coda_resolve_profile "$name")
    if [ -z "$profile_file" ]; then
        echo "Unknown profile: $name"
        return 1
    fi

    echo "Profile: $name ($profile_file)"
    echo "---"
    cat "$profile_file"
}

# ===========================================================================
# coda layout <apply|ls|show|create|name>
# ===========================================================================
_coda_layout_cmd() {
    local subcmd="${1:-}"
    case "$subcmd" in
        apply)  shift; _coda_layout_apply "$@" ;;
        ls)     _coda_layout_ls ;;
        show)   shift; _coda_layout_show "$@" ;;
        create) shift; _coda_layout_create "$@" ;;
        ""|help) cat <<'EOF'
Usage: coda layout <apply|ls|show|create|name>

  coda layout <name>           Apply layout to current session (shorthand)
  coda layout apply <name>     Apply layout to current session
  coda layout ls               List available layouts
  coda layout show <name>      Show layout file contents
  coda layout create <name>    Create a new layout from template
EOF
        ;;
        *)      _coda_layout_apply "$subcmd" "$@" ;;
    esac
}

_coda_layout_apply() {
    local name="${1:-}"
    if [ -z "$name" ]; then
        echo "Usage: coda layout apply <name>"
        echo "       coda layout <name>"
        return 1
    fi

    if [ -z "${TMUX:-}" ]; then
        echo "Not inside a tmux session. Attach first: coda attach <session>"
        return 1
    fi

    local session
    session=$(tmux display-message -p '#{session_name}')

    local dir
    dir=$(tmux show-environment -t "$session" CODA_DIR 2>/dev/null | sed 's/^CODA_DIR=//')
    if [ -z "$dir" ] || [ "${dir:0:1}" = "-" ]; then
        dir=$(tmux display-message -p '#{pane_current_path}')
    fi

    local nvim_appname="${CODA_NVIM_APPNAME:-$DEFAULT_NVIM_APPNAME}"

    _coda_load_layout "$name" || return 1

    if declare -f _layout_spawn &>/dev/null; then
        _layout_spawn "$session" "$dir" "$nvim_appname"
    else
        echo "Layout '$name' does not support spawning into existing sessions."
        echo "Add a _layout_spawn() function to the layout file."
        return 1
    fi
}

_coda_layout_ls() {
    echo "Available layouts:"
    local seen="" name source
    for f in "$CODA_LAYOUTS_DIR"/*.sh "$_CODA_DIR/layouts"/*.sh; do
        [ -f "$f" ] || continue
        name=$(basename "${f%.sh}")
        case "$seen" in *"|$name|"*) continue ;; esac
        seen="$seen|$name|"
        if [ -f "$CODA_LAYOUTS_DIR/${name}.sh" ]; then
            source="user"
        else
            source="builtin"
        fi
        echo "  $name  ($source)"
    done
    echo ""
    echo "Default: $DEFAULT_LAYOUT"
    echo ""
    echo "Apply to current session:  coda layout <name>"
    echo "Create a new layout:       coda layout create <name>"
}

_coda_layout_show() {
    local name="${1:-}"
    if [ -z "$name" ]; then
        echo "Usage: coda layout show <name>"
        return 1
    fi

    local layout_file=""
    if [ -f "$CODA_LAYOUTS_DIR/${name}.sh" ]; then
        layout_file="$CODA_LAYOUTS_DIR/${name}.sh"
    elif [ -f "$_CODA_DIR/layouts/${name}.sh" ]; then
        layout_file="$_CODA_DIR/layouts/${name}.sh"
    fi

    if [ -z "$layout_file" ]; then
        echo "Unknown layout: $name"
        return 1
    fi

    echo "Layout: $name ($layout_file)"
    echo "---"
    cat "$layout_file"
}

_coda_layout_create() {
    local name="${1:-}"
    if [ -z "$name" ]; then
        echo "Usage: coda layout create <name>"
        return 1
    fi

    mkdir -p "$CODA_LAYOUTS_DIR"
    local layout_file="$CODA_LAYOUTS_DIR/${name}.sh"

    if [ -f "$layout_file" ]; then
        echo "Layout already exists: $layout_file"
        return 1
    fi

    cat > "$layout_file" <<TMPL
#!/usr/bin/env bash
#
# ${name}.sh — tmux layout
#
# \$1 = session name    \$2 = working directory    \$3 = NVIM_APPNAME
#
# Layout:
#   ┌──────────────────────────────────────┐
#   │         (your layout here)            │
#   └──────────────────────────────────────┘
#
# Tips:
#   - End commands with "; exec \\\$SHELL" so the pane falls back to a shell
#   - Use -c "\$dir" on split/new-window to set the starting directory
#   - Use tmux send-keys for multi-command setup sequences
#   - Navigate panes with: select-pane -t "\$session" -L/-R/-U/-D
#   - See 'man tmux' for split-window, new-window, select-pane options

_layout_init() {
    local session="\$1" dir="\$2" nvim_appname="\${3:-nvim}"
    local cols="\${COLUMNS:-200}" rows="\${LINES:-50}"

    tmux new-session -d -s "\$session" -x "\$cols" -y "\$rows" -c "\$dir" "opencode; exec \\\$SHELL"

    # Add panes — use -l (absolute) not -p (percentage); -p is broken on tmux 3.4:
    # local half=\$(( cols / 2 ))
    # tmux split-window -h -t "\$session" -c "\$dir" -l "\$half" \\
    #     "NVIM_APPNAME=\$nvim_appname nvim .; exec \\\$SHELL"
    # tmux select-pane -t "\$session" -L
}

_layout_spawn() {
    local session="\$1" dir="\$2" nvim_appname="\${3:-nvim}"

    local script
    script=\$(mktemp "\${TMPDIR:-/tmp}/coda-layout.XXXXXX")
    cat > "\$script" <<SPAWN
#!/usr/bin/env bash
rm -f "\\\$0"
# Add splits here — use -l (absolute) not -p (percentage):
# pw=\\\$(tmux display-message -p '#{pane_width}')
# tmux split-window -h -c "\$dir" -l \\\$(( pw / 2 )) \\
#     "NVIM_APPNAME=\$nvim_appname nvim .; exec \\\\\\\$SHELL"
# tmux select-pane -t "\\\$TMUX_PANE"
opencode; exec "\\\$SHELL"
SPAWN
    chmod +x "\$script"
    tmux new-window -t "\$session" -c "\$dir" "\$script"
}
TMPL

    echo "Created: $layout_file"
    echo "Edit it, then apply: coda layout $name"
}

# ===========================================================================
# coda watch <start|stop|status>
# ===========================================================================
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

    tmux new-session -d -s "$watcher_session" "$_CODA_DIR/coda-watcher.sh"
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

# ===========================================================================
# coda help
# ===========================================================================
_coda_help() {
    cat <<'EOF'
coda — OpenCode session and project manager

USAGE
  coda [name] [dir]           Attach or create a session (default: current dir)
  coda ls                     List active sessions
  coda switch                 fzf session picker with preview
  coda serve [port]           Start OpenCode in headless server mode
  coda auth                   Wire Claude Code credentials to OpenCode

  coda project add <url> [name]        Clone a repo as a bare project
  coda project workon <name> [branch]  Open a project session (create worktree if needed)
  coda project ls                      List projects in PROJECTS_DIR

  coda feature start <branch> [base] [project]   New worktree + session
  coda feature done  <branch> [project]          Teardown worktree + session
  coda feature ls                                List worktrees for this project

  coda layout <name>                Apply a layout to the current session
  coda layout ls                   List available layouts
  coda layout show <name>          Show layout file contents
  coda layout create <name>        Create a new layout from template

  coda profile ls                  List profiles
  coda profile create <name>       Create a new profile
  coda profile show <name>         Show profile settings

  coda watch                       Start monitoring sessions (bell on idle)
  coda watch stop                  Stop the watcher
  coda watch status                Check if watcher is running

  coda help                   Show this help

GLOBAL FLAGS
  --profile <name>            Use a config profile (layout + nvim config)
  --layout <name>             Override the tmux layout for this session

EXAMPLES
  coda project add git@github.com:user/myapp.git
  cd ~/projects/myapp/main
  coda feature start auth
  coda --profile experimental feature start auth
  coda --layout classic myapp
  coda ls
  coda switch
  coda feature done auth

Run 'man coda' for the full manual.
EOF
}

# ===========================================================================
# Internal helpers
# ===========================================================================

_coda_list_layouts() {
    local seen="" name
    for f in "$CODA_LAYOUTS_DIR"/*.sh "$_CODA_DIR/layouts"/*.sh; do
        [ -f "$f" ] || continue
        name=$(basename "${f%.sh}")
        case "$seen" in *"|$name|"*) continue ;; esac
        seen="$seen|$name|"
        echo "$name"
    done
}

_coda_load_layout() {
    local name="$1"
    local layout_file=""

    if [ -f "$CODA_LAYOUTS_DIR/${name}.sh" ]; then
        layout_file="$CODA_LAYOUTS_DIR/${name}.sh"
    elif [ -f "$_CODA_DIR/layouts/${name}.sh" ]; then
        layout_file="$_CODA_DIR/layouts/${name}.sh"
    fi

    if [ -z "$layout_file" ]; then
        echo "Unknown layout: $name"
        echo "Available: $(_coda_list_layouts | tr '\n' ' ')"
        return 1
    fi

    unset -f _layout_init _layout_spawn _layout_apply 2>/dev/null

    # shellcheck source=/dev/null
    source "$layout_file"
}

_coda_resolve_profile() {
    local name="${1:-default}"
    local user_profile="$CODA_PROFILES_DIR/${name}.env"
    local repo_profile="$_CODA_DIR/profiles/${name}.env"

    if [ -f "$user_profile" ]; then
        echo "$user_profile"
    elif [ -f "$repo_profile" ]; then
        echo "$repo_profile"
    fi
}

_coda_list_profiles() {
    local seen=""
    local name

    for f in "$CODA_PROFILES_DIR"/*.env "$_CODA_DIR/profiles"/*.env; do
        [ -f "$f" ] || continue
        name=$(basename "${f%.env}")
        case "$seen" in
            *"|$name|"*) continue ;;
        esac
        seen="$seen|$name|"
        echo "$name"
    done
}

_coda_find_project_root() {
    local dir="$PWD"
    while [ "$dir" != "/" ]; do
        if [ -f "$dir/.git" ] && grep -q "gitdir: ./.bare" "$dir/.git" 2>/dev/null; then
            echo "$dir"
            return
        fi
        if [ -d "$dir/.bare" ]; then
            echo "$dir"
            return
        fi
        dir=$(dirname "$dir")
    done
}

_coda_find_free_port() {
    local port=$OPENCODE_BASE_PORT
    local max=$((OPENCODE_BASE_PORT + OPENCODE_PORT_RANGE))
    while [ "$port" -le "$max" ]; do
        if command -v ss &>/dev/null; then
            ss -tlnp 2>/dev/null | grep -q ":${port} " || { echo "$port"; return; }
        elif command -v lsof &>/dev/null; then
            lsof -i :"$port" &>/dev/null 2>&1 || { echo "$port"; return; }
        else
            (echo "" >/dev/tcp/127.0.0.1/"$port") 2>/dev/null || { echo "$port"; return; }
        fi
        port=$((port + 1))
    done
}

# ===========================================================================
# Auto-attach tmux on SSH login
# ===========================================================================
if [ "$AUTO_ATTACH_TMUX" = "true" ] && [ -n "${SSH_CONNECTION:-}" ] && [ -z "${TMUX:-}" ]; then
    tmux attach -t "$DEFAULT_TMUX_SESSION" 2>/dev/null || tmux new -s "$DEFAULT_TMUX_SESSION"
fi
