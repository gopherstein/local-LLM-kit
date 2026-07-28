#!/usr/bin/env bash
set -u
fail=0
check() { printf '%-38s' "$1"; shift; if "$@" >/dev/null 2>&1; then echo OK; else echo FAIL; fail=1; fi; }

check "Ubuntu detected" grep -qi ubuntu /etc/os-release
check "x86_64 architecture" test "$(uname -m)" = x86_64
check "curl installed" command -v curl
check "systemd available" command -v systemctl

if command -v lspci >/dev/null 2>&1; then
  echo "GPU: $(lspci | grep -Ei 'VGA|3D' | head -n1 || true)"
else
  echo "GPU: install pciutils for detection"
fi

if [[ -e /dev/kfd ]]; then
  echo "/dev/kfd (ROCm): present"
else
  echo "/dev/kfd (ROCm): absent — AMD acceleration may require a newer ROCm/amdgpu driver"
fi

if command -v ollama >/dev/null 2>&1; then
  ollama --version || true
  systemctl --no-pager --full status ollama 2>/dev/null | sed -n '1,8p' || true
fi

exit "$fail"
