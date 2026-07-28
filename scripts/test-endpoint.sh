#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
source .env

CA_ARGS=()
CURL_RESOLVE=()
if [[ "${TLS_MODE:-}" == "internal" && -f ./ollama-lan-root-ca.crt ]]; then
  CA_ARGS=(--cacert ./ollama-lan-root-ca.crt)
fi

# If the hostname does not resolve locally (common before split-DNS / hairpin),
# fall back to loopback with an explicit Host / SNI mapping.
if ! getent hosts "$OLLAMA_HOSTNAME" >/dev/null 2>&1; then
  echo "Note: $OLLAMA_HOSTNAME does not resolve here; testing via 127.0.0.1"
  CURL_RESOLVE=(--resolve "${OLLAMA_HOSTNAME}:443:127.0.0.1")
fi

echo "Health check:"
curl -fsS "${CA_ARGS[@]}" "${CURL_RESOLVE[@]}" "https://$OLLAMA_HOSTNAME/healthz"
echo

echo "Model list:"
curl -fsS "${CA_ARGS[@]}" "${CURL_RESOLVE[@]}" \
  -H "Authorization: Bearer $OLLAMA_API_KEY" \
  "https://$OLLAMA_HOSTNAME/v1/models"
echo
