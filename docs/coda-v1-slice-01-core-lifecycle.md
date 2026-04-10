# Slice 01: Core Lifecycle

## Status

Planned first implementation slice for the Coda v1 rewrite.

## Goal

Prove the core v1 invariant in running code:

```text
one active branch/worktree -> one tmux session
```

This is the smallest slice that validates the product's central promise.

## Why This Slice Comes First

Everything else depends on it.

Layouts, profiles, hooks, watcher behavior, and companion utilities only make sense if the branch/worktree/session model is stable first.

This slice tests whether the rewrite is actually converging on the right product.

## User Flow Under Test

1. Create or reconnect to a project.
2. Start a feature branch from the configured base branch.
3. Create the feature worktree.
4. Create or attach the corresponding tmux session.
5. Discover that session through list/switch/attach flows.
6. Tear the feature down safely when work is complete.

## In Scope

### Identity rules

- deterministic project naming
- deterministic worktree paths
- deterministic tmux session naming

### Core command behavior

- project entry flow
- feature start flow
- session attach/list/switch behavior needed to prove the model
- feature teardown flow

### Failure handling

- duplicate feature branch creation
- naming collisions
- missing or inconsistent worktree/session state
- safe error messages for recoverable failures

### Testability

- establish a repeatable command-level or shell-level test harness for the lifecycle path

## Out of Scope

For this slice, explicitly do not expand:

- layouts beyond what is necessary to preserve compatibility with session creation
- watcher redesign
- provider-specific auth flows
- install/bootstrap refactors
- tmux UX polish unrelated to the lifecycle proof
- generalized plugin or extension architecture

## Implementation Approach

### Step 1: Define deterministic identity rules

Before moving code around, make the project, branch, worktree, and session naming rules explicit in tests.

### Step 2: Build the happy path

Make the simplest end-to-end flow work:

- start/reconnect project
- create feature worktree
- create session for that worktree
- find and reattach to the session

### Step 3: Cover teardown

Prove that feature teardown removes or disconnects the right resources without damaging unrelated state.

### Step 4: Cover failure cases

Add explicit tests for collision and recovery paths.

### Step 5: Refactor only after green

Once the lifecycle spine is passing, extract stable helpers and simplify the implementation.

## Test Strategy

The current repository is shell-heavy, so this slice should validate behavior at the shell command level rather than only through isolated helper functions.

Minimum requirement:

- a repeatable test command
- fixtures or isolated temp directories for git/worktree state
- assertions around session naming and lifecycle outcomes

Preferred emphasis:

1. red: identity and lifecycle tests
2. green: minimal implementation
3. red: failure-mode tests
4. green: recovery behavior
5. refactor: simplify after behavior is proven

## Acceptance Criteria

Slice 01 is done when:

1. the core lifecycle flow works end-to-end
2. session and path naming rules are deterministic
3. list/attach/switch flows can find the expected session
4. teardown behavior is safe and predictable
5. the behavior is covered by targeted tests
6. the resulting code makes later config/profile/hook work easier, not harder

## Deliverables

1. tests for the lifecycle spine
2. minimal implementation changes needed to make those tests pass
3. any small supporting docs required to explain new public behavior

## Things To Watch For

1. Accidentally preserving personal assumptions as hidden defaults.
2. Letting layout concerns reshape the slice.
3. Solving bootstrap or auth problems before the lifecycle proof exists.
4. Refactoring too early before naming and teardown rules are stable.

## Exit Condition

Slice 01 exits successfully when the rewrite has a trustworthy core lifecycle spine that later slices can build on without guessing how session identity works.

The next slice should start only after this one establishes a stable base for:

- minimal config precedence
- profile behavior
- first lifecycle hooks
