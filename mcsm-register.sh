#!/bin/bash
NAME=$1
IP=$2

curl -X POST "http://EPIC-BOSS/api/instance" \
  -H "Content-Type: application/json" \
  -H "Authorization: YOUR_API_KEY" \
  -d "{
    \"daemonId\": \"YOUR_DAEMON_ID\",
    \"name\": \"$NAME\",
    \"type\": \"process\",
    \"startCommand\": \"lxc-start -n $NAME\",
    \"stopCommand\": \"lxc-stop -n $NAME\",
    \"cwd\": \"/\",
    \"logPath\": \"/var/lib/lxc/$NAME/rootfs/opt/bedrock/server.log\"
  }"
