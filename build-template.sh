#!/bin/bash
set -e

NAME="bedrock-template"
BEDROCK_VERSION="1.26.11.1"  # Change this to the latest version

echo "Creating base template..."
lxc-create -n $NAME -t download -- -d ubuntu -r jammy -a amd64

echo "Installing dependencies..."
lxc-start -n $NAME
sleep 5

lxc-attach -n $NAME -- bash -c "
  apt update &&
  apt install -y unzip curl tmux
"

echo "Installing Bedrock server version $BEDROCK_VERSION..."
lxc-attach -n $NAME -- bash -c "
  mkdir -p /opt/bedrock &&
  cd /opt/bedrock &&
  curl -L --http1.1 -A "Mozilla/5.0" -o bedrock.zip https://www.minecraft.net/bedrockdedicatedserver/bin-linux/bedrock-server-$BEDROCK_VERSION.zip &&
  unzip -o bedrock.zip &&
  chmod +x bedrock_server
"

lxc-stop -n $NAME

echo "Template ready with Bedrock server version $BEDROCK_VERSION."
