#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/.venv/bin/activate"

CERT_DIR="$SCRIPT_DIR/certs"
CERT_FILE="$CERT_DIR/dev.crt"
KEY_FILE="$CERT_DIR/dev.key"

if [[ ! -f "$CERT_FILE" || ! -f "$KEY_FILE" ]]; then
  echo "TLS certs not found. Run: $SCRIPT_DIR/scripts/generate_dev_cert.sh"
  exit 1
fi

uvicorn app.main:app \
  --host 0.0.0.0 \
  --port 8000 \
  --reload \
  --ssl-certfile "$CERT_FILE" \
  --ssl-keyfile "$KEY_FILE"
