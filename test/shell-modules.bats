#!/usr/bin/env bats

# Shell integration tests for the coda module split.
# Validates that shell-functions.sh loads all modules correctly
# and all expected functions are available.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

setup() {
    # Source in a clean environment, skip auto-attach
    export AUTO_ATTACH_TMUX=false
    export SSH_CONNECTION=""
    export CODA_SKIP_ENV=true
    source "$SCRIPT_DIR/shell-functions.sh"
}

# --- Module loading ---

@test "shell-functions.sh sources without error" {
    # setup already sourced it; if we got here, it worked
    [ "$_CODA_DIR" = "$SCRIPT_DIR" ]
}

@test "all lib modules exist on disk" {
    for mod in helpers core project feature layout provider profile watch; do
        [ -f "$SCRIPT_DIR/lib/${mod}.sh" ]
    done
}

# --- Core functions ---

@test "coda function is defined" {
    declare -f coda &>/dev/null
}

@test "_coda_attach is defined" {
    declare -f _coda_attach &>/dev/null
}

@test "_coda_ls is defined" {
    declare -f _coda_ls &>/dev/null
}

@test "_coda_switch is defined" {
    declare -f _coda_switch &>/dev/null
}

@test "_coda_serve is defined" {
    declare -f _coda_serve &>/dev/null
}

@test "_coda_help is defined" {
    declare -f _coda_help &>/dev/null
}

# --- Project functions ---

@test "_coda_project is defined" {
    declare -f _coda_project &>/dev/null
}

@test "_coda_project_start is defined" {
    declare -f _coda_project_start &>/dev/null
}

@test "_coda_project_add is defined" {
    declare -f _coda_project_add &>/dev/null
}

@test "_coda_project_workon is defined" {
    declare -f _coda_project_workon &>/dev/null
}

@test "_coda_project_close is defined" {
    declare -f _coda_project_close &>/dev/null
}

@test "_coda_project_ls is defined" {
    declare -f _coda_project_ls &>/dev/null
}

# --- Feature functions ---

@test "_coda_feature is defined" {
    declare -f _coda_feature &>/dev/null
}

@test "_coda_feature_start is defined" {
    declare -f _coda_feature_start &>/dev/null
}

@test "_coda_feature_done is defined" {
    declare -f _coda_feature_done &>/dev/null
}

@test "_coda_feature_finish is defined" {
    declare -f _coda_feature_finish &>/dev/null
}

# --- Layout functions ---

@test "_coda_layout_cmd is defined" {
    declare -f _coda_layout_cmd &>/dev/null
}

@test "_coda_load_layout is defined" {
    declare -f _coda_load_layout &>/dev/null
}

@test "_coda_list_layouts is defined" {
    declare -f _coda_list_layouts &>/dev/null
}

# --- Provider functions ---

@test "_coda_auth is defined" {
    declare -f _coda_auth &>/dev/null
}

@test "_coda_provider is defined" {
    declare -f _coda_provider &>/dev/null
}

@test "_coda_provider_status is defined" {
    declare -f _coda_provider_status &>/dev/null
}

@test "_coda_provider_mode is defined" {
    declare -f _coda_provider_mode &>/dev/null
}

# --- Profile functions ---

@test "_coda_profile_cmd is defined" {
    declare -f _coda_profile_cmd &>/dev/null
}

@test "_coda_resolve_profile is defined" {
    declare -f _coda_resolve_profile &>/dev/null
}

@test "_coda_list_profiles is defined" {
    declare -f _coda_list_profiles &>/dev/null
}

# --- Watch functions ---

@test "_coda_watch is defined" {
    declare -f _coda_watch &>/dev/null
}

# --- Helper functions ---

@test "_coda_sanitize_session_name is defined" {
    declare -f _coda_sanitize_session_name &>/dev/null
}

@test "_coda_detect_default_branch is defined" {
    declare -f _coda_detect_default_branch &>/dev/null
}

@test "_coda_find_project_root is defined" {
    declare -f _coda_find_project_root &>/dev/null
}

@test "_coda_find_free_port is defined" {
    declare -f _coda_find_free_port &>/dev/null
}

@test "_coda_normalize_url is defined" {
    declare -f _coda_normalize_url &>/dev/null
}

# --- Functional tests ---

@test "coda help produces output" {
    run coda help
    [ "$status" -eq 0 ]
    [[ "$output" == *"OpenCode session and project manager"* ]]
}

@test "coda help contains all subcommands" {
    run coda help
    [[ "$output" == *"coda project"* ]]
    [[ "$output" == *"coda feature"* ]]
    [[ "$output" == *"coda layout"* ]]
    [[ "$output" == *"coda profile"* ]]
    [[ "$output" == *"coda watch"* ]]
}

@test "_coda_sanitize_session_name replaces dots" {
    result=$(_coda_sanitize_session_name "my.project.name")
    [ "$result" = "my-project-name" ]
}

@test "_coda_sanitize_session_name passes through clean names" {
    result=$(_coda_sanitize_session_name "my-project")
    [ "$result" = "my-project" ]
}

@test "_coda_normalize_url strips trailing slash" {
    result=$(_coda_normalize_url "http://localhost:8080/")
    [ "$result" = "http://localhost:8080" ]
}

@test "_coda_normalize_url rejects non-http" {
    run _coda_normalize_url "ftp://example.com"
    [ "$status" -ne 0 ]
}

@test "_coda_normalize_url accepts http" {
    run _coda_normalize_url "http://example.com"
    [ "$status" -eq 0 ]
}

@test "_coda_normalize_url accepts https" {
    run _coda_normalize_url "https://example.com"
    [ "$status" -eq 0 ]
}

@test "_coda_provider_mode defaults to claude-auth" {
    unset CODA_PROVIDER_MODE
    result=$(_coda_provider_mode)
    [ "$result" = "claude-auth" ]
}

@test "_coda_provider_mode accepts cliproxyapi" {
    CODA_PROVIDER_MODE=cliproxyapi
    result=$(_coda_provider_mode)
    [ "$result" = "cliproxyapi" ]
}

@test "_coda_provider_mode rejects invalid" {
    CODA_PROVIDER_MODE=invalid
    run _coda_provider_mode
    [ "$status" -ne 0 ]
}

@test "_coda_validate_api_key accepts normal key" {
    run _coda_validate_api_key "sk-abc123"
    [ "$status" -eq 0 ]
}

@test "_coda_validate_api_key accepts empty key" {
    run _coda_validate_api_key ""
    [ "$status" -eq 0 ]
}

@test "_coda_expand_path expands tilde" {
    # Must single-quote to prevent shell tilde expansion before the function sees it
    result=$(_coda_expand_path '~/test')
    [ "$result" = "$HOME/test" ]
}

@test "_coda_expand_path passes absolute paths through" {
    result=$(_coda_expand_path "/usr/local/bin")
    [ "$result" = "/usr/local/bin" ]
}

@test "_coda_list_layouts finds builtin layouts" {
    result=$(_coda_list_layouts)
    [[ "$result" == *"default"* ]]
    [[ "$result" == *"classic"* ]]
}

@test "coda layout ls produces output" {
    run coda layout ls
    [ "$status" -eq 0 ]
    [[ "$output" == *"Available layouts"* ]]
    [[ "$output" == *"default"* ]]
}

@test "coda profile ls produces output" {
    run coda profile ls
    [ "$status" -eq 0 ]
    [[ "$output" == *"Available profiles"* ]]
}

@test "coda project ls runs without error" {
    run coda project ls
    # Either finds projects or says none found — both are success
    [ "$status" -eq 0 ] || [ "$status" -eq 1 ]
}

@test "coda layout help shows usage" {
    run coda layout help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage"* ]]
}

@test "coda feature help shows usage" {
    run coda feature help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage"* ]]
}

@test "coda project help shows usage" {
    run coda project help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage"* ]]
}

@test "default config values are set" {
    [ -n "$PROJECTS_DIR" ]
    [ -n "$SESSION_PREFIX" ]
    [ -n "$DEFAULT_BRANCH" ]
    [ -n "$DEFAULT_LAYOUT" ]
}
