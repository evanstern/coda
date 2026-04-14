# ADR 0003: Companion Utilities Boundary

## Status

Accepted (2025-07-14)

*Implementation review confirmed alignment. Companion utilities (`install.sh`, `coda-watcher.sh`, `scripts/`, provider auth) remain in-tree but are architecturally distinct from core lifecycle operations.*

## Context

The current repository includes several useful but different kinds of functionality:

- core worktree/session orchestration
- tmux UX defaults
- watcher behavior
- auth bridging
- machine bootstrap and package installation
- local-device helper scripts

These all help the workflow, but they do not all belong at the same architectural level.

Without an explicit boundary, the repo risks turning Coda into a bundle of environment assumptions instead of a reusable core tool.

## Decision

Treat machine-specific, provider-specific, and heavy environment setup concerns as companion utilities or optional built-ins rather than as the definition of Coda core.

Core remains the branch/worktree/session orchestration layer.

## Inclusion Criteria for Core

A feature belongs in core when it:

1. directly supports the branch/worktree/session lifecycle
2. improves predictability of attach, switch, list, start, or finish flows
3. is required to preserve the remote reconnectable session model
4. would be surprising if absent from the main `coda` experience

## Exclusion Criteria

A feature should be treated as a companion utility, optional built-in, or helper when it:

1. is specific to one machine, one device, or one hardware setup
2. primarily exists to integrate with one external provider or auth flow
3. is mostly about provisioning a host rather than orchestrating a session lifecycle
4. improves ergonomics without changing the core branch/session model

## Examples

Likely core:

- project/worktree management
- feature start and finish
- session attach/list/switch
- layout selection as part of session creation

Likely companion or optional:

- machine bootstrap scripts
- auth bridge commands tied to one provider workflow
- watcher-specific delivery backends
- desktop, phone, or Stream Deck connection helpers
- highly personal tmux UX helpers

## Alternatives Considered

### 1. Keep everything in core because it is all useful in one workflow

Rejected because usefulness alone is not enough to justify architectural centrality.

### 2. Spin every optional concern into a separate repo immediately

Rejected because that would fragment the project too early and make iteration slower.

### 3. Introduce a plugin system to absorb all non-core concerns

Rejected for v1 because it creates more platform surface area than the current product needs.

## Consequences

### Positive

- The product boundary becomes easier to defend.
- General usefulness improves without sacrificing strong defaults.
- Personal workflow helpers can still exist without dictating core architecture.

### Negative

- The repository may continue to contain some mixed concerns during transition.
- More judgment is required when deciding whether something is a built-in or a companion utility.

## Implementation Implication

As the repo evolves, it is acceptable for companion utilities to remain in-tree for a while. The critical change is architectural posture: they should be documented and treated as adjacent modules, not as the core identity of Coda.
