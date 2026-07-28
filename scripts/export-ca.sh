#!/usr/bin/env bash
set -euo pipefail
OUT=${1:-./ollama-lan-root-ca.crt}
SRC=/var/lib/caddy/.local/share/caddy/pki/authorities/local/root.crt
if [[ ! -f "$SRC" ]]; then
  echo "Caddy root CA not found at $SRC. Is TLS_MODE=internal and Caddy running?" >&2
  exit 1
fi
sudo cp "$SRC" "$OUT"
sudo chown "${SUDO_USER:-$USER}:$(id -gn "${SUDO_USER:-$USER}")" "$OUT"
chmod 644 "$OUT"
echo "Exported: $OUT"
