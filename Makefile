# ----------------------------------------------------------------------------
# Demo PostgreSQL HA on AKS (CNPG) — Makefile
# All targets are idempotent and read variables from `.env`.
# Usage: cp .env.example .env && make all
# ----------------------------------------------------------------------------

SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c

# Windows: auto-detect Git Bash if /bin/bash is unavailable (e.g., running from PowerShell/cmd).
# Use the 8.3 short path to avoid GNU Make issues with spaces in SHELL.
ifeq ($(OS),Windows_NT)
  ifneq (,$(wildcard C:/PROGRA~1/Git/bin/bash.exe))
    SHELL := C:/PROGRA~1/Git/bin/bash.exe
  else ifneq (,$(wildcard C:/PROGRA~2/Git/bin/bash.exe))
    SHELL := C:/PROGRA~2/Git/bin/bash.exe
  endif
endif

.DEFAULT_GOAL := help

ENV_FILE ?= .env

# Load .env if it exists (silent ignore otherwise so `make help` works)
ifneq (,$(wildcard $(ENV_FILE)))
include $(ENV_FILE)
export
endif

.PHONY: help all prereqs infra infra-secondary cnpg cluster \
        cnpg-secondary cluster-secondary \
        demo-failover demo-backup demo-perf demo-cross-cluster demo-interop \
        demo-connect demo-connect-forward \
        stop start clean

help: ## Show available targets
	@echo "Demo CNPG PoC — make targets"
	@echo "================================"
	@grep -hE '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}'

all: prereqs infra cnpg cluster ## Run prereqs + infra + cnpg + cluster end-to-end

prereqs: ## Check local CLI versions (az, kubectl, helm, jq, krew, cnpg)
	@bash scripts/00-prereqs.sh

infra: ## Deploy primary AKS multi-zone + Storage Account via Bicep
	@bash infra/deploy.sh

infra-secondary: ## Deploy secondary AKS (replica cluster demo) — run after infra
	@bash infra/deploy-secondary.sh

cnpg: ## Install CNPG 1.28 operator on PRIMARY cluster
	@bash scripts/01-bootstrap.sh cnpg

cluster: ## Apply Cluster CR + Pooler + backup + monitoring on PRIMARY cluster
	@bash scripts/01-bootstrap.sh cluster

cnpg-secondary: ## Install CNPG 1.28 operator on SECONDARY cluster
	@kubectl config use-context $(SECONDARY_AKS_NAME) && \
	 bash scripts/01-bootstrap.sh cnpg

cluster-secondary: ## Bootstrap replica cluster on secondary (runs setup phase)
	@bash scripts/13-demo-cross-cluster.sh setup

demo-failover: ## Kill primary pod and measure cross-AZ RTO
	@bash scripts/10-demo-failover.sh

demo-backup: ## Trigger on-demand backup and restore as new cluster (PITR)
	@bash scripts/11-demo-backup.sh

demo-perf: ## Run pgbench inside the cluster (init scale 50, 60s, 16 clients)
	@bash scripts/12-demo-perf.sh

demo-cross-cluster: ## Live demo: streaming replication + promote replica cluster
	@bash scripts/13-demo-cross-cluster.sh demo

demo-interop: ## Live demo: bidirectional pg_dump/pg_restore Flex <-> CNPG
	@bash scripts/14-demo-interop-bidir.sh demo

demo-connect: ## Print connection params (host/user/pass/db) + port-forward command for external clients (VS Code/psql/DBeaver). Default svc=rw; override: TARGET=ro|r|pooler
	@bash scripts/15-demo-connect.sh $(TARGET)

demo-connect-forward: ## Same as demo-connect but ALSO starts the port-forward in this shell (Ctrl+C to stop)
	@bash scripts/15-demo-connect.sh $(TARGET) --forward

stop: ## Stop both AKS clusters to save cost (~€2/day vs €17/day running)
	@echo "Stopping $(AKS_NAME)..."
	@az aks stop -g $(RG_NAME) -n $(AKS_NAME) --subscription $(SUBSCRIPTION_ID) --no-wait
	@echo "Stopping $(SECONDARY_AKS_NAME)..."
	@az aks stop -g $(RG_NAME) -n $(SECONDARY_AKS_NAME) --subscription $(SUBSCRIPTION_ID) --no-wait
	@echo "Both stopping. Check: az aks show -g $(RG_NAME) -n $(AKS_NAME) --query powerState"

start: ## Start both AKS clusters (~1.5h before demo/rehearsal)
	@echo "Starting $(AKS_NAME)..."
	@az aks start -g $(RG_NAME) -n $(AKS_NAME) --subscription $(SUBSCRIPTION_ID) --no-wait
	@echo "Starting $(SECONDARY_AKS_NAME)..."
	@az aks start -g $(RG_NAME) -n $(SECONDARY_AKS_NAME) --subscription $(SUBSCRIPTION_ID) --no-wait
	@echo "Both starting (~5-10 min). Watch: az aks show -g $(RG_NAME) -n $(AKS_NAME) --query powerState"

clean: ## Delete the entire resource group (irreversible)
	@bash scripts/99-cleanup.sh
