#!/bin/bash
set -e

VERBOSE=0
PROFILE_FILE=""
WORLD_FILE=""
MCSM_NO_BLOCK="${MCSM_NO_BLOCK:-0}"
LXC_ROOT="${BEDROCK_LXC_ROOT:-/var/lib/lxc}"

while getopts ":vp:w:" opt; do
  case "$opt" in
    v)
      VERBOSE=1
      ;;
    p)
      PROFILE_FILE="$OPTARG"
      ;;
    w)
      WORLD_FILE="$OPTARG"
      ;;
    *)
      echo "Usage: create.sh [-v] [-p profile.properties] [-w world.mcworld] <name>"
      exit 1
      ;;
  esac
done

shift $((OPTIND - 1))
NAME="$1"

if [ -z "$NAME" ]; then
  echo "Usage: create.sh [-v] [-p profile.properties] [-w world.mcworld] <name>"
  exit 1
fi

vlog() {
  if [ "$VERBOSE" -eq 1 ]; then
    echo "[DEBUG] $*"
  fi
}

ensure_bedrock_running() {
  local container_name="$1"
  vlog "Ensuring Bedrock tmux session is running in $container_name"
  lxc-attach -n "$container_name" -- bash -lc "
    cd /opt/bedrock
    if tmux has-session -t mc 2>/dev/null; then
      if tmux list-panes -t mc -F '#{pane_dead}' | grep -q '^1$'; then
        tmux kill-session -t mc
      else
        exit 0
      fi
    fi
    tmux new -d -s mc './bedrock_server'
  "
}

attach_and_hold_for_mcs() {
  local container_name="$1"
  if [ "$MCSM_NO_BLOCK" = "1" ]; then
    vlog "MCSM_NO_BLOCK=1 set, skipping log pipe attach and hold loop"
    return 0
  fi

  echo "[MCSM] Attaching to tmux session for log streaming..."
  # This NEVER exits until the tmux session ends
  lxc-attach -n "$container_name" -- tmux pipe-pane -t mc -o 'cat'
  tail -f /dev/null
}

apply_profile_if_present() {
  local container_name="$1"
  local profile_path="$PROFILE_FILE"

  if [ -z "$profile_path" ]; then
    profile_path="$SCRIPT_DIR/properties.d/${container_name}.server.properties"
  fi

  if [ ! -f "$profile_path" ]; then
    vlog "No properties profile found at: $profile_path"
    return 0
  fi

  local target_path="$LXC_ROOT/$container_name/rootfs/opt/bedrock/server.properties"
  if [ ! -f "$target_path" ]; then
    echo "Expected Bedrock server.properties not found at: $target_path"
    return 1
  fi

  vlog "Applying properties profile $profile_path to $target_path"
  "$SCRIPT_DIR/apply_server_properties.py" --profile "$profile_path" --target "$target_path"
}

import_world_if_requested() {
  local container_name="$1"

  if [ -z "$WORLD_FILE" ]; then
    return 0
  fi

  local container_root="$LXC_ROOT/$container_name/rootfs"
  vlog "Importing .mcworld archive $WORLD_FILE into $container_root"
  "$SCRIPT_DIR/import_mcworld.py" \
    --source "$WORLD_FILE" \
    --container-root "$container_root" \
    --server-name "$container_name"
}

sync_mcs_ping_if_configured() {
  local container_name="$1"
  local servers_path="$SERVERS_FILE"

  "$SCRIPT_DIR/mcs_sync_ping.py" \
    --name "$container_name" \
    --servers-file "$servers_path" \
    --best-effort || true
}

vlog "Requested server name: $NAME"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
SERVERS_FILE="${BEDROCK_SERVERS_FILE:-$SCRIPT_DIR/servers.txt}"
vlog "Script directory resolved to: $SCRIPT_DIR"
vlog "Using servers file: $SERVERS_FILE"
vlog "Using LXC root: $LXC_ROOT"

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
  echo "Server $EXISTING_NAME already exists with IP $EXISTING_IP. Ensuring container and Bedrock server are running..."
  vlog "Checking LXC state for $EXISTING_NAME"
  if ! lxc-info -n "$EXISTING_NAME" >/dev/null 2>&1; then
    echo "Container $EXISTING_NAME is missing even though it exists in servers.txt."
    echo "Recreate the container manually or remove the stale entry before retrying create."
    exit 1
  fi
  lxc-info -n "$EXISTING_NAME" | grep -q 'RUNNING' || lxc-start -n "$EXISTING_NAME"
  sleep 3

  apply_profile_if_present "$EXISTING_NAME"
  import_world_if_requested "$EXISTING_NAME"
  ensure_bedrock_running "$EXISTING_NAME"
  sync_mcs_ping_if_configured "$EXISTING_NAME"
  echo "Server $EXISTING_NAME is running at $EXISTING_IP:19132"

  attach_and_hold_for_mcs "$NAME"
  exit 0
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

POOL_FILE="${BEDROCK_POOL_FILE:-$SCRIPT_DIR/pool.txt}"
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

vlog "Appending network configuration to $LXC_ROOT/$NAME/config"
cat <<EOF >> "$LXC_ROOT/$NAME/config"
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

apply_profile_if_present "$NAME"
import_world_if_requested "$NAME"

vlog "Launching Bedrock server in tmux session inside container"
ensure_bedrock_running "$NAME"

vlog "Recording server mapping in $SERVERS_FILE"
echo "$NAME $FREE_IP" >> "$SERVERS_FILE"
vlog "Provisioning complete for $NAME"
sync_mcs_ping_if_configured "$NAME"
echo "Server $NAME running at $FREE_IP:19132"

attach_and_hold_for_mcs "$NAME"
