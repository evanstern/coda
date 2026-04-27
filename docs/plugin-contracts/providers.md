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
| `Output(sid, since?)` | `output <sessionID> [--since=<RFC3339>]` | (none)          | JSON array of `session.Message`                |
| `Attach(sid)`         | `attach <sessionID>`                | (none)               | (none) — exit 0 on success                     |

## JSON shapes

`session.Message`:

```json
{
  "ID": "ulid-or-string",
  "From": "agent-a",
  "To": "agent-b",
  "Type": "note",
  "Body": "<base64-encoded bytes>",
  "CreatedAt": "2025-01-01T00:00:00Z"
}
```

`session.ProviderConfig` is an opaque `map[string]string`.

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
