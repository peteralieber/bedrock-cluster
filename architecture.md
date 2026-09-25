# Architecture

This document describes the design and component model of `bedrock-cluster`.

---

## Overview

`bedrock-cluster` runs a pool of Minecraft Bedrock dedicated servers on a single Linux host. Each server is an isolated LXC container cloned from a shared template. The system is intentionally thin: state lives in plain text files (`servers.txt`, `pool.txt`) and under the LXC-managed path `/var/lib/lxc`. There is no database, service registry, or orchestration daemon.

```
┌─────────────────────────────────────────────┐
│               Linux Host                    │
│                                             │
│  bedrock-cluster/                           │
│  ├── servers.txt  (inventory)               │
│  ├── pool.txt     (IP candidates)           │
│  ├── bedrock.conf (host defaults)           │
│  └── properties.d/<name>.server.properties  │
│                                             │
│  /var/lib/lxc/                              │
│  ├── bedrock-template/   (base image)       │
│  ├── MyWorld/            (live server)      │
│  └── SurvivalWorld/      (live server)      │
│       └── rootfs/opt/bedrock/               │
│            ├── bedrock_server               │
│            ├── server.properties            │
│            └── worlds/                      │
└─────────────────────────────────────────────┘
```

---

## Components

### 1. Template Container (`bedrock-template`)

Built once by `build-template.sh`. It is an Ubuntu Jammy LXC container with:

- `unzip`, `curl`, `tmux` installed
- Bedrock server downloaded and extracted at `/opt/bedrock`
- `bedrock_server` marked executable

This container is never started for gameplay. It acts as a frozen image that all server containers are cloned from, ensuring every new server starts with an identical, known-good Bedrock installation.

Upgrading Bedrock means editing `BEDROCK_VERSION` in `build-template.sh`, rebuilding the template, and running `update-servers.sh` to push the new binaries to all existing containers.

### 2. Per-Server LXC Containers

Each server is an `lxc-copy` clone of `bedrock-template`. After cloning, `create-server.sh` appends a network stanza to `/var/lib/lxc/<name>/config` and starts the container.

Inside each container, the Bedrock process runs in a `tmux` session named `mc`:

```
container rootfs
└── opt/bedrock/
    ├── bedrock_server   (binary from template)
    ├── server.properties
    ├── whitelist.json
    ├── permissions.json
    ├── valid_known_packs.json
    └── worlds/
        └── <level-name>/
```

The `tmux` session provides:
- A stable command target for sending `stop` to the Bedrock console
- An output pipe (`tmux pipe-pane`) for log streaming to stdout
- A clean way to detect whether Bedrock is actually running

### 3. State Files

| File | Role |
|---|---|
| `servers.txt` | Authoritative name→IP inventory of all provisioned servers |
| `pool.txt` | Set of IP addresses available for assignment to new servers |
| `bedrock.conf` | Optional host-level network defaults sourced by Bash scripts |
| `properties.d/<name>.server.properties` | Optional partial Bedrock settings profile per server |
| `/var/lib/lxc/<name>/config` | Effective LXC network configuration (written by provisioning) |

`servers.txt` and `pool.txt` are plain text and must never be silently reformatted. All writes to `servers.txt` go through `manage_inventory.py`, which uses file locking and atomic replace to prevent partial writes under concurrent operations.

### 4. IP Allocation

When provisioning a new server:

1. `expand_pool.py` reads `pool.txt` and expands range/wildcard patterns into a flat list of candidate IPs.
2. `allocate_ip.py` reads currently assigned IPs from `servers.txt` and returns the first candidate not already in use.

IP reclamation is implicit: removing a line from `servers.txt` (via `terminate-server.sh`) makes that IP available again on the next allocation.

### 5. MCS Integration Layer

[MCSManager (MCS)](https://mcsmanager.com/) manages the lifecycle of each server by calling the wrapper scripts as external process commands. MCS does not call LXC directly.

```
MCS Panel
 ├── "Start" → create-server.sh <name>
 │              ├── provisions or resumes the LXC container
 │              └── streams Bedrock console output to stdout (log capture)
 │                  (blocks until tmux session ends)
 │
 └── "Stop"  → destroy-server.sh <name>
                ├── sends 'stop' to Bedrock console
                └── stops the LXC container (preserves data)
```

`mcs_register.py` automates the creation of MCS process instances with pre-built action commands. `render_mcs_template.py` generates per-server instance JSON from `mcs_template_bedrock_process.json`.

---

## Lifecycle Flows

### Provision (first start)

```
create-server.sh MyWorld
        │
        ├─ Read servers.txt → not found
        ├─ Destroy stale LXC container if present but untracked
        ├─ allocate_ip.py → pick first IP not in servers.txt
        ├─ lxc-copy bedrock-template → MyWorld
        ├─ Append macvlan network config to /var/lib/lxc/MyWorld/config
        ├─ lxc-start MyWorld
        ├─ apply_server_properties.py (if profile exists)
        ├─ import_mcworld.py (if -w provided)
        ├─ tmux new -d -s mc './bedrock_server'   (inside container)
        ├─ manage_inventory.py add MyWorld <ip>
        ├─ mcs_sync_ping.py (best-effort)
        └─ tmux pipe-pane + tail -f /dev/null     (blocks for MCS log capture)
```

### Resume (subsequent starts)

```
create-server.sh MyWorld
        │
        ├─ Read servers.txt → found (MyWorld, 192.168.101.1)
        ├─ lxc-info → verify container exists
        ├─ lxc-start if STOPPED
        ├─ apply_server_properties.py (if profile exists)
        ├─ import_mcworld.py (if -w provided)
        ├─ ensure tmux session mc is alive and running bedrock_server
        ├─ mcs_sync_ping.py (best-effort)
        └─ tmux pipe-pane + tail -f /dev/null     (blocks for MCS log capture)
```

### Stop (non-destructive)

```
destroy-server.sh MyWorld
        │
        ├─ lxc-info → container exists and RUNNING
        ├─ lxc-attach → tmux send-keys 'stop' (graceful Bedrock shutdown)
        ├─ Poll pgrep bedrock_server for up to 20 s
        ├─ tmux kill-session if still alive
        └─ lxc-stop MyWorld
           (container and servers.txt entry preserved)
```

### Terminate (destructive)

```
terminate-server.sh --force MyWorld
        │
        ├─ Graceful stop sequence (same as destroy-server.sh)
        ├─ lxc-destroy MyWorld
        └─ manage_inventory.py remove MyWorld
           (container deleted, IP returned to pool)
```

### Update (binary sync)

```
update-server.sh [--snapshot] [--dry-run] [--verify] MyWorld
        │
        ├─ Stop container if running
        ├─ backup-server.sh MyWorld  (if --snapshot)
        ├─ rsync bedrock-template:/opt/bedrock/ → MyWorld:/opt/bedrock/
        │   (excludes: server.properties, whitelist.json, permissions.json,
        │              valid_known_packs.json, worlds/)
        ├─ Verify bedrock_server checksum  (if --verify)
        └─ Restart container  (if it was running)
```

---

## Networking Model

Each server container uses `macvlan` in bridge mode, giving it a dedicated IP directly on the host's LAN. The network stanza appended to `/var/lib/lxc/<name>/config` at provisioning time:

```ini
lxc.net.0.type = macvlan
lxc.net.0.macvlan.mode = bridge
lxc.net.0.link = ens7
lxc.net.0.flags = up
lxc.net.0.ipv4.address = 192.168.101.1/16
lxc.net.0.ipv4.gateway = 192.168.0.1
```

All servers listen on UDP port `19132` (the standard Bedrock port) at their assigned IP. Players connect directly to the server IP, not through the host.

Host requirements:
- The `ens7` interface must support macvlan
- The gateway and subnet must match your LAN topology
- These defaults are configurable via `bedrock.conf` or environment variables

---

## Python / Bash Split

The codebase is deliberately split between two languages based on the nature of the work:

| Language | Used for |
|---|---|
| Bash | LXC commands, tmux session management, process lifecycle, rsync, curl |
| Python | File parsing, IP allocation logic, inventory updates, MCS API calls, validation |

The preferred pattern is: Python handles state decisions safely, Bash handles runtime operations. For example, `create-server.sh` delegates IP selection to `allocate_ip.py` and inventory writes to `manage_inventory.py`, while it handles all LXC and tmux operations directly.

### Python helpers

| Script | Responsibility |
|---|---|
| `expand_pool.py` | Expand `pool.txt` patterns → flat IP list |
| `allocate_ip.py` | Select first unassigned IP from expanded pool |
| `manage_inventory.py` | Atomic add/remove in `servers.txt` with file locking |
| `apply_server_properties.py` | Merge partial properties profile into container's `server.properties` |
| `import_mcworld.py` | Validate and unpack `.mcworld` archive into container world directory |
| `mcs_register.py` | Upsert MCS instance; manage per-server profile/schema files |
| `mcs_sync_ping.py` | Update MCS ping target IP from `servers.txt` |
| `render_mcs_template.py` | Render `mcs_template_bedrock_process.json` placeholders for a named server |
| `mcs_bedrock_actions.py` | Source of truth for selectable Bedrock settings and MCS action command list |

---

## Data Persistence

Servers are persistent by design. The `destroy-server.sh` (MCS stop) flow deliberately leaves everything intact:

- Container filesystem remains under `/var/lib/lxc/<name>`
- `servers.txt` entry is not removed
- World data, player data, and config are untouched

Only `terminate-server.sh --force` performs a destructive removal. This means:

- Crashes or unexpected stops do not cause data loss
- The next `create-server.sh` call always resumes the same container state
- Backups are separate from the lifecycle, not triggered by stop/start

Mutable data that is preserved across updates:
- `worlds/` (player worlds)
- `server.properties`
- `whitelist.json`
- `permissions.json`
- `valid_known_packs.json`

---

## Design Rationale

**Why LXC instead of Docker?**
LXC containers give each server its own network identity (dedicated IP) and process space without the overhead of a full VM. The template-and-clone provisioning model keeps new server creation fast and consistent. LXC's filesystem layout also makes it straightforward to manipulate server files from the host (e.g., for backup and update operations).

**Why tmux inside the container?**
Bedrock's dedicated server requires an interactive terminal. `tmux` provides a persistent session that survives SSH disconnects, can receive commands (`send-keys`), and can stream output (`pipe-pane`). This lets `destroy-server.sh` issue a clean `stop` command and lets `create-server.sh` expose console output to an MCS log capture stream.

**Why plain text state files?**
Plain text files (`servers.txt`, `pool.txt`) are transparent, easy to inspect, and safe to edit manually when needed. They require no database infrastructure and work naturally with version control. The risk of concurrent writes is managed by `manage_inventory.py`'s file locking rather than a database transaction.

**Why wrapper scripts instead of direct LXC commands in MCS?**
MCS needs a long-running foreground process to collect logs and track server state. `create-server.sh` fulfills this by blocking on `tail -f /dev/null` after piping the tmux session. This model also lets the start script handle provisioning, profile application, and world import transparently — MCS simply calls one command.
