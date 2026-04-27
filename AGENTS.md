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
cmd/coda/              binary entrypoint
internal/session/      session lifecycle (CRUD, state transitions)
internal/identity/     agent identity (PURPOSE.md, MEMORY.md, etc.)
internal/messages/     typed messaging primitives
internal/orch/         orchestrator-specific logic
internal/plugin/       plugin host, discovery, MCP server
internal/feature/      worktree lifecycle
internal/db/           SQLite state layer
internal/db/migrations/ numbered schema migrations (//go:embed)
```

Packages under `internal/` are not importable outside this module by
design. Keep public API surface on the CLI command layer only.

## Conventions

- **CLI framework**: Go standard library `flag` package. No cobra or
  third-party CLI frameworks.
- **Go version**: 1.22+
- **Package naming**: plural where the package models a collection
  (`messages`, `migrations`), singular otherwise (`session`, `plugin`).
- **Schema migrations**: numbered files under `internal/db/migrations/`,
  embedded via `//go:embed`. Forward-only, transactional.
- **Exit codes**: reserved constants live in their own package once
  introduced. `0` success, `1` user error, `2` usage error, `3`
  lifecycle-blocked (reserved for fatal hooks).
- **Commit style**: one card, one PR. Feature work on branches, not
  main. Memory-only / docs-only changes may land on main directly.

## Full architecture

The v3 architecture doc lives outside this repo (in the maintainer's
config directory). This AGENTS.md is the in-repo summary. When
building something and the spec feels ambiguous, ask the maintainer
before inferring.

## Status

v3 scaffold. Session, db, identity, messaging, and feature
primitives are landed: `coda agent new` provisions identity dirs,
`coda agent boot` emits a provider-ready JSON payload, `coda agent
ls/start/stop` manage sessions, `coda send/recv/ack` carries typed
messages between agents, and `coda feature start/finish/ls` manages
git-worktree lifecycles with a local hook runner. The plugin host
is still a stub.

Install: `./scripts/install.sh` (drops `coda-dev` in `$XDG_BIN_HOME`).
