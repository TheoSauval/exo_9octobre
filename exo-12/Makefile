# Outillage d'équipe Shop SAS
SHELL := /bin/bash
DC      := docker compose
DC_PROD := docker compose -f compose.yml -f compose.prod.yml

.PHONY: help init secrets up down logs ps tools prod-config prod-up prod-down migrate test

help: ## Affiche cette aide
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-12s %s\n", $$1, $$2}'

init: .env secrets ## Prépare .env et le secret (une seule fois)

.env:
	cp .env.example .env

secrets: secrets/db_password.txt ## Génère le mot de passe PostgreSQL s'il n'existe pas

secrets/db_password.txt:
	@mkdir -p secrets
	@umask 022; openssl rand -hex 24 > $@
	@echo "secret généré : $@ (non versionné)"

up: init ## Démarre la stack de dev et attend qu'elle soit saine
	$(DC) up -d --build --wait
	$(DC) ps

down: ## Arrête la stack (les volumes sont conservés)
	$(DC) down

logs: ## Suit les logs
	$(DC) logs -f --tail=50

ps: ## État des services
	$(DC) ps

tools: init ## Démarre adminer (adminer.localhost)
	$(DC) --profile tools up -d --wait adminer

prod-config: init ## Affiche le compose prod résolu
	$(DC_PROD) config

prod-up: init ## Démarre la stack de prod (images du registre)
	$(DC_PROD) up -d --wait
	$(DC_PROD) ps

prod-down: ## Arrête la stack de prod
	$(DC_PROD) down

migrate: init ## Applique une migration : make migrate M=002-add-sku.sql
	@test -n "$(M)" || { echo "Usage : make migrate M=002-add-sku.sql"; exit 2; }
	MIGRATION=$(M) $(DC) run --rm migrate

test: ## Smoke test de la stack démarrée
	./smoke-test.sh
