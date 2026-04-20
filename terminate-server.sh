#!/bin/bash
set -euo pipefail

usage() {
  echo "Usage: terminate-server.sh --force <container-name>"
  exit 1
}

FORCE=0
NAME=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --force)
      FORCE=1
      shift
      ;;
    -h|--help)
      usage
      ;;
    *)
      if [[ -z "$NAME" ]]; then
        NAME="$1"
        shift
      else
        usage
      fi
      ;;
  esac
done

if [[ "$FORCE" != "1" || -z "$NAME" ]]; then
  usage
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
SERVERS_FILE="${BEDROCK_SERVERS_FILE:-$SCRIPT_DIR/servers.txt}"
LXC_ROOT="${BEDROCK_LXC_ROOT:-/var/lib/lxc}"

if [[ ! -f "$SERVERS_FILE" ]]; then
  echo "servers.txt not found: $SERVERS_FILE"
  exit 2
fi

existing_ip=""
if grep -Eq "^${NAME}[[:space:]]+" "$SERVERS_FILE"; then
  existing_ip="$(awk -v target="$NAME" '$1 == target { print $2; exit }' "$SERVERS_FILE")"
fi

echo "[MCSM] Terminating server $NAME"

if lxc-info -n "$NAME" >/dev/null 2>&1; then
  if lxc-info -n "$NAME" | grep -q 'RUNNING'; then
    echo "[MCSM] Sending graceful Bedrock stop in container $NAME"
    lxc-attach -n "$NAME" -- bash -lc "
      if tmux has-session -t mc 2>/dev/null; then
        tmux send-keys -t mc 'stop' C-m
        for i in {1..20}; do
          if ! pgrep -x bedrock_server >/dev/null 2>&1; then
            exit 0
          fi
          sleep 1
        done
        tmux kill-session -t mc || true
      fi
    " || true

    echo "[MCSM] Stopping container $NAME"
    lxc-stop -n "$NAME" || true
  fi

  echo "[MCSM] Destroying container $NAME"
  lxc-destroy -n "$NAME" || true
else
  echo "[MCSM] Container $NAME not found; continuing inventory cleanup"
fi

"$SCRIPT_DIR/manage_inventory.py" --servers-file "$SERVERS_FILE" remove --name "$NAME" >/dev/null

if [[ -n "$existing_ip" ]]; then
  echo "[MCSM] Removed inventory entry for $NAME ($existing_ip); IP returned to pool"
else
  echo "[MCSM] No inventory entry found for $NAME"
fi

echo "[MCSM] Terminate complete"
