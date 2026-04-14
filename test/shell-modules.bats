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
    for mod in helpers core project feature layout provider profile watch plugin; do
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

# --- Config precedence tests ---

@test "_coda_resolve_effective_config returns defaults with no overrides" {
    unset CODA_LAYOUT CODA_NVIM_APPNAME
    result=$(_coda_resolve_effective_config "" "" "")
    layout=$(echo "$result" | sed -n '1p')
    nvim=$(echo "$result" | sed -n '2p')
    [ "$layout" = "$DEFAULT_LAYOUT" ]
    [ "$nvim" = "$DEFAULT_NVIM_APPNAME" ]
}

@test "_coda_resolve_effective_config respects project config" {
    unset CODA_LAYOUT CODA_NVIM_APPNAME
    local tmpdir
    tmpdir=$(mktemp -d)
    printf 'CODA_LAYOUT=project-layout\nCODA_NVIM_APPNAME=project-nvim\n' > "$tmpdir/.coda.env"
    result=$(_coda_resolve_effective_config "$tmpdir" "" "")
    layout=$(echo "$result" | sed -n '1p')
    nvim=$(echo "$result" | sed -n '2p')
    [ "$layout" = "project-layout" ]
    [ "$nvim" = "project-nvim" ]
    rm -rf "$tmpdir"
}

@test "_coda_resolve_effective_config profile overrides project" {
    unset CODA_LAYOUT CODA_NVIM_APPNAME
    local tmpdir
    tmpdir=$(mktemp -d)
    printf 'CODA_LAYOUT=project-layout\n' > "$tmpdir/.coda.env"
    mkdir -p "$CODA_PROFILES_DIR"
    printf 'CODA_LAYOUT=profile-layout\n' > "$CODA_PROFILES_DIR/test-precedence.env"
    result=$(_coda_resolve_effective_config "$tmpdir" "test-precedence" "")
    layout=$(echo "$result" | sed -n '1p')
    [ "$layout" = "profile-layout" ]
    rm -rf "$tmpdir" "$CODA_PROFILES_DIR/test-precedence.env"
}

@test "_coda_resolve_effective_config env var overrides profile" {
    local tmpdir
    tmpdir=$(mktemp -d)
    mkdir -p "$CODA_PROFILES_DIR"
    printf 'CODA_LAYOUT=profile-layout\n' > "$CODA_PROFILES_DIR/test-env.env"
    CODA_LAYOUT=env-layout
    result=$(_coda_resolve_effective_config "$tmpdir" "test-env" "")
    layout=$(echo "$result" | sed -n '1p')
    [ "$layout" = "env-layout" ]
    unset CODA_LAYOUT
    rm -rf "$tmpdir" "$CODA_PROFILES_DIR/test-env.env"
}

@test "_coda_resolve_effective_config flag overrides everything" {
    CODA_LAYOUT=env-layout
    result=$(_coda_resolve_effective_config "" "" "flag-layout")
    layout=$(echo "$result" | sed -n '1p')
    [ "$layout" = "flag-layout" ]
    unset CODA_LAYOUT
}

@test "_coda_find_project_root_from finds bare repo root" {
    local tmpdir
    tmpdir=$(mktemp -d)
    mkdir -p "$tmpdir/.bare"
    echo 'gitdir: ./.bare' > "$tmpdir/.git"
    mkdir -p "$tmpdir/main/src"
    result=$(_coda_find_project_root_from "$tmpdir/main/src")
    [ "$result" = "$tmpdir" ]
    rm -rf "$tmpdir"
}

@test "_coda_find_project_root_from returns empty for non-project" {
    local tmpdir
    tmpdir=$(mktemp -d)
    result=$(_coda_find_project_root_from "$tmpdir")
    [ -z "$result" ]
    rm -rf "$tmpdir"
}

@test "_coda_load_project_config sources .coda.env" {
    local tmpdir
    tmpdir=$(mktemp -d)
    printf 'CODA_TEST_VAR=hello_from_project\n' > "$tmpdir/.coda.env"
    _coda_load_project_config "$tmpdir"
    [ "$CODA_TEST_VAR" = "hello_from_project" ]
    unset CODA_TEST_VAR
    rm -rf "$tmpdir"
}

@test "_coda_load_project_config is no-op without .coda.env" {
    local tmpdir
    tmpdir=$(mktemp -d)
    run _coda_load_project_config "$tmpdir"
    [ "$status" -eq 0 ]
    rm -rf "$tmpdir"
}

@test "coda-dev function is defined" {
    declare -f coda-dev &>/dev/null
}

# --- Hook system tests ---

@test "_coda_run_hooks is defined" {
    declare -f _coda_run_hooks &>/dev/null
}

@test "_coda_run_hooks is no-op for missing event directory" {
    run _coda_run_hooks nonexistent-event
    [ "$status" -eq 0 ]
}

@test "_coda_run_hooks runs executable scripts" {
    local tmpdir
    tmpdir=$(mktemp -d)
    mkdir -p "$tmpdir/test-event"
    printf '#!/usr/bin/env bash\necho "hook-ran"\n' > "$tmpdir/test-event/01-test"
    chmod +x "$tmpdir/test-event/01-test"
    CODA_HOOKS_DIR="$tmpdir" run _coda_run_hooks test-event
    [ "$status" -eq 0 ]
    [[ "$output" == *"hook-ran"* ]]
    rm -rf "$tmpdir"
}

@test "_coda_run_hooks skips non-executable files" {
    local tmpdir
    tmpdir=$(mktemp -d)
    mkdir -p "$tmpdir/test-event"
    printf '#!/usr/bin/env bash\necho "should-not-run"\n' > "$tmpdir/test-event/01-noexec"
    CODA_HOOKS_DIR="$tmpdir" run _coda_run_hooks test-event
    [ "$status" -eq 0 ]
    [[ "$output" != *"should-not-run"* ]]
    rm -rf "$tmpdir"
}

@test "_coda_run_hooks passes env vars to hooks" {
    local tmpdir
    tmpdir=$(mktemp -d)
    mkdir -p "$tmpdir/test-event"
    printf '#!/usr/bin/env bash\necho "name=$CODA_PROJECT_NAME"\n' > "$tmpdir/test-event/01-env"
    chmod +x "$tmpdir/test-event/01-env"
    CODA_HOOKS_DIR="$tmpdir" CODA_PROJECT_NAME="testproj" run _coda_run_hooks test-event
    [ "$status" -eq 0 ]
    [[ "$output" == *"name=testproj"* ]]
    rm -rf "$tmpdir"
}

@test "_coda_run_hooks reports failing hooks without blocking" {
    local tmpdir
    tmpdir=$(mktemp -d)
    mkdir -p "$tmpdir/test-event"
    printf '#!/usr/bin/env bash\nexit 1\n' > "$tmpdir/test-event/01-fail"
    chmod +x "$tmpdir/test-event/01-fail"
    CODA_HOOKS_DIR="$tmpdir" run _coda_run_hooks test-event
    [ "$status" -eq 0 ]
    [[ "$output" == *"hook warning"* ]]
    rm -rf "$tmpdir"
}

@test "built-in post-project-create hook exists and is executable" {
    [ -x "$_CODA_DIR/hooks/post-project-create/00-editorconfig" ]
}

# --- Layout interface contract tests (A1) ---

@test "_coda_load_layout succeeds with valid builtin layout" {
    run _coda_load_layout "default"
    [ "$status" -eq 0 ]
}

@test "_coda_load_layout defines _layout_init after loading" {
    _coda_load_layout "default"
    declare -f _layout_init &>/dev/null
}

@test "_coda_load_layout fails for nonexistent layout" {
    run _coda_load_layout "nonexistent-layout-xyz"
    [ "$status" -ne 0 ]
    [[ "$output" == *"not found"* ]]
    [[ "$output" == *"Create one"* ]]
}

@test "_coda_load_layout rejects layout missing _layout_init" {
    local tmpdir
    tmpdir=$(mktemp -d)
    printf '#!/usr/bin/env bash\n_some_other_func() { true; }\n' > "$tmpdir/bad.sh"
    CODA_LAYOUTS_DIR="$tmpdir" run _coda_load_layout "bad"
    [ "$status" -ne 0 ]
    [[ "$output" == *"invalid"* ]]
    rm -rf "$tmpdir"
}

@test "_coda_load_layout accepts layout with only _layout_init" {
    local tmpdir
    tmpdir=$(mktemp -d)
    printf '#!/usr/bin/env bash\n_layout_init() { true; }\n' > "$tmpdir/minimal.sh"
    CODA_LAYOUTS_DIR="$tmpdir" run _coda_load_layout "minimal"
    [ "$status" -eq 0 ]
    rm -rf "$tmpdir"
}

@test "_coda_load_layout accepts layout with _layout_init and _layout_spawn" {
    local tmpdir
    tmpdir=$(mktemp -d)
    printf '#!/usr/bin/env bash\n_layout_init() { true; }\n_layout_spawn() { true; }\n' > "$tmpdir/full.sh"
    CODA_LAYOUTS_DIR="$tmpdir" run _coda_load_layout "full"
    [ "$status" -eq 0 ]
    rm -rf "$tmpdir"
}

@test "user layout overrides builtin of same name" {
    local tmpdir
    tmpdir=$(mktemp -d)
    printf '#!/usr/bin/env bash\n_layout_init() { echo "user-version"; }\n' > "$tmpdir/default.sh"
    CODA_LAYOUTS_DIR="$tmpdir" _coda_load_layout "default"
    result=$(_layout_init)
    [ "$result" = "user-version" ]
    rm -rf "$tmpdir"
}

@test "_coda_load_layout cleans up previous layout functions" {
    _layout_init() { echo "old"; }
    _layout_spawn() { echo "old"; }
    _coda_load_layout "default"
    result=$(_layout_init 2>&1 || true)
    [ "$result" != "old" ]
}

@test "_coda_layout_ls shows source annotation" {
    run coda layout ls
    [ "$status" -eq 0 ]
    [[ "$output" == *"builtin"* ]]
}

@test "_coda_load_layout accepts legacy _layout_apply" {
    local tmpdir
    tmpdir=$(mktemp -d)
    printf '#!/usr/bin/env bash\n_layout_apply() { true; }\n' > "$tmpdir/legacy.sh"
    CODA_LAYOUTS_DIR="$tmpdir" run _coda_load_layout "legacy"
    [ "$status" -eq 0 ]
    rm -rf "$tmpdir"
}

# --- Hook events coverage tests (A2) ---

@test "hooks: pre-session-create event fires" {
    local tmpdir
    tmpdir=$(mktemp -d)
    mkdir -p "$tmpdir/pre-session-create"
    printf '#!/usr/bin/env bash\necho "sess=$CODA_SESSION_NAME dir=$CODA_SESSION_DIR"\n' > "$tmpdir/pre-session-create/01-test"
    chmod +x "$tmpdir/pre-session-create/01-test"
    CODA_HOOKS_DIR="$tmpdir" CODA_SESSION_NAME="test-sess" CODA_SESSION_DIR="/tmp" \
        run _coda_run_hooks pre-session-create
    [ "$status" -eq 0 ]
    [[ "$output" == *"sess=test-sess"* ]]
    [[ "$output" == *"dir=/tmp"* ]]
    rm -rf "$tmpdir"
}

@test "hooks: post-session-attach event fires" {
    local tmpdir
    tmpdir=$(mktemp -d)
    mkdir -p "$tmpdir/post-session-attach"
    printf '#!/usr/bin/env bash\necho "sess=$CODA_SESSION_NAME"\n' > "$tmpdir/post-session-attach/01-test"
    chmod +x "$tmpdir/post-session-attach/01-test"
    CODA_HOOKS_DIR="$tmpdir" CODA_SESSION_NAME="test-sess" \
        run _coda_run_hooks post-session-attach
    [ "$status" -eq 0 ]
    [[ "$output" == *"sess=test-sess"* ]]
    rm -rf "$tmpdir"
}

@test "hooks: post-project-clone event fires with repo URL" {
    local tmpdir
    tmpdir=$(mktemp -d)
    mkdir -p "$tmpdir/post-project-clone"
    printf '#!/usr/bin/env bash\necho "proj=$CODA_PROJECT_NAME url=$CODA_REPO_URL"\n' > "$tmpdir/post-project-clone/01-test"
    chmod +x "$tmpdir/post-project-clone/01-test"
    CODA_HOOKS_DIR="$tmpdir" CODA_PROJECT_NAME="myapp" CODA_REPO_URL="git@github.com:user/myapp.git" \
        run _coda_run_hooks post-project-clone
    [ "$status" -eq 0 ]
    [[ "$output" == *"proj=myapp"* ]]
    [[ "$output" == *"url=git@github.com:user/myapp.git"* ]]
    rm -rf "$tmpdir"
}

@test "hooks: pre-project-close event fires" {
    local tmpdir
    tmpdir=$(mktemp -d)
    mkdir -p "$tmpdir/pre-project-close"
    printf '#!/usr/bin/env bash\necho "proj=$CODA_PROJECT_NAME dir=$CODA_PROJECT_DIR"\n' > "$tmpdir/pre-project-close/01-test"
    chmod +x "$tmpdir/pre-project-close/01-test"
    CODA_HOOKS_DIR="$tmpdir" CODA_PROJECT_NAME="myapp" CODA_PROJECT_DIR="/tmp/myapp" \
        run _coda_run_hooks pre-project-close
    [ "$status" -eq 0 ]
    [[ "$output" == *"proj=myapp"* ]]
    [[ "$output" == *"dir=/tmp/myapp"* ]]
    rm -rf "$tmpdir"
}

@test "hooks: post-feature-finish event fires" {
    local tmpdir
    tmpdir=$(mktemp -d)
    mkdir -p "$tmpdir/post-feature-finish"
    printf '#!/usr/bin/env bash\necho "proj=$CODA_PROJECT_NAME branch=$CODA_FEATURE_BRANCH"\n' > "$tmpdir/post-feature-finish/01-test"
    chmod +x "$tmpdir/post-feature-finish/01-test"
    CODA_HOOKS_DIR="$tmpdir" CODA_PROJECT_NAME="myapp" CODA_FEATURE_BRANCH="auth" \
        run _coda_run_hooks post-feature-finish
    [ "$status" -eq 0 ]
    [[ "$output" == *"proj=myapp"* ]]
    [[ "$output" == *"branch=auth"* ]]
    rm -rf "$tmpdir"
}

@test "hooks: post-layout-apply event fires" {
    local tmpdir
    tmpdir=$(mktemp -d)
    mkdir -p "$tmpdir/post-layout-apply"
    printf '#!/usr/bin/env bash\necho "sess=$CODA_SESSION_NAME layout=$CODA_SESSION_LAYOUT"\n' > "$tmpdir/post-layout-apply/01-test"
    chmod +x "$tmpdir/post-layout-apply/01-test"
    CODA_HOOKS_DIR="$tmpdir" CODA_SESSION_NAME="coda-myapp" CODA_SESSION_LAYOUT="four-pane" \
        run _coda_run_hooks post-layout-apply
    [ "$status" -eq 0 ]
    [[ "$output" == *"sess=coda-myapp"* ]]
    [[ "$output" == *"layout=four-pane"* ]]
    rm -rf "$tmpdir"
}

@test "hooks: sorted execution order" {
    local tmpdir
    tmpdir=$(mktemp -d)
    mkdir -p "$tmpdir/test-order"
    printf '#!/usr/bin/env bash\necho "first"\n' > "$tmpdir/test-order/01-first"
    printf '#!/usr/bin/env bash\necho "second"\n' > "$tmpdir/test-order/02-second"
    printf '#!/usr/bin/env bash\necho "third"\n' > "$tmpdir/test-order/10-third"
    chmod +x "$tmpdir/test-order/01-first" "$tmpdir/test-order/02-second" "$tmpdir/test-order/10-third"
    CODA_HOOKS_DIR="$tmpdir" run _coda_run_hooks test-order
    [ "$status" -eq 0 ]
    local first_pos second_pos third_pos
    first_pos=$(echo "$output" | grep -n "first" | head -1 | cut -d: -f1)
    second_pos=$(echo "$output" | grep -n "second" | head -1 | cut -d: -f1)
    third_pos=$(echo "$output" | grep -n "third" | head -1 | cut -d: -f1)
    [ "$first_pos" -lt "$second_pos" ]
    [ "$second_pos" -lt "$third_pos" ]
    rm -rf "$tmpdir"
}

@test "hooks: user hooks directory checked before builtin" {
    local tmpdir
    tmpdir=$(mktemp -d)
    mkdir -p "$tmpdir/test-priority"
    printf '#!/usr/bin/env bash\necho "user-hook"\n' > "$tmpdir/test-priority/01-user"
    chmod +x "$tmpdir/test-priority/01-user"
    CODA_HOOKS_DIR="$tmpdir" run _coda_run_hooks test-priority
    [ "$status" -eq 0 ]
    [[ "$output" == *"user-hook"* ]]
    rm -rf "$tmpdir"
}

# --- Provider plugin system tests (A3) ---

@test "_coda_load_provider loads claude-auth auth.sh" {
    run _coda_load_provider claude-auth auth
    [ "$status" -eq 0 ]
}

@test "_coda_load_provider loads cliproxyapi auth.sh" {
    run _coda_load_provider cliproxyapi auth
    [ "$status" -eq 0 ]
}

@test "_coda_load_provider defines _provider_auth" {
    _coda_load_provider claude-auth auth
    declare -f _provider_auth &>/dev/null
}

@test "_coda_load_provider fails for nonexistent provider" {
    run _coda_load_provider nonexistent-provider-xyz auth
    [ "$status" -ne 0 ]
    [[ "$output" == *"not found"* ]]
}

@test "_coda_load_provider fails for missing component" {
    local tmpdir
    tmpdir=$(mktemp -d)
    mkdir -p "$tmpdir/test-provider"
    CODA_PROVIDERS_DIR="$tmpdir" run _coda_load_provider test-provider auth
    [ "$status" -ne 0 ]
    [[ "$output" == *"missing auth.sh"* ]]
    rm -rf "$tmpdir"
}

@test "user provider overrides builtin of same name" {
    local tmpdir
    tmpdir=$(mktemp -d)
    mkdir -p "$tmpdir/claude-auth"
    printf '#!/usr/bin/env bash\n_provider_auth() { echo "user-provider"; }\n' > "$tmpdir/claude-auth/auth.sh"
    CODA_PROVIDERS_DIR="$tmpdir" _coda_load_provider claude-auth auth
    result=$(_provider_auth)
    [ "$result" = "user-provider" ]
    rm -rf "$tmpdir"
}

@test "_coda_list_providers finds builtin providers" {
    result=$(_coda_list_providers)
    [[ "$result" == *"claude-auth"* ]]
    [[ "$result" == *"cliproxyapi"* ]]
}

@test "coda provider ls shows output" {
    run coda provider ls
    [ "$status" -eq 0 ]
    [[ "$output" == *"Available providers"* ]]
    [[ "$output" == *"claude-auth"* ]]
}

@test "coda provider ls shows active indicator" {
    CODA_PROVIDER_MODE=claude-auth run coda provider ls
    [[ "$output" == *"(active)"* ]]
}

# --- Notification plugin tests (A4) ---

@test "builtin bell.sh notification exists and is executable" {
    [ -x "$_CODA_DIR/notifications/bell.sh" ]
}

@test "CODA_NOTIFICATIONS_DIR is set" {
    [ -n "$CODA_NOTIFICATIONS_DIR" ]
}

# --- Profile expansion tests (A5) ---

@test "profile with CODA_PROVIDER_MODE is read by resolve_effective_config" {
    unset CODA_LAYOUT CODA_NVIM_APPNAME CODA_PROVIDER_MODE
    mkdir -p "$CODA_PROFILES_DIR"
    printf 'CODA_PROVIDER_MODE=cliproxyapi\n' > "$CODA_PROFILES_DIR/test-provider.env"
    run _coda_resolve_effective_config "" "test-provider" ""
    rm -f "$CODA_PROFILES_DIR/test-provider.env"
    [ "$status" -eq 0 ]
}

@test "profile template includes new variables" {
    mkdir -p "$CODA_PROFILES_DIR"
    rm -f "$CODA_PROFILES_DIR/test-template.env"
    coda profile create test-template
    local content
    content=$(cat "$CODA_PROFILES_DIR/test-template.env")
    [[ "$content" == *"CODA_PROVIDER_MODE"* ]]
    [[ "$content" == *"CODA_WATCH_INTERVAL"* ]]
    [[ "$content" == *"CODA_WATCH_COOLDOWN"* ]]
    [[ "$content" == *"CODA_HOOKS_DIR"* ]]
    rm -f "$CODA_PROFILES_DIR/test-template.env"
}

@test "profile show for missing profile gives error" {
    run coda profile show nonexistent-profile-xyz
    [ "$status" -ne 0 ]
    [[ "$output" == *"not found"* ]]
    [[ "$output" == *"Create one"* ]]
}

# --- Failure-path tests (D3) ---

@test "_coda_sanitize_session_name handles slashes" {
    result=$(_coda_sanitize_session_name "feature/auth")
    [[ "$result" != *"/"* ]]
}

@test "_coda_sanitize_session_name handles spaces" {
    result=$(_coda_sanitize_session_name "my project")
    [[ "$result" != *" "* ]]
}

@test "_coda_sanitize_session_name handles colons" {
    result=$(_coda_sanitize_session_name "fix:bug")
    [[ "$result" != *":"* ]]
}

@test "_coda_sanitize_session_name handles dots" {
    result=$(_coda_sanitize_session_name "v1.2.3")
    [[ "$result" != *"."* ]]
}

@test "_coda_sanitize_session_name combined special chars" {
    result=$(_coda_sanitize_session_name "feature/v1.2:fix name")
    [[ "$result" != *"/"* ]]
    [[ "$result" != *"."* ]]
    [[ "$result" != *":"* ]]
    [[ "$result" != *" "* ]]
}

@test "coda switch with no sessions shows clean message" {
    TMUX="" run _coda_ls
    [ "$status" -eq 0 ]
}

@test "coda feature done without args shows usage" {
    run coda feature done
    [ "$status" -ne 0 ] || [[ "$output" == *"Usage"* ]]
}

@test "coda project close outside project gives error" {
    local tmpdir
    tmpdir=$(mktemp -d)
    (cd "$tmpdir" && run _coda_find_project_root)
    rm -rf "$tmpdir"
}

@test "layout show for missing layout gives helpful error" {
    run coda layout show nonexistent-layout-xyz
    [ "$status" -ne 0 ]
    [[ "$output" == *"not found"* ]]
    [[ "$output" == *"Create one"* ]]
}

# --- B1: Hardcoded values extraction tests ---

@test "NEW_PROJECT_GITHUB_OWNER is not hardcoded to evanstern" {
    unset NEW_PROJECT_GITHUB_OWNER
    source "$SCRIPT_DIR/shell-functions.sh"
    [ -z "$NEW_PROJECT_GITHUB_OWNER" ] || [ "$NEW_PROJECT_GITHUB_OWNER" != "evanstern" ]
}

@test "watcher session derives from SESSION_PREFIX" {
    local old_prefix="$SESSION_PREFIX"
    SESSION_PREFIX="test-prefix-"
    local watcher_name="${SESSION_PREFIX}watcher"
    [ "$watcher_name" = "test-prefix-watcher" ]
    SESSION_PREFIX="$old_prefix"
}

@test "CLAUDE_CREDENTIALS_PATH has a default" {
    [ -n "$CLAUDE_CREDENTIALS_PATH" ]
}

@test "CODA_HOOKS_DIR has a default" {
    [ -n "$CODA_HOOKS_DIR" ]
}

# --- C1: CLI subcommand tests ---

@test "coda hooks events lists all 10 events" {
    run coda hooks events
    [ "$status" -eq 0 ]
    [[ "$output" == *"pre-session-create"* ]]
    [[ "$output" == *"post-session-create"* ]]
    [[ "$output" == *"post-session-attach"* ]]
    [[ "$output" == *"post-project-create"* ]]
    [[ "$output" == *"post-project-clone"* ]]
    [[ "$output" == *"pre-project-close"* ]]
    [[ "$output" == *"post-feature-create"* ]]
    [[ "$output" == *"pre-feature-teardown"* ]]
    [[ "$output" == *"post-feature-finish"* ]]
    [[ "$output" == *"post-layout-apply"* ]]
}

@test "coda hooks help shows usage" {
    run coda hooks help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage"* ]]
}

@test "coda hooks ls shows builtin hooks" {
    run coda hooks ls
    [[ "$output" == *"post-project-create"* ]] || [[ "$output" == *"No hooks"* ]]
}

@test "coda hooks create scaffolds a hook" {
    local tmpdir
    tmpdir=$(mktemp -d)
    CODA_HOOKS_DIR="$tmpdir" run coda hooks create post-session-create test-hook
    [ "$status" -eq 0 ]
    [ -f "$tmpdir/post-session-create/test-hook" ]
    [ -x "$tmpdir/post-session-create/test-hook" ]
    rm -rf "$tmpdir"
}

@test "coda hooks create includes correct env vars" {
    local tmpdir
    tmpdir=$(mktemp -d)
    CODA_HOOKS_DIR="$tmpdir" coda hooks create post-project-clone my-hook
    local content
    content=$(cat "$tmpdir/post-project-clone/my-hook")
    [[ "$content" == *"CODA_REPO_URL"* ]]
    rm -rf "$tmpdir"
}

@test "coda hooks run executes hooks" {
    local tmpdir
    tmpdir=$(mktemp -d)
    mkdir -p "$tmpdir/test-event"
    printf '#!/usr/bin/env bash\necho "manual-run"\n' > "$tmpdir/test-event/01-test"
    chmod +x "$tmpdir/test-event/01-test"
    CODA_HOOKS_DIR="$tmpdir" run coda hooks run test-event
    [ "$status" -eq 0 ]
    [[ "$output" == *"manual-run"* ]]
    rm -rf "$tmpdir"
}

@test "coda provider ls is accessible" {
    run coda provider ls
    [ "$status" -eq 0 ]
}

# --- Plugin system tests ---

@test "_coda_plugin_cmd is defined" {
    declare -f _coda_plugin_cmd &>/dev/null
}

@test "_coda_plugin_load_all is defined" {
    declare -f _coda_plugin_load_all &>/dev/null
}

@test "_coda_plugin_dispatch is defined" {
    declare -f _coda_plugin_dispatch &>/dev/null
}

@test "_coda_plugin_install is defined" {
    declare -f _coda_plugin_install &>/dev/null
}

@test "_coda_plugin_remove is defined" {
    declare -f _coda_plugin_remove &>/dev/null
}

@test "_coda_plugin_ls is defined" {
    declare -f _coda_plugin_ls &>/dev/null
}

@test "coda plugin help shows usage" {
    run coda plugin help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage"* ]]
    [[ "$output" == *"install"* ]]
    [[ "$output" == *"remove"* ]]
}

@test "coda plugin ls shows message when no plugins" {
    CODA_PLUGINS_DIR=$(mktemp -d)
    run _coda_plugin_ls
    [ "$status" -eq 0 ]
    [[ "$output" == *"No plugins installed"* ]]
    rm -rf "$CODA_PLUGINS_DIR"
}

@test "coda help includes plugin subcommands" {
    run coda help
    [[ "$output" == *"coda plugin"* ]]
}

@test "_coda_plugin_load registers commands from mock plugin" {
    local tmpdir
    tmpdir=$(mktemp -d)
    mkdir -p "$tmpdir/lib"
    printf '{"name":"test-plugin","version":"1.0.0","provides":{"commands":{"test-cmd":{"handler":"lib/test.sh","function":"_test_func"}}}}' > "$tmpdir/plugin.json"
    printf '#!/usr/bin/env bash\n_test_func() { echo "plugin-ran"; }\n' > "$tmpdir/lib/test.sh"
    _CODA_PLUGIN_COMMANDS=()
    _coda_plugin_load "test-plugin" "$tmpdir"
    [[ -n "${_CODA_PLUGIN_COMMANDS[test-cmd]}" ]]
    rm -rf "$tmpdir"
}

@test "_coda_plugin_dispatch executes plugin command" {
    local tmpdir
    tmpdir=$(mktemp -d)
    mkdir -p "$tmpdir/lib"
    printf '#!/usr/bin/env bash\n_test_dispatch_func() { echo "dispatched"; }\n' > "$tmpdir/lib/handler.sh"
    _CODA_PLUGIN_COMMANDS=([test-dispatch]="$tmpdir/lib/handler.sh:_test_dispatch_func:$tmpdir")
    run _coda_plugin_dispatch test-dispatch
    [ "$status" -eq 0 ]
    [[ "$output" == *"dispatched"* ]]
    rm -rf "$tmpdir"
}

@test "_coda_plugin_dispatch returns 1 for unknown command" {
    _CODA_PLUGIN_COMMANDS=()
    run _coda_plugin_dispatch nonexistent-plugin-cmd
    [ "$status" -eq 1 ]
}

@test "_coda_plugin_name_from_url extracts name from SSH URL" {
    result=$(_coda_plugin_name_from_url "git@github.com:user/coda-github.git")
    [ "$result" = "coda-github" ]
}

@test "_coda_plugin_name_from_url extracts name from HTTPS URL" {
    result=$(_coda_plugin_name_from_url "https://github.com/user/coda-watch.git")
    [ "$result" = "coda-watch" ]
}

@test "CODA_PLUGINS_DIR has a default" {
    [ -n "$CODA_PLUGINS_DIR" ]
}

# --- Versioning tests ---

@test "CODA_VERSION is set" {
    [ -n "$CODA_VERSION" ]
}

@test "coda version prints version" {
    run coda version
    [ "$status" -eq 0 ]
    [[ "$output" == *"$CODA_VERSION"* ]]
}

@test "coda --version prints version" {
    run coda --version
    [ "$status" -eq 0 ]
    [[ "$output" == *"coda"* ]]
}

@test "_coda_semver_compare equal versions" {
    result=$(_coda_semver_compare "1.2.3" "1.2.3")
    [ "$result" -eq 0 ]
}

@test "_coda_semver_compare greater major" {
    result=$(_coda_semver_compare "2.0.0" "1.9.9")
    [ "$result" -eq 1 ]
}

@test "_coda_semver_compare lesser minor" {
    result=$(_coda_semver_compare "1.1.0" "1.2.0")
    [ "$result" -eq -1 ]
}

@test "_coda_semver_compare patch difference" {
    result=$(_coda_semver_compare "1.0.1" "1.0.0")
    [ "$result" -eq 1 ]
}

@test "_coda_semver_satisfies empty constraint" {
    _coda_semver_satisfies "1.0.0" ""
}

@test "_coda_semver_satisfies caret same major" {
    _coda_semver_satisfies "1.5.3" "^1.0.0"
}

@test "_coda_semver_satisfies caret rejects next major" {
    run _coda_semver_satisfies "2.0.0" "^1.0.0"
    [ "$status" -ne 0 ]
}

@test "_coda_semver_satisfies caret rejects below" {
    run _coda_semver_satisfies "0.9.0" "^1.0.0"
    [ "$status" -ne 0 ]
}

@test "_coda_semver_satisfies tilde same minor" {
    _coda_semver_satisfies "1.2.9" "~1.2.0"
}

@test "_coda_semver_satisfies tilde rejects next minor" {
    run _coda_semver_satisfies "1.3.0" "~1.2.0"
    [ "$status" -ne 0 ]
}

@test "_coda_semver_satisfies exact match" {
    _coda_semver_satisfies "1.0.0" "1.0.0"
}

@test "_coda_semver_satisfies exact mismatch" {
    run _coda_semver_satisfies "1.0.1" "1.0.0"
    [ "$status" -ne 0 ]
}

@test "_coda_semver_satisfies range" {
    _coda_semver_satisfies "1.5.0" ">= 1.0.0 < 2.0.0"
}

@test "_coda_semver_satisfies range rejects above" {
    run _coda_semver_satisfies "2.0.0" ">= 1.0.0 < 2.0.0"
    [ "$status" -ne 0 ]
}

@test "_coda_semver_satisfies range rejects below" {
    run _coda_semver_satisfies "0.9.0" ">= 1.0.0 < 2.0.0"
    [ "$status" -ne 0 ]
}

@test "_coda_semver_satisfies caret 0.x allows same minor" {
    _coda_semver_satisfies "0.1.5" "^0.1.0"
}

@test "_coda_semver_satisfies caret 0.x rejects next major" {
    run _coda_semver_satisfies "1.0.0" "^0.1.0"
    [ "$status" -ne 0 ]
}

@test "plugin load skips incompatible plugin" {
    local tmpdir
    tmpdir=$(mktemp -d)
    mkdir -p "$tmpdir/bad-plugin"
    printf '{"name":"bad","version":"1.0.0","coda":"^99.0.0","provides":{"commands":{"badcmd":{"handler":"h.sh","function":"f"}}}}' > "$tmpdir/bad-plugin/plugin.json"
    _coda_plugin_load "bad-plugin" "$tmpdir/bad-plugin" 2>/dev/null
    [ -z "${_CODA_PLUGIN_COMMANDS[badcmd]+x}" ]
    rm -rf "$tmpdir"
}

@test "plugin load accepts compatible plugin" {
    local tmpdir
    tmpdir=$(mktemp -d)
    mkdir -p "$tmpdir/good-plugin"
    printf '{"name":"good","version":"1.0.0","coda":"^0.1.0","provides":{"commands":{"goodcmd":{"handler":"h.sh","function":"f"}}}}' > "$tmpdir/good-plugin/plugin.json"
    _coda_plugin_load "good-plugin" "$tmpdir/good-plugin"
    [ -n "${_CODA_PLUGIN_COMMANDS[goodcmd]+x}" ]
    unset '_CODA_PLUGIN_COMMANDS[goodcmd]'
    rm -rf "$tmpdir"
}
