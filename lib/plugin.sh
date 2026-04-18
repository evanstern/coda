#!/usr/bin/env bash
#
# plugin.sh — coda plugin system
#
# Plugins are git repos cloned to ~/.config/coda/plugins/<name>/.
# Each plugin has a plugin.json manifest describing what it provides:
# commands, hooks, providers, and notifications.
#
# User config lives in ~/.config/coda/config.json.

CODA_PLUGINS_DIR="${CODA_PLUGINS_DIR:-$HOME/.config/coda/plugins}"

# Global state for loaded plugins
declare -gA _CODA_PLUGIN_COMMANDS 2>/dev/null || true
declare -gA _CODA_PLUGIN_HOOKS 2>/dev/null || true
declare -gA _CODA_PLUGIN_PROVIDERS 2>/dev/null || true
declare -ga _CODA_PLUGIN_NOTIFICATIONS 2>/dev/null || true

_coda_plugin_dir() {
    echo "$CODA_PLUGINS_DIR"
}

_coda_semver_parse() {
    local ver="$1"
    local major minor patch
    IFS='.' read -r major minor patch <<< "${ver%%-*}"
    echo "${major:-0} ${minor:-0} ${patch:-0}"
}

_coda_semver_compare() {
    local a_major a_minor a_patch b_major b_minor b_patch
    read -r a_major a_minor a_patch <<< "$(_coda_semver_parse "$1")"
    read -r b_major b_minor b_patch <<< "$(_coda_semver_parse "$2")"
    if (( a_major != b_major )); then
        (( a_major > b_major )) && echo 1 || echo -1
    elif (( a_minor != b_minor )); then
        (( a_minor > b_minor )) && echo 1 || echo -1
    elif (( a_patch != b_patch )); then
        (( a_patch > b_patch )) && echo 1 || echo -1
    else
        echo 0
    fi
}

_coda_semver_satisfies() {
    local version="$1" constraint="$2"
    [ -z "$constraint" ] && return 0

    constraint=$(echo "$constraint" | sed -E 's/(>=|<=|>|<)([0-9])/\1 \2/g')

    local part prev_op=""
    for part in $constraint; do
        if [[ "$part" == ^* ]]; then
            local base="${part#^}"
            local base_major base_minor_c
            read -r base_major base_minor_c _ <<< "$(_coda_semver_parse "$base")"
            local ceiling
            if (( base_major == 0 )); then
                ceiling="0.$((base_minor_c + 1)).0"
            else
                ceiling="$((base_major + 1)).0.0"
            fi
            [[ $(_coda_semver_compare "$version" "$base") -ge 0 ]] || return 1
            [[ $(_coda_semver_compare "$version" "$ceiling") -lt 0 ]] || return 1
        elif [[ "$part" == ~* ]]; then
            local base="${part#\~}"
            local base_major base_minor
            read -r base_major base_minor _ <<< "$(_coda_semver_parse "$base")"
            local next_minor=${base_major}.$((base_minor + 1)).0
            [[ $(_coda_semver_compare "$version" "$base") -ge 0 ]] || return 1
            [[ $(_coda_semver_compare "$version" "$next_minor") -lt 0 ]] || return 1
        elif [[ "$part" == ">=" || "$part" == "<" || "$part" == "<=" || "$part" == ">" ]]; then
            prev_op="$part"
            continue
        elif [[ "$prev_op" == ">=" ]]; then
            [[ $(_coda_semver_compare "$version" "$part") -ge 0 ]] || return 1
        elif [[ "$prev_op" == ">" ]]; then
            [[ $(_coda_semver_compare "$version" "$part") -gt 0 ]] || return 1
        elif [[ "$prev_op" == "<" ]]; then
            [[ $(_coda_semver_compare "$version" "$part") -lt 0 ]] || return 1
        elif [[ "$prev_op" == "<=" ]]; then
            [[ $(_coda_semver_compare "$version" "$part") -le 0 ]] || return 1
        else
            [[ $(_coda_semver_compare "$version" "$part") -eq 0 ]] || return 1
        fi
        prev_op=""
    done
    return 0
}

_coda_plugin_config_path() {
    echo "${CODA_CONFIG_PATH:-${HOME}/.config/coda/config.json}"
}

_coda_plugin_load_all() {
    # Skip if jq is not available
    command -v jq &>/dev/null || return 0

    local config_path
    config_path=$(_coda_plugin_config_path)
    [ -f "$config_path" ] || return 0

    # Reset global state
    _CODA_PLUGIN_COMMANDS=()
    _CODA_PLUGIN_HOOKS=()
    _CODA_PLUGIN_PROVIDERS=()
    _CODA_PLUGIN_NOTIFICATIONS=()

    local plugins_dir
    plugins_dir=$(_coda_plugin_dir)

    # Read each plugin URL from config
    local urls
    urls=$(jq -r '.plugins // {} | keys[]' "$config_path" 2>/dev/null) || return 0

    while IFS= read -r url; do
        [ -z "$url" ] && continue

        # Check if enabled
        local enabled
        enabled=$(jq -r --arg u "$url" '.plugins[$u].enabled // true' "$config_path" 2>/dev/null)
        [ "$enabled" = "true" ] || continue

        # Derive plugin name from URL
        local name
        name=$(_coda_plugin_name_from_url "$url")
        [ -z "$name" ] && continue

        local plugin_dir="$plugins_dir/$name"
        [ -d "$plugin_dir" ] || continue

        # Export plugin options as environment variables
        local options
        options=$(jq -r --arg u "$url" '.plugins[$u].options // {} | to_entries[] | "\(.key)=\(.value)"' "$config_path" 2>/dev/null)
        while IFS='=' read -r key val; do
            [ -z "$key" ] && continue
            export "$key=$val"
        done <<< "$options"

        _coda_plugin_load "$name" "$plugin_dir"
    done <<< "$urls"
}

_coda_plugin_load() {
    local name="$1" dir="$2"

    local manifest="$dir/plugin.json"
    [ -f "$manifest" ] || return 0

    local coda_constraint
    coda_constraint=$(jq -r '.coda // empty' "$manifest" 2>/dev/null)
    if [ -n "$coda_constraint" ] && ! _coda_semver_satisfies "${CODA_VERSION:-0.0.0}" "$coda_constraint"; then
        echo "warning: plugin '$name' requires coda $coda_constraint (have ${CODA_VERSION:-0.0.0}), skipping" >&2
        return 0
    fi

    local sys_deps
    sys_deps=$(jq -r '.dependencies.system // [] | .[]' "$manifest" 2>/dev/null)
    while IFS= read -r dep; do
        [ -z "$dep" ] && continue
        if ! command -v "$dep" &>/dev/null; then
            echo "warning: plugin '$name' requires '$dep' which is not installed, skipping" >&2
            return 0
        fi
    done <<< "$sys_deps"

    local go_dir
    go_dir=$(jq -r '.dependencies.go // empty' "$manifest" 2>/dev/null)
    if [ -n "$go_dir" ]; then
        local bin_name
        bin_name=$(basename "$go_dir")
        bin_name="${bin_name%/}"
        if [ ! -f "$HOME/.local/bin/$bin_name" ]; then
            echo "warning: plugin '$name' binary '$bin_name' not built, skipping (run: coda plugin update $name)" >&2
            return 0
        fi
    fi

    # Register commands
    local cmds
    cmds=$(jq -r '.provides.commands // {} | to_entries[] | "\(.key)\t\(.value.handler)\t\(.value.function)"' "$manifest" 2>/dev/null)
    while IFS=$'\t' read -r cmd_name handler func; do
        [ -z "$cmd_name" ] && continue
        _CODA_PLUGIN_COMMANDS["$cmd_name"]="$dir/$handler:$func:$dir"
    done <<< "$cmds"

    # Register hooks
    local hooks
    hooks=$(jq -r '.provides.hooks // {} | to_entries[] | "\(.key)\t\(.value | if type == "array" then join("|") else . end)"' "$manifest" 2>/dev/null)
    while IFS=$'\t' read -r event globs; do
        [ -z "$event" ] && continue
        local prefixed=""
        local _hg
        IFS='|' read -ra _hg_parts <<< "$globs"
        for _hg in "${_hg_parts[@]}"; do
            [ -n "$prefixed" ] && prefixed+="|"
            prefixed+="$dir/$_hg"
        done
        _CODA_PLUGIN_HOOKS["$event:$name"]="$prefixed"
    done <<< "$hooks"

    # Register providers
    local providers
    providers=$(jq -r '.provides.providers // {} | to_entries[] | "\(.key)\t\(.value)"' "$manifest" 2>/dev/null)
    while IFS=$'\t' read -r prov_name prov_dir; do
        [ -z "$prov_name" ] && continue
        _CODA_PLUGIN_PROVIDERS["$prov_name"]="$dir/$prov_dir"
    done <<< "$providers"

    # Register notifications
    local notifs
    notifs=$(jq -r '.provides.notifications // [] | .[]' "$manifest" 2>/dev/null)
    while IFS= read -r glob; do
        [ -z "$glob" ] && continue
        _CODA_PLUGIN_NOTIFICATIONS+=("$dir/$glob")
    done <<< "$notifs"

    # Source init script (eager load at shell init, not lazy)
    local init_script
    init_script=$(jq -r '.init // empty' "$manifest" 2>/dev/null)
    if [ -n "$init_script" ] && [ -f "$dir/$init_script" ]; then
        # shellcheck source=/dev/null
        source "$dir/$init_script"
    fi
}

_coda_plugin_name_from_url() {
    local url="$1"
    # git@github.com:user/coda-github.git -> coda-github
    # https://github.com/user/coda-github.git -> coda-github
    local name
    name=$(basename "$url")
    name="${name%.git}"
    echo "$name"
}

_coda_plugin_has_command() {
    [[ -n "${_CODA_PLUGIN_COMMANDS[$1]+x}" ]]
}

_coda_plugin_dispatch() {
    local subcmd="$1"
    shift

    if ! _coda_plugin_has_command "$subcmd"; then
        return 127
    fi

    local entry="${_CODA_PLUGIN_COMMANDS[$subcmd]}"
    local handler func plugin_dir
    IFS=':' read -r handler func plugin_dir <<< "$entry"

    if [ ! -f "$handler" ]; then
        echo "Plugin handler not found: $handler" >&2
        return 1
    fi

    # shellcheck source=/dev/null
    source "$handler"

    if ! declare -f "$func" &>/dev/null; then
        echo "Plugin function not found: $func" >&2
        return 1
    fi

    "$func" "$@"
}

_coda_plugin_check_installed() {
    command -v jq &>/dev/null || return 0

    local config_path
    config_path=$(_coda_plugin_config_path)
    [ -f "$config_path" ] || return 0

    local plugins_dir
    plugins_dir=$(_coda_plugin_dir)
    local missing=()

    local urls
    urls=$(jq -r '.plugins // {} | keys[]' "$config_path" 2>/dev/null) || return 0

    while IFS= read -r url; do
        [ -z "$url" ] && continue
        local enabled
        enabled=$(jq -r --arg u "$url" '.plugins[$u].enabled // true' "$config_path" 2>/dev/null)
        [ "$enabled" = "true" ] || continue

        local name
        name=$(_coda_plugin_name_from_url "$url")
        if [ ! -d "$plugins_dir/$name" ]; then
            missing+=("$url")
        fi
    done <<< "$urls"

    if [ ${#missing[@]} -gt 0 ]; then
        echo "The following plugins are configured but not installed:"
        for url in "${missing[@]}"; do
            echo "  $url"
        done
        echo ""
        read -r -p "Install them now? [y/N] " answer
        if [[ "$answer" =~ ^[Yy] ]]; then
            for url in "${missing[@]}"; do
                _coda_plugin_install "$url"
            done
        fi
    fi
}

_coda_plugin_install() {
    local url="$1"

    if ! command -v jq &>/dev/null; then
        echo "jq is required for plugin management. Install it with: sudo apt install jq"
        return 1
    fi

    if ! command -v git &>/dev/null; then
        echo "git is required for plugin management."
        return 1
    fi

    local name
    name=$(_coda_plugin_name_from_url "$url")
    if [ -z "$name" ]; then
        echo "Could not determine plugin name from: $url"
        return 1
    fi

    local plugins_dir
    plugins_dir=$(_coda_plugin_dir)
    local plugin_dir="$plugins_dir/$name"

    if [ -d "$plugin_dir" ]; then
        echo "Plugin '$name' is already installed at $plugin_dir"
        return 0
    fi

    echo "Installing plugin: $name"
    mkdir -p "$plugins_dir"

    if ! git clone "$url" "$plugin_dir" 2>&1; then
        echo "Failed to clone $url"
        rm -rf "$plugin_dir"
        return 1
    fi

    local manifest="$plugin_dir/plugin.json"
    if [ ! -f "$manifest" ]; then
        echo "Warning: Plugin '$name' has no plugin.json manifest."
    fi

    if [ -f "$manifest" ]; then
        local coda_constraint
        coda_constraint=$(jq -r '.coda // empty' "$manifest" 2>/dev/null)
        if [ -n "$coda_constraint" ] && ! _coda_semver_satisfies "${CODA_VERSION:-0.0.0}" "$coda_constraint"; then
            echo "Warning: Plugin '$name' requires coda $coda_constraint (you have ${CODA_VERSION:-0.0.0})"
            read -r -p "Install anyway? [y/N] " answer
            if [[ ! "$answer" =~ ^[Yy] ]]; then
                rm -rf "$plugin_dir"
                return 1
            fi
        fi
        _coda_plugin_install_deps "$plugin_dir"

        local install_script
        install_script=$(jq -r '.install // empty' "$manifest" 2>/dev/null)
        if [ -n "$install_script" ] && [ -f "$plugin_dir/$install_script" ]; then
            echo "Running install script: $install_script"
            (cd "$plugin_dir" && bash "$install_script")
        fi
    fi

    # Add to config if not already there
    _coda_plugin_config_add "$url"

    echo "Plugin '$name' installed successfully."
}

_coda_plugin_install_deps() {
    local plugin_dir="$1"
    local manifest="$plugin_dir/plugin.json"
    [ -f "$manifest" ] || return 0

    local missing_deps=()

    local sys_deps
    sys_deps=$(jq -r '.dependencies.system // [] | .[]' "$manifest" 2>/dev/null)
    while IFS= read -r dep; do
        [ -z "$dep" ] && continue
        if command -v "$dep" &>/dev/null; then
            echo "  $dep: found"
        else
            echo "  $dep: MISSING"
            missing_deps+=("$dep")
        fi
    done <<< "$sys_deps"

    local go_dir
    go_dir=$(jq -r '.dependencies.go // empty' "$manifest" 2>/dev/null)
    if [ -n "$go_dir" ] && [ -d "$plugin_dir/$go_dir" ]; then
        if ! command -v go &>/dev/null; then
            echo "  go: MISSING (needed to build $go_dir)"
            missing_deps+=("go")
        else
            echo "Building Go binary: $go_dir"
            mkdir -p "$HOME/.local/bin"
            (cd "$plugin_dir" && GOBIN="$HOME/.local/bin" go install "./$go_dir")
        fi
    fi

    local npm_deps
    npm_deps=$(jq -r '.dependencies.npm // [] | .[]' "$manifest" 2>/dev/null)
    while IFS= read -r dep; do
        [ -z "$dep" ] && continue
        if ! command -v npm &>/dev/null; then
            echo "  npm: MISSING (needed to install $dep)"
            missing_deps+=("npm")
        else
            echo "Installing npm package: $dep"
            npm install -g "$dep" 2>&1
        fi
    done <<< "$npm_deps"

    if [ ${#missing_deps[@]} -gt 0 ]; then
        echo ""
        echo "Missing dependencies: ${missing_deps[*]}"
        echo "Plugin will be disabled until these are installed."
        return 1
    fi
}

_coda_plugin_remove() {
    local name="$1"

    if [ -z "$name" ]; then
        echo "Usage: coda plugin remove <name>"
        return 1
    fi

    local plugins_dir
    plugins_dir=$(_coda_plugin_dir)
    local plugin_dir="$plugins_dir/$name"

    if [ ! -d "$plugin_dir" ]; then
        echo "Plugin '$name' is not installed."
        return 1
    fi

    echo "Removing plugin: $name"
    rm -rf "$plugin_dir"

    # Remove from config
    _coda_plugin_config_remove "$name"

    echo "Plugin '$name' removed."
}

_coda_plugin_update() {
    local name="$1"
    local plugins_dir
    plugins_dir=$(_coda_plugin_dir)

    if [ -n "$name" ]; then
        local plugin_dir="$plugins_dir/$name"
        if [ ! -d "$plugin_dir" ]; then
            echo "Plugin '$name' is not installed."
            return 1
        fi
        echo "Updating plugin: $name"
        (cd "$plugin_dir" && git pull) 2>&1
        _coda_plugin_install_deps "$plugin_dir"
        echo "Plugin '$name' updated."
    else
        # Update all installed plugins
        local found=0
        for plugin_dir in "$plugins_dir"/*/; do
            [ -d "$plugin_dir" ] || continue
            found=1
            name=$(basename "$plugin_dir")
            echo "Updating plugin: $name"
            (cd "$plugin_dir" && git pull) 2>&1
            _coda_plugin_install_deps "$plugin_dir"
        done
        if [ "$found" -eq 0 ]; then
            echo "No plugins installed."
        else
            echo "All plugins updated."
        fi
    fi
}

_coda_plugin_ls() {
    local plugins_dir
    plugins_dir=$(_coda_plugin_dir)

    if [ ! -d "$plugins_dir" ] || [ -z "$(ls -A "$plugins_dir" 2>/dev/null)" ]; then
        echo "No plugins installed."
        echo "Install one with: coda plugin install <git-url>"
        return 0
    fi

    echo "Installed plugins:"
    for plugin_dir in "$plugins_dir"/*/; do
        [ -d "$plugin_dir" ] || continue
        local name
        name=$(basename "$plugin_dir")
        local version="" description=""
        local manifest="$plugin_dir/plugin.json"
        if [ -f "$manifest" ] && command -v jq &>/dev/null; then
            version=$(jq -r '.version // ""' "$manifest" 2>/dev/null)
            description=$(jq -r '.description // ""' "$manifest" 2>/dev/null)
        fi
        local info="$name"
        [ -n "$version" ] && info="$info v$version"
        [ -n "$description" ] && info="$info - $description"
        echo "  $info"
    done
}

_coda_plugin_config_add() {
    local url="$1"
    local config_path
    config_path=$(_coda_plugin_config_path)

    mkdir -p "$(dirname "$config_path")"

    if [ ! -f "$config_path" ]; then
        printf '{"plugins":{"%s":{"enabled":true}}}' "$url" | jq . > "$config_path"
        return
    fi

    # Check if already in config
    local exists
    exists=$(jq -r --arg u "$url" '.plugins[$u] // empty' "$config_path" 2>/dev/null)
    if [ -n "$exists" ]; then
        return 0
    fi

    local tmp
    tmp=$(mktemp)
    jq --arg u "$url" '.plugins[$u] = {"enabled": true}' "$config_path" > "$tmp" && mv "$tmp" "$config_path"
}

_coda_plugin_config_remove() {
    local name="$1"
    local config_path
    config_path=$(_coda_plugin_config_path)
    [ -f "$config_path" ] || return 0

    # Find the URL that matches this plugin name
    local urls
    urls=$(jq -r '.plugins // {} | keys[]' "$config_path" 2>/dev/null) || return 0

    while IFS= read -r url; do
        [ -z "$url" ] && continue
        local url_name
        url_name=$(_coda_plugin_name_from_url "$url")
        if [ "$url_name" = "$name" ]; then
            local tmp
            tmp=$(mktemp)
            jq --arg u "$url" 'del(.plugins[$u])' "$config_path" > "$tmp" && mv "$tmp" "$config_path"
            return 0
        fi
    done <<< "$urls"
}

_coda_plugin_cmd() {
    local subcmd="${1:-}"
    shift 2>/dev/null || true

    case "$subcmd" in
        install)  _coda_plugin_install "$@" ;;
        remove)   _coda_plugin_remove "$@" ;;
        update)   _coda_plugin_update "$@" ;;
        ls|list)  _coda_plugin_ls ;;
        ""|help)
            cat <<'EOF'
Usage: coda plugin <install|remove|update|ls>

  coda plugin install <git-url>   Clone and install a plugin
  coda plugin remove <name>       Remove an installed plugin
  coda plugin update [name]       Update plugin(s) via git pull
  coda plugin ls                  List installed plugins
EOF
            ;;
        *)  echo "Unknown plugin subcommand: $subcmd"
            echo "Usage: coda plugin <install|remove|update|ls>"
            return 1
            ;;
    esac
}
