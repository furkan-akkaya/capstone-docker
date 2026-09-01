.DEFAULT_GOAL := help
CLUSTER := capstone

.PHONY: help
help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

## ─── Docker Compose (stage 1) ────────────────────────────────────────────────
.PHONY: compose-up compose-down
compose-up: ## Run the hardened Docker Compose stack
	docker compose up -d --build

compose-down: ## Stop the Docker Compose stack
	docker compose down

## ─── Kubernetes (stage 2) ────────────────────────────────────────────────────
.PHONY: build validate render kind-up deploy-dev deploy-prod verify kind-down
build: ## Build the API image
	docker build -t capstone-api:latest ./api

validate: ## Validate manifests offline (needs kubeconform)
	kubectl kustomize k8s/overlays/dev  | kubeconform -strict -summary -ignore-missing-schemas
	kubectl kustomize k8s/overlays/prod | kubeconform -strict -summary -ignore-missing-schemas

render: ## Print the fully-rendered dev manifests
	kubectl kustomize k8s/overlays/dev

kind-up: ## Create a local kind cluster and deploy the dev overlay
	./scripts/bootstrap-kind.sh

deploy-dev: ## Apply the dev overlay to the current kube-context
	kubectl apply -k k8s/overlays/dev

deploy-prod: ## Apply the prod overlay to the current kube-context
	kubectl apply -k k8s/overlays/prod

verify: ## Smoke-test the deployed stack through the ingress
	curl -fsS -H 'Host: capstone.local' http://localhost:8080/health && echo
	curl -fsS -H 'Host: capstone.local' http://localhost:8080/ && echo
	curl -fsS -H 'Host: capstone.local' http://localhost:8080/db-check && echo

kind-down: ## Delete the local kind cluster
	./scripts/teardown-kind.sh
