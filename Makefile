COMPOSE ?= docker compose
RAW := -f docker-compose.yml -f docker-compose.raw-pcm.yml
HOST ?= localhost
PORT ?= 8765

.PHONY: help up up-raw down logs logs-llm ps pool usage smoke build preflight

help:
	@grep -E '^[a-z-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

preflight: ## Verify GPU, Docker and NVIDIA container runtime
	./scripts/bootstrap-ec2.sh

build: ## Build the pipeline image
	$(COMPOSE) build

up: ## Start PipeKit (OpenAI Realtime protocol)
	$(COMPOSE) up -d

up-raw: ## Start PipeKit (raw PCM websocket)
	$(COMPOSE) $(RAW) up -d

down: ## Stop everything
	$(COMPOSE) down

logs: ## Follow pipeline logs
	$(COMPOSE) logs -f pipekit-core

logs-llm: ## Follow LLM logs
	$(COMPOSE) logs -f llm-engine

ps: ## Show service status
	$(COMPOSE) ps

pool: ## Pipeline pool occupancy
	@curl -s http://$(HOST):$(PORT)/v1/pool | python3 -m json.tool

usage: ## Aggregate usage counters
	@curl -s http://$(HOST):$(PORT)/v1/usage | python3 -m json.tool

smoke: ## Connect and verify a session (add AUDIO=file.wav for a full turn)
	python3 scripts/smoke_test.py --host $(HOST) --port $(PORT) $(if $(AUDIO),--audio $(AUDIO),)
