SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help

.PHONY: help configure doctor install export-ca test status logs restart models update rotate-key uninstall

help:
	@printf '%s\n' \
	  'make configure   Interactive configuration; creates .env' \
	  'make doctor      Check Ubuntu, GPU, DNS, and HTTPS endpoint health' \
	  'make install     Install Ollama + Caddy and pull configured models' \
	  'make export-ca   Export Caddy root CA (TLS_MODE=internal only)' \
	  'make test        Test HTTPS health and OpenAI-compatible model list' \
	  'make status      Show Ollama and Caddy service status' \
	  'make logs        Follow Ollama and Caddy logs' \
	  'make restart     Restart both services' \
	  'make models      List installed models' \
	  'make update      Update Ollama and Caddy packages' \
	  'make rotate-key  Generate a new API key and reload Caddy' \
	  'make uninstall   Remove kit config (keeps packages and models)'

configure:
	./scripts/configure.sh

doctor:
	./scripts/doctor.sh

install:
	sudo ./scripts/install.sh

export-ca:
	./scripts/export-ca.sh

test:
	./scripts/test-endpoint.sh

status:
	sudo systemctl --no-pager --full status ollama caddy

logs:
	sudo journalctl -fu ollama -u caddy

restart:
	sudo systemctl restart ollama caddy

models:
	ollama list

update:
	@echo "Updating Ollama via upstream installer..."
	curl -fsSL https://ollama.com/install.sh | sh
	@echo "Updating Caddy via apt..."
	sudo apt-get update && sudo apt-get install --only-upgrade -y caddy
	sudo systemctl restart ollama caddy
	@echo "Package update complete. Models are not auto-updated;"
	@echo "re-pull with: ollama pull <model>  (or re-run make install)"

rotate-key:
	./scripts/rotate-key.sh

uninstall:
	sudo ./scripts/uninstall.sh
