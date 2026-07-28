#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
[[ -f .env ]] || { echo "Missing .env" >&2; exit 1; }
source .env

if [[ "${TLS_MODE:-}" != "internal" ]]; then
  echo "export-ca only applies to TLS_MODE=internal (current: ${TLS_MODE:-unset})" >&2
  exit 1
fi

OUT=${1:-./ollama-lan-root-ca.crt}
SRC=/var/lib/caddy/.local/share/caddy/pki/authorities/local/root.crt
if [[ ! -f "$SRC" ]]; then
  echo "Caddy root CA not found at $SRC. Is Caddy running with tls internal?" >&2
  exit 1
fi
sudo cp "$SRC" "$OUT"
sudo chown "${SUDO_USER:-$USER}:$(id -gn "${SUDO_USER:-$USER}")" "$OUT"
chmod 644 "$OUT"
echo "Exported: $OUT"
