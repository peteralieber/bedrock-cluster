#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
LXC_ROOT="${BEDROCK_LXC_ROOT:-/var/lib/lxc}"
BACKUP_ROOT="${BEDROCK_BACKUP_ROOT:-$SCRIPT_DIR/.backups}"

usage() {
  echo "Usage: ./backup-server.sh <server-name>"
}

NAME="${1:-}"
if [[ -z "$NAME" ]]; then
  usage
  exit 1
fi

SRC_DIR="$LXC_ROOT/$NAME/rootfs/opt/bedrock"
if [[ ! -d "$SRC_DIR" ]]; then
  echo "Server bedrock directory not found: $SRC_DIR"
  exit 1
fi

mkdir -p "$BACKUP_ROOT/$NAME"
STAMP="$(date +%Y%m%d-%H%M%S)"
ARCHIVE="$BACKUP_ROOT/$NAME/$STAMP.tgz"

# Backup only mutable server data and key config files.
tar -C "$SRC_DIR" -czf "$ARCHIVE" \
  server.properties \
  whitelist.json \
  permissions.json \
  valid_known_packs.json \
  worlds \
  2>/dev/null || true

if [[ ! -s "$ARCHIVE" ]]; then
  echo "Backup failed: archive is empty ($ARCHIVE)"
  exit 1
fi

echo "$ARCHIVE"
