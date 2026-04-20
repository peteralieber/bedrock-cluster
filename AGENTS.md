# AGENTS.md

## Purpose
This file describes how coding agents should understand, maintain, and extend this repository.

The current operating model is:
- Python scripts for file operations, parsing, and high-level orchestration logic.
- Bash scripts for container and process management (LXC, tmux, ping probes, rsync, curl calls).

When adding new functionality, keep this split unless there is a strong reason not to.

## Project Overview
This repository manages a pool of Minecraft Bedrock server containers.

Core behavior:
- `bedrock-template` is the base LXC template container.
- Each game server is an LXC clone from that template.
- `servers.txt` maps server name to assigned IP.
- `pool.txt` defines candidate IP addresses and ranges.
- Bedrock runs inside each container in tmux session `mc`.
- Wrapper scripts are intended for MCS-managed lifecycle operations.

## Source Of Truth Files
- `servers.txt`: authoritative server inventory (`<name> <ip>`).
- `pool.txt`: IP allocation candidates.
- `properties.d/<name>.server.properties`: optional partial Bedrock settings profile per server.
- `bedrock.conf`: optional host-specific defaults (network interface/prefix/gateway, allocation strategy).
- `/var/lib/lxc/<name>/config`: effective container network config (host-side LXC state).

Agent rule:
- Never silently change formats of `servers.txt` or `pool.txt`.
- If format evolution is required, add migration logic and update this file.

## Current Script Responsibilities
- `build-template.sh`: builds and seeds the template container.
- `create-server.sh`: provision-or-resume wrapper, optional profile application, then log stream attachment.
- `destroy-server.sh`: graceful stop, non-destructive container shutdown.
- `terminate-server.sh`: destructive termination that removes container and inventory mapping.
- `expand_pool.py`: expands wildcard/range pool entries into concrete IPs.
- `allocate_ip.py`: allocates free IPs from pool expansion using inventory-safe or ping-probe strategy.
- `manage_inventory.py`: performs atomic add/remove updates for `servers.txt` mappings.
- `apply_server_properties.py`: validates and applies partial `server.properties` profiles.
- `import_mcworld.py`: validates and imports `.mcworld` archives into container Bedrock world paths.
- `mcs_register.py`: upserts MCS instance config to wrapper-based commands.
- `mcs_sync_ping.py`: updates MCS instance pingConfig IP from `servers.txt` inventory mappings.
- `backup-server.sh`: creates per-server backups of mutable Bedrock data.
- `restore-server.sh`: restores per-server backups created by `backup-server.sh`.
- `update-server.sh`: per-server template sync with dry-run and verify modes.
- `update-servers.sh`: batch wrapper over `update-server.sh` for all tracked servers.
- `health-check.sh`: reports container and Bedrock session status for tracked servers.

## Implementation Policy (Python vs Bash)
Use Bash when work is primarily:
- Calling `lxc-*` tools.
- Attaching to containers and tmux sessions.
- Launching/stopping long-running processes.
- Running direct host/network shell commands.

Use Python when work is primarily:
- Reading/writing structured text files (`servers.txt`, `pool.txt`, future metadata files).
- Validation, transformations, planning, and decision logic.
- Diff-safe or idempotent file updates.
- Any logic likely to become complex enough to be fragile in shell.

Preferred hybrid pattern:
1. Python script computes or updates state safely.
2. Bash script applies runtime/container operations.

## Editing Guidelines For Agents
1. Preserve non-destructive lifecycle behavior unless explicitly asked to change it.
2. Keep `create-server.sh` and `destroy-server.sh` semantics aligned with MCS wrapper flow.
3. Preserve tmux session name `mc` unless all references are updated together.
4. Keep paths script-relative when reading repository files.
5. Avoid introducing hidden state outside repository files and LXC-managed paths.
6. Add clear usage/help text when changing script interfaces.
7. Favor idempotent operations and explicit error messages over implicit fallback behavior.

## Adding New Features
For new feature work, follow this sequence:
1. Identify if the task is state logic (Python) or runtime control (Bash).
2. Update or add Python helpers for file/state handling first.
3. Wire Bash entrypoints to call those helpers where needed.
4. Validate behavior for both existing-server and new-server paths.
5. Ensure failures are safe (no half-written `servers.txt`, no orphaned config writes).
6. Update `bedrock-cluster-automation.md` when behavior changes.

## Safety Checks Before Merging
- New scripts include `set -e` (Bash) or explicit non-zero exits (Python).
- Input arguments are validated with clear usage text.
- `servers.txt` edits are atomic or guarded against partial writes.
- Existing tracked servers continue to start/stop correctly.
- No destructive cleanup is introduced by default in stop/destroy flow.

## Known Gaps
- None currently tracked.

## Maintenance Note
If project direction changes (for example, moving more lifecycle orchestration into Python), update this file first so future coding agents stay aligned.
