#!/usr/bin/env bash
#
# provider.sh — coda auth and provider management
#
# Providers live in directories:
#   $_CODA_DIR/providers/<mode>/     (builtin)
#   $CODA_PROVIDERS_DIR/<mode>/      (user, ~/.config/coda/providers/)
#
# Each provider directory contains:
#   auth.sh    — defines _provider_auth()
#   status.sh  — defines _provider_status()

CODA_PROVIDERS_DIR="${CODA_PROVIDERS_DIR:-$HOME/.config/coda/providers}"

_coda_auth() {
    local mode
    mode=$(_coda_provider_mode) || return 1

    _coda_load_provider "$mode" auth || return 1

    if ! declare -f _provider_auth &>/dev/null; then
        echo "Provider '$mode' does not define _provider_auth()."
        return 1
    fi

    _provider_auth
}

_coda_provider() {
    local subcmd="${1:-help}"

    case "$subcmd" in
        status) _coda_provider_status ;;
        ls)     _coda_provider_ls ;;
        ""|help)
            echo "Usage: coda provider <status|ls>"
            ;;
        *)
            echo "Unknown provider subcommand: $subcmd"
            echo "Usage: coda provider <status|ls>"
            return 1
            ;;
    esac
}

_coda_provider_status() {
    local mode
    mode=$(_coda_provider_mode) || return 1

    _coda_load_provider "$mode" status || return 1

    if ! declare -f _provider_status &>/dev/null; then
        echo "Provider '$mode' does not define _provider_status()."
        return 1
    fi

    _provider_status
}

_coda_provider_ls() {
    echo "Available providers:"
    local seen="" name source
    for d in "$CODA_PROVIDERS_DIR"/*/  "$_CODA_DIR/providers"/*/; do
        [ -d "$d" ] || continue
        name=$(basename "$d")
        case "$seen" in *"|$name|"*) continue ;; esac
        seen="$seen|$name|"
        if [ -d "$CODA_PROVIDERS_DIR/$name" ]; then
            source="user"
        else
            source="builtin"
        fi
        local active=""
        if [ "$name" = "${CODA_PROVIDER_MODE:-claude-auth}" ]; then
            active=" (active)"
        fi
        echo "  $name  ($source)$active"
    done
}

_coda_provider_mode() {
    local mode="${CODA_PROVIDER_MODE:-claude-auth}"

    if _coda_find_provider_dir "$mode" >/dev/null; then
        echo "$mode"
        return 0
    fi

    echo "Unknown provider: $mode" >&2
    echo "Available: $(_coda_list_providers | tr '\n' ' ')" >&2
    echo "Providers live in: $CODA_PROVIDERS_DIR/" >&2
    return 1
}

_coda_find_provider_dir() {
    local mode="$1"
    if [ -d "$CODA_PROVIDERS_DIR/$mode" ]; then
        echo "$CODA_PROVIDERS_DIR/$mode"
    elif [ -d "$_CODA_DIR/providers/$mode" ]; then
        echo "$_CODA_DIR/providers/$mode"
    else
        return 1
    fi
}

_coda_load_provider() {
    local mode="$1" component="$2"

    local provider_dir
    provider_dir=$(_coda_find_provider_dir "$mode") || {
        echo "Provider '$mode' not found."
        echo "Available: $(_coda_list_providers | tr '\n' ' ')"
        echo "Providers live in: $CODA_PROVIDERS_DIR/"
        return 1
    }

    local component_file="$provider_dir/${component}.sh"
    if [ ! -f "$component_file" ]; then
        echo "Provider '$mode' is missing ${component}.sh"
        echo "Expected: $component_file"
        return 1
    fi

    unset -f _provider_auth _provider_status 2>/dev/null

    # shellcheck source=/dev/null
    source "$component_file"
}

_coda_list_providers() {
    local seen="" name
    for d in "$CODA_PROVIDERS_DIR"/*/ "$_CODA_DIR/providers"/*/; do
        [ -d "$d" ] || continue
        name=$(basename "$d")
        case "$seen" in *"|$name|"*) continue ;; esac
        seen="$seen|$name|"
        echo "$name"
    done
}

_coda_print_models_status() {
    local models_url="$1"

    if ! command -v curl &>/dev/null; then
        echo "Models endpoint: unavailable (curl not found)"
        return 0
    fi

    if ! command -v jq &>/dev/null; then
        echo "Models endpoint: unavailable (jq not found)"
        return 0
    fi

    local response
    if ! response=$(_coda_fetch_cliproxyapi_models_response "$models_url"); then
        echo "Models endpoint: unreachable ($models_url)"
        return 0
    fi

    local http_code response_body
    http_code=${response##*$'\n'}
    response_body=${response%$'\n'*}

    if [ "$http_code" = "000" ]; then
        echo "Models endpoint: unreachable ($models_url)"
        return 0
    fi

    if [ "$http_code" = "401" ] || [ "$http_code" = "403" ]; then
        if [ -n "$CLIPROXYAPI_API_KEY" ]; then
            echo "Models endpoint: unauthorized ($models_url, HTTP $http_code; configured proxy API key was rejected)"
        else
            echo "Models endpoint: unauthorized ($models_url, HTTP $http_code; set CLIPROXYAPI_API_KEY if your proxy requires auth)"
        fi
        return 0
    fi

    if [ "$http_code" -lt 200 ] || [ "$http_code" -ge 300 ]; then
        echo "Models endpoint: reachable with non-2xx response ($models_url, HTTP $http_code)"
        return 0
    fi

    local count
    count=$(printf '%s' "$response_body" | jq -r 'if ((.data? | type) == "array") then (.data | length) else 0 end' 2>/dev/null)
    if [ -n "$count" ] && [ "$count" -gt 0 ] 2>/dev/null; then
        echo "Models endpoint: reachable ($models_url, HTTP $http_code, $count models)"
    else
        echo "Models endpoint: reachable but returned no usable models ($models_url, HTTP $http_code)"
    fi
}

_coda_fetch_cliproxyapi_models_response() {
    local models_url="$1"

    if [ -n "$CLIPROXYAPI_API_KEY" ]; then
        local header_file
        header_file=$(mktemp) || return 1
        printf 'Authorization: Bearer %s' "$CLIPROXYAPI_API_KEY" > "$header_file"
        curl --silent --show-error --max-time 5 \
            -H @"$header_file" \
            --write-out '\n%{http_code}' "$models_url" 2>/dev/null
        local rc=$?
        rm -f "$header_file"
        return $rc
    else
        curl --silent --show-error --max-time 5 \
            --write-out '\n%{http_code}' "$models_url" 2>/dev/null
    fi
}
