# Provider exec contract

A provider plugin contributes a `session.Provider` implementation
through a single executable declared as
`provides.providers.<name>.exec`. The host spawns the executable
once per provider method via `os/exec`, passes input on stdin, and
parses output from stdout. Non-zero exit codes become errors.

## Subcommand surface

| Method                | argv                                | stdin                | stdout                                         |
|-----------------------|-------------------------------------|----------------------|------------------------------------------------|
| `Start(agent, cfg)`   | `start --agent=<name>`              | provider config JSON | trimmed first line is the session ID           |
| `Stop(sessionID)`     | `stop <sessionID>`                  | (none)               | (none) — exit 0 on success                     |
| `Deliver(sid, msg)`   | `deliver <sessionID>`               | message JSON         | `{"delivered": <bool>}`                        |
| `Health(sid)`         | `health <sessionID>`                | (none)               | `{"State": "...", "Healthy": <bool>, "Detail": "..."}` |
| `Output(sid, since?)` | `output <sessionID> [--since=<cursor>]` | (none)          | JSON array of `session.Message`                |
| `Attach(sid)`         | `attach <sessionID>`                | (none)               | (none) — exit 0 on success                     |

## Cursor protocol

The `--since=<cursor>` value is opaque to coda and plugin-defined.
Each `session.Message` returned by `Output` may carry a `Cursor`
field. `Output` responses are ordered: plugins MUST return messages
in the same stream order they want cursor advancement to follow
(typically oldest to newest). Coda does not compare, sort, or
otherwise interpret cursor values. After a successful `Output`
call, coda persists the `Cursor` from the last message in the
returned array whose `Cursor` is non-empty, and echoes that exact
value back as `--since=` on the next call. If no returned message
has a non-empty `Cursor`, coda leaves the persisted cursor
unchanged. An empty cursor (or omitted `--since`) means "from the
beginning."

## JSON shapes

`session.Message`:

```json
{
  "ID": "ulid-or-string",
  "From": "agent-a",
  "To": "agent-b",
  "Type": "note",
  "Body": "<base64-encoded bytes>",
  "CreatedAt": "2025-01-01T00:00:00Z",
  "Cursor": "plugin-defined-opaque-value"
}
```

`session.ProviderConfig` is an opaque `map[string]string`.

### ProviderConfig key naming

`ProviderConfig` is per-agent: each agent declares one provider and
one config blob. The keys in that blob belong to exactly one
provider's namespace, so collision across providers is impossible
by construction.

**Convention: use unprefixed keys.** A CodaClaw provider config
uses `host_endpoint`, `image`, `mount_allowlist` — not
`codaclaw_host`, `codaclaw_image`. The provider's identity is
already implicit in the agent's `provider` field; restating it in
every key is noise.

Format notes:

- Values are always strings. Structured types (lists, paths, ports)
  serialize to strings — typically comma-separated for lists, with
  whitespace around commas ignored.
- Paths support `~/` expansion at the plugin layer; document the
  expansion behavior per-key when relevant.
- Names containing secrets (API keys, tokens) MUST refer to env
  var names rather than embed the secret. `ProviderConfig`
  serializes into `coda.db`; secrets do not belong there.
  Convention: `<thing>_env` for env-var-name keys
  (e.g. `anthropic_api_key_env: ANTHROPIC_API_KEY`).

## Error semantics

- **Zero exit code** is success. Any other exit is an error; the
  host wraps stderr (or stdout if stderr is empty) into an error
  string.
- **Empty stdout from `start`** is a fatal error; the plugin must
  print at least the session ID.
- **Malformed JSON** on `deliver`, `health`, or `output` becomes a
  parse error.

## Implementation tips

- One executable handles every subcommand; switch on `argv[1]`.
- Read all of stdin before responding on `start` and `deliver`.
- Keep stdout free of log noise — log to stderr.
- Long-running operations (e.g., a real session loop) belong inside
  `start`; the host treats stdout's first line as the ID and returns
  immediately, so background the actual work.
