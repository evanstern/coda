# Coda Rearchitecture Work Plan

**Date:** 2025-07-14  
**Status:** Approved (pending implementation kickoff)  
**Goal:** Get Coda from a well-built personal tool to a public-ready, pluggable tmux+OpenCode orchestrator.

---

## Executive Summary

Coda is 80% of the way there. The core lifecycle (`branch → worktree → session`) is solid. The work is making every seam that exists today *discoverable, documented, and extensible* — without adding complexity the architecture doesn't need.

Four parallel work streams, ordered by dependency:

```
         ┌─────────┐
         │ Stream D │  (can start immediately)
         │ Stabil.  │
         └─────────┘

         ┌─────────┐
         │ Stream A │  (can start immediately)
         │ Plugins  │
         └────┬────┘
              │ informs
         ┌────▼────┐
         │ Stream B │  (B1 can start now; B2-B3 after A3/A4 land)
         │ Config   │
         └────┬────┘
              │ feeds
         ┌────▼────┐
         │ Stream C │  (after A is done)
         │ CLI UX   │
         └─────────┘
```

---

## Stream A: Plugin Framework

**Goal:** Formalize every extension point with documented contracts, validation, and full test coverage.

### A1. Layout Interface Contract

**Files:** `lib/layout.sh`, new `docs/plugin-contracts/layouts.md`

**Changes:**
- Add `_coda_validate_layout()` — after `source`, verify `_layout_init` is defined (required), log warning if `_layout_spawn` is missing
- Document the 3-function interface: `_layout_init` (required), `_layout_spawn` (recommended), `_layout_apply` (deprecated alias)
- Document env vars available to layouts: `CODA_SESSION_NAME`, `CODA_SESSION_DIR`, `CODA_NVIM_APPNAME`
- Cleanup: `unset` ALL functions defined by previous layout, not just the 3 known names (track via `declare -F` before/after source)

**Tests (bats):**
- Layout with only `_layout_init` → succeeds
- Layout with `_layout_init` + `_layout_spawn` → both callable
- Layout missing `_layout_init` → error message, non-zero return
- Layout defining extra functions → cleaned up after next layout load
- User layout shadows builtin of same name → user wins
- `coda layout ls` → shows both user and builtin, annotated

### A2. Hooks Expansion

**Files:** `lib/hooks.sh`, `lib/core.sh`, `lib/project.sh`, `lib/feature.sh`, `lib/layout.sh`

**Changes — add 6 new hook events (10 total):**

| Event | Caller | New Env Vars |
|-------|--------|-------------|
| `pre-session-create` | `core.sh` before `tmux new-session` | `CODA_SESSION_NAME`, `CODA_SESSION_DIR` |
| `post-session-attach` | `core.sh` after attach/switch | `CODA_SESSION_NAME` |
| `post-project-clone` | `project.sh` (clone path, distinct from `--new`) | `CODA_PROJECT_NAME`, `CODA_PROJECT_DIR`, `CODA_REPO_URL` |
| `post-feature-finish` | `feature.sh` in the background teardown | `CODA_PROJECT_NAME`, `CODA_FEATURE_BRANCH` |
| `pre-project-close` | `project.sh` before kill | `CODA_PROJECT_NAME`, `CODA_PROJECT_DIR` |
| `post-layout-apply` | `layout.sh` after apply completes | `CODA_SESSION_NAME`, `CODA_SESSION_LAYOUT` |

**Tests (bats + stub):**
- For each of the 10 events: hook script runs, receives correct env vars
- Hook failure doesn't block caller (existing, but verify for new events)
- Hooks execute in sorted order
- User hooks run before builtin hooks
- Empty hook directory → no error
- Non-executable file in hook dir → skipped silently

### A3. Provider Plugin System

**Files:** `lib/provider.sh`, new `providers/` directory convention

**Changes:**
- Replace closed `case` enum with directory-based dispatch:
  ```
  $_CODA_DIR/providers/<mode>/   (builtin)
  $CODA_PROVIDERS_DIR/<mode>/    (user, ~/.config/coda/providers/)
  ```
- Each provider directory contains `auth.sh` and `status.sh` — sourced scripts that define `_provider_auth()` and `_provider_status()`
- Migrate `claude-auth` and `cliproxyapi` into `providers/claude-auth/` and `providers/cliproxyapi/`
- `_coda_provider_mode()` validates the mode directory exists
- Add `CODA_PROVIDERS_DIR` to `.env.example`

**Tests (bats):**
- `claude-auth` provider loads and defines `_provider_auth`
- `cliproxyapi` provider loads and defines `_provider_auth` + `_provider_status`
- Unknown provider mode → clear error with list of available providers
- User provider shadows builtin of same name → user wins
- Provider missing `auth.sh` → error
- `coda provider ls` → lists available providers from both dirs

### A4. Watcher Notification Plugins

**Files:** `cmd/coda-core/watch.go`, `coda-watcher.sh`, new `notifications/` directory

**Changes:**
- Replace hardcoded BEL with notification plugin directory:
  ```
  $_CODA_DIR/notifications/   (builtin)
  $CODA_NOTIFICATIONS_DIR/    (user, ~/.config/coda/notifications/)
  ```
- Each notification is an executable script receiving env vars: `CODA_PANE_ID`, `CODA_SESSION_NAME`, `CODA_NOTIFICATION_EVENT` (`idle`)
- Ship `notifications/bell.sh` as the default (the current BEL logic)
- `watch.go`: on notification trigger, execute all scripts in the notifications dirs (same sorted-overlay pattern as hooks)
- Add `CODA_NOTIFICATIONS_DIR` to `.env.example`

**Tests (Go + bats):**
- `bell.sh` notification runs on idle transition
- Custom notification script receives correct env vars
- Multiple notifications execute in order
- Failing notification doesn't block others
- Empty notifications dir → no error (silent)

### A5. Profile Expansion

**Files:** `lib/helpers.sh:60-97`, `lib/profile.sh`

**Changes:**
- Expand profile variables beyond just 2:

| Variable | Purpose |
|----------|--------|
| `CODA_LAYOUT` | (existing) |
| `CODA_NVIM_APPNAME` | (existing) |
| `CODA_PROVIDER_MODE` | Provider preference per profile |
| `CODA_HOOKS_DIR` | Hook directory override per profile |
| `CODA_WATCH_INTERVAL` | Watcher poll rate per profile |
| `CODA_WATCH_COOLDOWN` | Watcher cooldown per profile |

- Update `_coda_resolve_effective_config()` to extract and return all 6 values
- Replace the `sed -n '1p'` / `sed -n '2p'` protocol with tab-delimited output or associative array

**Tests (bats):**
- Profile with `CODA_PROVIDER_MODE` → overrides default
- Profile with `CODA_HOOKS_DIR` → hooks load from custom dir
- Precedence: flag > env var > profile > project `.coda.env` > default (for each variable)
- Profile with unknown variable → silently ignored
- Missing profile → error with list of available profiles

---

## Stream B: Configuration & Defaults

**Goal:** Remove all personal assumptions, document all config surfaces.

### B1. Extract Hardcoded Values

| What | File | Change |
|------|------|--------|
| `evanstern` GitHub owner | `shell-functions.sh:21` | Remove default. Add `NEW_PROJECT_GITHUB_OWNER` to `.env.example` with empty value. `project.sh` errors if unset when `--new` is used. |
| OpenCode version detect | `cmd/coda-core/watch.go:145-151` | Match `"OpenCode "` + any digit, not `"OpenCode 0."` through `"OpenCode 3."` |
| `$HOME/.claude/.credentials.json` | `lib/provider.sh:32` | Add `CLAUDE_CREDENTIALS_PATH` to `.env.example`, default to current path |
| Fallback model list | `lib/provider.sh:301-321` AND `cmd/coda-core/provider.go:285-293` | Delete from shell. Go is authoritative. Shell calls `coda-core provider fallback-models` |
| `coda-watcher` session name | `lib/watch.sh:8` | Derive: `"${SESSION_PREFIX}watcher"` |
| Branch sanitization | `lib/helpers.sh:7` | Replace `/` → `--`, spaces → `-`, colons → `-`, in addition to existing `.` → `-` |
| `tmux-opencode-compose` path | `tmux.conf:99` | Use `$CODA_COMPOSE_CMD` env var with fallback to current path |
| `_coda_switch` unfiltered | `lib/core.sh:135` | Filter by `SESSION_PREFIX` (same as `_coda_ls`) |

### B2. Document Per-Project `.coda.env`

**Files:** `.env.example`, `README.md`, `man/coda.1`
- Add section to `.env.example` explaining `.coda.env`
- Add section to README under Configuration
- Add to man page CONFIGURATION section

### B3. Missing `.env.example` Variables

Add to `.env.example`:
- `CODA_HOOKS_DIR` (default: `~/.config/coda/hooks`)
- `NEW_PROJECT_GITHUB_OWNER` (no default, required for `--new`)
- `CODA_PROVIDERS_DIR` (default: `~/.config/coda/providers`) — from A3
- `CODA_NOTIFICATIONS_DIR` (default: `~/.config/coda/notifications`) — from A4
- `CLAUDE_CREDENTIALS_PATH` (default: `~/.claude/.credentials.json`)

---

## Stream C: CLI UX & Discoverability

**Goal:** Every extension point has CLI commands, man page coverage, and tab completion.

### C1. New CLI Subcommands

**Files:** `lib/hooks.sh`, `lib/provider.sh`

- **`coda hooks ls [event]`** — list hook scripts. Show source (user/builtin), path, executable status.
- **`coda hooks create <event> <name>`** — scaffold a new hook in `$CODA_HOOKS_DIR/<event>/<name>`, pre-filled with available env vars.
- **`coda hooks run <event>`** — manually trigger hooks for an event (debug mode).
- **`coda hooks events`** — list all 10 supported events with descriptions.
- **`coda provider ls`** — list available providers from both dirs with active indicator.

### C2. Man Page Updates

**File:** `man/coda.1`
- Add `HOOKS` section: all 10 events, env vars for each, directory structure, execution order
- Add `PROVIDERS` section: how to create a custom provider, directory structure
- Add `NOTIFICATIONS` section: watcher notification plugins
- Update `CONFIGURATION` table with new variables from B3
- Add `PER-PROJECT CONFIGURATION` subsection documenting `.coda.env`
- Add `coda hooks` and `coda provider ls` to SUBCOMMANDS

### C3. Tab Completion Updates

**Files:** `completions/coda.bash`, `completions/coda.zsh`

New completions:
```
coda hooks <TAB>           → ls create run events
coda hooks ls <TAB>        → [available event names]
coda hooks create <TAB>    → [available event names] → [name]
coda hooks run <TAB>       → [available event names]
coda provider <TAB>        → status ls    (add 'ls')
```

Add helper functions:
- `_coda_hook_events()` — returns list of known event names
- `_coda_providers()` — returns list of available provider directories

### C4. Error Messages That Teach

**Files:** `lib/layout.sh`, `lib/hooks.sh`, `lib/provider.sh`, `lib/profile.sh`

When something isn't found, say where to put it:
- `Layout 'foo' not found. Available: ... Create one: coda layout create foo`
- `Profile 'bar' not found. Available: ... Create one: coda profile create bar`
- `Provider 'baz' not found. Available: ... Providers live in: ~/.config/coda/providers/`
- `No hooks for event 'post-session-create'. Create one: coda hooks create post-session-create my-hook`

---

## Stream D: Stabilization & DX

**Goal:** Go authoritative, fix fragilities, full test coverage, CI, close open items.

### D1. Go Authoritative (Eliminate Dual Implementation)

**Files:** `lib/provider.sh`, `cmd/coda-core/provider.go`

- Remove `_coda_auth_cliproxyapi_fallback` and `_coda_provider_status_fallback` from `provider.sh`
- Remove `_coda_fallback_cliproxyapi_models` from `provider.sh`
- `provider.sh` now requires `coda-core` — if missing, error: `"coda-core not found. Run install.sh to build it."`
- Add `coda-core provider fallback-models` subcommand to Go (single source of truth)
- `install.sh` already builds `coda-core`; verify it's in `$PATH` post-install

### D2. Fix OpenCode Version Detection

**File:** `cmd/coda-core/watch.go:145-151`
- Change match from `"OpenCode 0."` ... `"OpenCode 3."` to regex `OpenCode \d+\.`
- Also fix shell watcher `coda-watcher.sh` to match

### D3. Failure-Path Tests

**Files:** `tests/core-lifecycle.sh`, `test/shell-modules.bats`

New test cases:
- Branch name with `/` → session name is valid
- Branch name with spaces → sanitized correctly
- `feature done` on non-existent branch → clean error
- `feature start` when worktree already exists → attaches, doesn't duplicate
- `project close --delete` outside `PROJECTS_DIR` → refused
- `project start --new` without `NEW_PROJECT_GITHUB_OWNER` → clear error
- Concurrent `feature start` same branch → no corruption
- `coda switch` with no sessions → clean message

### D4. CI Pipeline

**New file:** `.github/workflows/ci.yml`
- Job 1: `go test ./cmd/coda-core/...`
- Job 2: `bats test/shell-modules.bats`
- Job 3: `bash tests/run.sh`
- Job 4: shellcheck on all `lib/*.sh` + `shell-functions.sh`
- Trigger: push to `rearchitect`, PRs targeting `rearchitect`

### D5. Accept ADRs

**Files:** `docs/adr/0001-*.md`, `docs/adr/0002-*.md`, `docs/adr/0003-*.md`
- Change status from "Proposed" to "Accepted"
- Add date of acceptance
- Add amendments from implementation decisions

### D6. Close Open Design Questions

**File:** `docs/coda-v1-design.md`

| Question | Answer | Rationale |
|----------|--------|-----------|
| Project config format? | `.coda.env` | Already implemented in `helpers.sh:51-58` |
| Which hook events? | 10 events (see A2) | Covers full lifecycle |
| Bundle watcher in core? | No — companion per ADR-0003 | Architecturally separate |
| Harness customization limit? | Layout + hooks + provider selection | No deeper harness customization for v1 |

---

## What We Keep (It's a Lot)

The rearchitecture is *not* a rewrite. These things are solid:

- The `branch → worktree → session` invariant and all lifecycle code
- The modular `lib/*.sh` structure and thin loader
- The Go companion binary architecture (zero deps, clean subcommands)
- The MCP server's thin-adapter pattern
- The two-directory overlay pattern (just formalize and extend it)
- The config precedence chain (just expand what it covers)
- The test infrastructure (just add coverage)
- The man page, completions, ADRs, design docs (just update)
- `coda-dev` isolation (elegant and correct)
