#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

read_default() {
  local prompt="$1" default="$2" var
  read -r -p "$prompt [$default]: " var
  printf '%s' "${var:-$default}"
}

HOSTNAME_VALUE=$(read_default "LAN DNS hostname" "ollama.home.arpa")
LAN_CIDR_VALUE=$(read_default "Allowed LAN CIDR" "192.168.1.0/24")
MODELS_VALUE=$(read_default "Comma-separated models" "qwen3-coder:30b,qwen2.5-coder:7b")
TLS_MODE_VALUE=$(read_default "TLS mode (internal/custom)" "internal")

CERT_FILE=""
KEY_FILE=""
if [[ "$TLS_MODE_VALUE" == "custom" ]]; then
  CERT_FILE=$(read_default "Absolute certificate path" "/etc/ssl/certs/ollama.crt")
  KEY_FILE=$(read_default "Absolute private-key path" "/etc/ssl/private/ollama.key")
elif [[ "$TLS_MODE_VALUE" != "internal" ]]; then
  echo "TLS_MODE must be internal or custom" >&2
  exit 1
fi

read -r -s -p "Bearer API key [press Enter to generate]: " API_KEY_VALUE
echo
if [[ -z "$API_KEY_VALUE" ]]; then
  API_KEY_VALUE=$(openssl rand -hex 32)
fi

cat > .env <<ENV
OLLAMA_HOSTNAME=$HOSTNAME_VALUE
LAN_CIDR=$LAN_CIDR_VALUE
OLLAMA_MODELS=$MODELS_VALUE
TLS_MODE=$TLS_MODE_VALUE
TLS_CERT_FILE=$CERT_FILE
TLS_KEY_FILE=$KEY_FILE
OLLAMA_API_KEY=$API_KEY_VALUE
OLLAMA_CONTEXT_LENGTH=32768
OLLAMA_KEEP_ALIVE=30m
OLLAMA_MAX_LOADED_MODELS=1
OLLAMA_NUM_PARALLEL=1
ENV
chmod 600 .env

echo
echo "Created .env"
echo "Endpoint: https://$HOSTNAME_VALUE"
echo "API key:  $API_KEY_VALUE"
echo "Store that key in a password manager."
