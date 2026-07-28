#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

read_default() {
  local prompt="$1" default="$2" var
  read -r -p "$prompt [$default]: " var
  printf '%s' "${var:-$default}"
}

HOSTNAME_VALUE=$(read_default "DNS hostname" "ollama.example.com")
LAN_CIDR_VALUE=$(read_default "Allowed LAN CIDR" "192.168.1.0/24")
MODELS_VALUE=$(read_default "Comma-separated models" "qwen3-coder:30b,qwen2.5-coder:7b")
TLS_MODE_VALUE=$(read_default "TLS mode (letsencrypt/internal/custom)" "letsencrypt")

CERT_FILE=""
KEY_FILE=""
ACME_EMAIL=""
case "$TLS_MODE_VALUE" in
  letsencrypt)
    ACME_EMAIL=$(read_default "Let's Encrypt email (expiry notices)" "")
    ;;
  custom)
    CERT_FILE=$(read_default "Absolute certificate path" "/etc/ssl/certs/ollama.crt")
    KEY_FILE=$(read_default "Absolute private-key path" "/etc/ssl/private/ollama.key")
    ;;
  internal) ;;
  *)
    echo "TLS_MODE must be letsencrypt, internal, or custom" >&2
    exit 1
    ;;
esac

CONTEXT_VALUE=$(read_default "OLLAMA_CONTEXT_LENGTH" "32768")
KEEP_ALIVE_VALUE=$(read_default "OLLAMA_KEEP_ALIVE" "30m")
MAX_LOADED_VALUE=$(read_default "OLLAMA_MAX_LOADED_MODELS" "1")
NUM_PARALLEL_VALUE=$(read_default "OLLAMA_NUM_PARALLEL" "1")
FLASH_ATTN_VALUE=$(read_default "Enable OLLAMA_FLASH_ATTENTION (1/0)" "0")

read -r -s -p "Bearer API key [press Enter to generate]: " API_KEY_VALUE
echo
if [[ -z "$API_KEY_VALUE" ]]; then
  API_KEY_VALUE=$(openssl rand -hex 32)
fi
if [[ ! "$API_KEY_VALUE" =~ ^[A-Za-z0-9_-]+$ ]]; then
  echo "API key must be alphanumeric (plus _ or -) so it is safe in Caddy matchers." >&2
  exit 1
fi

cat > .env <<ENV
OLLAMA_HOSTNAME=$HOSTNAME_VALUE
LAN_CIDR=$LAN_CIDR_VALUE
OLLAMA_MODELS=$MODELS_VALUE
TLS_MODE=$TLS_MODE_VALUE
TLS_CERT_FILE=$CERT_FILE
TLS_KEY_FILE=$KEY_FILE
ACME_EMAIL=$ACME_EMAIL
OLLAMA_API_KEY=$API_KEY_VALUE
OLLAMA_CONTEXT_LENGTH=$CONTEXT_VALUE
OLLAMA_KEEP_ALIVE=$KEEP_ALIVE_VALUE
OLLAMA_MAX_LOADED_MODELS=$MAX_LOADED_VALUE
OLLAMA_NUM_PARALLEL=$NUM_PARALLEL_VALUE
OLLAMA_FLASH_ATTENTION=$FLASH_ATTN_VALUE
ENV
chmod 600 .env

echo
echo "Created .env"
echo "Endpoint: https://$HOSTNAME_VALUE"
echo "API key:  $API_KEY_VALUE"
echo "Store that key in a password manager."
case "$TLS_MODE_VALUE" in
  letsencrypt)
    echo
    echo "Let's Encrypt requires:"
    echo "  - A public DNS A/AAAA record for $HOSTNAME_VALUE pointing at this host"
    echo "  - TCP 80 reachable from the internet (ACME HTTP-01)"
    echo "  - API stays LAN-only via Caddy remote_ip + UFW on 443"
    ;;
  internal)
    echo "Next after install: make export-ca, then trust the CA on each client."
    ;;
esac
