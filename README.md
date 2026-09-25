# bedrock-cluster

A lightweight automation toolkit for running a pool of Minecraft Bedrock dedicated servers on a single Linux host using LXC containers.

Each server is an isolated LXC container cloned from a shared template. Servers run the Bedrock dedicated server binary inside a `tmux` session, which keeps them manageable without a full process supervisor. The scripts are designed to be called directly or wired into [MCS (MCSManager)](https://mcsmanager.com/) as wrapper process commands.

See [`architecture.md`](architecture.md) for a detailed breakdown of how the components fit together.

---

## Table of Contents

- [Requirements](#requirements)
- [Quick Start](#quick-start)
- [Configuration](#configuration)
  - [bedrock.conf](#bedrockconf)
  - [pool.txt](#pooltxt)
  - [servers.txt](#serverstxt)
  - [properties.d/](#propertiesd)
- [Script Reference](#script-reference)
- [MCS Integration](#mcs-integration)
- [Backup and Restore](#backup-and-restore)
- [Updating Servers](#updating-servers)
- [Health Checks](#health-checks)
- [Safe Testing](#safe-testing)

---

## Requirements

- Linux host with LXC tools installed (`lxc-create`, `lxc-start`, `lxc-attach`, etc.)
- `tmux` available on the host (also installed inside each container by the template)
- `rsync` (used by `update-server.sh`)
- Python 3.8+ (no third-party packages required)
- Outbound internet access for the initial Bedrock download during template build
- A network interface configured for `macvlan` bridging (default: `ens7`)

---

## Quick Start

### 1. Build the base template

```bash
./build-template.sh
```

This creates an LXC container named `bedrock-template` containing a clean Bedrock server installation at `/opt/bedrock`.

### 2. Configure networking

Copy or edit `bedrock.conf` to match your host network:

```bash
BEDROCK_NET_INTERFACE="ens7"   # macvlan parent interface
BEDROCK_NET_PREFIX="16"        # subnet prefix length
BEDROCK_NET_GATEWAY="192.168.0.1"
```

Add IP addresses your servers can use to `pool.txt` (supports ranges and wildcards):

```text
192.168.101.*
192.168.1.50
192.168.1.51
```

### 3. Provision a server

```bash
./create-server.sh MyWorld
```

On first run this clones the template, assigns a free IP from `pool.txt`, starts the container, launches Bedrock inside `tmux`, and records the name/IP pair in `servers.txt`. It then streams Bedrock console output to stdout and blocks (suitable for use as an MCS start command).

### 4. Stop a server

```bash
./destroy-server.sh MyWorld
```

Sends a graceful `stop` to the Bedrock console, waits for the process to exit, and stops the LXC container. The container and `servers.txt` entry are preserved so the next `create-server.sh MyWorld` resumes rather than reprovisioning.

### 5. List servers

```bash
./list-servers.sh
```

---

## Configuration

### bedrock.conf

Optional host-level defaults sourced by the Bash scripts. Environment variables override these values.

| Variable | Default | Description |
|---|---|---|
| `BEDROCK_NET_INTERFACE` | `ens7` | macvlan parent network interface |
| `BEDROCK_NET_PREFIX` | `16` | Subnet prefix length |
| `BEDROCK_NET_GATEWAY` | `192.168.0.1` | Default gateway for container networking |

Override at runtime with environment variables or by editing `bedrock.conf`. The config file path can also be overridden with `BEDROCK_CONFIG_FILE`.

### pool.txt

Defines the set of IP addresses available to new servers. One pattern per line. Blank lines and `#` comments are ignored.

Supported syntax (handled by `expand_pool.py`):

| Pattern | Example | Expands to |
|---|---|---|
| Literal IP | `192.168.1.50` | `192.168.1.50` |
| Octet range | `192.168.1-3.5` | `.1.5`, `.2.5`, `.3.5` |
| Wildcard octet | `192.168.101.*` | `192.168.101.1` – `192.168.101.255` |

### servers.txt

Authoritative inventory of provisioned servers. Format: `<name> <ipv4>` one entry per line.

```text
MyWorld  192.168.101.1
SurvivalWorld  192.168.101.2
```

`create-server.sh` consults this file to decide whether a server needs to be provisioned or just resumed. `terminate-server.sh` removes entries from this file. **Do not edit the format** — see `manage_inventory.py` for safe atomic updates.

### properties.d/

Optional partial `server.properties` profiles per server. Place a file named `<name>.server.properties` here and `create-server.sh` will apply it automatically on start.

Only keys present in the profile are written; all other keys in the running `server.properties` remain unchanged.

Example (`properties.d/MyWorld.server.properties`):

```ini
server-name=My Bedrock Server
gamemode=survival
difficulty=normal
allow-cheats=false
max-players=10
```

---

## Script Reference

| Script | Purpose |
|---|---|
| `build-template.sh` | Create the `bedrock-template` LXC container with a specific Bedrock version |
| `create-server.sh` | Provision or resume a server; streams logs and blocks (MCS start command) |
| `destroy-server.sh` | Gracefully stop a server and its container (MCS stop command; non-destructive) |
| `terminate-server.sh` | Destructively remove a server's container and `servers.txt` entry |
| `list-servers.sh` | Pretty-print current `servers.txt` |
| `health-check.sh` | Report container and Bedrock session state for all tracked servers |
| `update-server.sh` | Sync one server's Bedrock binaries from the template |
| `update-servers.sh` | Batch `update-server.sh` across all tracked servers |
| `backup-server.sh` | Create a timestamped archive of a server's mutable data |
| `restore-server.sh` | Restore a server from a backup archive |
| `expand_pool.py` | Expand `pool.txt` patterns into concrete IP list |
| `allocate_ip.py` | Pick the first unassigned IP from the expanded pool |
| `manage_inventory.py` | Atomically add/remove entries in `servers.txt` |
| `apply_server_properties.py` | Merge a partial properties profile into a running server |
| `import_mcworld.py` | Import a `.mcworld` archive into a container's world directory |
| `mcs_register.py` | Upsert an MCS process instance and manage per-server profiles |
| `mcs_sync_ping.py` | Sync MCS ping target IP from `servers.txt` |
| `render_mcs_template.py` | Render a per-instance MCS JSON from the baseline template |

### create-server.sh options

```
./create-server.sh [-v] [-p profile.server.properties] [-w world.mcworld] <name>
```

| Flag | Description |
|---|---|
| `-v` | Verbose debug output |
| `-p <file>` | Apply a specific properties profile (overrides `properties.d/<name>`) |
| `-w <file>` | Import a `.mcworld` archive into the server on start |

### update-server.sh options

```
./update-server.sh [--dry-run] [--verify] [--snapshot] <name>
```

| Flag | Description |
|---|---|
| `--dry-run` | Preview rsync changes without applying them |
| `--verify` | After sync, assert that the Bedrock binary is present and its checksum matches the template |
| `--snapshot` | Create a backup archive before updating |

---

## MCS Integration

This repo is built to work as an external process wrapper for [MCSManager](https://mcsmanager.com/). MCS manages the wrapper scripts; the wrapper scripts manage the LXC containers and Bedrock processes.

**For a server named `MyWorld`:**

| MCS field | Value |
|---|---|
| Start command | `/path/to/bedrock-cluster/create-server.sh MyWorld` |
| Stop command | `/path/to/bedrock-cluster/destroy-server.sh MyWorld` |
| Working directory | `/path/to/bedrock-cluster` |

`create-server.sh` provisions the container on first run and resumes it on subsequent runs. It streams Bedrock console output to stdout so MCS can capture it as process logs. The script blocks indefinitely until the tmux session ends.

### Automated registration

```bash
export MCSM_PANEL_URL=http://localhost:23333
export MCSM_API_KEY=your-api-key
export MCSM_DAEMON_ID=your-daemon-id

./mcs_register.py --name MyWorld
```

This upserts an MCS instance for `MyWorld` with pre-built action commands for gamemode, difficulty, and server termination.

To render a standalone instance JSON without calling the API:

```bash
./render_mcs_template.py --name MyWorld
```

---

## Backup and Restore

Create a backup of a server's mutable data (worlds, `server.properties`, whitelists):

```bash
./backup-server.sh MyWorld
# → .backups/MyWorld/20250101-120000.tgz
```

Restore from the latest backup:

```bash
./restore-server.sh MyWorld
```

Restore from a specific archive:

```bash
./restore-server.sh MyWorld .backups/MyWorld/20250101-120000.tgz
```

---

## Updating Servers

To update the Bedrock binary across all servers from the template:

```bash
# Preview changes first
./update-servers.sh --dry-run

# Apply update (stops and restarts containers)
./update-servers.sh

# Update with snapshot backup and binary verification
./update-servers.sh --snapshot --verify
```

The update preserves `server.properties`, `whitelist.json`, `permissions.json`, `valid_known_packs.json`, and the `worlds` directory on each server.

---

## Health Checks

```bash
# Check all tracked servers
./health-check.sh

# Check a specific server
./health-check.sh --name MyWorld
```

Output columns: `NAME`, `IP`, `CONTAINER` (RUNNING/STOPPED/MISSING), `BEDROCK` (RUNNING/DOWN/N/A).

Exits with a non-zero code if any server has an issue.

---

## Safe Testing

A test harness runs provisioning and profile logic against isolated temporary directories without touching live `servers.txt` entries or `/var/lib/lxc`:

```bash
./safe-test.sh
```
