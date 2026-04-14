# ADR 0001: Core Orchestration Model

## Status

Accepted (2025-07-14)

*Implementation review confirmed alignment between design intent and code. The branch/worktree/session invariant is fully implemented across `lib/core.sh`, `lib/project.sh`, and `lib/feature.sh`.*

## Context

The current repository already centers on a clear operating model:

- projects are managed through git worktrees
- active branches are isolated in their own worktrees
- tmux sessions are used as persistent, reconnectable working contexts
- a session is the user-facing runtime unit for a branch

The strongest value in the current system is not bootstrap automation, tmux customization, or AI-harness-specific glue. It is the predictable mapping between branch, worktree, and session.

As Coda becomes more generally useful, there is a risk of broadening the product boundary until the main idea gets obscured.

## Decision

Treat Coda core as a remote-first orchestration layer for:

1. project registration and organization
2. worktree lifecycle
3. feature-branch lifecycle
4. tmux session creation, attachment, listing, and switching
5. predictable branch/worktree/session identity

The primary invariant is:

```text
one active worktree/branch -> one tmux session
```

Core commands should continue to revolve around that invariant.

## Alternatives Considered

### 1. Make Coda a more general remote development bundle

This would pull install/bootstrap, device integrations, and environment opinionation into the center of the tool.

Rejected because it dilutes the main value and makes the product feel more personal than portable.

### 2. Reframe Coda around the AI harness instead of the session/worktree model

This would make the core architecture depend too heavily on one harness and its surrounding auth, watcher, and workflow assumptions.

Rejected because the durable value is session orchestration, not provider-specific glue.

### 3. Make sessions more loosely related to branches

This would reduce predictability and weaken the isolation model.

Rejected because branch-to-session determinism is central to how Coda avoids context collisions.

## Consequences

### Positive

- The product remains easy to explain.
- Users can predict behavior from branch names and directory structure.
- Future features can be evaluated by asking whether they support or distract from the branch/session lifecycle.
- The shell remains a viable debugging interface.

### Negative

- Some useful adjacent capabilities will feel intentionally secondary.
- Certain workflows that do not fit the session-per-branch model will not be optimized first.
- Coda will remain opinionated rather than becoming a general-purpose remote dev framework.

## Follow-on Implications

1. Session naming conventions remain part of the architecture.
2. Worktree creation and teardown remain first-class behaviors.
3. Tmux stays the required session layer for v1.
4. Customization should not redefine the core identity model.
