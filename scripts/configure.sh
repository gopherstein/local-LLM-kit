#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

read_default() {
  local prompt="$1" default="$2" var
  read -r -p "$prompt [$default]: " var
  printf '%s' "${var:-$default}"
}

read_secret() {
  local prompt="$1" default="${2:-}" var
  if [[ -n "$default" ]]; then
    read -r -s -p "$prompt [enter keeps existing]: " var
  else
    read -r -s -p "$prompt: " var
  fi
  echo
  printf '%s' "${var:-$default}"
}

guess_lan_cidr() {
  local ip
  ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
  if [[ "$ip" =~ ^([0-9]+\.[0-9]+\.[0-9]+)\.[0-9]+$ ]]; then
    printf '%s.0/24' "${BASH_REMATCH[1]}"
  else
    printf '192.168.1.0/24'
  fi
}

HOSTNAME_VALUE=$(read_default "DNS hostname (LAN or split-DNS)" "ollama.home.arpa")
LAN_CIDR_VALUE=$(read_default "Allowed LAN CIDR" "$(guess_lan_cidr)")
MODELS_VALUE=$(read_default "Comma-separated models" "qwen3-coder:30b,qwen2.5-coder:7b")
echo
echo "TLS modes:"
echo "  internal          — LAN-only / private DNS (trust exported CA on clients)"
echo "  letsencrypt-dns   — Let's Encrypt DNS-01 via Route53 (best for private A records)"
echo "  letsencrypt       — Let's Encrypt HTTP-01 (needs public WAN A record + port 80)"
echo "  custom            — your own cert/key files"
TLS_MODE_VALUE=$(read_default "TLS mode (internal/letsencrypt-dns/letsencrypt/custom)" "internal")

CERT_FILE=""
KEY_FILE=""
ACME_EMAIL=""
AWS_ACCESS_KEY_ID_VALUE=""
AWS_SECRET_ACCESS_KEY_VALUE=""
AWS_REGION_VALUE=""
ROUTE53_HOSTED_ZONE_ID_VALUE=""
case "$TLS_MODE_VALUE" in
  letsencrypt)
    ACME_EMAIL=$(read_default "Let's Encrypt email (expiry notices)" "")
    echo
    echo "Note: HTTP-01 cannot issue when DNS resolves only to a private IP."
    echo "For private A records on Route53, choose letsencrypt-dns instead."
    ;;
  letsencrypt-dns)
    ACME_EMAIL=$(read_default "Let's Encrypt email (expiry notices)" "")
    AWS_ACCESS_KEY_ID_VALUE=$(read_default "AWS_ACCESS_KEY_ID" "")
    AWS_SECRET_ACCESS_KEY_VALUE=$(read_secret "AWS_SECRET_ACCESS_KEY")
    AWS_REGION_VALUE=$(read_default "AWS_REGION" "us-east-1")
    ROUTE53_HOSTED_ZONE_ID_VALUE=$(read_default "Route53 hosted zone ID (optional)" "")
    [[ -n "$AWS_ACCESS_KEY_ID_VALUE" && -n "$AWS_SECRET_ACCESS_KEY_VALUE" ]] || {
      echo "AWS access key and secret are required for letsencrypt-dns" >&2
      exit 1
    }
    echo
    echo "IAM: attach a policy like config/route53-acme-iam-policy.json (replace HOSTED_ZONE_ID)."
    ;;
  custom)
    CERT_FILE=$(read_default "Absolute certificate path" "/etc/ssl/certs/ollama.crt")
    KEY_FILE=$(read_default "Absolute private-key path" "/etc/ssl/private/ollama.key")
    ;;
  internal) ;;
  *)
    echo "TLS_MODE must be internal, letsencrypt-dns, letsencrypt, or custom" >&2
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
AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID_VALUE
AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY_VALUE
AWS_REGION=$AWS_REGION_VALUE
ROUTE53_HOSTED_ZONE_ID=$ROUTE53_HOSTED_ZONE_ID_VALUE
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
    echo "Let's Encrypt HTTP-01 requires a public WAN A record and TCP 80."
    ;;
  letsencrypt-dns)
    echo
    echo "Let's Encrypt DNS-01 via Route53: A record may stay private; no port 80 needed."
    echo "First install builds a custom Caddy with the Route53 plugin (needs Go; a few minutes)."
    ;;
  internal)
    echo "Next after install: make export-ca, then trust the CA on each client."
    ;;
esac
