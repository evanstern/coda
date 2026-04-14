# Plugin System

Plugins are git repos that extend coda with commands, hooks, providers, and notifications.

## Plugin Storage

Plugins are cloned to `$CODA_PLUGINS_DIR/<name>/` (default: `~/.config/coda/plugins/`).

## User Config (`~/.config/coda/config.json`)

```json
{
  "plugins": {
    "git@github.com:user/coda-github.git": {
      "enabled": true,
      "options": {
        "CODA_GITHUB_CLIENT_ID": "Iv23abc"
      }
    }
  }
}
```

Plugin options are exported as environment variables before the plugin's handlers are sourced.

## Plugin Manifest (`plugin.json`)

Each plugin repo has a `plugin.json` at the root:

```json
{
  "name": "coda-github",
  "version": "1.0.0",
  "coda": "^0.1.0",
  "description": "GitHub App bot identity for coda",
  "provides": {
    "commands": {
      "github": {
        "description": "Post comments as Coda bot identity",
        "handler": "lib/github.sh",
        "function": "_coda_github"
      }
    },
    "hooks": {
      "post-project-create": ["hooks/post-project-create/*"]
    },
    "providers": {
      "claude-auth": "providers/claude-auth/"
    },
    "notifications": ["notifications/*"]
  },
  "dependencies": {
    "system": ["lazygit"],
    "npm": ["opencode-claude-auth"],
    "go": "cmd/coda-github/"
  },
  "install": "install.sh"
}
```

All fields under `provides` are optional.

### `provides.commands`

Maps subcommand names to shell files and functions. When the user runs `coda <cmd>`, core sources the handler and calls the function.

| Field | Description |
|-------|-------------|
| `handler` | Relative path to the shell script |
| `function` | Function name to call after sourcing |
| `description` | Human-readable description |

### `provides.hooks`

Maps event names to glob patterns of executable hook scripts within the plugin directory. See [hooks.md](hooks.md) for events.

### `provides.providers`

Maps provider names to directories containing `auth.sh` and `status.sh`. See [providers.md](providers.md) for the provider contract.

### `provides.notifications`

Glob patterns of notification scripts. See [notifications.md](notifications.md).

### `provides.mcp_tools`

Registers tools with the coda MCP server so OpenCode agents can call plugin
functionality. Each entry maps a tool name to its definition:

```json
"mcp_tools": {
  "coda_watch_status": {
    "description": "Check if the session watcher is running",
    "command": ["watch", "status"]
  },
  "coda_github_comment": {
    "description": "Post a comment as Coda bot",
    "command": ["github", "comment"],
    "params": {
      "issue": { "type": "string", "description": "Issue or PR number" },
      "body": { "type": "string", "description": "Comment body" },
      "repo": { "type": "string", "description": "owner/repo", "optional": true }
    }
  }
}
```

| Field | Description |
|-------|-------------|
| `command` | Array of coda subcommand args (e.g. `["watch", "status"]`) |
| `description` | Human-readable description shown to agents |
| `params` | Optional parameter definitions |

Param types: `"string"`, `"boolean"`, `"cwd"` (used as working directory, not
appended to args). String params become `--name value` flags. Boolean params
become `--name` flags when true.

### `coda` (version constraint)

Specifies which versions of coda this plugin is compatible with, using
standard semver range syntax:

```json
"coda": "^0.1.0"
```

| Syntax | Meaning |
|--------|--------|
| `^0.1.0` | `>=0.1.0 <1.0.0` (compatible with 0.x) |
| `^1.2.0` | `>=1.2.0 <2.0.0` (same major) |
| `~1.2.0` | `>=1.2.0 <1.3.0` (same minor) |
| `>= 1.0.0 < 2.0.0` | Explicit range |
| `1.0.0` | Exact version |

At plugin load time, if the constraint doesn't match `CODA_VERSION`, the
plugin is skipped with a warning. During `coda plugin install`, a mismatch
prompts for confirmation.

If the `coda` field is absent, the plugin is treated as compatible with any
version.

### `dependencies`

| Field | Description |
|-------|-------------|
| `system` | Binary names that must be in PATH |
| `npm` | npm packages to install globally |
| `go` | Go module directory to build (installed to `~/.local/bin/`) |

### `install`

Optional custom install script to run after cloning and dependency installation.

## CLI Commands

```bash
coda plugin install <git-url>   # Clone and install a plugin
coda plugin remove <name>       # Remove an installed plugin
coda plugin update [name]       # Update plugin(s) via git pull
coda plugin ls                  # List installed plugins
```

## Plugin Lifecycle

1. **Install**: `coda plugin install` clones the repo, reads `plugin.json`, installs deps, runs install script.
2. **Load**: On shell startup, `_coda_plugin_load_all` reads `config.json`, discovers installed plugins, registers commands/hooks/providers/notifications.
3. **Auto-detect**: When `coda` runs and config.json references uninstalled plugins, prompts to install.
4. **Update**: `coda plugin update` does `git pull`, re-checks deps.
5. **Remove**: `coda plugin remove` deletes the plugin directory and config entry.

## Requirements

`jq` is required for plugin management. If jq is not available, the plugin system is silently skipped (coda works normally without plugins).
