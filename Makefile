SHELL := /bin/bash

.PHONY: new plan deploy apply destroy destroy-all base-plan base-deploy base-apply base-destroy-all help

help:
	@echo "Scenario lifecycle:"
	@echo "  make new DOMAIN=domain-N-slug NAME=scenario-slug"
	@echo "  make apply LAB=domain-N-slug/scenario-slug   # plan + auto-execute (pauses if cost-flagged)"
	@echo "  make plan LAB=domain-N-slug/scenario-slug    # plan only"
	@echo "  make deploy LAB=domain-N-slug/scenario-slug  # execute a pending plan"
	@echo "  make destroy LAB=domain-N-slug/scenario-slug"
	@echo "  make destroy-all"
	@echo ""
	@echo "Base stacks (network, iam-baseline, logging-baseline):"
	@echo "  make base-apply NAME=network   # plan + auto-execute (pauses if cost-flagged)"
	@echo "  make base-plan NAME=network"
	@echo "  make base-deploy NAME=network"
	@echo "  make base-destroy-all"

new:
	@scripts/lab-new.sh "$(DOMAIN)" "$(NAME)"

apply:
	@scripts/lab-apply.sh "$(LAB)"

plan:
	@scripts/lab-plan.sh "$(LAB)"

deploy:
	@scripts/lab-deploy.sh "$(LAB)"

destroy:
	@scripts/lab-destroy.sh "$(LAB)"

destroy-all:
	@scripts/lab-destroy-all.sh

base-apply:
	@scripts/base-apply.sh "$(NAME)"

base-plan:
	@scripts/base-plan.sh "$(NAME)"

base-deploy:
	@scripts/base-deploy.sh "$(NAME)"

base-destroy-all:
	@scripts/base-destroy-all.sh
