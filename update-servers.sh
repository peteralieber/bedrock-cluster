#!/bin/bash
set -e

TEMPLATE="bedrock-template"
SERVERS_FILE="servers.txt"

if [ ! -f "$SERVERS_FILE" ]; then
  echo "Servers file $SERVERS_FILE not found!"
  exit 1
fi

# Stop all servers
while read -r line; do
  NAME=$(echo "$line" | awk '{print $1}')
  echo "Stopping $NAME..."
  lxc-stop -n "$NAME" || true
  sleep 2

done < "$SERVERS_FILE"

# Copy updated files from template to each server, excluding config files
CONFIG_FILES=("server.properties" "whitelist.json" "permissions.json" "valid_known_packs.json" "worlds")

for line in $(cat "$SERVERS_FILE"); do
  NAME=$(echo "$line" | awk '{print $1}')
  echo "Updating files in $NAME..."

  # Rsync from template to server rootfs /opt/bedrock excluding config files and worlds directory
  rsync -av --delete 
    --exclude=${CONFIG_FILES[0]} 
    --exclude=${CONFIG_FILES[1]} 
    --exclude=${CONFIG_FILES[2]} 
    --exclude=${CONFIG_FILES[3]} 
    --exclude=${CONFIG_FILES[4]} 
    /var/lib/lxc/$TEMPLATE/rootfs/opt/bedrock/ /var/lib/lxc/$NAME/rootfs/opt/bedrock/

done

# Restart all servers
while read -r line; do
  NAME=$(echo "$line" | awk '{print $1}')
  echo "Starting $NAME..."
  lxc-start -n "$NAME"
  sleep 3
done < "$SERVERS_FILE"

echo "All servers updated and restarted."
