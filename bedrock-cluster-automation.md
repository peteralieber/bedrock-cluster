# Bedrock Cluster Automation

This repository automates a pool of Minecraft Bedrock dedicated servers using LXC containers. The model is simple:

- One LXC template container, `bedrock-template`, holds the shared Bedrock server installation.
- Each playable server is an LXC container cloned from that template.
- `servers.txt` is the inventory of logical server names and their assigned IP addresses.
- `pool.txt` defines the candidate IP address pool.
- A Bedrock process runs inside each container in a tmux session named `mc`.
- MCS can treat the cluster as an externally managed process by calling the shell scripts in this repo.

The automation is intentionally lightweight. It does not provision a database, service discovery, or orchestration layer. State is kept in plain text files and under `/var/lib/lxc`.

## Architecture Overview

### Core Components

1. **Template container**
	 - Built by `build-template.sh`.
	 - Base image: Ubuntu Jammy (`ubuntu jammy amd64`).
	 - Installs `unzip`, `curl`, and `tmux`.
	 - Downloads the Bedrock dedicated server into `/opt/bedrock`.

2. **Per-server LXC containers**
	 - Created by cloning `bedrock-template`.
	 - Named after the requested server instance.
	 - Given a dedicated IP via LXC `macvlan` networking.
	 - Started with a tmux session named `mc` running `./bedrock_server` in `/opt/bedrock`.

3. **Inventory and IP allocation files**
	 - `pool.txt`: Source of assignable IPs. Supports literal IPs, ranges per octet, and `*` wildcards.
	 - `servers.txt`: Name-to-IP mapping for known servers.

4. **MCS integration**
	 - `create-server.sh` is designed to be usable as an MCS start command.
	 - `destroy-server.sh` is designed to be usable as an MCS stop command.
	 - The create script streams tmux output to stdout and then stays alive so an MCS-managed process can keep an attached log stream.
	 - The destroy script sends `stop` into the Bedrock console, waits for shutdown, and stops the container.

### Lifecycle Flow

#### Provision / Start

When `create-server.sh <name>` runs:

1. It checks `servers.txt` for an existing record.
2. If the server already exists:
	 - It verifies the LXC container exists.
	 - Starts the container if needed.
	 - Ensures the tmux session `mc` is alive and starts `./bedrock_server` if not.
	 - Pipes tmux output to stdout for log streaming.
3. If the server does not exist:
	 - It expands the IP pool from `pool.txt` via `expand_pool.py`.
	 - It selects the first IP that does not respond to `ping`.
	 - It clones `bedrock-template` into a new container.
	 - It appends network configuration to `/var/lib/lxc/<name>/config`.
	 - It starts the container.
	 - It launches Bedrock inside tmux.
	 - It appends `<name> <ip>` to `servers.txt`.
	 - It pipes tmux output to stdout and keeps the process alive.

#### Stop

When `destroy-server.sh <name>` runs:

1. It checks whether the named container exists.
2. If the container is running, it sends `stop` to the tmux session `mc`.
3. It waits up to roughly 20 seconds for `bedrock_server` to exit.
4. If the process does not exit cleanly, it kills the tmux session.
5. It stops the LXC container.
6. It leaves both the container and the `servers.txt` record in place.

This means the current destroy path is **non-destructive**. A later `create-server.sh <name>` call acts more like resume/restart than fresh provisioning.

### Interaction With MCS

This repo is built around the idea that MCS does not manage the Bedrock process directly inside the container. Instead, MCS manages these wrapper scripts:

- MCS starts a server by launching `create-server.sh <name>`.
- That script either provisions or resumes the LXC-backed Bedrock instance.
- It then attaches tmux pane output to stdout so MCS can collect logs from the wrapper process.
- MCS stops a server by launching `destroy-server.sh <name>`.

There is also a helper script, `mcs_register.py`, that upserts an instance definition through the MCS API using this repository's wrapper-based runtime model.

## Files and State

### `pool.txt`

Defines the available IP pool. Current contents include:

- `192.168.101.*`
- `192.168.1.50` through `192.168.1.54`

Supported pattern syntax is provided by `expand_pool.py`:

- Literal octet: `192.168.1.50`
- Range inside an octet: `192.168.1-10.5`
- Wildcard octet: `192.168.101.*`

### `servers.txt`

Flat inventory of provisioned servers.

Format:

```text
<server-name> <ipv4-address>
```

Current example:

```text
TestServer 192.168.101.1
```

This file is authoritative for the automation flow. `create-server.sh` uses it to decide whether a server is already provisioned.

## Script Reference

### `build-template.sh`

**Purpose**

Creates the base LXC template container named `bedrock-template` and installs a specific Bedrock server version into `/opt/bedrock`.

**Usage**

```bash
./build-template.sh
```

**Parameters**

- No command-line parameters.
- Internal variables:
	- `NAME="bedrock-template"`
	- `BEDROCK_VERSION="1.26.11.1"`

**Behavior**

- Creates an Ubuntu Jammy LXC container.
- Starts the container.
- Installs `unzip`, `curl`, and `tmux`.
- Downloads the Bedrock server zip from minecraft.net.
- Extracts it into `/opt/bedrock`.
- Marks `bedrock_server` as executable.
- Stops the container.

**Side Effects**

- Creates or overwrites the LXC container `bedrock-template` if run in an environment where that name is free.
- Downloads software from the public internet.
- Writes under `/var/lib/lxc/bedrock-template`.

**Assumptions / Requirements**

- LXC tooling is installed and usable by the current user.
- Outbound internet access is available.
- The hard-coded Bedrock version is still downloadable.

**Operational Notes**

- Upgrading Bedrock means editing `BEDROCK_VERSION` and rebuilding or otherwise refreshing the template.

### `create-server.sh`

**Purpose**

Provision a new Bedrock LXC server from the template or resume an existing one, then expose its logs to MCS by attaching to the tmux session.

**Usage**

```bash
./create-server.sh [-v] [-p /path/to/profile.server.properties] [-w /path/to/world.mcworld] <name>
```

**Parameters**

- `-v`: Enable verbose debug logging.
- `-p`: Optional path to a partial Bedrock `server.properties` profile.
- `-w`: Optional path to a `.mcworld` archive to import into the server.
- `<name>`: Logical server/container name.

**Behavior**

- Resolves `servers.txt` and `pool.txt` relative to the script directory.
- Loads optional host defaults from `bedrock.conf` (or `BEDROCK_CONFIG_FILE`).
- Supports configurable network values (`BEDROCK_NET_INTERFACE`, `BEDROCK_NET_PREFIX`, `BEDROCK_NET_GATEWAY`).
- Uses `allocate_ip.py` with strategy `BEDROCK_IP_ALLOCATION_METHOD` (`inventory-safe` default).
- Resolves default profile path as `properties.d/<name>.server.properties` if `-p` is not provided.
- If `<name>` already exists in `servers.txt`:
	- Ensures the container exists.
	- Starts it if stopped.
	- Applies partial `server.properties` profile if present.
	- Imports `.mcworld` archive if `-w` is provided.
	- Ensures the Bedrock tmux session `mc` is running.
	- Pipes tmux output to stdout.
	- Blocks forever with `tail -f /dev/null` so the wrapper process remains alive.
- If `<name>` does not exist in `servers.txt`:
	- Destroys any stale LXC container of the same name that is not tracked.
	- Expands candidate IPs from `pool.txt` and picks the first inventory-free address.
	- Clones `bedrock-template` to `<name>`.
	- Appends LXC networking config using configured `macvlan` defaults.
	- Starts the container.
	- Applies partial `server.properties` profile if present.
	- Imports `.mcworld` archive if `-w` is provided.
	- Starts Bedrock in tmux session `mc`.
	- Appends the server record to `servers.txt`.
	- Pipes tmux output to stdout and then blocks indefinitely.

**Side Effects**

- May destroy an untracked stale LXC container with the requested name.
- Creates a new container under `/var/lib/lxc/<name>`.
- Appends network config to `/var/lib/lxc/<name>/config`.
- Starts the LXC container.
- Starts a Bedrock process inside the container.
- Imports world data under `/var/lib/lxc/<name>/rootfs/opt/bedrock/worlds` when `-w` is provided.
- Appends `<name> <ip>` to `servers.txt` on first provision.
- Holds an active foreground process open for MCS log collection.

**Outputs**

- Human-readable status lines.
- Debug lines when `-v` is set.
- Bedrock console output via `tmux pipe-pane`.

**Assumptions / Requirements**

- `bedrock-template` already exists.
- `expand_pool.py` is executable.
- `pool.txt` contains at least one reachable-free IP candidate.
- Network defaults are set correctly for your host (via `bedrock.conf` or env overrides).
- `.mcworld` archive contains one world folder with `level.dat`.

**Important Notes**

- This script is both a provisioning action and a long-running runtime wrapper.
- It does not remove records from `servers.txt`.
- It does not reclaim IPs except implicitly by leaving or removing lines from `servers.txt` and reusing free IPs from ping detection.

### `destroy-server.sh`

**Purpose**

Gracefully stop a Bedrock server and then stop its LXC container without deleting the container or its inventory record.

**Usage**

```bash
./destroy-server.sh <container-name>
```

**Parameters**

- `<container-name>`: LXC container/server name.

**Behavior**

- Checks whether the container exists.
- If the container is running:
	- Attaches into the container.
	- Sends `stop` to tmux session `mc`.
	- Waits for `bedrock_server` to exit.
	- Kills the tmux session if the process does not exit within the loop.
	- Stops the LXC container.
- If the container is already stopped, it reports that state.
- If the container is missing, it reports that state.

**Side Effects**

- Stops the Bedrock process.
- Stops the LXC container.
- Leaves `/var/lib/lxc/<name>` in place.
- Leaves the `servers.txt` entry in place.

**Important Notes**

- This is not a destroy operation in the infrastructure sense. It is closer to `stop-server.sh`.
- Because state is preserved, the next start can reuse the same container and IP.

### `list-servers.sh`

**Purpose**

Pretty-print the current `servers.txt` inventory.

**Usage**

```bash
./list-servers.sh
```

**Parameters**

- No command-line parameters.

**Behavior**

- Prints a header.
- Runs `column -t servers.txt`.

**Side Effects**

- None beyond terminal output.

**Assumptions / Requirements**

- Must be run from the repository root, because it references `servers.txt` with a relative path.
- Requires the `column` utility.

### `update-servers.sh`

**Purpose**

Intended to stop all tracked containers, copy updated Bedrock files from the template into each server while preserving world and config data, and then restart all servers.

**Usage**

```bash
./update-servers.sh
```

**Parameters**

- No command-line parameters.

**Intended Behavior**

- Reads `servers.txt`.
- Stops every listed LXC container.
- Uses `rsync` from the template's `/opt/bedrock` into each server's `/opt/bedrock`.
- Excludes these items from overwrite/deletion:
	- `server.properties`
	- `whitelist.json`
	- `permissions.json`
	- `valid_known_packs.json`
	- `worlds`
- Restarts every listed container.

**Side Effects**

- Stops and restarts all tracked containers.
- Overwrites shared Bedrock binaries and content files from the template.
- Preserves selected config and world data.

**Important Notes**

- `update-servers.sh` now orchestrates per-server updates by calling `update-server.sh`.
- Use `--dry-run` to preview changes before applying them.
- Use `--verify` to assert that critical Bedrock binaries remain valid after sync.
- Use `--snapshot` to create a pre-update backup archive via `backup-server.sh`.

### `backup-server.sh`

**Purpose**

Create a compressed per-server backup archive of mutable Bedrock data.

**Usage**

```bash
./backup-server.sh <name>
```

**Behavior**

- Backs up mutable files from `/opt/bedrock` (including `server.properties` and `worlds`).
- Writes archives under `.backups/<name>/` (or `BEDROCK_BACKUP_ROOT`).

### `restore-server.sh`

**Purpose**

Restore mutable Bedrock data from a backup archive.

**Usage**

```bash
./restore-server.sh <name> [backup-file]
```

**Behavior**

- Uses the latest backup if no explicit archive is supplied.
- Stops running container before restore and starts it again afterward.

### `mcs_register.py`

**Purpose**

Python helper that upserts a wrapper-based MCS process instance.

**Usage**

```bash
./mcs_register.py --name <name> [--properties-file /path/to/profile.server.properties] [--property key=value ...]
```

**Parameters**

- `--name <name>`: Instance/server name to register in MCS.
- `--properties-file`: Optional profile file path passed to the start wrapper.
- `--property key=value`: Optional repeatable profile key/value updates.

**Behavior**

- Reads MCS connection values from env or flags via `mcs_register.py`.
- Upserts an MCS `process` instance using wrapper commands.
- Populates MCS action commands for key Bedrock settings (gamemode, difficulty, allow-cheats, allow-list).
- Adds a destructive `Terminate Server (Destroy Container)` action command that calls `terminate-server.sh --force <name>`.
- Refreshes per-server UI field schema JSON at `properties.d/<name>.ui.schema.json`.
- Supports local-only profile updates when called with `--property` and no MCS API credentials.
- Uses:
	- `startCommand: /home/peter/minecraft/bedrock-cluster/create-server.sh ...`
	- `stopCommand: /home/peter/minecraft/bedrock-cluster/destroy-server.sh ...`
	- `cwd: /home/peter/minecraft/bedrock-cluster`

### Bedrock Settings UI Assets

- `mcs_bedrock_actions.py`: source of truth for selectable Bedrock settings fields and generated MCS action commands.
- `mcs_bedrock_settings_card.html`: starter custom HTML card for text boxes/selectors that generate update commands.
- `properties.d/<name>.ui.schema.json`: per-server schema file emitted by registration for UI consumers.

**Side Effects**

- Creates or attempts to create an instance definition in MCS.
- Sends credentials and metadata over HTTP to the configured endpoint.

**Important Caveats**

- Requires MCS API credentials (`MCSM_PANEL_URL`, `MCSM_API_KEY`, `MCSM_DAEMON_ID`) unless supplied via flags.
- If credentials are omitted and `--property` is provided, `mcs_register.py` updates local profile/schema only and skips remote instance updates.
- Gameplay settings should be managed by partial `server.properties` profiles, not by changing LXC-level commands.

### `mcs_sync_ping.py`

**Purpose**

Synchronize MCS ping target IP for an instance name using `servers.txt` inventory.

**Usage**

```bash
./mcs_sync_ping.py --name <name> [--best-effort]
```

**Behavior**

- Looks up `<name>` in `servers.txt` and extracts the assigned IP.
- Finds matching MCS instance by nickname.
- Updates MCS `pingConfig` to `<ip>:19132`.
- In `--best-effort` mode, exits successfully when credentials or instance are missing.

**Recommended Positioning**

- Use this as a reference for the MCS API shape only.
- Prefer manual instance creation in MCS or update this script to call the wrapper scripts instead of raw LXC commands.

### `expand_pool.py`

**Purpose**

Expand IP patterns from `pool.txt` into a newline-delimited list of candidate IPv4 addresses.

**Usage**

```bash
./expand_pool.py <pool-file>
```

**Parameters**

- `<pool-file>`: Path to a file containing one IP pattern per line.

**Behavior**

- Ignores blank lines and comment lines beginning with `#`.
- Splits each IPv4 pattern into octets.
- Supports:
	- `*` -> `1..255`
	- `N-M` -> inclusive integer range
	- `N` -> single literal value
- Prints each expanded IP on stdout.

**Side Effects**

- None beyond stdout output.

**Assumptions / Requirements**

- Input lines are IPv4-like and contain exactly four octets.
- No validation is performed beyond octet count.

### `allocate_ip.py`

**Purpose**

Choose a free IP from `pool.txt` expansion with a selectable strategy.

**Usage**

```bash
./allocate_ip.py --pool-file ./pool.txt --servers-file ./servers.txt [--method inventory-safe|ping-probe]
```

**Behavior**

- Reads currently assigned IPs from `servers.txt`.
- Expands candidates via `expand_pool.py`.
- `inventory-safe` (default): first candidate not already assigned.
- `ping-probe`: first candidate not assigned and not reachable by ping.

## Operational Model

### Why tmux Is Used

The actual Bedrock daemon runs inside a tmux session named `mc` within the LXC container. This provides:

- A stable target for attaching and sending commands.
- A way for `destroy-server.sh` to issue a clean `stop`.
- A way for `create-server.sh` to stream console output using `tmux pipe-pane`.

### Why LXC Is Used

Each Bedrock server gets its own isolated root filesystem and process space while still being lighter weight than a full VM. The template-and-clone pattern keeps provisioning fast and consistent.

### Where Persistent Data Lives

- Container filesystem: `/var/lib/lxc/<name>/rootfs`
- Bedrock install inside container: `/opt/bedrock`
- Cluster inventory: `servers.txt`
- IP source pool: `pool.txt`

### Networking Model

New servers are configured with an appended LXC network stanza:

```ini
lxc.net.0.type = macvlan
lxc.net.0.macvlan.mode = bridge
lxc.net.0.link = ens7
lxc.net.0.flags = up
lxc.net.0.ipv4.address = <assigned-ip>/16
lxc.net.0.ipv4.gateway = 192.168.0.1
```

This means the host must have:

- A working `ens7` interface.
- Layer-2 access appropriate for macvlan.
- Routing/gateway behavior compatible with `192.168.0.1`.

## Adding This Service to MCS

The most reliable approach is to add each Bedrock instance to MCS as a `process` that calls these wrapper scripts, not as a process that calls LXC directly.

### Recommended MCS Model

For a server named `MyWorld`:

- **Start command**

```bash
/home/peter/minecraft/bedrock-cluster/create-server.sh MyWorld
```

- **Stop command**

```bash
/home/peter/minecraft/bedrock-cluster/destroy-server.sh MyWorld
```

- **Working directory**

```text
/home/peter/minecraft/bedrock-cluster
```

### Why This Is the Recommended Model

- `create-server.sh` can provision the container if it does not exist yet.
- `create-server.sh` can recover an existing tracked server.
- `destroy-server.sh` performs a cleaner stop than `lxc-stop` alone.
- The start wrapper exposes the Bedrock console stream to stdout, which is friendlier to a process-oriented control panel.

### Stop vs Terminate

- `destroy-server.sh <name>` is non-destructive and should be used as the MCS stop command.
- `terminate-server.sh --force <name>` is destructive and removes both the container and the `servers.txt` mapping.
- The terminate flow returns the assigned IP to the pool by removing the inventory mapping.

### Manual MCS Setup Guide

1. Ensure the host can run all LXC commands without interactive prompts from the account MCS uses.
2. Build the base template first:

	 ```bash
	 cd /home/peter/minecraft/bedrock-cluster
	 ./build-template.sh
	 ```

3. In MCS, create a new instance of type `process`.
4. Set the instance name to the Bedrock server name you want, for example `MyWorld`.
5. Set the start command to `/home/peter/minecraft/bedrock-cluster/create-server.sh MyWorld`.
6. Set the stop command to `/home/peter/minecraft/bedrock-cluster/destroy-server.sh MyWorld`.
7. Set the working directory to `/home/peter/minecraft/bedrock-cluster`.
8. If MCS supports log capture from stdout/stderr, use that rather than pointing to a static file.
9. Start the instance from MCS. On first boot it should clone the template, assign an IP, register itself in `servers.txt`, and then stream console output.
10. Verify the server appears in `servers.txt` and that the container exists under `/var/lib/lxc/<name>`.

### Using the API Registration Helper

If you want to automate registration through `mcs_register.py`, configure it first.

At minimum, provide:

- `MCSM_PANEL_URL`
- `MCSM_API_KEY`
- `MCSM_DAEMON_ID`

`mcs_register.py` already writes wrapper-based process commands:

- `startCommand` should call `create-server.sh <name>`
- `stopCommand` should call `destroy-server.sh <name>`
- `cwd` should be `/home/peter/minecraft/bedrock-cluster`

That keeps MCS aligned with the actual runtime contract implemented by this repository.

## Known Risks and Caveats

- `destroy-server.sh` does not remove containers or inventory entries.
- `create-server.sh` chooses a free IP by ping failure, which can produce false positives in some networks.
- `create-server.sh` hard-codes host networking details: `ens7`, `/16`, and gateway `192.168.0.1`.
- `list-servers.sh` and `update-servers.sh` assume they are run from the repo root.

## Safe Testing Without Touching Live Servers

You can run the non-destructive harness below to test provisioning/profile logic without changing live `servers.txt` entries or writing under `/var/lib/lxc`.

```bash
cd /home/peter/minecraft/bedrock-cluster
./safe-test.sh
```

What this harness does:

- Uses sandbox copies for `servers.txt` and `pool.txt`.
- Uses a sandbox LXC root directory under `.safe-test-sandbox/`.
- Mocks `lxc-*` and `ping` calls so no real containers are created/stopped.
- Verifies production `servers.txt` is unchanged after the run.

## Recommended Improvements

If this automation is going to remain in service, the most useful follow-up changes would be:

1. Rename `destroy-server.sh` or add a true destructive variant so lifecycle semantics are explicit.
2. Expand update verification (for example additional integrity checks and optional snapshot hooks).
3. Move host-specific networking settings into a config file.
4. Replace ping-based IP allocation with inventory-based or ARP-aware allocation.
5. Extend `mcs_register.py` for additional registration metadata as needed.
