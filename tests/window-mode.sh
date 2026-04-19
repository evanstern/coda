#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/tests/testlib.sh"

TEST_TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TEST_TMPDIR"' EXIT

export HOME="$TEST_TMPDIR/home"
export PROJECTS_DIR="$TEST_TMPDIR/projects"
export SESSION_PREFIX="coda-"
export DEFAULT_BRANCH="main"
export GIT_REMOTE="origin"
export DEFAULT_LAYOUT="default"
export CODA_LAYOUTS_DIR="$ROOT_DIR/layouts"
export CODA_PROFILES_DIR="$TEST_TMPDIR/profiles"
export AUTO_ATTACH_TMUX="false"
export CODA_TEST_STATE_DIR="$TEST_TMPDIR/state"
export PATH="$ROOT_DIR/tests/bin:$PATH"
unset TMUX

mkdir -p "$HOME" "$PROJECTS_DIR" "$CODA_PROFILES_DIR" "$CODA_TEST_STATE_DIR"

REMOTE_REPO="$TEST_TMPDIR/remote.git"
SEED_REPO="$TEST_TMPDIR/seed"

git init "$SEED_REPO" -b main >/dev/null
git -C "$SEED_REPO" config user.name 'Coda Test'
git -C "$SEED_REPO" config user.email 'coda-test@example.com'
printf 'hello\n' > "$SEED_REPO/README.md"
git -C "$SEED_REPO" add README.md >/dev/null
git -C "$SEED_REPO" commit -m 'Initial commit' >/dev/null
git clone --bare "$SEED_REPO" "$REMOTE_REPO" >/dev/null

source "$ROOT_DIR/shell-functions.sh"

printf 'Running window-mode tests...\n'

# -- Setup project --

coda project start --repo "$REMOTE_REPO" window-test >/dev/null 2>&1
cd "$PROJECTS_DIR/window-test/main"

# -- Test 1: --orch flag with missing orch session falls back to session-mode --

orch_fallback_output="$(coda feature start feat-a --orch nonexistent 2>&1)"
assert_contains "$orch_fallback_output" "Orchestrator session not found" \
    "--orch should warn when orch session does not exist"
assert_contains "$orch_fallback_output" "Falling back to standalone session-mode" \
    "--orch should fall back when orch session does not exist"
assert_contains "$(cat "$CODA_TEST_STATE_DIR/tmux-sessions")" "coda-window-test--feat-a" \
    "--orch fallback should create standalone feature session"

# -- Test 2: --orch flag spawns window in orch session --

# Create a fake orch session
echo "coda-orch--my-orch" >> "$CODA_TEST_STATE_DIR/tmux-sessions"

feature_output="$(coda feature start feat-b --orch my-orch 2>&1)"
assert_contains "$feature_output" "Creating worktree: feat-b" \
    "--orch feature start should create worktree"
assert_file_exists "$PROJECTS_DIR/window-test/feat-b/.git" \
    "--orch feature start should create feature worktree"

# Window should be spawned in orch session, NOT a new standalone session
assert_contains "$(cat "$CODA_TEST_STATE_DIR/tmux-actions")" "new-window:coda-orch--my-orch" \
    "--orch should spawn window in orchestrator session"

# Should NOT have created a standalone session for the feature
if grep -Fx 'coda-window-test--feat-b' "$CODA_TEST_STATE_DIR/tmux-sessions" >/dev/null 2>&1; then
    fail "--orch should not create a standalone feature session"
fi

# -- Test 3: Without --orch, standard session is created --

feature_std_output="$(coda feature start feat-c 2>&1)"
assert_contains "$(cat "$CODA_TEST_STATE_DIR/tmux-sessions")" "coda-window-test--feat-c" \
    "without --orch, feature start should create standalone session"

# -- Test 4: --orch with existing worktree --

feat_b_again="$(coda feature start feat-b --orch my-orch 2>&1)"
assert_contains "$feat_b_again" "Worktree already exists" \
    "--orch with existing worktree should detect it"
assert_contains "$feat_b_again" "Attaching to existing session" \
    "--orch with existing worktree should say attaching"

# -- Test 5: feature done kills orch window for window-mode feature --

# feat-b was started in window-mode (orch session my-orch).
# Verify window exists before teardown.
assert_contains "$(cat "$CODA_TEST_STATE_DIR/tmux-windows")" "coda-orch--my-orch:feat-b" \
    "feat-b should be tracked as orch window before teardown"

done_window_output="$(coda feature done feat-b 2>&1)"
assert_contains "$done_window_output" "Killing window: coda-orch--my-orch:feat-b" \
    "feature done should kill the orch window"
assert_not_exists "$PROJECTS_DIR/window-test/feat-b" \
    "feature done should remove worktree for window-mode feature"

if git -C "$PROJECTS_DIR/window-test" show-ref --verify --quiet refs/heads/feat-b 2>/dev/null; then
    fail "feature done should delete the window-mode feature branch"
fi

# Window should be gone from windows file
assert_not_contains "$(cat "$CODA_TEST_STATE_DIR/tmux-windows")" "coda-orch--my-orch:feat-b" \
    "feature done should remove orch window from tracking"

# -- Test 6: feature done for standalone session still works --

done_standalone_output="$(coda feature done feat-c 2>&1)"
assert_contains "$done_standalone_output" "Killing session: coda-window-test--feat-c" \
    "feature done for standalone session should kill session"
assert_not_exists "$PROJECTS_DIR/window-test/feat-c" \
    "feature done should remove worktree for standalone feature"

# -- Test 7: feature done for fallback feature (feat-a, session mode via orch fallback) --

done_fallback_output="$(coda feature done feat-a 2>&1)"
assert_contains "$done_fallback_output" "Killing session: coda-window-test--feat-a" \
    "feature done for fallback session should kill session"
assert_not_exists "$PROJECTS_DIR/window-test/feat-a" \
    "feature done should remove worktree for fallback feature"

# -- Test 8: feature done with --orch explicit flag --

# Create another feature in window-mode
coda feature start feat-d --orch my-orch >/dev/null 2>&1
assert_contains "$(cat "$CODA_TEST_STATE_DIR/tmux-windows")" "coda-orch--my-orch:feat-d" \
    "feat-d should be tracked as orch window"

done_orch_output="$(coda feature done feat-d --orch my-orch 2>&1)"
assert_contains "$done_orch_output" "Killing window: coda-orch--my-orch:feat-d" \
    "feature done --orch should kill the named orch window"
assert_not_exists "$PROJECTS_DIR/window-test/feat-d" \
    "feature done --orch should remove worktree"

# -- Test 9: multi-match errors when two orchs have same window name --

# Set up: create two orch sessions, each with a window named "feat-e"
echo "coda-orch--alpha" >> "$CODA_TEST_STATE_DIR/tmux-sessions"
echo "coda-orch--beta" >> "$CODA_TEST_STATE_DIR/tmux-sessions"
echo "coda-orch--alpha:feat-e" >> "$CODA_TEST_STATE_DIR/tmux-windows"
echo "coda-orch--beta:feat-e" >> "$CODA_TEST_STATE_DIR/tmux-windows"

# Create worktree for feat-e manually so done doesn't fail on project lookup
coda feature start feat-e >/dev/null 2>&1

multi_status=0
multi_done_output="$(coda feature done feat-e 2>&1)" || multi_status=$?
assert_contains "$multi_done_output" "Multiple orchestrator sessions" \
    "multi-match should produce disambiguation error"
[ "$multi_status" -ne 0 ] || fail "multi-match should exit nonzero"

# Both orch windows should still exist (no teardown happened)
assert_contains "$(cat "$CODA_TEST_STATE_DIR/tmux-windows")" "coda-orch--alpha:feat-e" \
    "multi-match should not kill any windows"
assert_contains "$(cat "$CODA_TEST_STATE_DIR/tmux-windows")" "coda-orch--beta:feat-e" \
    "multi-match should not kill any windows"

# Clean up feat-e standalone session and worktree
coda feature done feat-e --orch alpha >/dev/null 2>&1 || true

printf 'PASS: window-mode tests\n'
