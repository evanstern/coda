# Copilot instructions for `evanstern/coda`

These instructions are the long-lived, task-independent context for the
Copilot cloud agent. Trust them first. Only search the repo when a
specific file or command isn't covered here, or when a documented
command fails (in which case flag the drift in the PR description).

## 1. What this repo is

Coda is an orchestration CLI for AI-assisted development. It is a
single Go binary that defines the workflow layer -- agent lifecycle,
identity, messaging, worktrees, plugins -- and delegates runtime
execution to provider plugins (CodaClaw, opencode, tmux). The binary
is plugin-composable and provider-agnostic.

State of the tree:

- v3 scaffold, early. Most `internal/*` packages are stubs
  (`package foo` and nothing else). `internal/db` and
  `internal/session` are the first real code; everything else will be
  filled in by future cards (#169-#175).
- Language: Go 1.22 (module declares `go 1.22.2`).
- CLI framework: Go standard library `flag`. No cobra / urfave /
  kong.
- Runtime target: a single binary, Linux + macOS. SQLite state at
  `$XDG_STATE_HOME/coda/coda.db` (default
  `~/.local/state/coda/coda.db`).
- Size: order-of-magnitude 10^3 lines of Go (small, growing).

`AGENTS.md` at the repo root is the in-repo architecture summary. Read
it for the five core primitives and the repo layout. This file is a
superset that also covers commands, timings, and traps.

## 2. Build and validation

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

## 3. Layout and architecture

```
cmd/coda/              binary entrypoint and dispatcher (stdlib flag)
internal/db/           SQLite open + numbered migrations
internal/db/migrations numbered *.sql files, //go:embed, forward-only
internal/session/      Agent, Session, Store, Provider interface, ULID IDs
internal/identity/     (stub) PURPOSE.md / MEMORY.md / PROJECT.md
internal/messages/     (stub) typed messaging primitives
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
- Everything else will be filled in by cards #169-#175. See
  `AGENTS.md` for the five core primitives and long-form
  architecture. Do not duplicate that summary here.

`internal/*` packages are not importable from outside the module by
design. Keep any public surface on `cmd/coda/`.

## 4. Conventions

- **CLI framework**: stdlib `flag`. Reject suggestions to add cobra,
  urfave/cli, kong, viper, or similar.
- **Package naming**: plural when the package models a collection
  (`messages`, `migrations`), singular otherwise (`session`,
  `plugin`, `feature`, `orch`, `identity`, `db`). Match what is
  already there.
- **Migrations**: numbered files under `internal/db/migrations/`
  (e.g. `001_initial.sql`), embedded via `//go:embed`, forward-only,
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

## 5. Review gates

- No CI today. The only gate is local:
  `go build ./... && go vet ./... && go test ./...`.
- Architect review (@evanstern) via GitHub PR review is the
  authoritative gate.
- Copilot reviewer catches inline issues on PRs.
- Cadence: a first spawn ships round 1. Reviews batch into a round 2
  spawn that addresses findings. Don't amend round 1 after it has
  been pushed.

## 6. When these instructions look wrong

Trust this file first. Fall back to searching the repo only when:

- A specific file, command, or convention you need isn't covered
  here.
- A documented command actually fails. That usually means these
  instructions drifted -- fix the issue in the PR if it's in scope,
  otherwise call it out in the PR description so the next editor of
  this file can update it.

Do not invent build steps. Do not add CI, Makefiles, lint configs,
or coverage gates unless a focus card explicitly requests them.
