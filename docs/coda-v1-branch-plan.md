# Coda v1 Rewrite Branch Plan

## Status

Active planning document for the long-running rewrite branch.

## Purpose

This document defines how the Coda v1 rewrite branch should operate.

It does not restate the full product design. Instead, it answers the execution questions:

- what this branch is for
- what work belongs on it
- how changes should be staged
- what milestones mark real progress
- what the first implementation slice should prove

Related documents:

- `docs/coda-v1-design.md`
- `docs/adr/0001-core-orchestration-model.md`
- `docs/adr/0002-layouts-and-customization-model.md`
- `docs/adr/0003-companion-utilities-boundary.md`

## Branch Role

This branch is the integration branch for the Coda v1 rewrite.

Its job is to produce the future canonical version of Coda without forcing `main` to carry partially rewritten architecture before it is coherent enough to replace the current tool.

`main` remains the current working implementation until this branch is ready to take over.

During the rewrite, prefer `coda-dev` as the development-facing command name when the new workflow must coexist with an existing `coda` installation on the same machine.

The product is still Coda. `coda-dev` is a temporary rewrite-phase entrypoint, not a permanent rename.

## Scope of This Branch

This branch is for:

1. reshaping Coda around the v1 core model
2. replacing personal assumptions with explicit boundaries
3. introducing the minimum configuration and hook surfaces needed by v1
4. proving that the branch/worktree/session lifecycle works cleanly end-to-end

This branch is not for:

1. polishing every adjacent utility before the core is stable
2. broad plugin work
3. machine-specific niceties unless they are needed to preserve core behavior
4. speculative abstractions without a concrete use in the rewrite

## Working Model

### Main branch

`main` is the stable line for the current Coda implementation.

Only critical fixes or necessary housekeeping should land there while the rewrite is in flight.

### Rewrite branch

The rewrite branch is where v1 work accumulates.

It may be structurally disruptive. That is acceptable as long as it is moving toward the defined v1 model rather than drifting into parallel experiments.

When both old and new environments coexist, the rewrite command should also use its own default tmux session prefix so development sessions do not collide with stable ones.

### Topic branches

Short-lived topic branches should be cut from the rewrite branch for isolated pieces of work, then merged back into the rewrite branch.

Examples:

- `rewrite/tests-core-lifecycle`
- `rewrite/session-identity`
- `rewrite/config-precedence`

## Operating Rules

1. **The rewrite branch is allowed to be incomplete, but not aimless.**
2. **Each change should advance one milestone or unlock the next one.**
3. **Architecture-changing decisions should be captured in ADRs when they are real decisions, not every time a file moves.**
4. **Doc commits and code commits should stay separate when possible.**
5. **Do not expand companion utilities while the core lifecycle is still unstable.**
6. **Do not merge rewrite work into `main` until a full end-to-end core path is proven.**

## Sync Strategy With `main`

The rewrite branch should not drift unnecessarily from `main`.

Recommended rule:

- merge or rebase from `main` at a steady cadence during active development
- pull in only meaningful fixes, not opportunistic feature churn
- resolve drift while the branch is still understandable, not right before replacement

The goal is not to keep the branch tiny. The goal is to avoid a last-week integration cliff.

## Milestones

## Milestone 1: Core lifecycle spine exists

The rewrite proves the central invariant in code:

```text
one active branch/worktree -> one tmux session
```

Required outcomes:

- deterministic project, branch, worktree, and session identity
- `project start` or equivalent entry flow works
- `feature start` creates the expected worktree + session relationship
- attach/list/switch behavior is predictable
- feature teardown works safely

## Milestone 2: Core behavior is testable and trustworthy

Required outcomes:

- a repeatable shell-level test harness exists
- happy-path lifecycle flows are covered
- failure paths are covered for collisions and invalid state
- core behavior no longer depends on manual inspection alone

## Milestone 3: Minimal customization seams exist

Required outcomes:

- config precedence is defined in code
- profile behavior is explicit
- first hook points exist at the lifecycle layer
- layout selection remains supported without dominating the rewrite

## Milestone 4: Adjacent modules are either adapted or deferred

Required outcomes:

- layouts still have a supported place in the product
- watcher/auth/bootstrap concerns are each classified as core, optional built-in, or companion
- unresolved non-core concerns are deferred explicitly instead of lingering as hidden assumptions

## Definition of Done for a Milestone

A milestone is done when:

1. the intended behavior exists end-to-end
2. targeted tests cover the new behavior
3. failure cases are explicit enough to debug
4. docs reflect any meaningful surface-area change
5. remaining uncertainty is captured as an open question or ADR, not left implicit

## Immediate Next Slice

The first implementation slice should prove the core lifecycle before any deeper customization work.

That slice is defined in:

- `docs/coda-v1-slice-01-core-lifecycle.md`

## Change Selection Rules

When deciding whether a task belongs in the current milestone, ask:

1. Does it strengthen the branch/worktree/session model?
2. Does it make the core easier to test or reason about?
3. Is it required by the current slice's acceptance criteria?

If the answer is no, it probably belongs later.

## What We Intentionally Defer Early

Until the core lifecycle is proven, defer:

- broad install/bootstrap cleanup
- provider-specific auth improvements
- watcher redesign beyond what is required for compatibility
- new UX helpers and personal machine integrations
- generalized plugin architecture

## Merge Criteria For Replacing `main`

The rewrite branch is ready to replace `main` when all of the following are true:

1. the end-to-end core lifecycle works reliably
2. the rewrite is usable as a real daily driver
3. essential configuration/customization seams are present
4. non-core concerns are either adapted or explicitly deferred
5. the result is simpler and more general than the current personal-tool shape

## Open Questions

1. What project-level config format should v1 standardize on?
2. Which hook points are required for the first usable release?
3. How much of the existing layout behavior must survive unchanged in the first replacement?
4. Should the watcher remain bundled at first replacement, or be deferred behind optional setup?
