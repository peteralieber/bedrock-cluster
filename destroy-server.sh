#!/bin/bash
set -e

NAME="$1"

if [ -z "$NAME" ]; then
  echo "Usage: destroy-server.sh <container-name>"
  exit 1
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
SERVERS_FILE="$SCRIPT_DIR/servers.txt"

echo "[MCSM] Stopping Bedrock server..."
if lxc-info -n "$NAME" >/dev/null 2>&1; then
  if lxc-info -n "$NAME" | grep -q 'RUNNING'; then
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

    echo "Stopping container $NAME..."
    lxc-stop -n "$NAME" || true
  else
    echo "Container $NAME is already stopped."
  fi
else
  echo "Container $NAME does not exist."
fi

echo "Container preserved. Entry preserved in $SERVERS_FILE."
echo "Done."
