#!/bin/bash
set -euo pipefail

# Non-destructive integration test harness for create-server.sh.
# Uses isolated copies/mocks and never touches production servers.txt or /var/lib/lxc.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
REPO_DIR="$SCRIPT_DIR"
WORK_DIR="$REPO_DIR/.safe-test-sandbox"
MOCK_BIN="$WORK_DIR/mockbin"
TEST_SERVERS="$WORK_DIR/servers.txt"
TEST_POOL="$WORK_DIR/pool.txt"
TEST_LXC_ROOT="$WORK_DIR/lxc-root"
TARGET_SERVER="SafeHarnessServer"
KEEP_SANDBOX="${SAFE_TEST_KEEP:-0}"

cleanup() {
  if [[ "$KEEP_SANDBOX" != "1" ]]; then
    rm -rf "$WORK_DIR"
  fi
}
trap cleanup EXIT

rm -rf "$WORK_DIR"
mkdir -p "$MOCK_BIN" "$TEST_LXC_ROOT"

cp "$REPO_DIR/pool.txt" "$TEST_POOL"
: > "$TEST_SERVERS"

REAL_SERVERS_SNAPSHOT="$WORK_DIR/servers.real.snapshot"
cp "$REPO_DIR/servers.txt" "$REAL_SERVERS_SNAPSHOT"

cat > "$MOCK_BIN/ping" <<'EOM'
#!/bin/bash
exit 1
EOM

cat > "$MOCK_BIN/lxc-info" <<'EOM'
#!/bin/bash
set -euo pipefail
name=""
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "-n" ]]; then
    name="$2"
    shift 2
  else
    shift
  fi
done
[[ -z "$name" ]] && exit 1
root="${BEDROCK_LXC_ROOT:-}"
if [[ -d "$root/$name" ]]; then
  if [[ -f "$root/$name/.running" ]]; then
    echo "State: RUNNING"
  else
    echo "State: STOPPED"
  fi
  exit 0
fi
exit 1
EOM

cat > "$MOCK_BIN/lxc-copy" <<'EOM'
#!/bin/bash
set -euo pipefail
name=""
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "-N" ]]; then
    name="$2"
    shift 2
  else
    shift
  fi
done
root="${BEDROCK_LXC_ROOT:-}"
mkdir -p "$root/$name/rootfs/opt/bedrock"
cat > "$root/$name/rootfs/opt/bedrock/server.properties" <<PROPS
server-name=Default
allow-cheats=false
max-players=10
PROPS
: > "$root/$name/config"
EOM

cat > "$MOCK_BIN/lxc-start" <<'EOM'
#!/bin/bash
set -euo pipefail
name=""
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "-n" ]]; then
    name="$2"
    shift 2
  else
    shift
  fi
done
root="${BEDROCK_LXC_ROOT:-}"
mkdir -p "$root/$name"
touch "$root/$name/.running"
EOM

cat > "$MOCK_BIN/lxc-stop" <<'EOM'
#!/bin/bash
set -euo pipefail
name=""
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "-n" ]]; then
    name="$2"
    shift 2
  else
    shift
  fi
done
root="${BEDROCK_LXC_ROOT:-}"
rm -f "$root/$name/.running"
EOM

cat > "$MOCK_BIN/lxc-destroy" <<'EOM'
#!/bin/bash
set -euo pipefail
name=""
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "-n" ]]; then
    name="$2"
    shift 2
  else
    shift
  fi
done
root="${BEDROCK_LXC_ROOT:-}"
rm -rf "$root/$name"
EOM

cat > "$MOCK_BIN/lxc-attach" <<'EOM'
#!/bin/bash
exit 0
EOM

chmod +x "$MOCK_BIN"/*

cat > "$WORK_DIR/profile.server.properties" <<'EOM'
server-name=Safe Harness
allow-cheats=true
max-players=20
EOM

echo "Running isolated create-server test..."
PATH="$MOCK_BIN:$PATH" \
BEDROCK_SERVERS_FILE="$TEST_SERVERS" \
BEDROCK_POOL_FILE="$TEST_POOL" \
BEDROCK_LXC_ROOT="$TEST_LXC_ROOT" \
MCSM_NO_BLOCK=1 \
"$REPO_DIR/create-server.sh" -p "$WORK_DIR/profile.server.properties" "$TARGET_SERVER"

if ! grep -q "^${TARGET_SERVER} " "$TEST_SERVERS"; then
  echo "FAIL: sandbox servers file was not updated"
  exit 1
fi

TARGET_PROPS="$TEST_LXC_ROOT/$TARGET_SERVER/rootfs/opt/bedrock/server.properties"
if ! grep -q '^allow-cheats=true$' "$TARGET_PROPS"; then
  echo "FAIL: profile was not applied in sandbox server.properties"
  exit 1
fi

if ! cmp -s "$REAL_SERVERS_SNAPSHOT" "$REPO_DIR/servers.txt"; then
  echo "FAIL: production servers.txt was modified"
  exit 1
fi

echo "PASS: isolated harness completed with no production servers.txt changes"
