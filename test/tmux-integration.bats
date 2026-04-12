#!/usr/bin/env bats

# tmux integration tests for coda.
# These tests create and destroy real tmux sessions.
# Requires: tmux, coda-core in PATH

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
TEST_PREFIX="codatest-"
TEST_SESSION="${TEST_PREFIX}integration"

setup() {
    export AUTO_ATTACH_TMUX=false
    export SSH_CONNECTION=""
    export SESSION_PREFIX="$TEST_PREFIX"
    export DEFAULT_LAYOUT="default"
    export PROJECTS_DIR="$(mktemp -d)"
    export CODA_SKIP_ENV=true
    source "$SCRIPT_DIR/shell-functions.sh"
}

teardown() {
    # Kill any test sessions we created
    tmux list-sessions -F '#{session_name}' 2>/dev/null | grep "^${TEST_PREFIX}" | while read -r s; do
        tmux kill-session -t "$s" 2>/dev/null || true
    done
    [ -d "${PROJECTS_DIR:-}" ] && rm -rf "$PROJECTS_DIR"
}

# --- Session lifecycle ---

@test "coda ls with no sessions shows empty message" {
    run coda ls
    [ "$status" -eq 0 ]
    [[ "$output" == *"No active sessions"* ]]
}

@test "tmux session creation via _coda_attach" {
    local tmpdir
    tmpdir=$(mktemp -d)
    _coda_attach "testapp" "$tmpdir" &
    sleep 1

    tmux has-session -t "${TEST_PREFIX}testapp" 2>/dev/null
    run tmux has-session -t "${TEST_PREFIX}testapp"
    [ "$status" -eq 0 ]

    tmux kill-session -t "${TEST_PREFIX}testapp" 2>/dev/null
    rm -rf "$tmpdir"
}

@test "coda ls shows created session" {
    local tmpdir
    tmpdir=$(mktemp -d)
    tmux new-session -d -s "${TEST_PREFIX}myapp" -c "$tmpdir"

    run coda ls
    [ "$status" -eq 0 ]
    [[ "$output" == *"${TEST_PREFIX}myapp"* ]]

    tmux kill-session -t "${TEST_PREFIX}myapp"
    rm -rf "$tmpdir"
}

@test "session name sanitizes dots" {
    local tmpdir
    tmpdir=$(mktemp -d)
    tmux new-session -d -s "${TEST_PREFIX}my-app" -c "$tmpdir"

    # The sanitizer should have converted dots to dashes
    result=$(_coda_sanitize_session_name "my.app")
    [ "$result" = "my-app" ]

    tmux kill-session -t "${TEST_PREFIX}my-app"
    rm -rf "$tmpdir"
}

# --- Layout loading ---

@test "_coda_load_layout loads default layout" {
    _coda_load_layout "default"
    declare -f _layout_init &>/dev/null
}

@test "_coda_load_layout loads classic layout" {
    _coda_load_layout "classic"
    declare -f _layout_init &>/dev/null
}

@test "_coda_load_layout fails on unknown layout" {
    run _coda_load_layout "nonexistent-layout-xyz"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Unknown layout"* ]]
}

@test "default layout creates single-pane session" {
    local tmpdir
    tmpdir=$(mktemp -d)
    _coda_load_layout "default"
    _layout_init "${TEST_PREFIX}default-test" "$tmpdir"

    run tmux has-session -t "${TEST_PREFIX}default-test"
    [ "$status" -eq 0 ]

    pane_count=$(tmux list-panes -t "${TEST_PREFIX}default-test" | wc -l)
    [ "$pane_count" -eq 1 ]

    tmux kill-session -t "${TEST_PREFIX}default-test"
    rm -rf "$tmpdir"
}

# --- coda-core layout snapshot ---

@test "coda-core layout snapshot requires tmux" {
    # Run outside tmux
    unset TMUX
    run coda-core layout snapshot --name test --output /tmp/test-layout.sh
    [ "$status" -ne 0 ]
    [[ "$output" == *"tmux"* ]]
}

# --- coda-core provider auth ---

@test "coda-core provider auth creates config file" {
    local tmpdir
    tmpdir=$(mktemp -d)
    local config="$tmpdir/opencode.json"

    run coda-core provider auth --base-url "http://localhost:8317/v1" --config "$config" --api-key "test-key"
    [ "$status" -eq 0 ]
    [ -f "$config" ]

    # Verify JSON structure
    run python3 -c "import json; d=json.load(open('$config')); assert 'cliproxyapi' in d['provider']"
    [ "$status" -eq 0 ]

    rm -rf "$tmpdir"
}

@test "coda-core provider auth preserves existing config" {
    local tmpdir
    tmpdir=$(mktemp -d)
    local config="$tmpdir/opencode.json"
    echo '{"theme": "dark"}' > "$config"

    run coda-core provider auth --base-url "http://localhost:8317/v1" --config "$config"
    [ "$status" -eq 0 ]

    # Verify existing key preserved
    run python3 -c "import json; d=json.load(open('$config')); assert d['theme'] == 'dark'"
    [ "$status" -eq 0 ]

    rm -rf "$tmpdir"
}

@test "coda-core provider auth requires base-url" {
    run coda-core provider auth --config /tmp/test.json
    [ "$status" -ne 0 ]
}

# --- coda-core provider status ---

@test "coda-core provider status runs in claude-auth mode" {
    run coda-core provider status --mode claude-auth --config /tmp/nonexistent.json --has-opencode false
    [ "$status" -eq 0 ]
    [[ "$output" == *"Provider mode: claude-auth"* ]]
    [[ "$output" == *"opencode: missing"* ]]
}

@test "coda-core provider status reports missing config" {
    run coda-core provider status --mode cliproxyapi --config /tmp/nonexistent.json --base-url "http://localhost:9999/v1" --has-opencode false
    [ "$status" -eq 0 ]
    [[ "$output" == *"cliproxyapi"* ]]
}
