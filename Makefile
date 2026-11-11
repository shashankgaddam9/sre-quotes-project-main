IMAGE ?= quotes-api
TAG   ?= $(shell git rev-parse --short HEAD 2>/dev/null || echo local)
CLUSTER = sre-lab

.PHONY: help test compose-up compose-down cluster argocd build deploy-local smoke load \
        grafana prometheus alertmanager status logs rollback destroy

help:            ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk -F':.*?## ' '{printf "  %-15s %s\n", $$1, $$2}'

test:            ## Run lint + unit tests
	cd app && pip install -q -r requirements-dev.txt && ruff check . && pytest -v

compose-up:      ## Phase 1: run app+redis+prometheus+grafana with Docker Compose
	docker compose up --build -d
	@echo "API http://localhost:8080 | Prometheus http://localhost:9090 | Grafana http://localhost:3000"

compose-down:    ## Stop Docker Compose stack
	docker compose down -v

cluster:         ## Phase 3: create kind cluster + ingress + monitoring
	./scripts/setup-cluster.sh

argocd:          ## Phase 5: install Argo CD
	./scripts/install-argocd.sh

build:           ## Build the container image
	docker build --build-arg APP_VERSION=$(TAG) -t $(IMAGE):$(TAG) app

deploy-local: build  ## Build, load into kind, deploy production overlay
	kind load docker-image $(IMAGE):$(TAG) --name $(CLUSTER)
	kubectl apply -k k8s/overlays/production
	kubectl -n quotes set image deployment/quotes-api api=$(IMAGE):$(TAG)
	kubectl -n quotes rollout status deployment/quotes-api --timeout=180s

smoke:           ## Run smoke tests against the ingress
	./scripts/smoke-test.sh http://quotes.localhost

load:            ## Generate 2 minutes of traffic
	./scripts/load-test.sh http://quotes.localhost 120 20

grafana:         ## Open Grafana on localhost:3000 (admin/admin)
	kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80

prometheus:      ## Open Prometheus on localhost:9090
	kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090

alertmanager:    ## Open Alertmanager on localhost:9093
	kubectl -n monitoring port-forward svc/kube-prometheus-stack-alertmanager 9093:9093

status:          ## Show what's running
	kubectl -n quotes get deploy,sts,pods,svc,hpa,pdb,ingress -o wide

logs:            ## Tail API logs
	kubectl -n quotes logs -l app=quotes-api -f --max-log-requests=10

rollback:        ## Roll back the last deployment
	kubectl -n quotes rollout undo deployment/quotes-api
	kubectl -n quotes rollout status deployment/quotes-api

destroy:         ## Delete the kind cluster
	kind delete cluster --name $(CLUSTER)
