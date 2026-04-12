# Coda

A headless development server running multiple [OpenCode](https://opencode.ai) AI coding agents
in parallel across isolated git worktrees, accessible from anywhere via Tailscale + mosh.

## What this is

You provision a VM (on Proxmox, or any Ubuntu host), run `./install.sh`, and get:

- **Multiple parallel OpenCode sessions** — each in its own tmux window, each in its own git worktree, each on its own branch. No conflicts, no stepping on each other.
- **Access from anywhere** — Tailscale gives the VM a stable IP from any network. mosh survives WiFi drops, cellular handoffs, and laptop sleep. tmux sessions persist regardless of connection state.
- **Fire-and-forget mode** — `opencode serve` exposes an HTTP API. Submit tasks from scripts, cron jobs, or your phone, and check results when you're back.
- **`coda`** — a unified CLI that wraps all session, project, and feature management into one command with tab completion and a man page.

```
+----------------------------------------------+
|  YOUR DEVICES (laptop, phone, tablet)         |
|  mosh over Tailscale                          |
+--------------------+-------------------------+
                     |  100.x.x.x (Tailscale)
+--------------------v-------------------------+
|  VM (Ubuntu 24.04)                            |
|                                               |
|  tmux                                         |
|  |-- coda-myapp           (main branch)       |
|  |-- coda-myapp--auth     (feature/auth)      |
|  |-- coda-myapp--api      (feature/api)       |
|  \-- coda-other-proj      (main branch)       |
|                                               |
|  ~/projects/myapp/                            |
|  |-- .bare/               (all git objects)   |
|  |-- main/                (worktree)          |
|  |-- auth/                (worktree)          |
|  \-- api/                 (worktree)          |
+----------------------------------------------+
```

---

## Installation

On a fresh Ubuntu Server 24.04 VM, clone this repo and run:

```bash
git clone <this-repo-url> ~/coda
cd ~/coda
chmod +x install.sh
./install.sh
```

`install.sh` is fully idempotent — safe to re-run at any time. It installs and
configures everything in one pass:

| Step | What it does |
|------|-------------|
| 1 | System packages: git, tmux, mosh, curl, build-essential, jq, lsof, etc. |
| 2 | Neovim (latest release from GitHub, upgrades if installed version is too old) |
| 3 | Node.js via NodeSource (version-aware, won't skip on outdated installs) |
| 4 | OpenCode via `npm install -g opencode-ai@latest` |
| 5 | Claude Code CLI via `npm install -g @anthropic-ai/claude-code` |
| 6 | fzf (fuzzy finder, binary install) |
| 7 | yazi (terminal file manager, used by four-pane layout) |
| 8 | lazygit (terminal git UI, used by four-pane layout) |
| 9 | Oh My Posh prompt theme engine (user install to `~/.local/bin`) |
| 10 | tmux Plugin Manager (TPM) |
| 11 | Tailscale |
| 12 | Config files, tab completions, man page, Oh My Posh shell init, SSH keepalive, tmux plugins |

To skip optional components:

```bash
SKIP_TAILSCALE=true ./install.sh
SKIP_OPENCODE=true  ./install.sh
SKIP_CLAUDE=true    ./install.sh
SKIP_OHMYPOSH=true  ./install.sh
SKIP_YAZI=true      ./install.sh
SKIP_LAZYGIT=true   ./install.sh
```

### After install

Reload your shell first, then choose one provider path.

```bash
sudo tailscale up          # connect to your Tailscale network
source ~/.bashrc           # pick up coda + completions
tmux                       # start your first session
```

#### Claude path

```bash
claude auth login          # one-time OAuth flow
coda auth                  # install Claude plugin + verify
```

#### CLIProxyAPI path

Run CLIProxyAPI separately, then point Coda at it:

```bash
# in ~/coda/.env
CODA_PROVIDER_MODE="cliproxyapi"
CLIPROXYAPI_BASE_URL="http://localhost:8317/v1"
CLIPROXYAPI_API_KEY=""      # optional; set if your proxy requires auth

coda auth                  # write/update OpenCode provider config
coda provider status       # probe config/auth readiness (not runtime proof)
```

---

## Process Flow

```
  ┌─────────────────────────────────────────────────────────────────┐
  │  FIRST TIME (once per VM)                                        │
  │                                                                   │
  │  ./install.sh                                                     │
  │       │                                                           │
  │       ├──▶  sudo tailscale up                                    │
  │       ├──▶  source ~/.bashrc                                     │
  │       ├──▶  Claude path: claude auth login -> coda auth         │
  │       └──▶  CLIProxyAPI path: edit .env -> coda auth ->         │
  │                             coda provider status                 │
  │                                    │                              │
  │                                    └──▶  ready ✓                 │
  └─────────────────────────────────────────────────────────────────┘

  ┌─────────────────────────────────────────────────────────────────┐
  │  START A PROJECT (once per repo)                                  │
  │                                                                   │
  │  coda project start --repo git@github.com:user/myapp.git        │
  │  coda project start --new my-tool -m "CLI for widgets"          │
  │       │                                                           │
  │       └──▶  ~/projects/myapp/                                    │
  │                  ├── .bare/    (all git objects)                  │
  │                  ├── .git      (pointer to .bare)                 │
  │                  └── main/     ◀── cd here to start              │
  └─────────────────────────────────────────────────────────────────┘

  ┌─────────────────────────────────────────────────────────────────┐
  │  DAILY WORKFLOW                                                   │
  │                                                                   │
  │  mosh user@100.x.x.x  (Tailscale IP)                            │
  │       │                                                           │
  │       └──▶  tmux  (auto-attached on SSH login)                   │
  │                │                                                  │
  │                ├──▶  coda ls          see what's running         │
  │                ├──▶  coda switch      fzf-pick a session         │
  │                │                                                  │
  │                └──▶  cd ~/projects/myapp/main                    │
  │                              │                                    │
  │                              │  New feature?                      │
  │                              ├── YES ──▶  coda feature start auth│
  │                              │                   │                │
  │                              │                   └──▶  OpenCode  │
  │                              │                         opens in   │
  │                              │                         new tmux   │
  │                              │                         session    │
  │                              │                                    │
  │                              └── NO  ──▶  coda [name]            │
  │                                                  │                │
  │                                                  └──▶  OpenCode  │
  │                                                        opens or   │
  │                                                        attaches   │
  └─────────────────────────────────────────────────────────────────┘

  ┌─────────────────────────────────────────────────────────────────┐
  │  FEATURE LIFECYCLE                                               │
  │                                                                   │
  │  coda feature start auth                                         │
  │       │                                                           │
  │       ├──▶  git worktree add  ~/projects/myapp/auth              │
  │       └──▶  tmux session: coda-myapp--auth                      │
  │                    │                                              │
  │                    └──▶  OpenCode running in auth/               │
  │                                   │                              │
  │                           [work happens; PR merged]              │
  │                                   │                              │
  │  coda feature done auth           │                              │
  │       │                           │                              │
  │       ├──▶  kill session: coda-myapp--auth                      │
  │       ├──▶  git worktree remove  auth/                           │
  │       └──▶  git branch -D auth                                   │
  └─────────────────────────────────────────────────────────────────┘

  ┌─────────────────────────────────────────────────────────────────┐
  │  PARALLEL AGENTS                                                  │
  │                                                                   │
  │  coda feature start auth      session: coda-myapp--auth         │
  │  coda feature start payments  session: coda-myapp--payments     │
  │  coda feature start docs      session: coda-myapp--docs         │
  │       │                                                           │
  │       └──▶  coda switch   ──▶  fzf picker to hop between them   │
  │                                                                   │
  │  From phone / without attaching:                                  │
  │       tmux send-keys -t coda-myapp--auth "fix the bug" Enter    │
  └─────────────────────────────────────────────────────────────────┘

  ┌─────────────────────────────────────────────────────────────────┐
  │  HEADLESS / FIRE-AND-FORGET                                      │
  │                                                                   │
  │  coda serve                                                       │
  │       │                                                           │
  │       └──▶  opencode serve --port 4096                          │
  │                    │                                              │
  │                    ├──▶  opencode attach http://localhost:4096   │
  │                    │     (TUI monitor)                            │
  │                    │                                              │
  │                    └──▶  POST /session/:id/prompt_async          │
  │                           (fire-and-forget API call)              │
  └─────────────────────────────────────────────────────────────────┘
```

---

## Shell Commands

All commands are provided by the `coda` function, sourced from `shell-functions.sh`.
Run `man coda` for the full manual. Tab completion is available for all subcommands.

### Global Flags

These flags can be placed anywhere in the command:

| Flag | Description |
|---|---|
| `--profile <name>` | Use a config profile (overrides layout + nvim config) |
| `--layout <name>` | Override the tmux layout for this session |

```bash
coda --profile experimental feature start auth
coda --layout classic myapp
```

---

### `coda [name] [dir]`

Attach to an existing session or create a new one running OpenCode.

```bash
coda                          # session named after current directory
coda myapp                    # create/attach session "coda-myapp"
coda myapp ~/projects/myapp   # session in a specific directory
```

- Strips the `coda-` prefix automatically if you type it (both work)
- If already inside tmux, switches to the session instead of nesting

---

### `coda attach [name]`

Explicitly attach to an existing session. Equivalent to `coda [name]`.

```bash
coda attach myapp
```

---

### `coda ls`

List all active coda sessions.

```bash
coda ls
# Active sessions:
#   coda-myapp  (2w, created ...)
#   coda-myapp--auth  (1w, created ...)
```

---

### `coda switch`

fzf session picker with a live preview of each session's output.

```bash
coda switch
```

Also available as `prefix + f` inside tmux (popup).

---

### `coda project start`

Unified entry point for starting projects. Three modes:

**Reconnect** — from inside a project directory, connect to the existing
main/master session:

```bash
cd ~/projects/myapp/main
coda project start
```

**Clone** — clone an existing repo using the bare repository pattern:

```bash
coda project start --repo git@github.com:user/myapp.git
coda project start --repo https://github.com/user/myapp.git custom-name
```

**Create new** — create a new private repo on GitHub under `evanstern`,
bootstrap it from a local bare coda project, and push the initial commit:

```bash
coda project start --new my-tool
coda project start --new my-tool -m "CLI for managing widgets"
```

When `--message` / `-m` is provided, that message is written verbatim to
`AGENTS.md` in the repo root as initial context for AI coding agents. Requires
`gh` CLI.

All modes produce the same project layout:
```
~/projects/<name>/
  .bare/    (all git objects)
  .git      (pointer: "gitdir: ./.bare")
  main/     (initial worktree, checked out on main)
```

---

### `coda project ls`

List all coda-managed projects in `PROJECTS_DIR`.

```bash
coda project ls
#   myapp  →  /home/user/projects/myapp/
#   api    →  /home/user/projects/api/
```

---

### `coda project workon <name> [branch]`

Open a project session, creating a worktree if needed.

```bash
coda project workon myapp            # open on default branch
coda project workon myapp develop    # open on specific branch
```

If the branch worktree doesn't exist yet, it's created automatically.

---

### `coda project close [--delete]`

Close the tmux sessions for the current project. Must be run from inside a coda
project directory.

```bash
cd ~/projects/myapp/main

coda project close
# closes coda-myapp and any coda-myapp--* sessions
# keeps ~/projects/myapp/ on disk

coda project close --delete
# closes the same sessions
# also removes ~/projects/myapp/
```

By default, `close` only shuts down the project's tmux sessions. Pass
`--delete` to also remove the project folder and all worktrees under it.
Teardown is backgrounded, so the sessions or folders may take a moment to disappear.

---

### `coda feature start <branch> [base] [project]`

Create a git worktree on a new branch and open an OpenCode session inside it.
Must be run from inside a project directory.

```bash
cd ~/projects/myapp/main

coda feature start auth                   # branch from main
coda feature start auth develop           # branch from develop
coda feature start auth develop myapp     # explicit project name
```

Session name: `coda-<project>--<branch>`
Worktree path: `~/projects/<project>/<branch>/`

If the worktree already exists, attaches to the existing session.

---

### `coda feature done <branch> [project]`

Tear down a feature completely.

```bash
cd ~/projects/myapp/main
coda feature done auth
# Killing session: coda-myapp--auth
# Removing worktree: ~/projects/myapp/auth
# Deleting branch: auth
```

> **Note:** Deletes the branch regardless of merge status. Merge or push first.

---

### `coda feature finish [--force]`

Agent-safe teardown of the current feature branch. Detects the branch and
project from the working directory (takes no arguments). The teardown runs in
the background so it completes even when called from within the session being
destroyed.

```bash
coda feature finish          # must be on a feature branch
coda feature finish --force  # skip uncommitted changes check
```

Refuses to proceed if there are uncommitted or untracked changes unless
`--force` is passed.

---

### `coda feature ls`

Show all worktrees for the current project.

```bash
cd ~/projects/myapp/auth
coda feature ls
# Worktrees for myapp:
#   /home/user/projects/myapp/.bare  (bare)
#   /home/user/projects/myapp/main   abc1234 [main]
#   /home/user/projects/myapp/auth   def5678 [auth]
```

---

### `coda serve [port]`

Start OpenCode in headless server mode. Auto-selects a free port starting at
`OPENCODE_BASE_PORT` if none specified. Uses `OPENCODE_HEADLESS_PERMISSION`
(default: auto-approve everything).

```bash
coda serve          # auto-select port
coda serve 4100     # specific port

# Attach a TUI to watch it:
opencode attach http://localhost:4096

# Submit a task asynchronously:
curl -X POST http://localhost:4096/session/$SESSION_ID/prompt_async \
     -H 'Content-Type: application/json' \
     -d '{"parts":[{"type":"text","text":"Add error handling to all routes"}]}'
```

---

### `coda auth`

One-time setup to wire the active provider into OpenCode. The behavior depends
on `CODA_PROVIDER_MODE`.

**Claude path** (`CODA_PROVIDER_MODE=claude-auth`, the default):

```bash
claude auth login   # complete OAuth in browser
coda auth           # install plugin + verify

# Verify:
opencode models anthropic
```

If Claude auth expires, re-run `claude auth login` then `coda auth`.

**CLIProxyAPI path** (`CODA_PROVIDER_MODE=cliproxyapi`):

```bash
# in ~/coda/.env
CODA_PROVIDER_MODE="cliproxyapi"
CLIPROXYAPI_BASE_URL="http://localhost:8317/v1"
CLIPROXYAPI_API_KEY=""      # optional; set if your proxy requires auth

coda auth             # writes/updates ~/.config/opencode/opencode.json
coda provider status  # probes config/auth readiness; not end-to-end runtime proof
```

CLIProxyAPI stays external to this repo. `coda auth` manages the OpenCode
provider config and includes proxy auth when `CLIPROXYAPI_API_KEY` is set; it
does not start or stop the proxy.

---

### `coda provider status`

Show provider diagnostics for the current mode.

```bash
coda provider status
```

In `cliproxyapi` mode this reports the active mode, effective OpenCode config
path, whether the managed `cliproxyapi` provider block is present, whether
optional proxy auth is configured, and probes the base URL, health endpoint,
and models endpoint. Missing config, unauthorized models access, and probe-only
success are reported separately so the output does not imply end-to-end runtime
proof.

---

### `coda watch`

Start a background watcher that monitors all OpenCode sessions. When an agent
finishes processing and starts waiting for your input, the watcher sends a
terminal bell to every connected tmux client. The bell propagates through mosh
to your local terminal, which shows an OS-native notification.

```bash
coda watch                # start the watcher (runs in coda-watcher tmux session)
coda watch status         # check if running
coda watch stop           # stop the watcher
```

Detection: the watcher captures each pane's status bar every `CODA_WATCH_INTERVAL`
seconds (default: 5). It looks for the `esc interrupt` indicator that appears
while OpenCode is actively processing. When that indicator disappears (processing
→ idle transition), the notification fires.

A cooldown of `CODA_WATCH_COOLDOWN` seconds (default: 60) prevents repeated
notifications for the same pane.

---

### `coda layout [name]`

Apply a tmux layout to the current session or manage layouts.

```bash
coda layout wide-twopane     # apply layout to current session
coda layout ls               # list available layouts
coda layout show four-pane   # show layout file contents
coda layout create my-custom # create a new layout from template
```

Built-in layouts:

| Layout | Description |
|---|---|
| `default` | Single pane running opencode |
| `classic` | Single pane running opencode (alias) |
| `wide-twopane` | opencode (left) + nvim (right) |
| `three-pane` | opencode (top-left), nvim (top-right), shell (bottom) |
| `four-pane` | Four-pane arrangement with opencode, nvim, lazygit, and yazi |

User-created layouts in `CODA_LAYOUTS_DIR` override built-ins of the same name.

---

### `coda profile <ls|create|show>`

Manage config profiles that bundle layout and nvim settings.

```bash
coda profile ls              # list available profiles
coda profile create dev      # create a new profile
coda profile show dev        # show profile settings
```

Profiles are `.env` files stored in `CODA_PROFILES_DIR` that can override
`CODA_LAYOUT` and `CODA_NVIM_APPNAME`. Use with `--profile`:

```bash
coda --profile dev feature start auth
```

---

### `coda help`

Print a short usage summary. Full manual: `man coda`.

---

## Tab Completion

Installed automatically by `install.sh` for both bash and zsh.

```
coda <TAB>                     → attach ls switch serve auth project feature
                                 layout profile watch provider help [active sessions]
coda attach <TAB>              → [active sessions]
coda feature <TAB>             → start done finish ls
coda feature start <TAB>       → [local git branches]
coda feature done <TAB>        → [branches with active worktrees]
coda feature finish <TAB>      → --force
coda project <TAB>             → start workon close ls
coda project close <TAB>       → --delete
coda project start <TAB>       → --repo --new --message
coda project workon <TAB>      → [project names] → [branches]
coda layout <TAB>              → apply ls show create [available layouts]
coda layout apply <TAB>        → [available layouts]
coda profile <TAB>             → ls create show
coda profile show <TAB>        → [available profiles]
coda watch <TAB>               → start stop status
coda provider <TAB>            → status
coda serve <TAB>               → [port numbers]
coda switch                    → (no completion needed — interactive fzf)
coda --profile <TAB>           → [available profiles]
coda --layout <TAB>            → [available layouts]
```

---

## Remote Access

### Tailscale

Install inside the VM (not on the Proxmox host):

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up
```

> **Proxmox note:** Do not install Tailscale on the Proxmox host with
> `--advertise-routes` for your VM subnet. It can route the host's own traffic
> through the VPN, breaking cluster communication.

### mosh

mosh is installed by `install.sh`. Connect identically to SSH but with
UDP transport that survives interruptions:

```bash
mosh user@100.x.x.x      # Tailscale IP
```

Tailscale handles the UDP traversal — no extra firewall rules needed.

### Mobile access

- **iOS/Android**: [Termius](https://termius.com) or [Blink Shell](https://blink.sh) over Tailscale
- Dispatch tasks to running agents without attaching:
  ```bash
  tmux send-keys -t coda-myapp--auth "fix the failing tests" Enter
  ```

---

## Configuration

All behaviour is controlled by `.env` in the repo directory. Created from
`.env.example` on first `install.sh` run.

| Variable | Default | Description |
|---|---|---|
| `PROJECTS_DIR` | `~/projects` | Root directory for all repos |
| `SESSION_PREFIX` | `coda-` | tmux session name prefix |
| `DEFAULT_BRANCH` | `main` | Default branch for new worktrees |
| `GIT_REMOTE` | `origin` | Git remote name |
| `EDITOR` / `VISUAL` | `vim` | Editor for OpenCode `/editor` flows |
| `OPENCODE_BASE_PORT` | `4096` | First port tried by `coda serve` |
| `OPENCODE_PORT_RANGE` | `10` | Number of ports to scan |
| `OPENCODE_HEADLESS_PERMISSION` | `{"*":"allow"}` | Permission policy for `coda serve` |
| `CODA_PROVIDER_MODE` | `claude-auth` | Provider mode for `coda auth`: `claude-auth` or `cliproxyapi` |
| `CLIPROXYAPI_BASE_URL` | `http://localhost:8317/v1` | OpenAI-compatible base URL written into the managed CLIProxyAPI provider block |
| `CLIPROXYAPI_API_KEY` | empty | Optional proxy API key used for cliproxy model discovery/status probes and written into the managed provider block when set |
| `CLIPROXYAPI_HEALTH_URL` | empty | Optional health endpoint used by `coda provider status`; skipped when unset |
| `CODA_OPENCODE_CONFIG_PATH` | empty | Optional override for the OpenCode config path; if set, Coda also exports `OPENCODE_CONFIG` |
| `NODE_MAJOR_VERSION` | `20` | Node.js major version for install |
| `PACKAGE_MANAGER` | `npm` | Package manager preference (npm, pnpm, or yarn) |
| `DEFAULT_LAYOUT` | `four-pane` | Default tmux layout when creating sessions |
| `DEFAULT_NVIM_APPNAME` | `nvim` | Neovim config name (maps to `~/.config/<name>/`) |
| `CODA_LAYOUTS_DIR` | `~/.config/coda/layouts` | User layout scripts directory |
| `CODA_PROFILES_DIR` | `~/.config/coda/profiles` | User profile overrides directory |
| `CODA_WATCH_INTERVAL` | `5` | Watcher poll interval (seconds) |
| `CODA_WATCH_COOLDOWN` | `60` | Min seconds between repeat notifications per pane |
| `AUTO_ATTACH_TMUX` | `true` | Auto-attach to tmux on SSH login |
| `DEFAULT_TMUX_SESSION` | `default` | Session name for auto-attach |

---

## tmux Keybinds

Prefix key: `Ctrl+b`

| Binding | Action |
|---|---|
| `prefix + \|` | Split pane vertically |
| `prefix + -` | Split pane horizontally |
| `prefix + h/j/k/l` | Navigate panes (vim-style) |
| `prefix + H/J/K/L` | Resize panes |
| `prefix + c` | New window (inherits current path) |
| `prefix + f` | fzf session switcher (popup) |
| `prefix + o` | Open a vim popup and submit the saved buffer to the window's OpenCode pane |
| `prefix + r` | Reload tmux config |
| `prefix + p` | Paste buffer |

**Copy mode** (`prefix + [`):

| Key | Action |
|---|---|
| `v` | Begin selection |
| `V` | Select whole line |
| `Ctrl+v` | Rectangle selection |
| `y` | Copy and exit |
| `/` / `?` | Search forward / backward |

Copies go to the system clipboard via OSC 52. tmux-continuum saves sessions
every 15 minutes and restores them on reboot.

In the four-pane layout, `prefix + o` opens a popup editor and pastes the saved
text into the most relevant OpenCode pane in the current tmux session, then
presses Enter. It prefers the current window, then falls back within the same
session using pane title, running command, active window, and matching working
directory, so it works with the built-in four-pane layout and similar custom
layouts.

---

## File Structure

```
coda/
|-- install.sh              Full install: packages → config wiring
|-- setup-vm.sh             Lightweight VM bootstrap (subset of install.sh)
|-- coda-watcher.sh         Background session monitor (started via coda watch)
|-- shell-functions.sh      The coda command (sourced into your shell)
|-- completions/
|   |-- coda.bash           Bash tab completion
|   \-- coda.zsh            Zsh tab completion
|-- layouts/
|   |-- classic.sh          Single pane running opencode
|   |-- default.sh          Single pane running opencode (default)
|   |-- four-pane.sh        opencode + nvim + lazygit + yazi
|   |-- three-pane.sh       opencode + nvim + shell
|   \-- wide-twopane.sh     opencode (left) + nvim (right)
|-- man/
|   \-- coda.1              Man page (installed to /usr/local/share/man/man1/)
|-- scripts/
|   |-- streamdeck-vm104-connect.sh   Stream Deck helper
|   \-- tmux-pane-picker.sh           Pane picker utility
|-- tmux.conf               tmux configuration
|-- tui.json.example        OpenCode TUI keybind config
|-- .env.example            Configuration template
\-- .env                    Your local config (git-ignored)
```

---

## Design Notes

### KVM over LXC

OpenCode executes shell commands and arbitrary code on your behalf. LXC
containers share the host kernel — a misbehaving agent has a direct path to
your Proxmox host. KVM virtualizes at the hypervisor level. Use LXC for
stateless services (Ollama, proxies). Use KVM for anything that runs agent code.

### Bare repo + worktrees

A normal clone can only have one checked-out branch at a time. The bare repo
pattern keeps every worktree for a project inside one directory:

```
~/projects/myapp/
|-- .bare/          (all git objects — never touched directly)
|-- .git            (one-line pointer: "gitdir: ./.bare")
|-- main/           (worktree on main)
|-- auth/           (worktree on feature/auth)
\-- payments/       (worktree on feature/payments)
```

Each OpenCode agent sees exactly one branch with no cross-branch file pollution.

### mosh over SSH

mosh uses UDP. It survives WiFi drops, cellular handoffs, and laptop sleep.
The full resilience stack: **Tailscale** (stable IP) → **mosh** (UDP transport)
→ **tmux** (session persistence).

### ext4 over ZFS/Btrfs

Git worktrees generate heavy small-file metadata operations. Copy-on-write
filesystems add latency with no benefit — your snapshots are git branches.

### VM sizing

| Resource | Allocation | Notes |
|---|---|---|
| CPU | 8 vCPUs | ~2 per active instance + headroom |
| RAM | 24–32 GB | ~2–4 GB per instance + OS |
| Disk | 100–150 GB | OS (20 GB) + repos/worktrees |
| OS | Ubuntu 24.04 LTS | 5-year LTS, best Node.js tooling |

OpenCode instances are mostly idle (waiting on API responses). The primary
concern is memory — restart long-running instances every 4–6 hours to reclaim.
