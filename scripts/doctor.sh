#!/usr/bin/env bash
set -u
cd "$(dirname "$0")/.."
fail=0

check() {
  printf '%-42s' "$1"
  shift
  if "$@" >/dev/null 2>&1; then
    echo OK
  else
    echo FAIL
    fail=1
  fi
}

warn() {
  printf '%-42s%s\n' "$1" "$2"
}

check "Ubuntu detected" grep -qi ubuntu /etc/os-release
check "x86_64 architecture" test "$(uname -m)" = x86_64
check "curl installed" command -v curl
check "systemd available" command -v systemctl

if command -v lspci >/dev/null 2>&1; then
  echo "GPU: $(lspci | grep -Ei 'VGA|3D' | head -n1 || true)"
else
  warn "GPU:" "install pciutils for detection"
fi

if [[ -e /dev/kfd ]]; then
  echo "/dev/kfd (ROCm): present"
else
  echo "/dev/kfd (ROCm): absent — AMD acceleration may require a newer ROCm/amdgpu driver"
fi

if command -v nvidia-smi >/dev/null 2>&1; then
  echo "NVIDIA: $(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -n1 || echo present)"
fi

DISK_AVAIL_GB=$(df -BG --output=avail / | tail -1 | tr -dc '0-9')
if [[ -n "$DISK_AVAIL_GB" && "$DISK_AVAIL_GB" -lt 40 ]]; then
  warn "Disk free on /:" "${DISK_AVAIL_GB}G (models often need 40G+)"
else
  echo "Disk free on /: ${DISK_AVAIL_GB:-unknown}G"
fi

if [[ -f .env ]]; then
  # shellcheck disable=SC1091
  source .env
  echo "Config: .env present (TLS_MODE=${TLS_MODE:-unset})"
  if [[ -n "${OLLAMA_HOSTNAME:-}" ]]; then
    if getent hosts "$OLLAMA_HOSTNAME" >/dev/null 2>&1; then
      echo "DNS $OLLAMA_HOSTNAME: $(getent hosts "$OLLAMA_HOSTNAME" | awk '{print $1}' | head -n1)"
    else
      warn "DNS $OLLAMA_HOSTNAME:" "does not resolve on this host"
    fi
  fi
else
  warn "Config:" ".env missing — run make configure"
fi

if command -v ss >/dev/null 2>&1; then
  if ss -ltn | grep -E '0\.0\.0\.0:11434|\[::\]:11434|\*:11434' >/dev/null 2>&1; then
    warn "Ollama bind:" "FAIL — listening on a non-loopback address"
    fail=1
  elif ss -ltn | grep -q '127.0.0.1:11434'; then
    echo "Ollama bind: 127.0.0.1:11434"
  else
    echo "Ollama bind: not listening yet"
  fi
fi

if command -v ollama >/dev/null 2>&1; then
  ollama --version || true
  systemctl --no-pager --full status ollama 2>/dev/null | sed -n '1,8p' || true
fi

# HTTPS endpoint checks (post-install). Skip quietly when not configured yet.
endpoints_ok=0
if [[ -n "${OLLAMA_HOSTNAME:-}" && -n "${OLLAMA_API_KEY:-}" ]]; then
  CA_ARGS=()
  CURL_RESOLVE=()
  if [[ "${TLS_MODE:-}" == "internal" && -f ./ollama-lan-root-ca.crt ]]; then
    CA_ARGS=(--cacert ./ollama-lan-root-ca.crt)
  fi
  if ! getent hosts "$OLLAMA_HOSTNAME" >/dev/null 2>&1; then
    CURL_RESOLVE=(--resolve "${OLLAMA_HOSTNAME}:443:127.0.0.1")
  fi

  curl_endpoint() {
    curl -fsS --connect-timeout 5 --max-time 20 \
      "${CA_ARGS[@]}" "${CURL_RESOLVE[@]}" "$@"
  }

  if systemctl is-active --quiet caddy 2>/dev/null; then
    printf '%-42s' "HTTPS https://$OLLAMA_HOSTNAME/healthz"
    if body=$(curl_endpoint "https://$OLLAMA_HOSTNAME/healthz" 2>/dev/null) && [[ "$body" == "ok" ]]; then
      echo OK
    else
      echo FAIL
      fail=1
    fi

    printf '%-42s' "HTTPS /v1/models (bearer)"
    if models_json=$(curl_endpoint \
      -H "Authorization: Bearer $OLLAMA_API_KEY" \
      "https://$OLLAMA_HOSTNAME/v1/models" 2>/dev/null); then
      echo OK
      endpoints_ok=1
    else
      echo FAIL
      fail=1
    fi
  else
    caddy_state=$(systemctl is-active caddy 2>/dev/null || true)
    warn "Caddy service:" "${caddy_state:-unknown}"
    if [[ "$caddy_state" == "failed" ]]; then
      fail=1
      err_line=$(systemctl show caddy -p StatusText --value 2>/dev/null || true)
      if [[ -n "$err_line" ]]; then
        warn "Caddy error:" "$err_line"
      fi
      warn "Hint:" "journalctl -u caddy -n 50"
    else
      warn "HTTPS endpoints:" "skipped (caddy not active — run make install)"
    fi
  fi
fi

if [[ "$fail" -eq 0 && -n "${OLLAMA_HOSTNAME:-}" && -n "${OLLAMA_API_KEY:-}" && "$endpoints_ok" -eq 1 ]]; then
  echo
  echo "======== Connection information ========"
  echo "Base URL:     https://$OLLAMA_HOSTNAME"
  echo "OpenAI API:   https://$OLLAMA_HOSTNAME/v1"
  echo "Health:       https://$OLLAMA_HOSTNAME/healthz"
  echo "Models:       https://$OLLAMA_HOSTNAME/v1/models"
  echo "Auth header:  Authorization: Bearer <OLLAMA_API_KEY>"
  echo "API key:      $OLLAMA_API_KEY"
  echo "TLS mode:     ${TLS_MODE:-unset}"
  echo "LAN CIDR:     ${LAN_CIDR:-unset}"
  if [[ -n "${OLLAMA_MODELS:-}" ]]; then
    echo "Configured:   $OLLAMA_MODELS"
  fi
  if [[ -n "${models_json:-}" ]]; then
    model_ids=$(printf '%s' "$models_json" | python3 -c '
import json,sys
try:
  data=json.load(sys.stdin)
  ids=[m.get("id","") for m in data.get("data",[])]
  print(", ".join(i for i in ids if i) or "(none)")
except Exception:
  print("(unable to parse)")
' 2>/dev/null || echo "(unable to parse)")
    echo "Available:    $model_ids"
  fi
  echo
  echo "Client env:"
  echo "  export OPENAI_BASE_URL=\"https://$OLLAMA_HOSTNAME/v1\""
  echo "  export OPENAI_API_KEY=\"$OLLAMA_API_KEY\""
  if [[ "${TLS_MODE:-}" == "internal" ]]; then
    echo
    echo "Internal CA: trust ./ollama-lan-root-ca.crt on each client (make export-ca)."
  fi
  echo "========================================"
fi

exit "$fail"
