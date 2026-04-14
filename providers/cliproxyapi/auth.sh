#!/usr/bin/env bash

_provider_auth() {
    if ! command -v opencode &>/dev/null; then
        echo "opencode not found. Re-run install.sh."
        return 1
    fi

    _coda_validate_api_key "$CLIPROXYAPI_API_KEY" || return 1

    local base_url
    base_url=$(_coda_normalize_url "$CLIPROXYAPI_BASE_URL") || {
        echo "Invalid CLIPROXYAPI_BASE_URL: $CLIPROXYAPI_BASE_URL"
        echo "Expected http://... or https://..."
        return 1
    }

    local config_path
    config_path=$(_coda_resolve_opencode_config_path)

    if command -v coda-core &>/dev/null; then
        CODA_API_KEY="${CLIPROXYAPI_API_KEY:-}" coda-core provider auth \
            --base-url "$base_url" \
            --config "$config_path"
        return $?
    fi

    echo "coda-core not found. Run install.sh to build it."
    return 1
}
