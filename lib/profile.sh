#!/usr/bin/env bash
#
# profile.sh — coda profile management (ls/create/show)
#

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
