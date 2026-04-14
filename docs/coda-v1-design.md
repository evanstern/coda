# Coda v1 Design Brief

## Status

Draft working design for the next shape of Coda.

## Purpose

This document defines what Coda v1 is, what it is not, and where customization belongs.
It is an implementation-facing companion to the public `README.md` and `man/coda.1`, not a replacement for them.

## Summary

Coda is a terminal-first orchestration tool for remote development servers.

Its core model is simple:

- a project is managed as a git worktree workspace
- each active feature branch maps to its own worktree
- each active worktree maps to its own tmux session
- sessions are persistent, reconnectable, and safe to run in parallel

That session-per-branch/worktree model is the product. Most other concerns exist to support it.

## Goals

1. Make parallel branch-based AI-assisted development predictable.
2. Keep remote development sessions easy to reconnect to from anywhere.
3. Preserve strong defaults without forcing one personal machine setup.
4. Support customization through stable, simple extension surfaces.
5. Keep core behavior legible enough that shell users can understand and debug it.

## Non-Goals

1. Coda is not a general IDE platform.
2. Coda is not a generic plugin host for arbitrary third-party code.
3. Coda is not responsible for language-specific build or test tooling.
4. Coda is not a cross-platform bootstrap framework for every operating system.
5. Coda is not trying to replace tmux, git, or the AI harness itself.

## Primary Users

The intended user is a developer who:

- works primarily in the terminal
- treats a remote dev server as a persistent working environment
- uses an AI harness as a primary coding interface
- frequently has multiple branches or tasks active at once
- values reconnectability and low-friction context switching more than GUI polish

## Primary Use Cases

### 1. Start or reconnect to a project

The user clones or creates a project once, then reconnects to its main branch session whenever needed.

### 2. Start a feature in isolation

The user creates a new worktree for a branch and gets a dedicated tmux session attached to that worktree.

### 3. Run multiple AI sessions in parallel

The user keeps several feature branches open at once, each with its own isolated session.

### 4. Leave and return later

The user disconnects from the remote server, then reconnects later and resumes work without reconstructing local state.

### 5. Customize workspace ergonomics

The user chooses a preferred session layout, editor sandbox, and machine-level defaults without changing core orchestration behavior.

## Core Mental Model

The core relationship is:

```text
project
  -> bare repo + managed worktree root
  -> default branch worktree
  -> zero or more feature worktrees

feature worktree
  -> one branch
  -> one tmux session
  -> one active AI working context
```

This mapping should remain easy to reason about from the shell.

If a user knows the project name and branch name, they should be able to predict:

- where the worktree lives
- what the tmux session is called
- how to attach to it
- how it is torn down

## Current Repository Shape

Today, the repository already contains most of the relevant building blocks:

- core command and lifecycle logic in `shell-functions.sh`
- built-in layouts in `layouts/`
- profile and layout search paths via config
- watcher support in `coda-watcher.sh`
- shell integration and bootstrap logic in `install.sh`
- tmux UX defaults in `tmux.conf`
- some machine-specific helper scripts in `scripts/`

V1 should preserve the working core while making the boundaries more explicit.

## What Belongs in Core

Core is the part of Coda that owns the branch-to-session lifecycle.

That includes:

1. Project registration and worktree organization.
2. Feature creation and teardown.
3. Session naming and attachment behavior.
4. Session switching and discovery.
5. Basic runtime configuration needed to support the lifecycle.

Concretely, the core command surface should continue to center on:

- `coda`
- `coda attach`
- `coda ls`
- `coda switch`
- `coda project ...`
- `coda feature ...`

## What Core Explicitly Owns

### Session identity

Session naming conventions are not cosmetic. They are part of how the system remains predictable.

### Worktree lifecycle

Branch creation, worktree creation, session launch, and teardown are the heart of the tool.

### Remote-first reconnectability

Coda assumes a persistent remote environment where tmux is the continuity mechanism.

### Sharp defaults

The core should continue to prefer one good way to work over many ambiguous modes.

## Layouts

Layouts remain a first-class Coda feature.

They are part of how a session becomes usable immediately after creation, and they affect the primary interface the user sees every day.

At the same time, layouts are customization surfaces rather than orchestration surfaces.

That means:

- core owns the fact that sessions can be created with layouts
- layout implementations remain swappable
- bundled layouts are useful defaults, not the definition of Coda itself

### Layout Design Rules

1. Layouts control pane topology and startup commands inside a session.
2. Layouts do not redefine the project/worktree/session model.
3. Layouts should be discoverable from both built-in and user-owned locations.
4. A broken layout should fail locally without corrupting core project state.

### V1 Direction

Keep:

- `coda layout ...`
- built-in layout presets
- user layout override directories

Avoid:

- a general plugin marketplace mentality around layouts
- making layouts the main product abstraction
- forcing layouts into a separate repository before the core interface stabilizes

## Profiles and Configuration

Profiles are the right place for workflow-specific defaults.

Examples include:

- preferred layout
- alternate `NVIM_APPNAME`
- machine- or user-specific session defaults

Configuration should remain layered and easy to inspect.

### Preferred precedence

From lowest to highest priority:

1. built-in defaults
2. global config
3. project-level config
4. profile values
5. environment variables
6. explicit CLI flags

### Configuration Principles

1. Use config for stable preferences.
2. Use profiles for named workflow variants.
3. Use environment variables for machine/runtime wiring.
4. Use flags for explicit one-off overrides.

## Hooks Instead of a Broad Plugin System

V1 should prefer hooks over a general plugin platform.

Why:

- shell hooks are easier to debug than plugin APIs
- lifecycle events already provide natural extension boundaries
- users of terminal tools are comfortable composing behavior with scripts
- the core is still stabilizing, so a plugin API would calcify the wrong boundaries too early

### Likely hook points

- after project creation
- after feature/worktree creation
- before feature teardown
- after session creation
- after session switch
- after layout application

### Hook expectations

1. Hooks should receive predictable environment variables.
2. Hooks should be optional.
3. Hook failures should be visible.
4. Hooks should not silently mutate core state contracts.

## Companion Utilities Boundary

Some capabilities are useful but should not define Coda core.

These belong in companion utilities, optional built-ins, or separate helper scripts:

- machine bootstrap and package installation
- provider-specific auth bridging
- device-specific connection helpers
- desktop notification integrations
- personal hardware automation

### Why this boundary matters

Without it, Coda becomes a bundle of one person's infrastructure choices instead of a reusable tool.

### Current repo examples that are adjacent, not core-defining

- `install.sh`
- `setup-vm.sh`
- `coda-watcher.sh`
- `scripts/streamdeck-vm104-connect.sh`
- parts of `tmux.conf` that improve UX but do not define orchestration

These can still ship in the repository. The important thing is that they are treated as supporting modules rather than the center of the design.

## AI Harness Boundary

Coda should orchestrate AI working contexts, not become tightly identified with one harness implementation detail.

V1 should support the current OpenCode-oriented workflow while making room for harness-level customization at the config or hook layer.

That means:

- session orchestration remains core
- harness launch commands and auth bridges are configurable edges
- harness-specific watchers or helpers should not distort the core model

## Operational Constraints

V1 assumes:

- a remote environment where tmux is available
- git worktrees are the isolation mechanism
- shell-based inspection and repair are normal operating tools

V1 does not need to solve every local-desktop workflow.

## Failure Modes to Design Around

1. Session naming drift that makes sessions hard to predict.
2. Layout logic becoming so smart that it obscures failures.
3. Bootstrap logic crowding the core command surface.
4. Harness-specific assumptions leaking into unrelated commands.
5. Personal machine integrations becoming de facto architecture.

## Design Principles for v1

1. **Session-per-branch is the invariant.**
2. **Core owns lifecycle; customization reacts to lifecycle.**
3. **Configuration beats plugins.**
4. **Layouts are first-class, but not the center of the product.**
5. **Machine-specific conveniences are companions, not foundations.**
6. **The shell should remain a good debugging interface to the system.**
7. **Users should be able to predict behavior from naming and directory structure alone.**

## Open Questions (Resolved)

1. **Project-level config format?** `.coda.env` — implemented in `lib/helpers.sh:51-58`. Consistent with the global `.env` format, no new parser needed.
2. **Which hook points for v1?** 10 events covering the full lifecycle: `pre-session-create`, `post-session-create`, `post-session-attach`, `post-project-create`, `post-project-clone`, `pre-project-close`, `post-feature-create`, `pre-feature-teardown`, `post-feature-finish`, `post-layout-apply`.
3. **Watcher bundling?** No — companion utility per ADR-0003. Lives in-tree but architecturally separate from core lifecycle.
4. **Harness customization limit?** Layout + hooks + provider selection. No deeper harness customization for v1. The AI harness launch command is configurable through layouts; auth bridging is configurable through providers.

## Related ADRs

- `docs/adr/0001-core-orchestration-model.md`
- `docs/adr/0002-layouts-and-customization-model.md`
- `docs/adr/0003-companion-utilities-boundary.md`
