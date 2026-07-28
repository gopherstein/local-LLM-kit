#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

[[ -f .env ]] || { echo "Missing .env. Run make configure first." >&2; exit 1; }

NEW_KEY=${1:-}
if [[ -z "$NEW_KEY" ]]; then
  NEW_KEY=$(openssl rand -hex 32)
fi
if [[ ! "$NEW_KEY" =~ ^[A-Za-z0-9_-]+$ ]]; then
  echo "API key must be alphanumeric (plus _ or -)" >&2
  exit 1
fi

tmp=$(mktemp)
awk -v key="$NEW_KEY" '
  BEGIN { done=0 }
  /^OLLAMA_API_KEY=/ { print "OLLAMA_API_KEY=" key; done=1; next }
  { print }
  END { if (!done) print "OLLAMA_API_KEY=" key }
' .env > "$tmp"
chmod 600 "$tmp"
mv "$tmp" .env

if [[ -f /etc/ollama-lan.env ]]; then
  sudo install -m 600 .env /etc/ollama-lan.env
  sudo systemctl restart caddy
  echo "Updated .env and /etc/ollama-lan.env; restarted Caddy."
else
  echo "Updated .env. Run make install (or copy to /etc/ollama-lan.env and restart caddy) on the server."
fi

echo "New API key: $NEW_KEY"
echo "Store it in a password manager and update clients."
