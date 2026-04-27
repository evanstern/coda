# Hook contract

Hooks are executable scripts that fire at lifecycle events. The
runner discovers hooks from two layers:

1. **User layer** — `$XDG_CONFIG_HOME/coda/hooks/<event>/`
2. **Plugin layer** — for each loaded plugin, either
   - the manifest-declared `provides.hooks.<event>` glob patterns
     (resolved relative to the plugin root), or
   - if no manifest entry, `<plugin-root>/hooks/<event>/`

Within each layer, the runner sorts entries by `LC_ALL=C` filename
and invokes them in order. Layers run user → plugin so user hooks
get a first crack.

## Events

Coda v3 fires hooks at four feature-lifecycle events:

| event                  | when                                                     |
|------------------------|----------------------------------------------------------|
| `pre-feature-create`   | before `git worktree add` for a new feature              |
| `post-feature-create`  | after the worktree is on disk                            |
| `pre-feature-teardown` | before tearing down a worktree (after dirty-state check) |
| `post-feature-finish`  | after worktree removal and branch deletion               |

## Environment

The runner merges these v2-compatible environment variables into the
hook process environment:

| variable               | value                                  |
|------------------------|----------------------------------------|
| `CODA_PROJECT_NAME`    | resolved project name                  |
| `CODA_PROJECT_DIR`     | absolute path to the project root      |
| `CODA_FEATURE_BRANCH`  | the branch being created or finished   |
| `CODA_WORKTREE_DIR`    | absolute path to the worktree on disk  |

`os.Environ()` is also passed through; any matching keys in the
hook env override the parent's.

## Failure model

Hooks are warn-only: a non-zero exit logs `warn: hook <event>/<name>
failed: <err>` to stderr and the runner continues with subsequent
hooks. Non-executable regular files in the hook dir are silently
skipped.

## Authoring

A hook is any executable file. Shebangs work:

```sh
#!/bin/sh
echo "creating ${CODA_FEATURE_BRANCH} for ${CODA_PROJECT_NAME}"
```

Make it executable (`chmod +x`) and drop it into the appropriate
directory.
