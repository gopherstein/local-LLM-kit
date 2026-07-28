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

exit "$fail"
