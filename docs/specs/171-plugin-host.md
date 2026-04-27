# Spec #171 — Plugin host

**Status:** drafted 2026-04-27, implemented in this PR.
**Milestone:** [#166](https://github.com/users/evanstern/projects) coda v3 Go CLI
**Card:** focus #171
**Implements:** primitive 4 of 5

## Vision

The unblocking primitive. Until this lands, `ProviderRegistry`
stays empty and `agent start` fails with "no provider registered."
v3 stores everything correctly but executes nothing real. Plugin
host is what makes v3 actually run.

Five subsystems in one package (`internal/plugin/`):

1. **Manifest parsing** — read `plugin.json` from each plugin dir
2. **Loader** — discover, validate, return `[]Plugin`
3. **SubprocessProvider** — implements `session.Provider` by
   spawning plugin executables (the unblocking piece)
4. **HookRunner** — replaces `internal/feature/`'s local runner
   with a plugin-aware one
5. **MCP server (stdio)** — JSON-RPC 2.0, three methods only
6. **Command registration** — `coda <subcmd>` via subprocess

Reference: v2 plugin contract at
`~/projects/coda-archive/main/docs/plugin-contracts/{plugins,hooks}.md`.
v3 inherits the manifest shape but the dispatch model diverges
(Go binary, can't source bash).

## Architectural decisions

These are **answered**. Don't relitigate during implementation.

- **Plugin command dispatch: subprocess (option a).** A plugin
  command is an executable file in the plugin dir. v3 dispatches
  via `exec.Command`. v2 plugins wrap their shell functions in
  thin executable wrappers. No shell sourcing.
- **Hook dispatch: provided by #171.** This card owns the full
  hook runner including plugin-hook layering. #172 shipped a
  minimal version (user dir only); #171 replaces it.
- **MCP transport: stdio only.** No HTTP server. v2's shared
  port-3111 server is out of scope.
- **MCP library: hand-rolled JSON-RPC 2.0.** No new dependencies.
  ~200-300 lines, full control over dispatch and error handling.
- **Plugin storage: `~/.config/coda/plugins/<name>/`** (matches v2
  default `$CODA_PLUGINS_DIR`). Override via `CODA_PLUGINS_DIR`.
- **Manifest validation: strict for required keys, warn-only for
  unknown.** Required: `name`, `version`, `coda`. Unknown
  top-level keys log a warning, don't fail load.

## Scope

### 1. Manifest parsing (`internal/plugin/manifest.go`)

Parse `plugin.json`. Schema (v2-derived, simplified for v3):

```json
{
  "name":        "coda-codaclaw",
  "version":     "0.1.0",
  "coda":        "^0.1.0",
  "description": "CodaClaw provider plugin",
  "provides": {
    "commands":  { "<name>": { "description": "...", "exec": "bin/cmd-<name>" } },
    "hooks":     { "<event>": ["hooks/<event>/*"] },
    "providers": { "<name>": { "exec": "bin/provider-<name>" } },
    "mcp_tools": { "<tool>": { "description": "...", "command": ["arg1","arg2"] } }
  },
  "dependencies": { "system": ["..."], "go": "...", "npm": [...] },
  "install": "scripts/install.sh"
}
```

**Differences from v2:**

- `commands.<name>` uses `exec` (path to executable), not
  `handler` + `function` (bash sourcing). The `exec` path is
  resolved relative to the plugin dir.
- `providers.<name>` uses `exec` (path to executable), not a
  directory of `auth.sh` + `status.sh`.
- `dependencies.system/go/npm` are advisory; install enforces.

**Out of scope:** `notifications`, `layouts`. v3 doesn't have
those primitives — file separate cards if/when needed.

### 2. Plugin discovery (`internal/plugin/loader.go`)

```go
type Loader struct { dir string }

// Load discovers plugins in dir, parses manifests, returns the
// set. Errors on: missing required manifest fields, unparseable
// JSON. Warns on: unknown top-level keys, missing optional sections.
func (l *Loader) Load(ctx context.Context) ([]Plugin, error)

type Plugin struct {
    Manifest Manifest
    Root     string  // absolute path to plugin dir
}
```

Default discovery dir: `$XDG_CONFIG_HOME/coda/plugins/` (or
`~/.config/coda/plugins/`). Override via `CODA_PLUGINS_DIR`.

### 3. Provider registration (the unblocking piece)

For each plugin with a `providers` section, instantiate a
`SubprocessProvider` that implements `session.Provider` by
spawning the plugin's `provider.exec` binary with subcommand args:

| Provider method        | Subprocess args            | Stdin/stdout                                       |
|------------------------|----------------------------|----------------------------------------------------|
| `Start(agent, cfg)`    | `start --agent=<name>`     | stdin: cfg JSON; stdout: session_id                |
| `Stop(sessionID)`      | `stop <sessionID>`         | exit code 0 = ok                                   |
| `Deliver(sid, msg)`    | `deliver <sid>`            | stdin: message JSON; stdout: `{delivered: bool}`   |
| `Health(sid)`          | `health <sid>`             | stdout: `{state, healthy, detail}` JSON            |
| `Output(sid, since?)`  | `output <sid> [--since=t]` | stdout: `[Message]` JSON                           |
| `Attach(sid)`          | `attach <sid>`             | exit code 0 = ok                                   |

The provider executable contract is published as
`docs/plugin-contracts/providers.md` (new file in this PR).

After loader runs, register every discovered provider into the
`session.ProviderRegistry`. Wire this into `cmd/coda/main.go`'s
`defaultRegistry()` so it's no longer empty.

### 4. Hook dispatch (`internal/plugin/hooks.go`)

```go
// HookRunner runs sorted scripts for a given event from both the
// user hooks dir and any manifest-declared plugin hook dirs.
type HookRunner struct { /* dirs */ }

// Run executes hooks in two layers:
//   1. user dir: $XDG_CONFIG_HOME/coda/hooks/<event>/
//   2. plugin dirs: each plugin's hooks/<event>/* (manifest-declared)
// Within each layer, sort by LC_ALL=C filename. Failures warn to
// stderr, don't block. env passed via os.Environ + extras.
func (h *HookRunner) Run(ctx context.Context, event string, env map[string]string) error
```

Must satisfy the `feature.HookRunner` interface that #172
shipped. The replacement in `cmd/coda/main.go` is a one-line wire
change: replace `feature.NewLocalHookRunner(...)` with
`plugin.NewHookRunner(...)`.

**Hook events the new runner must support** (the four #172
fires today):

- `pre-feature-create`
- `post-feature-create`
- `pre-feature-teardown`
- `post-feature-finish`

**Trap:** v2 docs use `CODA_*` env vars exactly. Match them so v2
plugins port cleanly: `CODA_PROJECT_NAME`, `CODA_PROJECT_DIR`,
`CODA_FEATURE_BRANCH`, `CODA_WORKTREE_DIR`. #172 already sets
these correctly; the new runner just needs to pass them through.

### 5. MCP server (stdio)

A coda-managed stdio MCP server that exposes plugin-declared
`mcp_tools`.

```go
// cmd/coda/main.go new top-level subcommand:
//   coda mcp serve   # reads jsonrpc from stdin, writes to stdout
//   coda mcp tools   # lists registered tools (debugging)
```

The server reads tool registrations from loaded plugins. When a
client calls a tool, the server dispatches via `exec.Command` to
the plugin's declared `command` array, passes JSON params on
stdin, returns stdout as the tool result.

**Scope guardrail:** implement only `initialize`, `tools/list`,
and `tools/call`. Do NOT implement prompts, resources, sampling,
completion, logging, or any other MCP method. Future methods are
follow-up cards.

**Library: hand-rolled JSON-RPC 2.0.** No new dependencies.

JSON-RPC 2.0 essentials:

- Request: `{"jsonrpc": "2.0", "id": <int|string>, "method": "...", "params": {...}}`
- Response (success): `{"jsonrpc": "2.0", "id": <same>, "result": {...}}`
- Response (error): `{"jsonrpc": "2.0", "id": <same>, "error": {"code": <int>, "message": "..."}}`
- Notification (no response): same shape as request, no `id`
- Standard error codes: -32700 parse, -32600 invalid request,
  -32601 method not found, -32602 invalid params, -32603 internal

MCP-specific shapes:

- `initialize` — params: `{"protocolVersion": "...", "capabilities": {...}}`. Response: server capabilities.
- `tools/list` — params: optional pagination cursor. Response: `{"tools": [{"name", "description", "inputSchema"}]}`.
- `tools/call` — params: `{"name": "...", "arguments": {...}}`. Response: `{"content": [{"type": "text", "text": "..."}], "isError": bool}`.

Stdio framing: newline-delimited JSON-RPC (one JSON object per
line). The MCP spec also defines content-length-framed transport
for non-stdio; not in scope here.

### 6. Command registration

For each plugin's `provides.commands.<name>`, register the
command in `cmd/coda/main.go`. Dispatch via:

```go
exec.Command("<plugin.Root>/<exec>", remaining_args...)
```

Pass through stdin/stdout/stderr. Plugin's exit code becomes
coda's exit code.

**Reserved core subcommands** must NOT be shadowable: `version`,
`agent`, `send`, `recv`, `ack`, `feature`, `mcp`. Plugins
attempting to register these get a **load-time error** (not a
silent skip — the plugin author needs to know).

## Repo layout (new files)

```
internal/plugin/
  plugin.go              (currently stub — replace)
  manifest.go            Manifest struct, Parse(), validation
  manifest_test.go
  loader.go              Loader, discovery, validation
  loader_test.go
  provider.go            SubprocessProvider (implements session.Provider)
  provider_test.go
  hooks.go               HookRunner (replaces feature.localHookRunner)
  hooks_test.go
  mcp.go                 stdio MCP server (hand-rolled JSON-RPC)
  mcp_test.go
  command.go             plugin-command dispatch helpers
  command_test.go
docs/plugin-contracts/
  plugins.md             v3 plugin.json schema + how to write a plugin
  hooks.md               v3 hook events + env vars
  providers.md           provider exec contract (subcommand args, JSON shapes)
  mcp.md                 v3 MCP tool contract
docs/specs/
  171-plugin-host.md     (this doc)
```

`cmd/coda/main.go`:

- New `mcp` top-level subcommand (`mcp serve`, `mcp tools`)
- `defaultRegistry()` replaced with a function that loads plugins
- Hook runner wire change: `feature.NewLocalHookRunner(...)` →
  `plugin.NewHookRunner(...)`

## Test surface

**Unit tests:**

- **Manifest parse:** valid, missing required fields, unknown
  top-level keys (warn, not fail), invalid JSON.
- **Loader:** empty dir, single plugin, multiple plugins,
  malformed plugin (one plugin failing doesn't kill others).
- **HookRunner:** user-dir only, plugin-dirs only, both, sort
  order, non-executable files skipped, failure warns but doesn't
  abort.
- **MCP server:** initialize, tools/list, tools/call (golden
  JSON-RPC fixtures). Error responses for unknown method, bad
  params.
- **SubprocessProvider:** each method calls the right exec args,
  marshals JSON correctly, handles non-zero exit codes.

**Integration tests:**

- End-to-end plugin load: scaffold a fake plugin in a tempdir
  with a real executable (a tiny Go binary built in-test, or a
  shell script), exercise commands/hooks/provider/mcp paths.
- Reserved-name shadowing rejected at load (assert error message
  names the conflicting subcommand).

## Acceptance gate

```bash
cd <worktree>
go build ./...
go vet ./...
go test ./... -count=1 -race
```

All three must exit 0.

## Out of scope

- Plugin install/remove CLI (`coda plugin install`). Follow-up
  card. For now, plugins are dropped manually into
  `~/.config/coda/plugins/`.
- HTTP MCP server (v2 had a shared port-3111 server; v3 doesn't
  yet).
- v2 `provides.notifications` / `provides.layouts` — not v3
  primitives.
- Plugin update / strict version-checking against `coda` field
  in manifest. Parse it, log a warning on mismatch. Strict
  enforcement is a follow-up card.
- Don't touch `internal/identity/`, `internal/messages/`,
  `internal/session/` (other than wiring providers into the
  registry through `cmd/coda/main.go`).
- Don't fix the harness FEATURE SESSION preamble (#188 — Riley
  scope).
- Don't update CLI usage strings (#185).

## Done when

- All six subsystems (manifest, loader, providers, hooks, MCP,
  commands) implemented with tests
- Four contract docs in `docs/plugin-contracts/`
- `defaultRegistry()` in `cmd/coda/main.go` is no longer always-empty
- `coda mcp serve` works end-to-end against a fixture plugin
- Acceptance gate exits 0
- AGENTS.md updated to reflect the plugin host shipping
- This spec doc committed at `docs/specs/171-plugin-host.md`
- PR opened against main

## Coordination

- **Depends on:** #172 (HookRunner interface). Already shipped at
  PR #8 / commit `75e80db`.
- **Unblocks:** #173 (codaclaw provider) absolutely needs this —
  Kit's surface but the interface is ours.
- **Foreshadows:** #174 (port v2 plugins) requires this contract
  finalized.
