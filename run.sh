#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKEND_RUN="${ROOT_DIR}/backend/run.sh"

detect_lan_ip() {
  local ip=""
  ip="$(ifconfig en0 2>/dev/null | awk '/inet /{print $2; exit}')"
  if [[ -z "$ip" ]]; then
    ip="$(ifconfig en1 2>/dev/null | awk '/inet /{print $2; exit}')"
  fi
  echo "$ip"
}

LAN_IP="${LAN_IP:-$(detect_lan_ip)}"

if [[ ! -x "$BACKEND_RUN" ]]; then
  echo "Missing backend runner: $BACKEND_RUN" >&2
  exit 1
fi

echo "Starting ZT-Authenticator backend..."
if [[ -n "$LAN_IP" ]]; then
  echo "Phone access hint: https://${LAN_IP}:8000"
fi

exec "$BACKEND_RUN"
