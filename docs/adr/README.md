# Architecture Decision Records

This directory holds small, focused decision records for Coda.

The goal of an ADR in this repo is not to document every idea. It is to capture decisions that affect how future implementation work should be scoped.

## Status meanings

- **Proposed**: direction we intend to follow, but not fully implemented
- **Accepted**: agreed direction that future work should treat as the default
- **Superseded**: replaced by a later ADR

## Current ADRs

| ADR | Status | Decision |
| --- | --- | --- |
| [0001](./0001-core-orchestration-model.md) | Accepted | Coda core is remote tmux + git worktree/session orchestration |
| [0002](./0002-layouts-and-customization-model.md) | Accepted | Layouts remain first-class; customization prefers config/profiles/hooks over plugins |
| [0003](./0003-companion-utilities-boundary.md) | Accepted | Machine-specific and auxiliary concerns belong outside the core product boundary |

## How to use ADRs here

1. Keep each ADR to one decision.
2. Write the context that made the decision necessary.
3. Record the alternatives that were seriously considered.
4. Be explicit about consequences, especially what gets easier and what gets harder.
5. If a later decision replaces an earlier one, add a new ADR instead of rewriting history.
