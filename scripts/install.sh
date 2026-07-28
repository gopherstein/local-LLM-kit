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
if [[ ! "$OLLAMA_API_KEY" =~ ^[A-Za-z0-9_-]+$ ]]; then
  echo "OLLAMA_API_KEY must be alphanumeric (plus _ or -)" >&2
  exit 1
fi

ufw_ensure_comment() {
  local comment=$1
  shift
  if ufw status 2>/dev/null | grep -F "$comment" >/dev/null 2>&1; then
    echo "UFW already has rule: $comment"
  else
    ufw "$@" || true
  fi
}

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y curl ca-certificates gnupg debian-keyring debian-archive-keyring apt-transport-https ufw openssl dnsutils python3

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
# caddy runs as User=caddy; root-owned log files from validate/prior runs cause startup failure
chown -R caddy:caddy /var/log/caddy
chmod 755 /var/log/caddy

sed \
  -e "s|__OLLAMA_CONTEXT_LENGTH__|${OLLAMA_CONTEXT_LENGTH:-32768}|g" \
  -e "s|__OLLAMA_KEEP_ALIVE__|${OLLAMA_KEEP_ALIVE:-30m}|g" \
  -e "s|__OLLAMA_MAX_LOADED_MODELS__|${OLLAMA_MAX_LOADED_MODELS:-1}|g" \
  -e "s|__OLLAMA_NUM_PARALLEL__|${OLLAMA_NUM_PARALLEL:-1}|g" \
  "$ROOT_DIR/systemd/ollama-override.conf" > /etc/systemd/system/ollama.service.d/override.conf
if [[ "${OLLAMA_FLASH_ATTENTION:-0}" == "1" ]]; then
  sed -i 's|__OLLAMA_EXTRA_ENV__|Environment="OLLAMA_FLASH_ATTENTION=1"|' \
    /etc/systemd/system/ollama.service.d/override.conf
else
  sed -i '/__OLLAMA_EXTRA_ENV__/d' /etc/systemd/system/ollama.service.d/override.conf
fi
install -m 644 "$ROOT_DIR/systemd/caddy-env.conf" /etc/systemd/system/caddy.service.d/ollama-env.conf

GLOBAL_OPTIONS="{"
TLS_LINE="# tls: automatic (Let's Encrypt / ZeroSSL)"
case "$TLS_MODE" in
  letsencrypt)
    if [[ -n "${ACME_EMAIL:-}" ]]; then
      GLOBAL_OPTIONS+=$'\n\temail '"${ACME_EMAIL}"
    fi
    # 443 stays LAN-only; issue/renew via HTTP-01 on public port 80.
    GLOBAL_OPTIONS+=$'\n\tcert_issuer acme {'
    GLOBAL_OPTIONS+=$'\n\t\tdisable_tlsalpn_challenge'
    GLOBAL_OPTIONS+=$'\n\t}\n}'
    ;;
  internal)
    GLOBAL_OPTIONS+=$'\n\tauto_https disable_redirects\n}'
    TLS_LINE="tls internal"
    ;;
  custom)
    [[ -f "${TLS_CERT_FILE:-}" && -f "${TLS_KEY_FILE:-}" ]] || { echo "Custom TLS files not found" >&2; exit 1; }
    GLOBAL_OPTIONS+=$'\n\tauto_https disable_redirects\n}'
    TLS_LINE="tls ${TLS_CERT_FILE} ${TLS_KEY_FILE}"
    ;;
  *)
    echo "Unsupported TLS_MODE: $TLS_MODE" >&2
    exit 1
    ;;
esac

python3 - "$ROOT_DIR/config/Caddyfile.tmpl" /etc/caddy/Caddyfile "$GLOBAL_OPTIONS" "$TLS_LINE" <<'PY'
import pathlib, sys
src, dst, global_options, tls_line = sys.argv[1:5]
text = pathlib.Path(src).read_text()
text = text.replace("__GLOBAL_OPTIONS__", global_options)
text = text.replace("__TLS_LINE__", tls_line)
pathlib.Path(dst).write_text(text)
PY
chmod 644 /etc/caddy/Caddyfile

# caddy validate expands {$ENV} placeholders; load the same env systemd will use.
set -a
# shellcheck disable=SC1091
source /etc/ollama-lan.env
set +a
caddy validate --config /etc/caddy/Caddyfile
# validate may create log files as root — fix ownership before service start
chown -R caddy:caddy /var/log/caddy
systemctl daemon-reload
systemctl enable --now ollama caddy
systemctl restart ollama caddy
if ! systemctl is-active --quiet caddy; then
  echo "Caddy failed to start. Recent logs:" >&2
  systemctl --no-pager --full status caddy >&2 || true
  journalctl -u caddy --no-pager -n 30 >&2 || true
  exit 1
fi

# Firewall: never auto-enable UFW (can lock out SSH). Rules are idempotent by comment.
ufw_ensure_comment "Ollama loopback only" deny 11434/tcp comment "Ollama loopback only"
ufw_ensure_comment "Ollama HTTPS LAN" allow proto tcp from "$LAN_CIDR" to any port 443 comment "Ollama HTTPS LAN"
if [[ "$TLS_MODE" == "letsencrypt" ]]; then
  ufw_ensure_comment "ACME HTTP-01" allow 80/tcp comment "ACME HTTP-01"
fi

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
case "$TLS_MODE" in
  letsencrypt)
    echo "Let's Encrypt: ensure public DNS for $OLLAMA_HOSTNAME points here and TCP 80 is reachable."
    echo "Certificate issuance may take a minute; check: journalctl -u caddy -n 50"
    ;;
  internal)
    echo "Next: make export-ca, then install the CA on each client device."
    ;;
esac
echo "Review UFW with: sudo ufw status"
echo "Enable it only after confirming SSH is allowed: sudo ufw allow OpenSSH && sudo ufw enable"
echo "Rotate the API key later with: make rotate-key"
