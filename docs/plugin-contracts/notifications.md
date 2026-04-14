# Notification Plugin Contract

Notifications are executable scripts that fire when the watcher detects an agent transition from processing to idle.

## Directory Resolution

Notifications are discovered from multiple sources:

1. `$_CODA_DIR/notifications/` (builtin)
2. `$CODA_NOTIFICATIONS_DIR/` (user, default: `~/.config/coda/notifications/`)
3. Plugin notification directories (from `provides.notifications` globs in `plugin.json`)

## Writing a Notification Script

A notification script is any executable file in a notifications directory. The watcher runs each script when a session becomes idle.

```bash
#!/usr/bin/env bash
# Send a terminal bell
printf '\a'
```

The built-in `bell.sh` sends a terminal bell to all connected tmux clients.

## Plugin Notifications

Plugins can provide notification scripts via the `provides.notifications` field in `plugin.json`:

```json
{
  "provides": {
    "notifications": ["notifications/*"]
  }
}
```

Glob patterns are resolved relative to the plugin directory.
