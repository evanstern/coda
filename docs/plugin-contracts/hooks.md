# Hook Events Contract

Hooks are executable scripts in event directories. Coda runs them at lifecycle boundaries.

## Directory Resolution

User hooks run first, then builtins:

1. `$CODA_HOOKS_DIR/<event>/` (default: `~/.config/coda/hooks/`)
2. `$_CODA_DIR/hooks/<event>/`

Scripts are sorted by filename (`LC_ALL=C sort`) and executed in order. Failures warn but never block.

## Events

| Event | When | Environment Variables |
|-------|------|----------------------|
| `pre-session-create` | Before `tmux new-session` | `CODA_SESSION_NAME`, `CODA_SESSION_DIR` |
| `post-session-create` | After session + layout created | `CODA_SESSION_NAME`, `CODA_SESSION_DIR`, `CODA_SESSION_LAYOUT` |
| `post-session-attach` | After `tmux attach` or `switch-client` | `CODA_SESSION_NAME` |
| `post-project-create` | After project setup (both clone and new) | `CODA_PROJECT_NAME`, `CODA_PROJECT_DIR` |
| `post-project-clone` | After clone specifically (in addition to post-project-create) | `CODA_PROJECT_NAME`, `CODA_PROJECT_DIR`, `CODA_REPO_URL` |
| `pre-project-close` | Before sessions are killed | `CODA_PROJECT_NAME`, `CODA_PROJECT_DIR` |
| `post-feature-create` | After worktree created, before session attach | `CODA_PROJECT_NAME`, `CODA_PROJECT_DIR`, `CODA_FEATURE_BRANCH`, `CODA_WORKTREE_DIR` |
| `pre-feature-teardown` | Before `feature done` kills session | `CODA_PROJECT_NAME`, `CODA_PROJECT_DIR`, `CODA_FEATURE_BRANCH`, `CODA_WORKTREE_DIR`, `CODA_SESSION_NAME` |
| `post-feature-finish` | After backgrounded `feature finish` teardown completes | `CODA_PROJECT_NAME`, `CODA_FEATURE_BRANCH` |
| `post-layout-apply` | After `coda layout apply` succeeds | `CODA_SESSION_NAME`, `CODA_SESSION_LAYOUT` |

## Writing a Hook

A hook is any executable file in the event directory. Convention: `NN-name` where NN is a sort prefix.

```bash
#!/usr/bin/env bash
# hooks/post-session-create/10-notify
echo "Session $CODA_SESSION_NAME created in $CODA_SESSION_DIR"
```

Make it executable: `chmod +x hooks/post-session-create/10-notify`

## Plugin Hooks

Plugins can provide hooks via the `provides.hooks` field in `plugin.json`:

```json
{
  "provides": {
    "hooks": {
      "post-project-create": ["hooks/post-project-create/*"]
    }
  }
}
```

Plugin hooks run after user and builtin hooks. Glob patterns are resolved relative to the plugin directory. See [plugins.md](plugins.md).

## Guarantees

- Hooks receive context via exported environment variables, not positional arguments
- Hook failures are reported to stderr but never block core operations
- Hooks within a directory execute in `LC_ALL=C` sorted order
- Non-executable files are silently skipped
- Empty or missing event directories produce no error
