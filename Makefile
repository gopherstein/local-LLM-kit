SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help

.PHONY: help configure doctor install export-ca test status logs restart models update

help:
	@printf '%s\n' \
	  'make configure  Interactive configuration; creates .env' \
	  'make doctor     Check Ubuntu, architecture, and GPU visibility' \
	  'make install    Install Ollama + Caddy and pull configured models' \
	  'make export-ca  Export Caddy root CA for client trust stores' \
	  'make test       Test HTTPS health and OpenAI-compatible model list' \
	  'make status     Show Ollama and Caddy service status' \
	  'make logs       Follow Ollama and Caddy logs' \
	  'make restart    Restart both services' \
	  'make models     List installed models' \
	  'make update     Update Ollama and Caddy packages'

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
	curl -fsSL https://ollama.com/install.sh | sh
	sudo apt-get update && sudo apt-get install --only-upgrade -y caddy
	sudo systemctl restart ollama caddy
