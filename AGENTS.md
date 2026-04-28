# AGENTS.md -- coda

Project context for agents and human contributors.

## What this is

Coda is the orchestration CLI for AI-assisted development. A Go binary
that defines the workflow layer (agent lifecycle, identity, messaging,
worktrees, plugins) and delegates runtime execution to provider plugins
(CodaClaw, opencode, tmux).

Coda without a provider is still useful: identity management, card
management (via the focus plugin), worktree lifecycle. With a provider,
it runs full agent sessions.

## Five core primitives

Everything the binary ships falls into one of these. Everything else is
a plugin.

1. **Session model** -- agent lifecycle (created -> started -> running
   -> stopped). Provider-delegated execution. SQLite state in
   `~/.local/state/coda/coda.db`.
2. **Identity** -- `PURPOSE.md` + `MEMORY.md` + `PROJECT.md` per agent.
   `coda agent new/boot`. The `coda-soul` plugin extends this with
   `SOUL.md` (personality, voice, values) and dream/reflect cycles.
3. **Messaging** -- typed messages (note/brief/completion/status/
   escalation) with a routing table and send/recv/ack semantics.
   Providers implement transport.
4. **Worktree lifecycle** -- `coda feature start/finish/ls`. Git
   worktrees as the isolation primitive. Provider-agnostic.
5. **Plugin host** -- `plugin.json` loading, MCP server (stdio), hook
   dispatch, command registration.

## Repo layout

```
cmd/coda/              binary entrypoint and dispatcher (stdlib flag)
internal/db/           SQLite open + numbered migrations
internal/db/migrations numbered *.sql files, //go:embed, forward-only
internal/session/      Agent, Session, Store, Provider interface, ULID IDs
internal/identity/     PURPOSE.md / MEMORY.md / PROJECT.md scaffold + boot
internal/messages/     typed messaging primitives (send/recv/ack, routing)
internal/orch/         (stub) orchestrator-specific logic
internal/plugin/       (stub) plugin host, plugin.json, MCP server
internal/feature/      (stub) worktree lifecycle
```

- `cmd/coda/main.go` is the sole CLI dispatcher. Each subcommand is a
  `flag.FlagSet` parsed in a `switch`. No cobra commands, no
  middleware.
- `internal/db/` owns opening the database and running embedded
  migrations. Migrations are transactional and forward-only.
- `internal/session/` owns the agent/session state machine
  (`created -> started -> running -> stopped`, plus
  `created -> stopped`). `stopped` is terminal. Session IDs are
  ULIDs. Provider implementations live behind a `ProviderRegistry`
  populated by plugins; the registry is empty in core.

Packages under `internal/` are not importable outside this module by
design. Keep public API surface on the CLI command layer only.

## Build and validation

All commands run from the repo root. Go 1.22+ is required. Every
command here was executed in a fresh worktree off `main`; timings are
from that run.

| Step        | Command              | Timing | Notes |
|-------------|----------------------|--------|-------|
| Bootstrap   | `go mod download`    | <1s    | Optional; `go build` will fetch. |
| Build       | `go build ./...`     | <1s    | Silent on success. |
| Vet         | `go vet ./...`       | <1s    | Always run. No output on success. |
| Test        | `go test ./...`      | <1s    | Packages with no tests print `[no test files]`; not a failure. |
| Tidy check  | `go mod tidy`        | <1s    | Must leave `go.mod` and `go.sum` unchanged. See trap 2. |
| Binary      | `go build -o coda-dev ./cmd/coda && ./coda-dev version` | <1s | Prints `dev` unless `-ldflags "-X main.Version=..."` is set (the install script does this). |

**Minimum gate before opening a PR:**

```
go build ./... && go vet ./... && go test ./...
```

There is no CI pipeline, no Makefile, no justfile, no taskfile, and
no golangci-lint configuration. Do not add any of these unless a
focus card explicitly asks for them.

### First-run side effects

`coda-dev version` is pure; it does not touch disk. `coda-dev agent ...`
commands open or create `$XDG_STATE_HOME/coda/coda.db` (default
`~/.local/state/coda/coda.db`) and run pending migrations. The
containing directory is created if missing.

### Known traps

1. **SQLite driver name is `sqlite`, not `sqlite3`.** We use
   `modernc.org/sqlite` (pure Go), which registers the driver as
   `sqlite`. `database/sql.Open("sqlite3", ...)` will fail at
   runtime. This is a common leak from v2 habits.

2. **`modernc.org/sqlite` is pinned to `v1.34.1`.** Versions from
   `v1.35+` require Go 1.25. Do NOT run `go get -u` on this module
   without also bumping the declared Go toolchain in a dedicated card.
   If `go mod tidy` wants to change the pin, fix the import or vendor
   issue rather than committing the drift.

3. **`db.SetMaxOpenConns(1)` in `internal/db/db.go` is load-bearing.**
   SQLite writers serialize anyway, and a single connection avoids
   PRAGMA-per-connection surprises. Do not bump this. Do not
   interleave `rows.Next()` with `ExecContext` on the same `*sql.DB`
   -- the second call will block on the open cursor. Use
   `conn.QueryContext` on a dedicated `*sql.Conn` or fully drain
   rows before issuing writes.

4. **`PRAGMA foreign_keys` is per-connection, not per-database.**
   Migration code pins a single `*sql.Conn` for the whole migration
   sequence so that `PRAGMA foreign_keys=OFF` and the subsequent
   `PRAGMA foreign_key_check` inside the transaction are guaranteed
   to hit the same connection. Do not refactor that to use the pool
   directly.

5. **SQLite `datetime('now')` returns UTC with no timezone suffix.**
   Values come back as strings like `2026-04-24 02:10:50`. Parse with
   `time.ParseInLocation("2006-01-02 15:04:05", s, time.UTC)`; do
   not use `time.Parse` with an RFC3339 layout.

## Conventions

- **CLI framework**: Go standard library `flag` package. Reject
  suggestions to add cobra, urfave/cli, kong, viper, or similar.
- **Go version**: 1.22+
- **Package naming**: plural when the package models a collection
  (`messages`, `migrations`), singular otherwise (`session`, `plugin`,
  `feature`, `orch`, `identity`, `db`). Match what is already there.
- **Schema migrations**: numbered files under `internal/db/migrations/`
  (e.g. `001_initial.sql`), embedded via `//go:embed`. Forward-only,
  transactional. Never edit a migration that has already landed on
  `main`; write a new one.
- **Tests**: `*_test.go` files next to the code under test. In-memory
  SQLite uses `file::memory:?cache=shared` with a unique shared DSN
  per test so connections see the same database.
- **Exit codes**: `0` success, `1` user error, `2` usage error, `3`
  lifecycle-blocked (reserved).
- **Comments**: godoc on exported API. Inline comments only where
  the logic isn't self-evident or where a documented trap needs a
  pointer. Do not add explanatory comments to code that speaks for
  itself.
- **Branches**: `NNN-brief-slug` (e.g. `168-core-session-model`),
  where `NNN` is the focus card ID.
- **Commits**: first line `Title (#N)`; body leads with the shape of
  the change, not a diff recap; `Closes #N` on the last line when
  the PR resolves a card. Memory-only or docs-only changes may land
  on `main` directly; everything else goes through a feature branch
  and PR.
- **One card, one PR.** Don't bundle unrelated changes.

## Conventions for spawn agents

- **Slicing pattern.** Build in slices that each pass `go build ./...
  && go vet ./... && go test ./...`. One slice = one commit. Don't
  ship a "wires it all up" commit at the end.
- **Spec wins over brief.** When `IMPLEMENT.md` and
  `docs/specs/<id>-<slug>.md` disagree, the spec is authoritative.
- **Preamble strip.** If your prompt arrived with a `# FEATURE
  SESSION` preamble, strip it before any commit message or PR body.
  It's session metadata, not artifact content.
- **`gh pr create --body`, not `--fill`.** `--fill` is broken in this
  environment (silently truncates). Always pass `--body` with the
  full PR body, ideally via heredoc or `--body-file`.
- **TEARDOWN.md before exit.** If the card produced disposable
  artifacts (smoke fixtures, scratch files, temp configs), write a
  `TEARDOWN.md` listing them before reporting `PR ready`. The
  orchestrator runs it on merge.
- **Brief shape (canonical).** `IMPLEMENT.md` should be ~30-50 lines
  and look like this:

  ```markdown
  # IMPLEMENT.md — #<id> <title>

  Card: #<id>
  Branch: <branch>
  Worktree: <path>
  Base: <sha>
  Spec: docs/specs/<id>-<slug>.md  ← AUTHORITATIVE (when present)

  ## Read first
  1. docs/specs/<id>-<slug>.md (or "this brief" if no spec doc)
  2. AGENTS.md
  3. <other repo files this card needs>

  ## Implementation slices
  1. <slice 1>
  2. <slice 2>
  ...

  ## Pre-PR checks specific to this card
  - <card-specific gotchas not in AGENTS.md>

  ## PR body template
  <pre-formatted markdown>

  Report `PR ready: <url>` when done.
  ```

  Anything that would apply to every card belongs in AGENTS.md, not
  the brief. If you find yourself copy-pasting boilerplate into a
  brief, that's a signal AGENTS.md is missing a convention.
- **Report `PR ready: <url>` as your final line.** The orchestrator
  watches for this pattern to know the card is complete.

## Review gates

- No CI today. The only gate is local:
  `go build ./... && go vet ./... && go test ./...`.
- Architect review (@evanstern) via GitHub PR review is the
  authoritative gate.
- Copilot reviewer catches inline issues on PRs.
- Cadence: a first spawn ships round 1. Reviews batch into a round 2
  spawn that addresses findings. Don't amend round 1 after it has
  been pushed.

## Full architecture

The v3 architecture doc lives outside this repo (in the maintainer's
config directory). This AGENTS.md is the in-repo summary. When
building something and the spec feels ambiguous, ask the maintainer
before inferring.

## Status

v3 scaffold. All five core primitives have landed: `coda agent new`
provisions identity dirs, `coda agent boot` emits a provider-ready
JSON payload, `coda agent ls/start/stop` manage sessions, `coda
send/recv/ack` carries typed messages between agents, `coda feature
start/finish/ls` manages git-worktree lifecycles, and the plugin
host loads `plugin.json` manifests, registers subprocess providers
into the `ProviderRegistry`, layers user and plugin hooks, dispatches
plugin-contributed CLI commands, and exposes plugin tools through
`coda mcp serve` (stdio JSON-RPC 2.0).

Install: `./scripts/install.sh` (drops `coda-dev` in `$XDG_BIN_HOME`).
