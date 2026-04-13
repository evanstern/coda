# Coda Agent Guide

This file defines what Coda is, what it is not, and how agents should work in this repository.

It is intentionally opinionated.

For fuller design context, also read:

- `docs/coda-v1-design.md`
- `docs/coda-v1-branch-plan.md`
- `docs/coda-v1-slice-01-core-lifecycle.md`
- `docs/adr/0001-core-orchestration-model.md`
- `docs/adr/0002-layouts-and-customization-model.md`
- `docs/adr/0003-companion-utilities-boundary.md`

## What Coda Is

Coda is a terminal-first orchestration tool for remote development servers.

Its purpose is to make branch-based development easy to run in parallel by mapping git worktrees to persistent tmux sessions.

The core model is:

```text
project -> worktree -> branch -> tmux session
```

More specifically:

- a project has a managed git workspace
- each active feature branch gets its own worktree
- each active worktree gets its own tmux session
- that session is reconnectable and safe to leave running on a remote server

This branch/worktree/session relationship is the center of the product.

## What Coda Is Not

Coda is not:

- a general IDE platform
- a plugin platform for arbitrary third-party behavior
- a bundle of one person's machine setup
- a replacement for tmux, git, or the AI harness itself
- a broad remote bootstrap framework for every operating system and environment

## Product Philosophy

When developing Coda, adhere to these principles:

1. **Session-per-branch is the invariant.**
2. **Core owns lifecycle; customization reacts to lifecycle.**
3. **Predictability beats cleverness.**
4. **Configuration beats plugins.**
5. **Layouts are first-class, but not the center of the product.**
6. **Machine-specific conveniences are companions, not foundations.**
7. **The shell must remain a good debugging interface.**

If a change weakens the predictability of the branch/worktree/session model, it is probably the wrong change.

## How Coda Should Be Used

The intended workflow is:

1. Connect to a persistent remote development server.
2. Use Coda to enter or reconnect to a project.
3. Start a feature branch in an isolated worktree.
4. Let Coda create or attach the matching tmux session.
5. Work inside that session with your editor, shell tools, and AI harness.
6. Leave and reconnect later without losing the session context.
7. Finish the feature by tearing down the worktree/session cleanly.

Agents should preserve and strengthen this workflow.

## Development Priorities

### Core

Prioritize:

- project/worktree/session identity
- feature lifecycle behavior
- attach/list/switch flows
- deterministic naming and path rules
- testability of the lifecycle spine

### First-Class Customization

Support, but do not let dominate the architecture:

- layouts
- profiles
- config layering
- lifecycle hooks

### Companion Concerns

Keep adjacent to core, not inside its identity:

- bootstrap/install scripts
- auth bridges tied to specific providers
- watcher delivery backends
- personal hardware or desktop helpers
- highly personal tmux UX niceties

## Guidance For Agents Working In This Repo

### Prefer changes that clarify the model

Good changes:

- make naming/path/session behavior more deterministic
- reduce personal assumptions in core code
- add tests around lifecycle behavior
- introduce explicit boundaries where behavior is currently implicit

Suspicious changes:

- adding new integration surface before the core lifecycle is stable
- inventing a plugin system to avoid making a design decision
- making bootstrap or auth flows more elaborate before the core is proven
- adding convenience behavior that hides state transitions from the user

### Do not confuse built-ins with the core

Some features can remain bundled without defining the product.

Examples include watcher support, machine bootstrap helpers, and personal connection scripts. These may be useful, but they should not dictate the architecture of Coda itself.

### Keep the product easy to explain

A future user should be able to understand Coda in a few sentences:

> Coda gives each branch its own worktree and its own tmux session on a remote server so you can run several AI-assisted coding tasks in parallel and reconnect to them anytime.

If a new change makes that explanation harder, reconsider it.

## Repository Structure

The codebase is organized as modular shell libraries loaded by a thin entry point:

```
shell-functions.sh          Loader: sources .env, sets defaults, loads lib/*.sh
lib/
  helpers.sh                Shared utilities (sanitize, detect branch, find root)
  core.sh                   Entry points: coda(), coda-dev(), attach/ls/switch/serve/help
  project.sh                Project management (start/add/workon/close/ls)
  feature.sh                Feature branch lifecycle (start/done/finish/ls)
  layout.sh                 Layout management (apply/ls/show/create)
  provider.sh               Auth provider wiring (claude-auth, cliproxyapi)
  profile.sh                Profile management (ls/create/show)
  hooks.sh                  Lifecycle hook runner
  watch.sh                  Session watcher (start/stop/status)
hooks/                      Built-in lifecycle hook scripts (post-project-create, etc.)
cmd/coda-core/              Go companion binary (layout snapshot, provider, watcher)
tests/                      Shell lifecycle regression tests (bash, mock tmux/fzf)
test/                       Bats integration tests (module loading, functional)
layouts/                    Built-in tmux layout scripts
```

## Rewrite Branch Guidance

This repository is currently being reshaped on a long-running rewrite branch.

While working here:

- treat `main` as the current stable implementation
- treat the rewrite branch as the place to build the future canonical version of Coda
- prefer `coda-dev` as the rewrite-phase command name when validating the new workflow alongside stable `coda`
- do not expand adjacent utilities before the core lifecycle is trustworthy
- prefer small, testable slices over large conceptual rewrites

The first proving slice is the core lifecycle spine described in `docs/coda-v1-slice-01-core-lifecycle.md`.

## Decision Rule

Before making a change, ask:

1. Does this strengthen the branch/worktree/session model?
2. Does this make the core easier to reason about or test?
3. Does this belong in core, or is it actually a companion concern?

If the answer to all three is unclear, stop and clarify before implementing.
