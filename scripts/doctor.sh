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
  if [[ -n "${LAN_CIDR:-}" ]]; then
    host_ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
    if [[ -n "$host_ip" ]] && command -v python3 >/dev/null 2>&1; then
      if python3 - "$host_ip" "$LAN_CIDR" <<'PY'
import ipaddress, sys
ip, cidr = sys.argv[1], sys.argv[2]
sys.exit(0 if ipaddress.ip_address(ip) in ipaddress.ip_network(cidr, strict=False) else 1)
PY
      then
        echo "LAN_CIDR $LAN_CIDR contains host $host_ip"
      else
        warn "LAN_CIDR mismatch:" "host is $host_ip but LAN_CIDR=$LAN_CIDR (API/healthz will 401 from this LAN)"
        fail=1
      fi
    fi
  fi
  if [[ "${TLS_MODE:-}" == "letsencrypt" && -n "${OLLAMA_HOSTNAME:-}" ]]; then
    pub_ip=""
    if command -v dig >/dev/null 2>&1; then
      pub_ip=$(dig +short "$OLLAMA_HOSTNAME" A @1.1.1.1 2>/dev/null | awk 'NR==1 && $1 ~ /^[0-9.]+$/ {print; exit}')
    fi
    if [[ -z "$pub_ip" ]]; then
      warn "Public DNS:" "$OLLAMA_HOSTNAME has no A record at 1.1.1.1 — Let's Encrypt cannot issue"
      fail=1
    elif python3 - "$pub_ip" <<'PY'
import ipaddress, sys
sys.exit(0 if ipaddress.ip_address(sys.argv[1]).is_private else 1)
PY
    then
      warn "Public DNS:" "$OLLAMA_HOSTNAME → $pub_ip (private). Let's Encrypt cannot issue for RFC1918 addresses."
      warn "Fix:" "use TLS_MODE=internal (LAN-only), or point public DNS at a real WAN IP"
      fail=1
    else
      echo "Public DNS $OLLAMA_HOSTNAME: $pub_ip"
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
    health_err=$(mktemp)
    if body=$(curl_endpoint "https://$OLLAMA_HOSTNAME/healthz" 2>"$health_err") && [[ "$body" == "ok" ]]; then
      echo OK
    else
      echo FAIL
      fail=1
      err=$(tr '\n' ' ' <"$health_err" | sed 's/[[:space:]]\+/ /g')
      [[ -n "$err" ]] && warn "  curl:" "$err"
      if journalctl -u caddy --no-pager -n 80 2>/dev/null | grep -q 'acme:error:dns\|could not get certificate\|authorization failed'; then
        warn "  TLS:" "Let's Encrypt has not issued a cert yet (see journalctl -u caddy)"
      fi
    fi
    rm -f "$health_err"

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
