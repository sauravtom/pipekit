COMPOSE ?= docker compose
RAW := -f docker-compose.yml -f docker-compose.raw-pcm.yml
CPU := -f docker-compose.yml -f docker-compose.cpu.yml
HOST ?= localhost
PORT ?= 8765

.PHONY: help up up-raw up-cpu down down-cpu logs logs-llm ps pool usage smoke build build-cpu preflight lint

help:
	@grep -E '^[a-z-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

lint: ## Lint the compose files (same checks as CI)
	./scripts/lint-compose.sh

preflight: ## Verify GPU, Docker and NVIDIA container runtime
	./scripts/bootstrap-ec2.sh

build: ## Build the pipeline image (GPU)
	$(COMPOSE) build

build-cpu: ## Build the CPU image
	$(COMPOSE) $(CPU) build

up: ## Start PipeKit (GPU, OpenAI Realtime protocol)
	$(COMPOSE) up -d

up-raw: ## Start PipeKit (GPU, raw PCM websocket)
	$(COMPOSE) $(RAW) up -d

up-cpu: ## Start PipeKit (CPU dev/fallback profile — slow)
	$(COMPOSE) $(CPU) up -d

down: ## Stop everything
	$(COMPOSE) down

down-cpu: ## Stop the CPU profile
	$(COMPOSE) $(CPU) down

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
