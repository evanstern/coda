# CLIProxyAPI × OpenCode × Coda Design

## Goal

Adapt the basic OpenCode custom-provider pattern from the CLIProxyAPI gist into a Coda-native workflow that fits this repo’s existing architecture:

- shell-first orchestration in `shell-functions.sh`
- config centralized in `.env`
- OpenCode launched via `coda` and `coda serve`
- tmux-driven UX and worktree-per-feature isolation

This design is intentionally tailored to the current repo, not a generic app/server rewrite.

---

## What the example gist proves

The gist shows that OpenCode can talk to CLIProxyAPI as a custom provider by using:

- `npm: "@ai-sdk/openai-compatible"`
- `options.baseURL: "http://localhost:8317/v1"`
- a provider-local `models` map in `opencode.json`

That means the integration boundary is simple: OpenCode only needs an OpenAI-compatible endpoint plus model metadata. CLIProxyAPI handles upstream auth and model routing.

---

## What this repo already does today

### Existing integration surfaces

- `shell-functions.sh`
  - `_coda_auth()` currently wires Claude credentials into OpenCode by installing `opencode-claude-auth`
  - `_coda_serve()` runs `opencode serve --port ...` with `OPENCODE_HEADLESS_PERMISSION`
- `.env.example`
  - already defines the repo’s config contract, including OpenCode port and permission settings
- `README.md`
  - documents `coda auth`, `coda serve`, layouts, profiles, and OpenCode workflows
- `tmux.conf` and `scripts/tmux-opencode-compose.sh`
  - assume OpenCode is the interactive agent surface and route composed prompts into the correct pane heuristically

### Important constraint

This repo is not an application server. It is a shell/tmux control plane around OpenCode. So the correct design is to add provider/config/auth management around OpenCode, not to build new proxy logic into Coda itself.

---

## Recommended design

### Summary

Treat CLIProxyAPI as an optional Coda-managed upstream for OpenCode.

Coda should:

1. manage the local OpenCode config needed to point at CLIProxyAPI
2. expose simple shell commands for setup/verification
3. keep provider defaults in `.env`
4. preserve existing OpenCode session, layout, and headless workflows unchanged

CLIProxyAPI should remain a separate process/service.

---

## Architecture

```text
User / tmux / coda
    |
    |  coda auth / coda serve / coda <session>
    v
OpenCode
    |
    |  custom provider via opencode.json
    v
CLIProxyAPI (localhost:8317/v1)
    |
    |  provider routing + auth handling
    v
Claude / Gemini / Qwen / DeepSeek / etc.
```

### Why this shape fits the repo

- matches the existing shell-first control model
- keeps `.env` as the configuration source of truth
- does not interfere with tmux pane detection or session management
- keeps `coda serve` focused on OpenCode headless mode, not upstream proxy responsibilities

---

## Scope boundaries

### In scope

- Coda-side configuration for using CLIProxyAPI from OpenCode
- Coda commands for setup, verification, and switching provider mode
- generated or managed `opencode.json` content for the custom provider
- documentation for the new flow

### Out of scope

- embedding CLIProxyAPI into this repo
- rewriting Coda as an HTTP proxy
- replacing tmux/OpenCode interaction patterns
- inventing a second auth stack when CLIProxyAPI already manages upstream auth

---

## Design details

## 1. Provider mode becomes explicit in Coda config

Add provider-oriented env settings to `.env.example` so the repo can support both the current Claude-auth path and the new CLIProxyAPI path.

Suggested additions:

```bash
# Which OpenCode provider mode Coda should configure
# Options: claude-auth, cliproxyapi
CODA_PROVIDER_MODE="claude-auth"

# CLIProxyAPI endpoint for OpenCode custom provider
CLIPROXYAPI_BASE_URL="http://localhost:8317/v1"

# Optional health endpoint used by verification commands
CLIPROXYAPI_HEALTH_URL="http://localhost:8317/health"

# Path where Coda writes/maintains the OpenCode provider config
# Leave empty to use OpenCode's default config location
CODA_OPENCODE_CONFIG_PATH=""
```

### Why

- preserves the repo’s existing `.env` pattern
- lets users opt in without breaking today’s Claude-based flow
- avoids hardcoding CLIProxyAPI assumptions into session creation or tmux logic

---

## 2. `coda auth` becomes provider-aware

Today `_coda_auth()` is Claude-specific:

- checks `claude auth status`
- checks `~/.claude/.credentials.json`
- installs `opencode-claude-auth`
- lists Anthropic models

The design should evolve `coda auth` into a small dispatcher:

- `CODA_PROVIDER_MODE=claude-auth`
  - keep the current behavior
- `CODA_PROVIDER_MODE=cliproxyapi`
  - verify CLIProxyAPI is reachable
  - write or update the OpenCode custom provider config
  - optionally probe `/v1/models`
  - print next-step verification commands

### Recommendation

Keep the command name `coda auth` for continuity, but make its behavior mode-dependent.

Why that is better than adding a completely separate command:

- fits current docs and mental model
- keeps one “wire OpenCode to its provider” entry point
- avoids spreading setup across multiple commands too early

---

## 3. Coda should manage `opencode.json`, not ask users to hand-edit it

The gist is manual. This repo should automate it.

### Recommended behavior

When provider mode is `cliproxyapi`, `coda auth` should generate the required OpenCode config block with:

- provider name `cliproxyapi`
- `npm: "@ai-sdk/openai-compatible"`
- `options.baseURL` from `CLIPROXYAPI_BASE_URL`
- a model map sourced from discovery or a curated fallback

### Preferred source of models

1. **First choice:** query CLIProxyAPI dynamically, ideally via `/v1/models`
2. **Fallback:** ship a curated minimal model set in this repo
3. **Avoid:** a giant static model catalog copied from the gist

### Why dynamic-first is the right default

The gist’s large model list is useful as proof of compatibility, but it is a poor long-term config source for this repo because it becomes stale and couples Coda to someone else’s local setup.

---

## 4. Keep CLIProxyAPI lifecycle separate from `coda serve`

`_coda_serve()` currently means “run OpenCode headless on a free local port.” That should stay true.

### Recommendation

Do **not** overload `coda serve` to also start CLIProxyAPI.

Instead, add either:

- lightweight verification only, or
- a separate helper such as `coda provider status` / `coda provider doctor`

### Why

- `coda serve` is already clearly documented as OpenCode headless mode
- mixing upstream proxy lifecycle into it would blur responsibilities
- users may run one shared CLIProxyAPI instance for many OpenCode sessions

---

## 5. Add a provider-status command

The repo needs a fast sanity check for the full chain.

Recommended command shape:

```bash
coda provider status
```

Expected checks:

1. print active `CODA_PROVIDER_MODE`
2. verify `opencode` is installed
3. if mode is `cliproxyapi`, verify `CLIPROXYAPI_BASE_URL` responds
4. if available, probe `/health`
5. probe `/v1/models`
6. report config file path used by OpenCode

This gives a clean operator workflow before users start sessions.

---

## 6. Preserve tmux and layout behavior exactly as-is

No design change is needed in:

- `tmux.conf`
- `scripts/tmux-opencode-compose.sh`
- layout scripts under `layouts/`
- watcher behavior in `coda-watcher.sh`

These parts interact with OpenCode as a terminal application, not with the upstream provider. As long as OpenCode still launches normally, they should remain unchanged.

---

## 7. Documentation should teach two provider paths

The README currently documents the Claude-only setup flow:

1. `claude auth login`
2. `coda auth`

That needs to become two explicit paths:

### Claude path

Keep the current flow for users who want direct Claude auth.

### CLIProxyAPI path

Document:

1. install/run CLIProxyAPI separately
2. set `CODA_PROVIDER_MODE=cliproxyapi`
3. set `CLIPROXYAPI_BASE_URL`
4. run `coda auth`
5. run `coda provider status`
6. start or attach to OpenCode sessions normally

---

## File-level plan

### `shell-functions.sh`

Add:

- provider-mode dispatch inside `_coda_auth()` or a new wrapper around it
- helpers for:
  - resolving OpenCode config path
  - writing/updating custom provider config
  - probing CLIProxyAPI endpoints
  - printing provider diagnostics
- optional new subcommand such as `coda provider status`

Preserve:

- `_coda_serve()` contract
- session naming with `SESSION_PREFIX`
- worktree/session behavior

### `.env.example`

Add provider-mode and CLIProxyAPI config variables.

### `README.md`

Update installation/auth sections and add a CLIProxyAPI setup flow.

### `man/coda.1`

Mirror the new provider-aware command behavior.

### `install.sh`

Possibly add soft checks or optional messaging, but do not make CLIProxyAPI a hard dependency for base install.

---

## Rollout plan

## Phase 1 — Minimal useful integration

Deliver:

- env-driven provider mode
- `coda auth` support for `cliproxyapi`
- managed custom-provider config generation
- README/man updates

This gets OpenCode talking to CLIProxyAPI in a way that matches the repo’s architecture.

## Phase 2 — Better diagnostics

Deliver:

- `coda provider status`
- `/health` and `/v1/models` checks
- clearer failure messages for bad base URLs or missing models

## Phase 3 — Dynamic model sync polish

Deliver:

- model discovery from CLIProxyAPI
- stable mapping into generated OpenCode provider config
- fallback behavior when discovery is unavailable

---

## Explicit recommendation

The best design for this repo is:

1. **keep CLIProxyAPI external**
2. **make Coda provider-aware through `.env` + `coda auth`**
3. **generate OpenCode custom-provider config automatically**
4. **add provider diagnostics instead of overloading `coda serve`**
5. **leave tmux/layout/session mechanics untouched**

This is the smallest design that is aligned with the current codebase and gives Coda a clean path from today’s Claude plugin flow to a broader CLIProxyAPI-backed provider model.

---

## Open questions to resolve before implementation

1. Where should Coda write the OpenCode config by default: project-local, user-global, or a Coda-managed generated path?
2. Should `cliproxyapi` mode fully replace `claude-auth`, or should users be able to keep both configured simultaneously?
3. Do we want a curated default model subset for a stable UX, or full dynamic discovery from the proxy every time?
4. Do we want optional helper commands for starting/stopping CLIProxyAPI locally, or should process management remain fully outside this repo?

---

## Decision

If we proceed, I recommend implementing **Phase 1 + Phase 2 together**. That yields a usable integration and enough diagnostics to keep support costs reasonable.
