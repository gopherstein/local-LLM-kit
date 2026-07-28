# Ollama Ubuntu LAN HTTPS Bootstrap

Installs Ollama natively on Ubuntu, keeps its API bound to loopback, and publishes it to a trusted DNS name through Caddy over HTTPS.

Designed for an Ubuntu workstation/server with an AMD Radeon RX 7900 XTX, but it also works with CPU or supported NVIDIA hardware. GPU driver installation is deliberately **not automated** because changing kernel/ROCm drivers can make a remote machine unbootable or temporarily inaccessible.

## Resulting architecture

```text
VS Code / OpenCode / curl
          |
          | HTTPS :443 + Bearer token (LAN only)
          v
  ollama.example.com (Caddy)
          |
          | HTTP loopback only
          v
    127.0.0.1:11434 (Ollama)
```

Only TCP 443 (and TCP 80 when using Let's Encrypt) is intended to be reachable as configured. Ollama itself is never bound to the LAN interface. Caddy also enforces your `LAN_CIDR` in the reverse-proxy matcher so the API is not reachable from arbitrary remote IPs even if the firewall is misconfigured.

## Requirements

- Ubuntu 22.04 or newer, x86-64
- A fixed IP address or DHCP reservation
- A DNS record pointing your chosen hostname at this host
- `sudo` access
- For the 7900 XTX: a current ROCm-compatible AMD driver

## Quick start

```bash
git clone <this-repository-url>
cd local-LLM-kit

make configure
make doctor
make install
```

Default TLS mode is **internal** (LAN-only / private DNS). The installer also pulls these models unless you change them:

- `qwen3-coder:30b`
- `qwen2.5-coder:7b`

Model downloads are large and may take a while.

## TLS choices

### Internal CA — recommended for LAN-only / private DNS

Choose `internal` during `make configure` (the default). This is the right mode when your hostname resolves to a private IP such as `192.168.x.x` by design.

Caddy creates a private certificate authority and issues the server certificate. No ports need to be exposed to the internet.

Export its root certificate:

```bash
make export-ca
```

Copy `ollama-lan-root-ca.crt` to each client and trust it.

#### Trust the CA on macOS

GUI method:

1. Open **Keychain Access**.
2. Import `ollama-lan-root-ca.crt` into the **System** keychain.
3. Open the imported certificate.
4. Under **Trust**, choose **Always Trust**.

CLI method:

```bash
sudo security add-trusted-cert \
  -d -r trustRoot \
  -k /Library/Keychains/System.keychain \
  ollama-lan-root-ca.crt
```

#### Trust the CA on Ubuntu/Debian clients

```bash
sudo cp ollama-lan-root-ca.crt /usr/local/share/ca-certificates/ollama-lan.crt
sudo update-ca-certificates
```

### Let's Encrypt — only when public DNS points at a public IP

Choose `letsencrypt` only if a **public** A/AAAA record points at your **WAN** IP and TCP 80 is reachable from the internet. Let's Encrypt will not issue certificates for names that resolve only to private RFC1918 addresses.

Typical pattern:

1. Public DNS A record → WAN IP.
2. Port-forward TCP 80 to this host (ACME HTTP-01). TLS-ALPN on 443 is disabled so issuance still works while 443 stays LAN-only.
3. Split DNS / hairpin so LAN clients resolve the hostname to the LAN IP.
4. Keep TCP 443 limited to your LAN.

Optional: provide an email during configure for expiry notices.

### Custom certificate

Choose `custom` if you already have a certificate and key from your own internal PKI. Supply absolute paths during configuration.

## Firewall

The installer adds UFW rules (idempotent by comment) but does **not** enable UFW, because enabling a firewall during an SSH session can lock you out.

Rules added:

- Allow TCP **443** from `LAN_CIDR`
- Deny TCP **11434** (defense in depth if Ollama were ever mis-bound)
- Allow TCP **80** from anywhere when `TLS_MODE=letsencrypt` (ACME HTTP-01)

Review first:

```bash
sudo ufw status verbose
sudo ufw allow OpenSSH
sudo ufw enable
```

## Test the endpoint

```bash
make test
```

If the hostname does not resolve on the server itself, the test falls back to `--resolve hostname:443:127.0.0.1`.

Manual OpenAI-compatible test (Let's Encrypt):

```bash
source .env
curl -H "Authorization: Bearer $OLLAMA_API_KEY" \
  "https://$OLLAMA_HOSTNAME/v1/models"
```

With an internal CA:

```bash
source .env
curl --cacert ./ollama-lan-root-ca.crt \
  -H "Authorization: Bearer $OLLAMA_API_KEY" \
  "https://$OLLAMA_HOSTNAME/v1/models"
```

Chat completion:

```bash
source .env
curl -H "Authorization: Bearer $OLLAMA_API_KEY" \
  -H 'Content-Type: application/json' \
  "https://$OLLAMA_HOSTNAME/v1/chat/completions" \
  -d '{
    "model": "qwen3-coder:30b",
    "messages": [{"role":"user","content":"Write a small Go HTTP server."}],
    "stream": false
  }'
```

## VS Code built-in Chat

1. Open the Command Palette.
2. Run **Chat: Manage Language Models**.
3. Add an **OpenAI-compatible** provider rather than the localhost-only Ollama preset.
4. Use the base URL:

   ```text
   https://ollama.example.com/v1
   ```

5. Enter the value of `OLLAMA_API_KEY` as the API key.
6. Add `qwen3-coder:30b` as the chat/agent model.
7. Optionally add `qwen2.5-coder:7b` for faster lightweight work.

For `TLS_MODE=internal`, trust the Caddy CA on the client first.

The exact menu wording can change between VS Code releases. If the native provider does not expose Agent tools for the model, use OpenCode or Continue against the same OpenAI-compatible endpoint.

## Point other OpenAI-compatible tools at the server

```bash
export OPENAI_BASE_URL="https://ollama.example.com/v1"
export OPENAI_API_KEY="your-generated-key"
```

## AMD Radeon 7900 XTX notes

Run:

```bash
make doctor
ls -l /dev/kfd /dev/dri/render*
ollama ps
journalctl -u ollama --no-pager -n 200
```

`/dev/kfd` is a useful sign that the ROCm device interface is present. If Ollama falls back to CPU, install or update the AMD ROCm/amdgpu driver using AMD/Ollama guidance for your exact Ubuntu release, reboot, and retest. Do not blindly install a driver package intended for another Ubuntu/kernel version.

During `make configure` you can set `OLLAMA_FLASH_ATTENTION=1` if you want that experiment enabled in the systemd override.

## Operations

```bash
make status
make logs
make models
make restart
make update
make rotate-key
```

`make update` upgrades Ollama and Caddy packages only; re-pull models separately with `ollama pull <name>`.

`make rotate-key` writes a new bearer token to `.env` and `/etc/ollama-lan.env`, then restarts Caddy. Update every client afterward.

Configuration is installed at:

```text
/etc/ollama-lan.env
/etc/caddy/Caddyfile
/etc/systemd/system/ollama.service.d/override.conf
/etc/systemd/system/caddy.service.d/ollama-env.conf
```

Tune context length, keep-alive, parallelism, and flash attention in `.env`, then re-run `make install` (or edit `/etc/ollama-lan.env` / the systemd override and restart).

## Security notes

- The API is protected by HTTPS and a bearer token (case-insensitive `Bearer` match).
- Requests must also come from loopback or `LAN_CIDR` (Caddy `remote_ip`).
- Ollama listens only on `127.0.0.1:11434`.
- Caddy is the only LAN-facing process for the API.
- `/healthz` is reachable only from loopback/`LAN_CIDR` and does not require the API key.
- Access logs are JSON request metadata only (no Authorization header capture).
- Do not expose the API directly to the public internet; Let's Encrypt only needs TCP 80 for issuance.
- Treat the API key like a password; any authorized LAN client can consume GPU/CPU resources.

## Uninstall

```bash
make uninstall
```

This stops the services and removes kit-managed drop-ins, `/etc/ollama-lan.env`, and the managed Caddyfile. It does **not** remove the `ollama`/`caddy` packages or downloaded models.
