#!/usr/bin/env bash
#
# layout.sh — coda layout management (apply/ls/show/create/snapshot)
#

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
  coda layout create <name> --yaml      Create a YAML layout template
  coda layout create <name> --snapshot  Capture current window layout
  coda layout create <name> --snapshot --yaml  Capture as YAML config
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
        if ! _layout_spawn "$session" "$dir" "$nvim_appname"; then
            echo "Layout '$name' spawn failed."
            return 1
        fi
    else
        echo "Layout '$name' does not support spawning into existing sessions."
        echo "Add a _layout_spawn() function to the layout file."
        return 1
    fi

    CODA_SESSION_NAME="$session" CODA_SESSION_LAYOUT="$name" \
        _coda_run_hooks post-layout-apply
}

_coda_layout_ls() {
    echo "Available layouts:"
    local seen="" name source fmt_tag
    for f in "$CODA_LAYOUTS_DIR"/*.sh "$CODA_LAYOUTS_DIR"/*.yaml "$_CODA_DIR/layouts"/*.sh "$_CODA_DIR/layouts"/*.yaml; do
        [ -f "$f" ] || continue
        local base
        base=$(basename "$f")
        name="${base%.*}"
        case "$seen" in *"|$name|"*) continue ;; esac
        seen="$seen|$name|"
        if [ -f "$CODA_LAYOUTS_DIR/${name}.sh" ] || [ -f "$CODA_LAYOUTS_DIR/${name}.yaml" ]; then
            source="user"
        else
            source="builtin"
        fi
        case "$base" in
            *.yaml) fmt_tag="yaml" ;;
            *)      fmt_tag="sh" ;;
        esac
        echo "  $name  ($source, $fmt_tag)"
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
    elif [ -f "$CODA_LAYOUTS_DIR/${name}.yaml" ]; then
        layout_file="$CODA_LAYOUTS_DIR/${name}.yaml"
    elif [ -f "$_CODA_DIR/layouts/${name}.sh" ]; then
        layout_file="$_CODA_DIR/layouts/${name}.sh"
    elif [ -f "$_CODA_DIR/layouts/${name}.yaml" ]; then
        layout_file="$_CODA_DIR/layouts/${name}.yaml"
    fi

    if [ -z "$layout_file" ]; then
        echo "Layout '$name' not found."
        echo "Available: $(_coda_list_layouts | tr '\n' ' ')"
        echo "Create one: coda layout create $name"
        return 1
    fi

    echo "Layout: $name ($layout_file)"
    echo "---"
    cat "$layout_file"
}

_coda_layout_create() {
    local name="" snapshot=false use_yaml=false
    while [ $# -gt 0 ]; do
        case "$1" in
            --snapshot) snapshot=true; shift ;;
            --yaml)     use_yaml=true; shift ;;
            *) if [ -z "$name" ]; then name="$1"; fi; shift ;;
        esac
    done

    if [ -z "$name" ]; then
        echo "Usage: coda layout create <name> [--snapshot] [--yaml]"
        return 1
    fi

    mkdir -p "$CODA_LAYOUTS_DIR"

    local ext="sh"
    if [ "$use_yaml" = true ]; then
        ext="yaml"
    fi
    local layout_file="$CODA_LAYOUTS_DIR/${name}.${ext}"

    if [ -f "$CODA_LAYOUTS_DIR/${name}.sh" ] || [ -f "$CODA_LAYOUTS_DIR/${name}.yaml" ]; then
        echo "Layout already exists: $(ls "$CODA_LAYOUTS_DIR"/${name}.* 2>/dev/null)"
        return 1
    fi

    if [ "$snapshot" = true ]; then
        if [ "$use_yaml" = true ]; then
            _coda_layout_snapshot_yaml "$name" "$layout_file"
        else
            _coda_layout_snapshot "$name" "$layout_file"
        fi
        return $?
    fi

    if [ "$use_yaml" = true ]; then
        _coda_layout_create_yaml_template "$name" "$layout_file"
    else
        _coda_layout_create_template "$name" "$layout_file"
    fi
}

_coda_layout_create_template() {
    local name="$1" layout_file="$2"

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

_layout_init() {
    local session="\$1" dir="\$2" nvim_appname="\${3:-nvim}"
    local cols="\${COLUMNS:-200}" rows="\${LINES:-50}"

    tmux new-session -d -s "\$session" -x "\$cols" -y "\$rows" -c "\$dir" "opencode; exec \\\$SHELL"
}

_layout_spawn() {
    local session="\$1" dir="\$2" nvim_appname="\${3:-nvim}"
    tmux new-window -t "\$session" -c "\$dir" "opencode; exec \\\$SHELL"
}
TMPL

    echo "Created: $layout_file"
    echo "Edit it, then apply: coda layout $name"
}

_coda_layout_snapshot() {
    local name="$1" layout_file="$2"

    if [ -z "${TMUX:-}" ]; then
        echo "--snapshot requires being inside a tmux session."
        return 1
    fi

    if command -v coda-core &>/dev/null; then
        coda-core layout snapshot --name "$name" --output "$layout_file"
        return $?
    fi

    echo "coda-core not found. Install it to use --snapshot."
    echo "Falling back to blank template."
    _coda_layout_create_template "$name" "$layout_file"
}

_coda_layout_snapshot_yaml() {
    local name="$1" layout_file="$2"

    if [ -z "${TMUX:-}" ]; then
        echo "--snapshot requires being inside a tmux session."
        return 1
    fi

    if command -v coda-core &>/dev/null; then
        coda-core layout snapshot --name "$name" --output "$layout_file" --format yaml
        return $?
    fi

    echo "coda-core not found. Install it to use --snapshot --yaml."
    echo "Falling back to blank YAML template."
    _coda_layout_create_yaml_template "$name" "$layout_file"
}

_coda_layout_create_yaml_template() {
    local name="$1" layout_file="$2"

    cat > "$layout_file" <<TMPL
direction: horizontal
panes:
  - command: "opencode"
    title: OpenCode
    size: "50%"
  - size: "50%"
TMPL

    echo "Created: $layout_file"
    echo "Edit it, then apply: coda layout $name"
}

_coda_load_layout() {
    local name="$1"
    local layout_file="" layout_type="sh"

    if [ -f "$CODA_LAYOUTS_DIR/${name}.sh" ]; then
        layout_file="$CODA_LAYOUTS_DIR/${name}.sh"
    elif [ -f "$_CODA_DIR/layouts/${name}.sh" ]; then
        layout_file="$_CODA_DIR/layouts/${name}.sh"
    elif [ -f "$CODA_LAYOUTS_DIR/${name}.yaml" ]; then
        layout_file="$CODA_LAYOUTS_DIR/${name}.yaml"
        layout_type="yaml"
    elif [ -f "$_CODA_DIR/layouts/${name}.yaml" ]; then
        layout_file="$_CODA_DIR/layouts/${name}.yaml"
        layout_type="yaml"
    fi

    if [ -z "$layout_file" ]; then
        echo "Layout '$name' not found."
        echo "Available: $(_coda_list_layouts | tr '\n' ' ')"
        echo "Create one: coda layout create $name"
        return 1
    fi

    unset -f _layout_init _layout_spawn _layout_apply 2>/dev/null

    if [ "$layout_type" = "yaml" ]; then
        if ! command -v coda-core &>/dev/null; then
            echo "YAML layouts require coda-core. Install it first."
            return 1
        fi
        local rendered
        rendered=$(coda-core layout render --config "$layout_file" 2>&1)
        if [ $? -ne 0 ]; then
            echo "Failed to render YAML layout '$name': $rendered"
            return 1
        fi
        eval "$rendered"
    else
        # shellcheck source=/dev/null
        source "$layout_file"
    fi

    if ! declare -f _layout_init &>/dev/null && ! declare -f _layout_apply &>/dev/null; then
        echo "Layout '$name' is invalid: must define _layout_init() (or legacy _layout_apply())."
        echo "File: $layout_file"
        return 1
    fi

    return 0
}

_coda_list_layouts() {
    local seen="" name
    for f in "$CODA_LAYOUTS_DIR"/*.sh "$CODA_LAYOUTS_DIR"/*.yaml "$_CODA_DIR/layouts"/*.sh "$_CODA_DIR/layouts"/*.yaml; do
        [ -f "$f" ] || continue
        name=$(basename "$f")
        name="${name%.*}"
        case "$seen" in *"|$name|"*) continue ;; esac
        seen="$seen|$name|"
        echo "$name"
    done
}
