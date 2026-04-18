#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
SERVERS_FILE="${BEDROCK_SERVERS_FILE:-$SCRIPT_DIR/servers.txt}"
UPDATER="$SCRIPT_DIR/update-server.sh"
DRY_RUN=0
VERIFY=0

usage() {
  echo "Usage: ./update-servers.sh [--dry-run] [--verify]"
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
    *)
      echo "Unknown option: $1"
      usage
      exit 1
      ;;
  esac
done

if [[ ! -f "$SERVERS_FILE" ]]; then
  echo "Servers file not found: $SERVERS_FILE"
  exit 1
fi

if [[ ! -x "$UPDATER" ]]; then
  echo "Updater not executable: $UPDATER"
  exit 1
fi

ARGS=()
[[ "$DRY_RUN" == "1" ]] && ARGS+=("--dry-run")
[[ "$VERIFY" == "1" ]] && ARGS+=("--verify")

echo "Starting batch update using $SERVERS_FILE"

while read -r line; do
  [[ -z "$line" || "$line" =~ ^# ]] && continue
  NAME="$(echo "$line" | awk '{print $1}')"
  [[ -z "$NAME" ]] && continue

  echo "---- Updating $NAME ----"
  "$UPDATER" "${ARGS[@]}" "$NAME"
done < "$SERVERS_FILE"

echo "Batch update complete"
