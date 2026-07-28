#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
source .env
CA_ARGS=()
if [[ "$TLS_MODE" == "internal" && -f ./ollama-lan-root-ca.crt ]]; then
  CA_ARGS=(--cacert ./ollama-lan-root-ca.crt)
fi

echo "Health check:"
curl -fsS "${CA_ARGS[@]}" "https://$OLLAMA_HOSTNAME/healthz"
echo

echo "Model list:"
curl -fsS "${CA_ARGS[@]}" \
  -H "Authorization: Bearer $OLLAMA_API_KEY" \
  "https://$OLLAMA_HOSTNAME/v1/models"
echo
