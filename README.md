# Ollama Ubuntu LAN HTTPS Bootstrap

Installs Ollama natively on Ubuntu, keeps its API bound to loopback, and publishes it to a trusted local DNS name through Caddy over HTTPS.

Designed for an Ubuntu workstation/server with an AMD Radeon RX 7900 XTX, but it also works with CPU or supported NVIDIA hardware. GPU driver installation is deliberately **not automated** because changing kernel/ROCm drivers can make a remote machine unbootable or temporarily inaccessible.

## Resulting architecture

```text
VS Code / OpenCode / curl
          |
          | HTTPS :443 + Bearer token
          v
  ollama.example.lan (Caddy)
          |
          | HTTP loopback only
          v
    127.0.0.1:11434 (Ollama)
```

Only TCP 443 is intended to be reachable from the LAN. Ollama itself is never bound to the LAN interface.

## Requirements

- Ubuntu 22.04 or newer, x86-64
- A fixed IP address or DHCP reservation
- A local DNS record pointing your chosen hostname to the Ubuntu host
- `sudo` access
- For the 7900 XTX: a current ROCm-compatible AMD driver

Example DNS record:

```text
ollama.home.arpa  A  192.168.1.50
```

`home.arpa` is a good private-home naming suffix. A split-horizon subdomain you own also works.

## Quick start

```bash
git clone <this-repository-url>
cd ollama-ubuntu-lan

make configure
make doctor
make install
```

The installer pulls these defaults unless you change them:

- `qwen3-coder:30b`
- `qwen2.5-coder:7b`

Model downloads are large and may take a while.

## TLS choices

### Internal CA — recommended for a local-only hostname

Choose `internal` during `make configure`. Caddy creates a private certificate authority and issues the server certificate.

Export its root certificate:

```bash
make export-ca
```

Copy `ollama-lan-root-ca.crt` to each client and trust it.

### Trust the CA on macOS

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

### Trust the CA on Ubuntu/Debian clients

```bash
sudo cp ollama-lan-root-ca.crt /usr/local/share/ca-certificates/ollama-lan.crt
sudo update-ca-certificates
```

### Custom certificate

Choose `custom` if you already have a certificate and key from your own internal PKI or a public CA. Supply absolute paths during configuration.

For a publicly trusted certificate on an internal address, a split-DNS hostname under a domain you own plus DNS-01 issuance is typically the cleanest design. This repository does not automate provider-specific DNS credentials.

## Firewall

The installer adds an inactive/active UFW rule allowing TCP 443 only from `LAN_CIDR`. It does **not** enable UFW because enabling a firewall during an SSH session can lock you out.

Review first:

```bash
sudo ufw status verbose
sudo ufw allow OpenSSH
sudo ufw enable
```

Port `11434` should not be opened.

## Test the endpoint

After the CA is trusted or exported locally:

```bash
make test
```

Manual OpenAI-compatible test:

```bash
source .env
curl --cacert ./ollama-lan-root-ca.crt \
  -H "Authorization: Bearer $OLLAMA_API_KEY" \
  "https://$OLLAMA_HOSTNAME/v1/models"
```

Chat completion:

```bash
source .env
curl --cacert ./ollama-lan-root-ca.crt \
  -H "Authorization: Bearer $OLLAMA_API_KEY" \
  -H 'Content-Type: application/json' \
  "https://$OLLAMA_HOSTNAME/v1/chat/completions" \
  -d '{
    "model": "qwen3-coder:30b",
    "messages": [{"role":"user","content":"Write a small Go HTTP server."}],
    "stream": false
  }'
```

## VS Code built-in Chat

After trusting the Caddy CA on the Mac:

1. Open the Command Palette.
2. Run **Chat: Manage Language Models**.
3. Add an **OpenAI-compatible** provider rather than the localhost-only Ollama preset.
4. Use the base URL:

   ```text
   https://ollama.home.arpa/v1
   ```

5. Enter the value of `OLLAMA_API_KEY` as the API key.
6. Add `qwen3-coder:30b` as the chat/agent model.
7. Optionally add `qwen2.5-coder:7b` for faster lightweight work.

The exact menu wording can change between VS Code releases. If the native provider does not expose Agent tools for the model, use OpenCode or Continue against the same OpenAI-compatible endpoint.

## Point other OpenAI-compatible tools at the server

```bash
export OPENAI_BASE_URL="https://ollama.home.arpa/v1"
export OPENAI_API_KEY="your-generated-key"
```

The client must trust your Caddy root CA.

## AMD Radeon 7900 XTX notes

Run:

```bash
make doctor
ls -l /dev/kfd /dev/dri/render*
ollama ps
journalctl -u ollama --no-pager -n 200
```

`/dev/kfd` is a useful sign that the ROCm device interface is present. If Ollama falls back to CPU, install or update the AMD ROCm/amdgpu driver using AMD/Ollama guidance for your exact Ubuntu release, reboot, and retest. Do not blindly install a driver package intended for another Ubuntu/kernel version.

## Operations

```bash
make status
make logs
make models
make restart
make update
```

Configuration is installed at:

```text
/etc/ollama-lan.env
/etc/caddy/Caddyfile
/etc/systemd/system/ollama.service.d/override.conf
/etc/systemd/system/caddy.service.d/ollama-env.conf
```

## Security notes

- The API is protected by HTTPS and a bearer token.
- Ollama listens only on `127.0.0.1:11434`.
- Caddy is the only LAN-facing process.
- Restrict TCP 443 to your LAN CIDR with UFW or an upstream firewall.
- Do not expose this endpoint directly to the public internet.
- Treat the API key like a password; any authorized client can consume GPU/CPU resources and ask the model to generate arbitrary content.

## Uninstall

This repository does not include an automatic destructive uninstall. To remove it, stop and disable the services, remove the generated drop-ins/configuration, and uninstall packages only after reviewing what else uses them.
