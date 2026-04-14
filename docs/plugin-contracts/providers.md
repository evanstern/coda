# Provider Plugin Contract

Providers handle auth and status for AI harness backends.

## Directory Resolution

User providers override builtins of the same name:

1. `$CODA_PROVIDERS_DIR/<mode>/` (default: `~/.config/coda/providers/`)
2. `$_CODA_DIR/providers/<mode>/`

## Required Files

### `auth.sh`

Defines `_provider_auth()`. Called by `coda auth`.

### `status.sh`

Defines `_provider_status()`. Called by `coda provider status`.

## Available Helpers

Provider scripts are sourced into the shell, so all coda helpers are available:

- `_coda_resolve_opencode_config_path` u2014 path to managed OpenCode config
- `_coda_validate_api_key` u2014 rejects CRLF injection
- `_coda_normalize_url` u2014 validates and normalizes HTTP(S) URLs
- `_coda_probe_url` / `_coda_print_url_status` u2014 HTTP health checks

## Built-in Providers

| Name | Purpose |
|------|--------|
| `claude-auth` | Claude CLI OAuth + opencode-claude-auth plugin |
| `cliproxyapi` | OpenAI-compatible proxy via CLIProxyAPI |

## Creating a Provider

```bash
mkdir -p ~/.config/coda/providers/my-provider
# Create auth.sh defining _provider_auth()
# Create status.sh defining _provider_status()
```

Set `CODA_PROVIDER_MODE=my-provider` in `.env` to activate it.
