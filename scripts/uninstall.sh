#!/usr/bin/env bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Run with sudo: sudo ./scripts/uninstall.sh" >&2
  exit 1
fi

echo "This removes Ollama LAN bootstrap config and stops the related units."
echo "Packages (ollama, caddy) and pulled models are left installed."
read -r -p "Continue? [y/N]: " ans
[[ "${ans:-}" =~ ^[Yy]$ ]] || exit 0

systemctl stop caddy ollama 2>/dev/null || true

rm -f /etc/systemd/system/ollama.service.d/override.conf
rm -f /etc/systemd/system/caddy.service.d/ollama-env.conf
rmdir /etc/systemd/system/ollama.service.d 2>/dev/null || true
rmdir /etc/systemd/system/caddy.service.d 2>/dev/null || true
rm -f /etc/ollama-lan.env

if [[ -f /etc/caddy/Caddyfile ]] && grep -q 'ollama-access.log\|127.0.0.1:11434' /etc/caddy/Caddyfile 2>/dev/null; then
  rm -f /etc/caddy/Caddyfile
  echo "Removed /etc/caddy/Caddyfile (was managed by this kit)."
fi

systemctl daemon-reload
echo "Uninstall of kit config complete."
echo "Optional: sudo apt-get remove --purge caddy"
echo "Optional: remove Ollama per upstream docs; models usually live under /usr/share/ollama or ~ollama"
