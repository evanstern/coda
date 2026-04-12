#!/usr/bin/env bash
#
# provider.sh — coda auth and provider management
#

_coda_auth() {
    local mode
    mode=$(_coda_provider_mode) || return 1

    case "$mode" in
        claude-auth) _coda_auth_claude ;;
        cliproxyapi) _coda_auth_cliproxyapi ;;
    esac
}

_coda_auth_claude() {
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

_coda_auth_cliproxyapi() {
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
        coda-core provider auth \
            --base-url "$base_url" \
            --config "$config_path" \
            --api-key "${CLIPROXYAPI_API_KEY:-}"
        return $?
    fi

    _coda_auth_cliproxyapi_fallback "$base_url" "$config_path"
}

_coda_auth_cliproxyapi_fallback() {
    local base_url="$1"
    local config_path="$2"

    if ! command -v jq &>/dev/null; then
        echo "jq not found. Install coda-core or jq."
        return 1
    fi

    local config_dir
    config_dir=$(dirname "$config_path")
    mkdir -p "$config_dir"

    local models_json=""
    if ! models_json=$(_coda_discover_cliproxyapi_models "$base_url"); then
        echo "Warning: could not discover models from ${base_url}/models"
        echo "Writing fallback CLIProxyAPI provider config instead."
        models_json=$(_coda_fallback_cliproxyapi_models)
    fi

    if ! _coda_merge_cliproxyapi_provider "$config_path" "$base_url" "$models_json"; then
        return 1
    fi

    echo "Updated OpenCode config: $config_path"
    echo "Provider mode: cliproxyapi"
    echo "Base URL: $base_url"
}

_coda_provider() {
    local subcmd="${1:-help}"

    case "$subcmd" in
        status) _coda_provider_status ;;
        ""|help)
            echo "Usage: coda provider <status>"
            ;;
        *)
            echo "Unknown provider subcommand: $subcmd"
            echo "Usage: coda provider <status>"
            return 1
            ;;
    esac
}

_coda_provider_status() {
    local mode
    mode=$(_coda_provider_mode) || return 1

    if command -v coda-core &>/dev/null; then
        local config_path
        config_path=$(_coda_resolve_opencode_config_path)
        coda-core provider status \
            --mode "$mode" \
            --config "$config_path" \
            --base-url "${CLIPROXYAPI_BASE_URL:-}" \
            --health-url "${CLIPROXYAPI_HEALTH_URL:-}" \
            --api-key "${CLIPROXYAPI_API_KEY:-}" \
            --has-opencode "$(command -v opencode &>/dev/null && echo true || echo false)"
        return $?
    fi

    _coda_provider_status_fallback "$mode"
}

_coda_provider_status_fallback() {
    local mode="$1"
    local config_path
    config_path=$(_coda_resolve_opencode_config_path)
    local provider_block_present="unknown"
    local provider_auth_present="unknown"

    echo "Provider mode: $mode"
    echo "OpenCode config: $config_path"

    if command -v opencode &>/dev/null; then
        echo "opencode: found"
    else
        echo "opencode: missing"
    fi

    if command -v jq &>/dev/null && [ -f "$config_path" ]; then
        if ! jq -e 'type == "object"' "$config_path" >/dev/null 2>&1; then
            echo "cliproxyapi provider block: config is not a valid JSON object ($config_path)"
        elif ! jq -e '(.provider | type) == "object"' "$config_path" >/dev/null 2>&1; then
            provider_block_present="no"
        elif jq -e '.provider.cliproxyapi != null' "$config_path" >/dev/null 2>&1; then
            provider_block_present="yes"
            if jq -e '.provider.cliproxyapi.options.apiKey? != null and .provider.cliproxyapi.options.apiKey != ""' "$config_path" >/dev/null 2>&1; then
                provider_auth_present="yes"
            else
                provider_auth_present="no"
            fi
        else
            provider_block_present="no"
        fi
    elif [ -f "$config_path" ]; then
        echo "cliproxyapi provider block: unknown (jq not found)"
    else
        echo "cliproxyapi provider block: config file not found (run: coda auth)"
    fi

    if [ "$mode" = "cliproxyapi" ]; then
        _coda_validate_api_key "$CLIPROXYAPI_API_KEY" || return 1

        local base_url health_url models_url

        base_url=$(_coda_normalize_url "$CLIPROXYAPI_BASE_URL") || {
            echo "Base URL: invalid ($CLIPROXYAPI_BASE_URL)"
            return 1
        }

        models_url="${base_url}/models"

        if [ -n "$CLIPROXYAPI_HEALTH_URL" ]; then
            health_url=$(_coda_normalize_url "$CLIPROXYAPI_HEALTH_URL") || {
                echo "Health URL: invalid ($CLIPROXYAPI_HEALTH_URL)"
                return 1
            }
        else
            health_url=""
        fi

        if [ "$provider_block_present" = "yes" ]; then
            if [ -n "$CLIPROXYAPI_API_KEY" ] && [ "$provider_auth_present" = "no" ]; then
                echo "cliproxyapi provider block: present, but missing proxy auth (re-run: coda auth)"
            else
                echo "cliproxyapi provider block: present (configuration ready; runtime not proven)"
            fi

            if [ "$provider_auth_present" = "yes" ]; then
                echo "Managed proxy auth: present in provider block"
            else
                echo "Managed proxy auth: absent from provider block"
            fi
        elif [ "$provider_block_present" = "no" ]; then
            echo "cliproxyapi provider block: absent (run: coda auth)"
        fi

        if [ -n "$CLIPROXYAPI_API_KEY" ]; then
            echo "Proxy API key env: set in CLIPROXYAPI_API_KEY"
        else
            echo "Proxy API key env: not set (optional)"
        fi

        _coda_print_url_status "Base URL" "$base_url"
        if [ -n "$health_url" ]; then
            _coda_print_url_status "Health URL" "$health_url"
        else
            echo "Health URL: skipped (CLIPROXYAPI_HEALTH_URL not set)"
        fi
        _coda_print_models_status "$models_url"
        echo "Readiness note: config and HTTP probes are not end-to-end runtime proof."
    fi
}

_coda_provider_mode() {
    case "${CODA_PROVIDER_MODE:-claude-auth}" in
        ""|claude-auth)
            echo "claude-auth"
            ;;
        cliproxyapi)
            echo "cliproxyapi"
            ;;
        *)
            echo "Invalid CODA_PROVIDER_MODE: ${CODA_PROVIDER_MODE}" >&2
            echo "Expected: claude-auth or cliproxyapi" >&2
            return 1
            ;;
    esac
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

_coda_fallback_cliproxyapi_models() {
    cat <<'EOF'
{
  "gpt-4o": {
    "name": "gpt-4o"
  },
  "gpt-4.1": {
    "name": "gpt-4.1"
  },
  "claude-opus-4-6": {
    "name": "claude-opus-4-6"
  },
  "claude-haiku-4-5-20251001": {
    "name": "claude-haiku-4-5-20251001"
  },
  "claude-sonnet-4-5-20250929": {
    "name": "claude-sonnet-4-5-20250929"
  }
}
EOF
}

_coda_discover_cliproxyapi_models() {
    local base_url="$1"

    if ! command -v curl &>/dev/null; then
        return 1
    fi

    local response
    response=$(_coda_fetch_cliproxyapi_models_response "${base_url}/models") || return 1

    local http_code models_json
    http_code=${response##*$'\n'}
    models_json=${response%$'\n'*}

    if [ "$http_code" = "000" ] || [ "$http_code" -lt 200 ] || [ "$http_code" -ge 300 ]; then
        return 1
    fi

    local normalized
    normalized=$(printf '%s' "$models_json" | jq -c '
        if ((.data? | type) == "array") then
            reduce .data[] as $model ({};
                if ($model | type) == "object" and ($model.id // "") != "" then
                    ($model.id) as $id
                    | . + { ($id): { name: ($model.name // $id) } }
                elif ($model | type) == "string" and $model != "" then
                    . + { ($model): { name: ($model) } }
                else
                    .
                end
            )
        else
            {}
        end
    ' 2>/dev/null) || return 1

    if [ "$normalized" = "{}" ]; then
        return 1
    fi

    echo "$normalized"
}

_coda_merge_cliproxyapi_provider() {
    local config_path="$1"
    local base_url="$2"
    local models_json="$3"
    local api_key="${CLIPROXYAPI_API_KEY:-}"
    local config_dir
    config_dir=$(dirname "$config_path")

    local input_json='{}'
    if [ -f "$config_path" ]; then
        if ! jq -e 'type == "object"' "$config_path" >/dev/null 2>&1; then
            echo "Existing OpenCode config is not valid JSON object: $config_path"
            return 1
        fi
        input_json=$(jq -c '.' "$config_path") || return 1
    fi

    local tmp_file
    tmp_file=$(mktemp "$config_dir/opencode.json.XXXXXX") || return 1

    if ! printf '%s' "$input_json" | jq --arg base_url "$base_url" --arg api_key "$api_key" --argjson models "$models_json" '
        .provider = (if (.provider | type) == "object" then .provider else {} end)
        | .provider.cliproxyapi = {
            npm: "@ai-sdk/openai-compatible",
            name: "CLIProxyAPI",
            options: ({
                baseURL: $base_url
            } + if $api_key != "" then {
                apiKey: $api_key
            } else {} end),
            models: $models
        }
    ' > "$tmp_file"; then
        rm -f "$tmp_file"
        echo "Failed to merge CLIProxyAPI provider config."
        return 1
    fi

    mv "$tmp_file" "$config_path"
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
