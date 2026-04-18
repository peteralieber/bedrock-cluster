#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
LXC_ROOT="${BEDROCK_LXC_ROOT:-/var/lib/lxc}"
TEMPLATE="${BEDROCK_TEMPLATE_NAME:-bedrock-template}"
DRY_RUN=0
VERIFY=0

usage() {
  echo "Usage: ./update-server.sh [--dry-run] [--verify] <server-name>"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --verify)
      VERIFY=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -* )
      echo "Unknown option: $1"
      usage
      exit 1
      ;;
    *)
      break
      ;;
  esac
done

NAME="${1:-}"
if [[ -z "$NAME" ]]; then
  usage
  exit 1
fi

SRC_DIR="$LXC_ROOT/$TEMPLATE/rootfs/opt/bedrock"
DST_DIR="$LXC_ROOT/$NAME/rootfs/opt/bedrock"
DST_CONFIG="$LXC_ROOT/$NAME/config"

if [[ ! -d "$SRC_DIR" ]]; then
  echo "Template source directory not found: $SRC_DIR"
  exit 1
fi

if [[ ! -d "$DST_DIR" ]]; then
  echo "Target server directory not found: $DST_DIR"
  exit 1
fi

if [[ ! -f "$DST_CONFIG" ]]; then
  echo "Target server config not found: $DST_CONFIG"
  exit 1
fi

EXCLUDES=(
  "server.properties"
  "whitelist.json"
  "permissions.json"
  "valid_known_packs.json"
  "worlds"
)

RSYNC_ARGS=("-a" "--delete" "--checksum")
for item in "${EXCLUDES[@]}"; do
  RSYNC_ARGS+=("--exclude=$item")
done

if [[ "$DRY_RUN" == "1" ]]; then
  RSYNC_ARGS+=("--dry-run" "--itemize-changes")
fi

WAS_RUNNING=0
if lxc-info -n "$NAME" 2>/dev/null | grep -q 'RUNNING'; then
  WAS_RUNNING=1
fi

if [[ "$DRY_RUN" != "1" && "$WAS_RUNNING" == "1" ]]; then
  echo "Stopping running server: $NAME"
  lxc-stop -n "$NAME"
fi

echo "Syncing template files into $NAME"
rsync "${RSYNC_ARGS[@]}" "$SRC_DIR/" "$DST_DIR/"

if [[ "$VERIFY" == "1" && "$DRY_RUN" != "1" ]]; then
  if [[ ! -x "$DST_DIR/bedrock_server" ]]; then
    echo "Verification failed: $DST_DIR/bedrock_server is missing or not executable"
    exit 1
  fi
  echo "Verification passed for $NAME"
fi

if [[ "$DRY_RUN" != "1" && "$WAS_RUNNING" == "1" ]]; then
  echo "Restarting updated server: $NAME"
  lxc-start -n "$NAME"
fi

echo "Update complete for $NAME"
