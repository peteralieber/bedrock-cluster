#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
LXC_ROOT="${BEDROCK_LXC_ROOT:-/var/lib/lxc}"
BACKUP_ROOT="${BEDROCK_BACKUP_ROOT:-$SCRIPT_DIR/.backups}"

usage() {
  echo "Usage: ./restore-server.sh <server-name> [backup-file]"
}

NAME="${1:-}"
ARCHIVE="${2:-}"

if [[ -z "$NAME" ]]; then
  usage
  exit 1
fi

DST_DIR="$LXC_ROOT/$NAME/rootfs/opt/bedrock"
if [[ ! -d "$DST_DIR" ]]; then
  echo "Server bedrock directory not found: $DST_DIR"
  exit 1
fi

if [[ -z "$ARCHIVE" ]]; then
  latest="$(ls -1 "$BACKUP_ROOT/$NAME"/*.tgz 2>/dev/null | sort | tail -n1 || true)"
  if [[ -z "$latest" ]]; then
    echo "No backups found for $NAME in $BACKUP_ROOT/$NAME"
    exit 1
  fi
  ARCHIVE="$latest"
fi

if [[ ! -f "$ARCHIVE" ]]; then
  echo "Backup archive not found: $ARCHIVE"
  exit 1
fi

WAS_RUNNING=0
if lxc-info -n "$NAME" 2>/dev/null | grep -q 'RUNNING'; then
  WAS_RUNNING=1
fi

if [[ "$WAS_RUNNING" == "1" ]]; then
  echo "Stopping running server before restore: $NAME"
  lxc-stop -n "$NAME"
fi

echo "Restoring backup $ARCHIVE into $DST_DIR"
tar -C "$DST_DIR" -xzf "$ARCHIVE"

if [[ "$WAS_RUNNING" == "1" ]]; then
  echo "Restarting server after restore: $NAME"
  lxc-start -n "$NAME"
fi

echo "Restore complete for $NAME"
