#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
SERVERS_FILE="${BEDROCK_SERVERS_FILE:-$SCRIPT_DIR/servers.txt}"

usage() {
  echo "Usage: ./health-check.sh [--name <server>]"
}

TARGET_NAME=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)
      TARGET_NAME="${2:-}"
      shift 2
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
  echo "servers file not found: $SERVERS_FILE"
  exit 2
fi

failures=0
printf "%-24s %-16s %-12s %-12s\n" "NAME" "IP" "CONTAINER" "BEDROCK"

while read -r line; do
  line="${line%%#*}"
  [[ -z "${line// }" ]] && continue

  name="$(echo "$line" | awk '{print $1}')"
  ip="$(echo "$line" | awk '{print $2}')"

  if [[ -n "$TARGET_NAME" && "$name" != "$TARGET_NAME" ]]; then
    continue
  fi

  container_state="MISSING"
  bedrock_state="N/A"

  if lxc-info -n "$name" >/dev/null 2>&1; then
    if lxc-info -n "$name" | grep -q 'RUNNING'; then
      container_state="RUNNING"
      if lxc-attach -n "$name" -- tmux has-session -t mc >/dev/null 2>&1; then
        bedrock_state="RUNNING"
      else
        bedrock_state="DOWN"
        failures=$((failures + 1))
      fi
    else
      container_state="STOPPED"
      bedrock_state="DOWN"
      failures=$((failures + 1))
    fi
  else
    failures=$((failures + 1))
  fi

  printf "%-24s %-16s %-12s %-12s\n" "$name" "$ip" "$container_state" "$bedrock_state"
done < "$SERVERS_FILE"

if [[ "$failures" -gt 0 ]]; then
  echo "Health check completed with $failures issue(s)."
  exit 1
fi

echo "Health check passed."
