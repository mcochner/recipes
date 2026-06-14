# Run the recipes locally with a single command.
#
#   make                       list everything you can run
#   make cluster-up            ensure a local Kubernetes cluster exists
#   make k8s-owner-references  run the owner-references recipe end-to-end
#   make k8s-owner-references STEP=1   step through it one command at a time
#   make cluster-down          tear down the local kind cluster
#
# Add STEP=1 to any recipe target to run it interactively (press a key per step).

.DEFAULT_GOAL := help
SHELL := bash

# STEP=1  -> run recipes interactively, one command per keypress.
# FRESH=1 -> discard saved state before running.
STEP ?=
FRESH ?=
RUN_FLAGS := $(if $(filter 1 yes true,$(STEP)),--step,) \
             $(if $(filter 1 yes true,$(FRESH)),--fresh,)

.PHONY: help cluster-up cluster-down k8s-owner-references k8s-block-owner-deletion k8s-finalizers k8s-reconcile-observer

help: ## List available recipes and commands
	@echo "Recipes you can run locally:"
	@echo
	@grep -E '^[a-zA-Z0-9_-]+:.*## ' $(MAKEFILE_LIST) \
		| sed -E 's/^([a-zA-Z0-9_-]+):.*## /  make \1\t/' \
		| expand -t28

cluster-up: ## Ensure a local Kubernetes cluster is available (creates a kind cluster if needed)
	@scripts/cluster-up.sh

cluster-down: ## Delete the local kind cluster created by 'make cluster-up'
	@scripts/cluster-down.sh

k8s-owner-references: cluster-up ## Run kubernetes/owner-references.md end-to-end (add STEP=1 to step through it)
	@scripts/run-recipe.sh $(RUN_FLAGS) kubernetes/owner-references.md

k8s-block-owner-deletion: cluster-up ## Run kubernetes/block-owner-deletion.md end-to-end (add STEP=1 to step through it)
	@scripts/run-recipe.sh $(RUN_FLAGS) kubernetes/block-owner-deletion.md

k8s-finalizers: cluster-up ## Run kubernetes/finalizers.md end-to-end (add STEP=1 to step through it)
	@scripts/run-recipe.sh $(RUN_FLAGS) kubernetes/finalizers.md

k8s-reconcile-observer: cluster-up ## Run kubernetes/controllers-and-reconcile.md end-to-end (needs Go; add STEP=1 to step through it)
	@scripts/run-recipe.sh $(RUN_FLAGS) kubernetes/controllers-and-reconcile.md
