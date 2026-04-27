# Plugin manifest (`plugin.json`)

A coda v3 plugin is a directory under
`$XDG_CONFIG_HOME/coda/plugins/<name>/` (overridable via
`$CODA_PLUGINS_DIR`) containing a `plugin.json` manifest plus any
executable artifacts the manifest references.

The host loads every immediate subdirectory of the plugins dir; a
malformed manifest is logged as a warning and the plugin is skipped
without aborting the load.

## Schema

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
    "mcp_tools": { "<tool>": { "description": "...", "inputSchema": {...}, "command": ["bin/tool", "arg"] } }
  },
  "dependencies": { "system": ["..."], "go": "1.22", "npm": [] },
  "install": "scripts/install.sh"
}
```

## Required fields

| field     | type   | notes                                          |
|-----------|--------|------------------------------------------------|
| `name`    | string | identifier; used in error messages and logs   |
| `version` | string | plugin version; informational                 |
| `coda`    | string | semver range against host (warn-only for now) |

A missing or empty required field aborts the manifest with a
descriptive error. Unknown top-level keys log a warning but do not
fail the load.

## Provides

All four subsections are optional.

- **`commands.<name>`** registers a top-level CLI verb. `exec` is a
  path relative to the plugin root. The host dispatches via
  `os/exec` with explicit argv and pipes through stdin/stdout/stderr.
  The plugin's exit code becomes the coda exit code.
- **`hooks.<event>`** is a list of glob patterns rooted at the plugin
  dir. Matched executables run for the event. If `hooks` is omitted,
  the host falls back to `<plugin-root>/hooks/<event>/*`.
- **`providers.<name>`** registers a `session.Provider`
  implementation. See `providers.md` for the executable contract.
- **`mcp_tools.<name>`** registers a tool exposed via `coda mcp serve`.
  See `mcp.md`.

## Reserved names

The following CLI verbs are reserved for the host. A plugin
declaring a `commands.<name>` entry shadowing one of them is a
load-time error:

```
version  agent  send  recv  ack  feature  mcp  help
```

## Dependencies

`dependencies` is advisory. The host does not enforce; the plugin's
`install` script is responsible for any system/runtime requirements.

## Install

`install` is a path (relative to plugin root) the user can run after
dropping the plugin directory in place. The host does not run it
automatically.
