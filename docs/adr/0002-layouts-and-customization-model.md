# ADR 0002: Layouts and Customization Model

## Status

Proposed

## Context

The current repository already supports layouts and profiles in a useful way:

- built-in layouts live in `layouts/`
- user layouts can override or extend them from a config directory
- profiles provide named workflow-specific overrides

At the same time, there is pressure to generalize the product and avoid baking too much personal behavior into core. One possible response would be to introduce a broad plugin system. Another would be to split all layouts and adjacent features into separate repositories.

Both approaches risk introducing abstraction weight before the core model has fully stabilized.

## Decision

Keep layouts as first-class Coda features, but treat customization as a layered system built from:

1. config
2. profiles
3. lifecycle hooks

V1 should prefer these mechanisms over a broad plugin platform.

## What this means

### Layouts stay first-class

Layouts are part of the primary session experience. They determine how a newly created session becomes immediately useful.

### Profiles stay as named workflow presets

Profiles remain the place for stable variations like alternate default layouts or editor sandboxes.

### Hooks handle lifecycle customization

When users need behavior to happen around project, worktree, session, or layout events, hooks are the preferred extension surface.

### Broad plugins are deferred

V1 does not need a generalized plugin API, plugin registry, or plugin packaging story.

## Alternatives Considered

### 1. Move layouts fully out of Coda into a separate repository

Rejected because layouts affect the primary interface and are too close to the session experience to be treated as completely external.

### 2. Introduce a plugin system for layouts and all integrations

Rejected for v1 because it would force early API design, create versioning pressure, and make the product boundary less clear.

### 3. Keep layouts but make customization ad hoc and undocumented

Rejected because the repo already shows real customization seams, and those seams should become intentional rather than accidental.

## Consequences

### Positive

- Customization remains powerful without forcing framework-level complexity.
- Users can continue to create and own their own layouts.
- The core product stays coherent while still feeling adaptable.

### Negative

- Some advanced integrations will need to live as scripts or companion tools rather than polished plugins.
- Hook design becomes more important because it will carry more extension weight.

## Boundaries for v1

Use:

- layouts for pane topology and startup behavior
- profiles for named workflow defaults
- config for stable settings
- hooks for lifecycle reactions

Avoid:

- plugin marketplaces
- dynamic runtime extension systems
- making layouts the only customization concept
