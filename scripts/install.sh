#!/usr/bin/env bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Run with sudo: sudo ./scripts/install.sh" >&2
  exit 1
fi

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
ENV_FILE="$ROOT_DIR/.env"
[[ -f "$ENV_FILE" ]] || { echo "Missing .env. Run make configure first." >&2; exit 1; }
# shellcheck disable=SC1090
source "$ENV_FILE"

for required in OLLAMA_HOSTNAME LAN_CIDR OLLAMA_MODELS TLS_MODE OLLAMA_API_KEY; do
  [[ -n "${!required:-}" ]] || { echo "$required is empty" >&2; exit 1; }
done
[[ "$OLLAMA_API_KEY" != "CHANGE_ME" ]] || { echo "Set a real OLLAMA_API_KEY" >&2; exit 1; }

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y curl ca-certificates gnupg debian-keyring debian-archive-keyring apt-transport-https ufw openssl

if ! command -v ollama >/dev/null 2>&1; then
  curl -fsSL https://ollama.com/install.sh | sh
fi

if ! command -v caddy >/dev/null 2>&1; then
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' > /etc/apt/sources.list.d/caddy-stable.list
  chmod o+r /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  chmod o+r /etc/apt/sources.list.d/caddy-stable.list
  apt-get update
  apt-get install -y caddy
fi

install -m 600 "$ENV_FILE" /etc/ollama-lan.env
mkdir -p /etc/systemd/system/ollama.service.d /etc/systemd/system/caddy.service.d /var/log/caddy
chown caddy:caddy /var/log/caddy

sed \
  -e "s|__OLLAMA_CONTEXT_LENGTH__|${OLLAMA_CONTEXT_LENGTH:-32768}|g" \
  -e "s|__OLLAMA_KEEP_ALIVE__|${OLLAMA_KEEP_ALIVE:-30m}|g" \
  -e "s|__OLLAMA_MAX_LOADED_MODELS__|${OLLAMA_MAX_LOADED_MODELS:-1}|g" \
  -e "s|__OLLAMA_NUM_PARALLEL__|${OLLAMA_NUM_PARALLEL:-1}|g" \
  "$ROOT_DIR/systemd/ollama-override.conf" > /etc/systemd/system/ollama.service.d/override.conf
install -m 644 "$ROOT_DIR/systemd/caddy-env.conf" /etc/systemd/system/caddy.service.d/ollama-env.conf

case "$TLS_MODE" in
  internal) install -m 644 "$ROOT_DIR/config/Caddyfile" /etc/caddy/Caddyfile ;;
  custom)
    [[ -f "${TLS_CERT_FILE:-}" && -f "${TLS_KEY_FILE:-}" ]] || { echo "Custom TLS files not found" >&2; exit 1; }
    install -m 644 "$ROOT_DIR/config/Caddyfile.custom-tls" /etc/caddy/Caddyfile
    ;;
  *) echo "Unsupported TLS_MODE: $TLS_MODE" >&2; exit 1 ;;
esac

caddy validate --config /etc/caddy/Caddyfile
systemctl daemon-reload
systemctl enable --now ollama caddy
systemctl restart ollama caddy

# Restrict public exposure to HTTPS from the configured LAN. Do not enable UFW
# automatically because doing so can interrupt remote SSH sessions.
ufw allow proto tcp from "$LAN_CIDR" to any port 443 comment 'Ollama HTTPS LAN' || true

echo "Waiting for Ollama..."
for _ in $(seq 1 30); do
  curl -fsS http://127.0.0.1:11434/api/tags >/dev/null && break
  sleep 1
done
curl -fsS http://127.0.0.1:11434/api/tags >/dev/null || { echo "Ollama did not become ready" >&2; exit 1; }

IFS=',' read -ra MODELS <<< "$OLLAMA_MODELS"
for model in "${MODELS[@]}"; do
  model=$(echo "$model" | xargs)
  [[ -n "$model" ]] || continue
  echo "Pulling $model"
  sudo -u ollama ollama pull "$model"
done

echo
echo "Installation complete."
echo "Endpoint: https://$OLLAMA_HOSTNAME"
echo "Ollama remains bound to 127.0.0.1; Caddy is the only LAN-facing service."
if [[ "$TLS_MODE" == "internal" ]]; then
  echo "Next: make export-ca, then install the CA on each client device."
fi
echo "Review UFW with: sudo ufw status"
echo "Enable it only after confirming SSH is allowed: sudo ufw allow OpenSSH && sudo ufw enable"
