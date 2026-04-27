# Spec #172 — Worktree lifecycle (`coda feature start/finish/ls`)

**Status:** drafted 2026-04-27, implemented in this PR.
**Milestone:** [#166](https://github.com/users/evanstern/projects) coda v3 Go CLI
**Card:** focus #172
**Implements:** primitive 5 of 5

## Vision

`coda feature start/finish/ls` — git-worktrees as the isolation
primitive for parallel feature work. Provider-agnostic (no tmux,
no attach, no session creation). Runs hooks at four lifecycle
boundaries.

Reference: v2 `lib/feature.sh` (~316 lines bash, mostly tmux-attach
logic that's NOT in v3 scope). v3 inherits the worktree mechanics
but drops the session/tmux coupling.

## Architectural decisions

These are **answered**. Don't relitigate during implementation.

- **Project resolution: cwd-walk (v2-compatible).** Walk up from
  cwd looking for `.bare/` + `.git` text-file pattern. Override
  via `--project <name>` flag (resolves to
  `$PROJECTS_DIR/<name>/`).
- **Worktree path: `<project_root>/<branch>/`.** Same as v2.
  Branch names with slashes (`feature/foo`) work as-is — git
  accepts them.
- **Hook implementation: minimal local runner.** This card ships
  its own hook runner that scans
  `$XDG_CONFIG_HOME/coda/hooks/<event>/` and runs sorted scripts
  with env vars. #171 will REPLACE this runner with the full
  plugin-aware version. Design the hook-call site so #171's
  replacement is a one-line wire change.
- **No tmux/attach/session integration.** v2's
  `_coda_feature_start` ends in `tmux attach`. v3's just creates
  the worktree and fires hooks. Session creation is a separate
  concern (would happen via `coda agent start` if at all).
- **No PR creation.** `coda feature start` doesn't run
  `gh pr create`. That's a separate workflow.

## Scope

### 1. Project resolution (`internal/feature/project.go`)

```go
type Project struct {
    Name string
    Root string  // absolute path to bare-repo project root
}

// FindProject resolves a project from cwd or by explicit name.
// nameHint == "" -> walk up from cwd looking for .bare/ + .git
// nameHint != "" -> resolve PROJECTS_DIR/<nameHint>/ (must exist)
func FindProject(cwd, nameHint string) (*Project, error)
```

Error cases:
- `nameHint` set but `PROJECTS_DIR/<name>` doesn't exist or isn't
  a coda project (no `.bare/`)
- `nameHint` empty, cwd-walk reaches root without finding a
  project
- Found dir but `.git` text-file doesn't point at `./.bare`

`PROJECTS_DIR` env var with default `$HOME/projects`.

### 2. Worktree operations (`internal/feature/worktree.go`)

```go
type Worktree struct {
    Branch string  // raw branch name (may contain /)
    Path   string  // absolute worktree dir
    Base   string  // base branch the worktree was forked from
}

// Start creates a new worktree at <project.Root>/<branch>/ from <base>.
// If base is empty, detects the project's default branch.
// Errors if branch already exists or worktree path is occupied.
func Start(project *Project, branch, base string) (*Worktree, error)

// Finish removes the worktree and (optionally) deletes the branch.
// Refuses if worktree has uncommitted changes unless force=true.
func Finish(project *Project, branch string, force bool) error

// List returns active worktrees, excluding the bare repo's main worktree.
func List(project *Project) ([]Worktree, error)
```

**Default branch detection:** look at
`origin/HEAD -> refs/remotes/origin/<name>` (via
`git symbolic-ref refs/remotes/origin/HEAD`). Fallback: `main`,
then `master`. Same as v2's `_coda_detect_default_branch`.

**git invocation:** use `git -C <project.Root> worktree add ...`,
not bare-shell. Capture stderr on failure for the user-facing
error.

### 3. Hook runner (minimal, replaceable)

```go
// internal/feature/hooks.go (REPLACED when #171 lands)
type HookRunner interface {
    Run(ctx context.Context, event string, env map[string]string) error
}

type localHookRunner struct {
    dir string  // $XDG_CONFIG_HOME/coda/hooks/
}

// Run executes hooks for an event:
//  1. Read $h.dir/<event>/
//  2. List entries; filter to executable regular files
//  3. Sort by LC_ALL=C filename order
//  4. exec.Command each, pipe env, run; warn-on-failure to stderr
//  5. Return nil even if some failed (warn-only contract)
func (h *localHookRunner) Run(ctx context.Context, event string, env map[string]string) error
```

`feature.Start/Finish` take a `HookRunner` parameter.
`cmd/coda/main.go` constructs `localHookRunner` for v3.0; #171
will swap in `plugin.HookRunner`.

**Hook events fired:**
- `pre-feature-create` — before `git worktree add` runs
- `post-feature-create` — after worktree exists, before return
- `pre-feature-teardown` — before `git worktree remove`
- `post-feature-finish` — after teardown completes

**Env vars (match v2 names exactly):**
- `CODA_PROJECT_NAME`
- `CODA_PROJECT_DIR` (= project.Root)
- `CODA_FEATURE_BRANCH` (= raw branch name)
- `CODA_WORKTREE_DIR` (= worktree.Path)

These are exported to the hook subprocess via `os.Environ` plus
overrides. v2 plugins port cleanly when they read these.

### 4. CLI surface (`cmd/coda/main.go`)

New top-level subcommand `feature`:

```
coda feature start <branch> [--base <branch>] [--project <name>]
coda feature finish <branch> [--project <name>] [--force]
coda feature ls [--project <name>]
```

Output:

| Subcommand | stdout | exit |
|---|---|---|
| `feature start` | `created: <branch> at <path>` | 0 |
| `feature finish` | `removed: <branch>` | 0 |
| `feature finish` (uncommitted, no `--force`) | error to stderr | 1 |
| `feature ls` | tabwriter `BRANCH\tBASE\tPATH` | 0 |

Stick to stdlib `flag`. Each subcommand is a `flag.FlagSet`
parsed in a `switch`. No cobra.

## Repo layout (new files)

```
internal/feature/
  feature.go      (currently stub — replace; or add files alongside)
  project.go      Project, FindProject
  project_test.go
  worktree.go     Worktree, Start, Finish, List
  worktree_test.go
  hooks.go        HookRunner interface + localHookRunner
  hooks_test.go
docs/specs/
  172-worktree-lifecycle.md   (this doc)
```

`cmd/coda/main.go`: new `feature` top-level subcommand wired
into the `run()` switch.

## Test surface

**Unit tests:**

- `FindProject`:
  - cwd inside project
  - cwd outside (error)
  - nameHint set, exists
  - nameHint set, missing dir (error)
  - nameHint set, dir without `.bare` (error)
- `Start`:
  - clean case
  - branch already exists (error)
  - worktree path occupied (error)
  - default-branch detection
- `Finish`:
  - clean case
  - uncommitted changes + force=false (error)
  - uncommitted changes + force=true (succeeds)
  - nonexistent branch (error)
- `List`:
  - empty project
  - project with worktrees (output excludes bare/main worktree)
- `localHookRunner.Run`:
  - empty event dir
  - sort order respected
  - env-var passthrough
  - non-executable files skipped
  - failure → warn to stderr but don't abort

**Integration tests:**

- End-to-end: build a fake bare-repo project in `t.TempDir()`
  (init bare + check out main worktree), call
  `feature.Start("foo")`, assert worktree exists at right path,
  then `feature.Finish` and assert removed.
- Hook firing: drop a script in user hooks dir, call
  `feature.Start`, assert script ran with right env vars.
- CLI E2E (in `cmd/coda/main_test.go`):
  `coda feature start/finish` through `run()`.

**git fixture helper:** `internal/feature/testutil.go` (or
similar) with `NewTestProject(t)` that initializes a bare repo +
default branch in `t.TempDir()`. Use real `git` calls — git is
a hard runtime dep already, no need to mock it.

## Acceptance gate

```bash
cd <worktree>
go build ./...
go vet ./...
go test ./... -count=1 -race
```

All three must exit 0.

## Out of scope

- tmux/attach/session integration. v2's feature_start ends in
  attach; v3 doesn't.
- PR creation via `gh pr create`.
- Project lifecycle (`coda project start/clone/close`) — separate
  card if/when needed.
- Plugin hooks. #171's job. THIS card uses a local-only runner.
- Backward compat with v2 `coda feature start` shell command —
  v3 binary is independent.
- Don't touch `internal/identity/`, `internal/messages/`,
  `internal/session/`.
- Don't update CLI usage strings (#185).
- Don't fix the harness FEATURE SESSION preamble (#188) — strip
  it from this PR's AGENTS.md as part of normal hygiene.

## Done when

- `coda feature start/finish/ls` work end-to-end against a real
  git project
- Four hook events fire with v2-compatible env vars
- `localHookRunner` is replaceable (HookRunner interface) so #171
  can swap it in cleanly
- Acceptance gate exits 0
- AGENTS.md updated to reflect feature lifecycle shipping
- This spec doc committed at `docs/specs/172-worktree-lifecycle.md`
- PR opened against main

## Coordination

- **Lands first.** #171 will replace `internal/feature/hooks.go`
  with calls into `internal/plugin/HookRunner`. The interface in
  this card is the seam.
- **Unblocks:** orchestrator workflow (creating feature sessions
  for spawn agents) — including this orchestrator's own work.
- **Sequenced before #171** to keep #171's scope manageable.
