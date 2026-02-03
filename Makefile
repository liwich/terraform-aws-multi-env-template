SHELL := /bin/bash
TF := ./scripts/tf
STACK ?= storage
ENV ?= dev

dev-plan:
	$(TF) env=dev stack=$(STACK) plan

dev-apply:
	$(TF) env=dev stack=$(STACK) apply

stage-plan:
	$(TF) env=stage stack=$(STACK) plan

stage-apply:
	$(TF) env=stage stack=$(STACK) apply

prod-plan:
	$(TF) env=prod stack=$(STACK) plan

prod-apply:
	$(TF) env=prod stack=$(STACK) apply

fmt:
	$(TF) fmt

validate:
	$(TF) env=$(ENV) stack=$(STACK) validate

lint:
	$(TF) env=$(ENV) stack=$(STACK) lint

sec:
	$(TF) env=$(ENV) stack=$(STACK) sec
