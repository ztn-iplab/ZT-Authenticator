#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODEL="$ROOT_DIR/tamarin/zt_totp_protocol.spthy"

if command -v tamarin-prover >/dev/null 2>&1; then
  tamarin-prover --prove "$MODEL"
  exit 0
fi

echo "tamarin-prover not found, running via container..."

run_image() {
  local runtime="$1"
  local image="$2"
  "$runtime" run --rm -v "$ROOT_DIR/tamarin":/work "$image" \
    tamarin-prover --prove /work/zt_totp_protocol.spthy
}

TAMARIN_IMAGE_DEFAULT="docker.io/tamarinprover/tamarin-prover:1.10.0"
TAMARIN_IMAGE_FALLBACKS=(
  "docker.io/tamarinprover/tamarin-prover:latest"
  "ghcr.io/tamarin-prover/tamarin-prover:1.10.0"
  "ghcr.io/tamarin-prover/tamarin-prover:latest"
)

if command -v docker >/dev/null 2>&1; then
  run_image docker "${TAMARIN_IMAGE:-$TAMARIN_IMAGE_DEFAULT}" && exit 0
  for img in "${TAMARIN_IMAGE_FALLBACKS[@]}"; do
    run_image docker "$img" && exit 0
  done
fi

if command -v podman >/dev/null 2>&1; then
  run_image podman "${TAMARIN_IMAGE:-$TAMARIN_IMAGE_DEFAULT}" && exit 0
  for img in "${TAMARIN_IMAGE_FALLBACKS[@]}"; do
    run_image podman "$img" && exit 0
  done
fi

echo "No container runtime found or image pull failed." >&2
exit 1
