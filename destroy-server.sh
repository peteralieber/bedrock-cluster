#!/bin/bash
NAME=$1

if [ -z "$NAME" ]; then
  echo "Usage: destroy-server.sh <container-name>"
  exit 1
fi

IP=$(grep $NAME servers.txt | awk '{print $2}')

echo "[MCSM] Stopping Bedrock server..."
lxc-attach -n "$NAME" -- tmux kill-session -t mc || true

echo "Stopping $NAME..."
lxc-stop -n "$NAME"

echo "Destroying container..."
lxc-destroy -n "$NAME"

echo "Releasing IP $IP..."
sed -i "/$NAME/d" servers.txt

echo "Done."
