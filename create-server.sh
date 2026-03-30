#!/bin/bash
set -e

VERBOSE=0

while getopts ":v" opt; do
  case "$opt" in
    v)
      VERBOSE=1
      ;;
    *)
      echo "Usage: create.sh [-v] <name>"
      exit 1
      ;;
  esac
done

shift $((OPTIND - 1))
NAME="$1"

if [ -z "$NAME" ]; then
  echo "Usage: create.sh [-v] <name>"
  exit 1
fi

vlog() {
  if [ "$VERBOSE" -eq 1 ]; then
    echo "[DEBUG] $*"
  fi
}

vlog "Requested server name: $NAME"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
SERVERS_FILE="$SCRIPT_DIR/servers.txt"
vlog "Script directory resolved to: $SCRIPT_DIR"
vlog "Using servers file: $SERVERS_FILE"

# Check if server already exists
EXISTING_NAME=""
EXISTING_IP=""
vlog "Checking if server already exists"
while read -r line; do
  name=$(echo "$line" | awk '{print $1}')
  ip=$(echo "$line" | awk '{print $2}')
  vlog "Inspecting existing entry: name=$name ip=$ip"
  if [ "$name" == "$NAME" ]; then
    EXISTING_NAME="$name"
    EXISTING_IP="$ip"
    vlog "Found existing server match: $EXISTING_NAME ($EXISTING_IP)"
    break
  fi
done < "$SERVERS_FILE"

if [ -n "$EXISTING_NAME" ]; then
  echo "Server $EXISTING_NAME already exists with IP $EXISTING_IP. Ensuring it is running..."
  vlog "Checking LXC state for $EXISTING_NAME"
  lxc-info -n "$EXISTING_NAME" | grep -q 'RUNNING' || lxc-start -n "$EXISTING_NAME"
  echo "Server $EXISTING_NAME is running."

  echo "[MCSM] Attaching to tmux session for log streaming..."
  # This NEVER exits until the tmux session ends
  lxc-attach -n "$NAME" -- tmux pipe-pane -t mc -o 'cat'
  tail -f /dev/null
fi

vlog "No matching entry found in servers.txt for $NAME"
if lxc-info -n "$NAME" >/dev/null 2>&1; then
  echo "Container $NAME exists but is missing from servers.txt. Destroying stale container..."
  vlog "Checking if stale container $NAME is running"
  if lxc-info -n "$NAME" | grep -q 'RUNNING'; then
    vlog "Stopping running stale container $NAME"
    lxc-stop -n "$NAME"
  fi
  vlog "Destroying stale container $NAME"
  lxc-destroy -n "$NAME"
  echo "Stale container $NAME destroyed."
fi

POOL_FILE="$SCRIPT_DIR/pool.txt"
TEMPLATE="bedrock-template"
vlog "Using pool file: $POOL_FILE"
vlog "Using template container: $TEMPLATE"

# Expand pool using Python helper
vlog "Expanding IP pool"
IP_POOL=($($SCRIPT_DIR/expand_pool.py "$POOL_FILE"))
vlog "Expanded IP pool size: ${#IP_POOL[@]}"

FREE_IP=""
vlog "Searching for a free IP by ping probe"
for ip in "${IP_POOL[@]}"; do
  vlog "Probing IP: $ip"
  if ! ping -c1 -W1 "$ip" >/dev/null 2>&1; then
    FREE_IP="$ip"
    vlog "Selected free IP: $FREE_IP"
    break
  fi
done

if [ -z "$FREE_IP" ]; then
  vlog "No available free IP found after probing pool"
  echo "No free IPs available"
  exit 1
fi

echo "Creating LXC container $NAME with IP $FREE_IP"
vlog "Copying template $TEMPLATE into new container $NAME"

lxc-copy -n "$TEMPLATE" -N "$NAME"

vlog "Appending network configuration to /var/lib/lxc/$NAME/config"
cat <<EOF >> /var/lib/lxc/$NAME/config
lxc.net.0.type = macvlan
lxc.net.0.macvlan.mode = bridge
lxc.net.0.link = ens7
lxc.net.0.flags = up
lxc.net.0.ipv4.address = $FREE_IP/16
lxc.net.0.ipv4.gateway = 192.168.0.1
EOF

vlog "Starting container $NAME"
lxc-start -n "$NAME"
vlog "Waiting for container boot"
sleep 3

vlog "Launching Bedrock server in tmux session inside container"
lxc-attach -n "$NAME" -- bash -c "
  cd /opt/bedrock &&
  tmux new -d -s mc './bedrock_server'
"

vlog "Recording server mapping in $SCRIPT_DIR/servers.txt"
echo "$NAME $FREE_IP" >> $SCRIPT_DIR/servers.txt
vlog "Provisioning complete for $NAME"
echo "Server $NAME running at $FREE_IP:19132"

echo "[MCSM] Attaching to tmux session for log streaming..."
# This NEVER exits until the tmux session ends
lxc-attach -n "$NAME" -- tmux pipe-pane -t mc -o 'cat'
tail -f /dev/null
