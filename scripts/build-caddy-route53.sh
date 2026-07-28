#!/usr/bin/env bash
# Build a Caddy binary with the Route53 DNS provider for ACME DNS-01.
set -euo pipefail

DEST=${1:-/usr/local/bin/caddy}
MODULE_MARK="dns.providers.route53"

if command -v "$DEST" >/dev/null 2>&1 && "$DEST" list-modules 2>/dev/null | grep -q "$MODULE_MARK"; then
  echo "Caddy at $DEST already includes $MODULE_MARK"
  "$DEST" version
  exit 0
fi

# Prefer an existing caddy on PATH that already has the module.
if command -v caddy >/dev/null 2>&1 && caddy list-modules 2>/dev/null | grep -q "$MODULE_MARK"; then
  echo "System caddy already includes $MODULE_MARK; copying to $DEST"
  install -m 755 "$(command -v caddy)" "$DEST"
  exit 0
fi

export DEBIAN_FRONTEND=noninteractive
apt-get install -y golang-go git

export GOTOOLCHAIN=auto
export GOPATH="${GOPATH:-/root/go}"
export PATH="$PATH:${GOPATH}/bin"
# Include common distro Go bin dirs without relying on shell globs in PATH.
for d in /usr/lib/go/bin /usr/local/go/bin; do
  [[ -d "$d" ]] && PATH="$PATH:$d"
done

go install github.com/caddyserver/xcaddy/cmd/xcaddy@latest
XCADDY=$(command -v xcaddy || true)
[[ -n "$XCADDY" ]] || XCADDY="$GOPATH/bin/xcaddy"
[[ -x "$XCADDY" ]] || { echo "xcaddy install failed" >&2; exit 1; }

BUILD_DIR=$(mktemp -d)
trap 'rm -rf "$BUILD_DIR"' EXIT
cd "$BUILD_DIR"

echo "Building Caddy with github.com/caddy-dns/route53 (this may take a few minutes)..."
"$XCADDY" build --with github.com/caddy-dns/route53

install -m 755 ./caddy "$DEST"
"$DEST" version
"$DEST" list-modules | grep -F "$MODULE_MARK"
echo "Installed $DEST with Route53 DNS module"
