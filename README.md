# Remote Dev Server

A headless development server running multiple [OpenCode](https://opencode.ai) AI coding agents
in parallel across isolated git worktrees, accessible from anywhere via Tailscale + mosh.

## What this is

You provision a VM (on Proxmox, or any Ubuntu host), run `./install.sh`, and get:

- **Multiple parallel OpenCode sessions** — each in its own tmux window, each in its own git worktree, each on its own branch. No conflicts, no stepping on each other.
- **Access from anywhere** — Tailscale gives the VM a stable IP from any network. mosh survives WiFi drops, cellular handoffs, and laptop sleep. tmux sessions persist regardless of connection state.
- **Fire-and-forget mode** — `opencode serve` exposes an HTTP API. Submit tasks from scripts, cron jobs, or your phone, and check results when you're back.

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
|  |-- oc-myapp          (main branch)          |
|  |-- oc-myapp--auth    (feature/auth)         |
|  |-- oc-myapp--api     (feature/api)          |
|  \-- oc-other-proj     (main branch)          |
|                                               |
|  ~/projects/myapp/                            |
|  |-- .bare/            (all git objects)      |
|  |-- main/             (worktree)             |
|  |-- auth/             (worktree)             |
|  \-- api/              (worktree)             |
+----------------------------------------------+
```

---

## Installation

On a fresh Ubuntu Server 24.04 VM, clone this repo and run:

```bash
git clone <this-repo-url> ~/remote-dev-server
cd ~/remote-dev-server
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
| 4 | OpenCode via `npm install -g opencode@latest` |
| 5 | Claude Code CLI via `npm install -g @anthropic-ai/claude-code` |
| 6 | fzf (fuzzy finder, binary install) |
| 7 | tmux Plugin Manager (TPM) |
| 8 | Tailscale |
| 9 | Config files: `~/.tmux.conf`, `~/.config/opencode/tui.json`, shell RC source line, SSH keepalive, tmux plugins |

To skip optional components:

```bash
SKIP_TAILSCALE=true ./install.sh   # already have Tailscale
SKIP_OPENCODE=true  ./install.sh   # skip OpenCode install
SKIP_CLAUDE=true    ./install.sh   # skip Claude Code CLI install
```

### After install

```bash
# 1. Connect this VM to your Tailscale network
sudo tailscale up

# 2. Reload your shell to pick up the new functions
source ~/.bashrc

# 3. Sign in to Claude (one-time, OAuth flow)
claude auth login

# 4. Wire OpenCode to use the Claude credentials
oc-auth-setup

# 5. Start tmux
tmux
```

---

## Shell Commands

All commands are sourced from `shell-functions.sh` into your shell. They read
configuration from `.env` in the repo directory.

### `oc` — Create or attach to an OpenCode session

```
oc [name] [dir]
```

Creates a new tmux session running OpenCode, or attaches to an existing one.
Session names are prefixed with `SESSION_PREFIX` (default: `oc-`).

```bash
oc                        # use current directory name as session name
oc myapp                  # create/attach session "oc-myapp"
oc myapp ~/projects/myapp # session in a specific directory
```

- If already inside tmux, switches to the session instead of attaching.
- Enforces `MAX_CONCURRENT_SESSIONS` (default: 5). Lists running sessions if at the limit.
- After OpenCode exits, the shell stays open (no accidental session loss).

---

### `ocs` — List active OpenCode sessions

```
ocs
```

Lists all tmux sessions whose names match `SESSION_PREFIX`.

```bash
ocs
# Active OpenCode sessions:
#   oc-myapp (2 windows, created 1733500000)
#   oc-myapp--auth (1 windows, created 1733500100)
```

---

### `tm` — Fuzzy session switcher

```
tm
```

Opens an fzf picker with all tmux sessions. The right pane shows a live preview
of each session's last 30 lines of output.

- Select a session and press Enter to switch to it.
- Press Esc to cancel.

Also available as `prefix + f` inside tmux (popup version).

---

### `setup-project` — Clone a repo using the bare repository pattern

```
setup-project <repo-url> [project-name]
```

Clones a remote repository as a bare repo and creates the initial `main` worktree.
If the project already exists, fetches the latest and shows current worktrees.

```bash
setup-project git@github.com:user/myapp.git
# Creates:
#   ~/projects/myapp/.bare/     (all git objects)
#   ~/projects/myapp/.git       (pointer file to .bare)
#   ~/projects/myapp/main/      (worktree checked out on main)

setup-project https://github.com/user/myapp.git custom-name
# Same, but project directory is ~/projects/custom-name/
```

After setup, `cd` into the worktree to start working:

```bash
cd ~/projects/myapp/main
oc    # starts an OpenCode session here
```

---

### `feature` — Create a feature worktree and session

```
feature <branch-name> [base-branch] [project-name]
```

Creates a new git worktree on a new branch and immediately opens an OpenCode
tmux session inside it. Must be run from inside a project directory.

```bash
cd ~/projects/myapp/main

feature auth                     # new branch "auth" from main
feature auth develop             # new branch "auth" from develop
feature auth develop myapp       # explicit project name
```

If the worktree already exists, attaches to the existing session without
creating another.

Session name: `oc-<project>--<branch>` (e.g. `oc-myapp--auth`)
Worktree path: `~/projects/<project>/<branch>/`

---

### `done-feature` — Clean up after a feature is merged

```
done-feature <branch-name> [project-name]
```

Tears down a feature completely:
1. Kills the tmux session
2. Removes the git worktree
3. Deletes the local branch

```bash
cd ~/projects/myapp/main

done-feature auth
# Killing tmux session: oc-myapp--auth
# Removing worktree: ~/projects/myapp/auth
# Deleting local branch: auth
# Done.
```

> **Note:** This deletes the branch regardless of merge status. Merge or push
> your changes first.

---

### `list-features` — Show all worktrees for the current project

```
list-features
```

Runs `git worktree list` for the project root detected from the current directory.

```bash
cd ~/projects/myapp/auth

list-features
# Worktrees for myapp:
#   /home/user/projects/myapp/.bare  (bare)
#   /home/user/projects/myapp/main   abc1234 [main]
#   /home/user/projects/myapp/auth   def5678 [auth]
```

---

### `oc-serve` — Start OpenCode in headless server mode

```
oc-serve [port]
```

Starts `opencode serve` on the specified port (or auto-selects the next free
port in the configured range starting at `OPENCODE_BASE_PORT`).

Uses `OPENCODE_HEADLESS_PERMISSION` for the permission policy (default: full
autonomy — auto-approves everything).

```bash
oc-serve             # auto-selects port 4096 (or next free)
oc-serve 4100        # use a specific port

# Starting OpenCode server on port 4096
# Attach with: opencode attach http://localhost:4096
```

Once running, interact with it programmatically:

```bash
# Attach a TUI to watch it
opencode attach http://localhost:4096

# Submit a task asynchronously
curl -X POST http://localhost:4096/session/$SESSION_ID/prompt_async \
     -H 'Content-Type: application/json' \
     -d '{"parts":[{"type":"text","text":"Add error handling to all API routes"}]}'

# One-shot run with JSON output
opencode run --format json "Write tests for src/auth.ts"
```

---

### `oc-auth-setup` — Wire Claude Code auth to OpenCode

```
oc-auth-setup
```

One-time setup that installs the `opencode-claude-auth` plugin globally, which
lets OpenCode reuse the OAuth credentials that `claude auth login` writes to
`~/.claude/.credentials.json`.

```bash
claude auth login    # complete OAuth flow in browser
oc-auth-setup        # install plugin + verify

# Verify it works:
opencode models anthropic
opencode run --model anthropic/claude-sonnet-4-5 "Reply with: auth-ok"
```

If Claude auth expires, re-run `claude auth login` then `oc-auth-setup`.

---

## Daily Workflow

### Starting the day

SSH or mosh into the VM. If `AUTO_ATTACH_TMUX=true` (the default), you land
directly in tmux:

```bash
mosh user@100.x.x.x

# Already in tmux. Check what's running:
ocs

# Pick a session to review:
tm
```

### Starting work on a feature

```bash
cd ~/projects/myapp/main

# Create a worktree + session for the feature:
feature auth

# OpenCode opens automatically in ~/projects/myapp/auth/
# Give it a task:
#   "Implement JWT auth middleware with refresh token rotation"
```

### Running multiple features in parallel

Each `feature` call creates an isolated worktree on its own branch with its own
OpenCode agent. They can all run concurrently without conflicts.

```bash
feature auth          # session: oc-myapp--auth
feature payments      # session: oc-myapp--payments
feature docs          # session: oc-myapp--docs

# Switch between them:
tm
# Or with tmux directly:  prefix + f
```

### Dispatching tasks from your phone

```bash
# Send a message to a running agent without attaching:
tmux send-keys -t oc-myapp--auth "Add rate limiting to the login endpoint" Enter

# Check status without attaching (last 20 lines of output):
tmux capture-pane -t oc-myapp--auth -p | tail -20
```

### Cleaning up after a merge

```bash
# After merging the PR on GitHub:
cd ~/projects/myapp/main
git fetch --all

done-feature auth       # kills session, removes worktree, deletes branch
done-feature payments

# See what's left:
list-features
```

### Fire-and-forget / background work

Run a headless server for fully autonomous, unattended tasks:

```bash
# In a dedicated tmux window:
cd ~/projects/myapp/main
oc-serve

# Submit work and disconnect:
tmux send-keys -t oc-myapp--auth \
    'curl -X POST http://localhost:4096/session/$SESSION_ID/prompt_async \
     -d "{\"parts\":[{\"type\":\"text\",\"text\":\"Audit all dependencies and fix CVEs\"}]}"' \
    Enter
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
> `--advertise-routes` for your VM subnet. It can cause the host to route its
> own local traffic through the VPN tunnel, breaking cluster communication.

### mosh

mosh is installed by `install.sh`. Clients connect identically to SSH but with
UDP-based transport that survives interruptions:

```bash
mosh user@100.x.x.x      # Tailscale IP
```

mosh requires UDP port 60001 to be reachable. Tailscale handles this
automatically (no firewall rules needed for Tailscale peers).

### Mobile access

- **iOS/Android**: [Termius](https://termius.com) or [Blink Shell](https://blink.sh) over Tailscale
- Install the Tailscale app on the device first

---

## Configuration

All behaviour is controlled by `.env` in the repo directory. `install.sh`
creates it from `.env.example` on first run.

| Variable | Default | Description |
|---|---|---|
| `PROJECTS_DIR` | `~/projects` | Root directory for all repos |
| `SESSION_PREFIX` | `oc-` | Prefix for OpenCode tmux session names |
| `DEFAULT_BRANCH` | `main` | Default branch for new worktrees |
| `GIT_REMOTE` | `origin` | Git remote name |
| `EDITOR` / `VISUAL` | `vim` | Editor for OpenCode `/editor` flows |
| `OPENCODE_BASE_PORT` | `4096` | First port to try for `oc-serve` |
| `OPENCODE_PORT_RANGE` | `10` | How many ports to scan for an open one |
| `MAX_CONCURRENT_SESSIONS` | `5` | Cap on parallel OpenCode sessions |
| `OPENCODE_HEADLESS_PERMISSION` | `{"*":"allow"}` | Permission policy for `oc-serve` |
| `NODE_MAJOR_VERSION` | `20` | Node.js major version for install |
| `AUTO_ATTACH_TMUX` | `true` | Auto-attach to tmux on SSH login |
| `DEFAULT_TMUX_SESSION` | `default` | Session name for auto-attach |

---

## tmux Keybinds

The prefix key is the default `Ctrl+b`.

| Binding | Action |
|---|---|
| `prefix + \|` | Split pane vertically |
| `prefix + -` | Split pane horizontally |
| `prefix + h/j/k/l` | Navigate panes (vim-style) |
| `prefix + H/J/K/L` | Resize panes |
| `prefix + c` | New window (inherits current path) |
| `prefix + f` | fzf session switcher (popup) |
| `prefix + r` | Reload tmux config |
| `prefix + p` | Paste buffer |

**Copy mode** (`prefix + [`):

| Key | Action |
|---|---|
| `v` | Begin selection |
| `V` | Select whole line |
| `Ctrl+v` | Rectangle/block selection |
| `y` | Copy selection and exit |
| `/` | Search forward |
| `?` | Search backward |
| `q` | Quit copy mode |

Copies go to the system clipboard via OSC 52 (works with Ghostty and any
terminal that supports OSC 52). Hold `Shift` while selecting to bypass tmux and
use the terminal's native selection.

**Persistence:** tmux-continuum saves sessions every 15 minutes and restores
them automatically on reboot.

---

## File Structure

```
remote-dev-server/
|-- install.sh            # Full install: system packages through config wiring
|-- shell-functions.sh    # Shell functions (oc, feature, setup-project, etc.)
|-- tmux.conf             # tmux configuration (plugins, keybinds, status bar)
|-- tui.json.example      # OpenCode TUI keybind config
|-- .env.example          # Configuration template
\-- .env                  # Your local config (git-ignored)
```

---

## Design Notes

### KVM over LXC

OpenCode executes shell commands and arbitrary code on your behalf. LXC containers
share the host kernel — a misbehaving agent has a direct path to your Proxmox
host. KVM virtualizes at the hypervisor level, so an agent is trapped inside the
VM. Use LXC for stateless services (Ollama, reverse proxies). Use KVM for
anything that runs untrusted code.

### Bare repo + worktrees

A normal `git clone` can only have one checked-out branch at a time. Worktrees
let you check out multiple branches simultaneously, but the default layout puts
worktrees outside the project directory as siblings, making them easy to lose.

The bare repo pattern keeps everything in one directory:

```
~/projects/myapp/
|-- .bare/          (all git objects — never touched directly)
|-- .git            (one-line pointer: "gitdir: ./.bare")
|-- main/           (worktree on main branch)
|-- auth/           (worktree on feature/auth)
\-- payments/       (worktree on feature/payments)
```

Each worktree is a full checkout. Each OpenCode agent sees exactly one branch,
with no risk of cross-branch file pollution.

### mosh over SSH

mosh uses UDP. It survives WiFi drops, cellular handoffs, laptop sleep, and
high-latency links. It does local echo (keystrokes appear instantly even on
poor connections). SSH over unreliable connections hangs and drops sessions.
The full resilience stack: **Tailscale** (stable IP) → **mosh** (UDP transport)
→ **tmux** (session persistence).

### ext4 over ZFS/Btrfs

Git worktrees generate heavy small-file metadata operations. Copy-on-write
filesystems add latency for those operations with no benefit here — your
snapshots are git branches. ext4 is fast, stable, and zero-overhead for this
workload.

### VM sizing

For up to 5 concurrent sessions:

| Resource | Allocation | Notes |
|---|---|---|
| CPU | 8 vCPUs | ~2 per active instance + headroom |
| RAM | 24–32 GB | ~2–4 GB per instance + OS |
| Disk | 100–150 GB | OS (20 GB) + repos/worktrees |
| OS | Ubuntu 24.04 LTS | 5-year LTS, best Node.js tooling |

OpenCode instances are mostly idle (waiting on API responses). The primary
concern is memory — Node.js processes grow over long sessions. Restart
long-running instances every 4–6 hours to reclaim memory.
