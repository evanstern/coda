#!/usr/bin/env bash
#
# helpers.sh — shared utility functions for coda
#

_coda_sanitize_session_name() {
    printf '%s' "$1" | tr '.' '-'
}

_coda_detect_default_branch() {
    local project_dir="$1"
    local ref
    ref=$(git -C "$project_dir/.bare" symbolic-ref HEAD 2>/dev/null)
    if [ -n "$ref" ]; then
        printf '%s' "${ref#refs/heads/}"
    else
        printf '%s' "$DEFAULT_BRANCH"
    fi
}

_coda_find_project_root() {
    _coda_find_project_root_from "$PWD"
}

_coda_find_project_root_from() {
    local dir="${1:-$PWD}"
    while [ "$dir" != "/" ]; do
        if [ -d "$dir/.bare" ] && [ -f "$dir/.git" ] && grep -q "gitdir: ./.bare" "$dir/.git" 2>/dev/null; then
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

_coda_load_project_config() {
    local project_root="${1:-}"
    [ -z "$project_root" ] && return 0
    local config_file="$project_root/.coda.env"
    if [ -f "$config_file" ]; then
        set -a; source "$config_file"; set +a
    fi
}

_coda_resolve_effective_config() {
    local project_root="${1:-}" profile_name="${2:-}" flag_layout="${3:-}"
    local layout nvim_appname

    layout="$DEFAULT_LAYOUT"
    nvim_appname="$DEFAULT_NVIM_APPNAME"

    if [ -n "$project_root" ] && [ -f "$project_root/.coda.env" ]; then
        local _proj_layout="" _proj_nvim=""
        _proj_layout=$(. "$project_root/.coda.env" 2>/dev/null && printf '%s' "${CODA_LAYOUT:-}")
        _proj_nvim=$(. "$project_root/.coda.env" 2>/dev/null && printf '%s' "${CODA_NVIM_APPNAME:-}")
        [ -n "$_proj_layout" ] && layout="$_proj_layout"
        [ -n "$_proj_nvim" ] && nvim_appname="$_proj_nvim"
    fi

    if [ -n "$profile_name" ]; then
        local profile_file
        profile_file=$(_coda_resolve_profile "$profile_name")
        if [ -n "$profile_file" ]; then
            local _prof_layout="" _prof_nvim=""
            _prof_layout=$(. "$profile_file" 2>/dev/null && printf '%s' "${CODA_LAYOUT:-}")
            _prof_nvim=$(. "$profile_file" 2>/dev/null && printf '%s' "${CODA_NVIM_APPNAME:-}")
            [ -n "$_prof_layout" ] && layout="$_prof_layout"
            [ -n "$_prof_nvim" ] && nvim_appname="$_prof_nvim"
        fi
    fi

    [ -n "${CODA_LAYOUT:-}" ] && layout="$CODA_LAYOUT"
    [ -n "${CODA_NVIM_APPNAME:-}" ] && nvim_appname="$CODA_NVIM_APPNAME"

    [ -n "$flag_layout" ] && layout="$flag_layout"

    printf '%s\n%s\n' "$layout" "$nvim_appname"
}

_coda_expand_path() {
    case "$1" in
        "~") printf '%s\n' "$HOME" ;;
        "~/"*) printf '%s/%s\n' "$HOME" "${1#\~/}" ;;
        *) printf '%s\n' "$1" ;;
    esac
}

_coda_resolve_opencode_config_path() {
    if [ -n "${CODA_OPENCODE_CONFIG_PATH:-}" ]; then
        _coda_expand_path "$CODA_OPENCODE_CONFIG_PATH"
    else
        echo "$HOME/.config/opencode/opencode.json"
    fi
}

_coda_validate_api_key() {
    local key="$1"
    if [ -z "$key" ]; then
        return 0
    fi
    case "$key" in
        *$'\r'*|*$'\n'*)
            echo "CLIPROXYAPI_API_KEY contains CR/LF characters; rejected to prevent header injection." >&2
            return 1
            ;;
    esac
}

_coda_normalize_url() {
    local url="${1:-}"
    url="${url%/}"

    case "$url" in
        http://*|https://*)
            echo "$url"
            ;;
        *)
            return 1
            ;;
    esac
}

_coda_probe_url() {
    local url="$1"

    if ! command -v curl &>/dev/null; then
        echo "curl not found"
        return 2
    fi

    curl --silent --show-error --output /dev/null --write-out '%{http_code}' --max-time 5 "$url" 2>/dev/null
}

_coda_print_url_status() {
    local label="$1"
    local url="$2"
    local code

    code=$(_coda_probe_url "$url")
    case "$?" in
        0)
            if [ "$code" = "000" ]; then
                echo "$label: unreachable ($url)"
            elif [ "$code" -ge 200 ] && [ "$code" -lt 300 ]; then
                echo "$label: reachable ($url, HTTP $code)"
            else
                echo "$label: reachable with non-2xx response ($url, HTTP $code)"
            fi
            ;;
        2)
            echo "$label: unavailable (curl not found)"
            ;;
        *)
            echo "$label: unreachable ($url)"
            ;;
    esac
}
