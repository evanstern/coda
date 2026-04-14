# Layout Plugin Contract

Layouts are shell scripts that define how a tmux session's panes are arranged.

## Directory Resolution

User layouts override builtins of the same name:

1. `$CODA_LAYOUTS_DIR/<name>.sh` (default: `~/.config/coda/layouts/`)
2. `$_CODA_DIR/layouts/<name>.sh` (repo builtins)

## Required Interface

A layout file **must** define at least one of:

### `_layout_init session dir nvim_appname`

Create a new tmux session with the desired pane arrangement.

| Arg | Description |
|-----|-------------|
| `session` | tmux session name (e.g., `coda-myapp`) |
| `dir` | Working directory for the session |
| `nvim_appname` | Neovim config name (maps to `~/.config/<name>/`) |

This function must call `tmux new-session -d -s "$session" ...` to create the session.

### `_layout_spawn session dir nvim_appname`

Apply the layout into an existing session by creating a new window.

Same arguments as `_layout_init`. Called by `coda layout apply <name>`.

If absent, `coda layout apply` will report that the layout doesn't support spawning.

### `_layout_apply session dir nvim_appname` (deprecated)

Legacy alias for `_layout_init`. Accepted but new layouts should use `_layout_init`.

## Environment Available to Layouts

| Variable | Description |
|----------|-------------|
| `CODA_SESSION_NAME` | Set after session creation |
| `CODA_SESSION_DIR` | Working directory |
| `CODA_NVIM_APPNAME` | Neovim config name |
| `COLUMNS` | Terminal width (may not be set) |
| `LINES` | Terminal height (may not be set) |

## Validation

`_coda_load_layout` validates that at least `_layout_init` or `_layout_apply` is defined after sourcing. If neither exists, the layout is rejected with an error.

## Creating a Layout

```bash
coda layout create my-layout           # from template
coda layout create my-layout --snapshot # capture current window
```

Templates include both `_layout_init` and `_layout_spawn` stubs.
