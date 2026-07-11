.PHONY: help build up down clean ps logs wait smoke bench generate load query cluster read-gradient observe grafana \
        k8s-up k8s-wait k8s-smoke k8s-bench k8s-cluster k8s-read k8s-sweep k8s-observe k8s-ps k8s-down

# ─────────── Kubernetes target (RUNTIME=k8s) ───────────
# Prerequisite: KUBECONFIG pointing at your cluster, and OBJSTORE_SECRET_KEY set
# (object-storage password for RustFS/Mimir; see .env.example).
K8S_NS ?= bench-prom-ch

k8s-up: ## Deploy the stack on Kubernetes (needs OBJSTORE_SECRET_KEY)
	kubectl apply -f k8s/00-namespace.yaml
	kubectl -n $(K8S_NS) create secret generic objstore-creds \
	  --from-literal=access-key="$${OBJSTORE_ACCESS_KEY:-benchuser}" \
	  --from-literal=secret-key="$${OBJSTORE_SECRET_KEY:?set OBJSTORE_SECRET_KEY (see .env.example)}" \
	  --dry-run=client -o yaml | kubectl apply -f -
	kubectl apply -f k8s/
	@$(MAKE) k8s-wait

k8s-wait: ## Wait until ClickHouse, Mimir and TSBS are ready
	kubectl -n $(K8S_NS) rollout status statefulset/chkeeper --timeout=180s
	kubectl -n $(K8S_NS) rollout status statefulset/chnode   --timeout=300s
	kubectl -n $(K8S_NS) rollout status statefulset/mimir    --timeout=300s
	kubectl -n $(K8S_NS) rollout status deployment/tsbs      --timeout=600s
	@echo "ClickHouse cluster:"; kubectl -n $(K8S_NS) exec chnode-0 -- clickhouse-client -q \
	  "SELECT shard_num, replica_num, host_name FROM system.clusters WHERE cluster='bench_cluster' FORMAT PrettyCompact"

k8s-smoke: ## Quick validation bench on k8s
	RUNTIME=k8s SCALE=100 DURATION_HOURS=3 QUERY_COUNT=200 bash scripts/bench_all.sh
k8s-bench: ## Full bench on k8s (parameters from .env)
	RUNTIME=k8s bash scripts/bench_all.sh
k8s-cluster: ## ClickHouse cluster lab on k8s
	RUNTIME=k8s bash scripts/clickhouse_cluster_ops.sh all
k8s-read: ## Mirrored read gradient (Mimir vs ClickHouse) on k8s
	RUNTIME=k8s bash scripts/read_gradient.sh
k8s-sweep: ## Mimir write throughput vs client concurrency on k8s
	RUNTIME=k8s bash scripts/mimir_concurrency_sweep.sh
k8s-observe: ## Maintenance snapshot (CH + Mimir) on k8s
	RUNTIME=k8s bash scripts/observe.sh
k8s-ps: ## Pod status
	kubectl -n $(K8S_NS) get pods -o wide
k8s-down: ## Remove the entire k8s stack (namespace + volumes)
	kubectl delete -f k8s/00-namespace.yaml --wait=false || true


help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

build: ## Build the TSBS image
	docker compose build tsbs

up: ## Start the whole stack (Mimir cluster + ClickHouse cluster + TSBS)
	docker compose up -d
	@$(MAKE) wait

grafana: ## Start Grafana (obs profile) on http://localhost:3000
	docker compose --profile obs up -d grafana

wait: ## Wait until ClickHouse and Mimir are ready
	@echo "Waiting for ClickHouse…"; \
	for i in $$(seq 1 60); do docker compose exec -T chnode1 clickhouse-client -q "SELECT 1" >/dev/null 2>&1 && break || sleep 2; done
	@echo "Waiting for Mimir (via gateway)…"; \
	for i in $$(seq 1 60); do docker compose exec -T tsbs curl -sf http://mimir-gw:9009/ready >/dev/null 2>&1 && break || sleep 2; done
	@echo "ClickHouse cluster:"; docker compose exec -T chnode1 clickhouse-client -q "SELECT host_name, shard_num, replica_num FROM system.clusters WHERE cluster='bench_cluster' FORMAT PrettyCompact"

smoke: ## Quick validation bench (SCALE=100, 3h ~ 1M points)
	SCALE=100 DURATION_HOURS=3 QUERY_COUNT=200 bash scripts/bench_all.sh

bench: ## Full bench (parameters from .env)
	bash scripts/bench_all.sh

generate: ## Generate the dataset only
	bash scripts/01_generate.sh
load: ## Load ClickHouse then Mimir
	bash scripts/02_load_clickhouse.sh && bash scripts/03_load_mimir.sh
query: ## Generate and run the read queries
	bash scripts/04_gen_queries.sh && bash scripts/05_query_clickhouse.sh && bash scripts/06_query_mimir.sh
read-gradient: ## Mirrored read gradient (Mimir vs ClickHouse)
	bash scripts/read_gradient.sh
cluster: ## ClickHouse cluster lab (setup + compaction + rebuild)
	bash scripts/clickhouse_cluster_ops.sh all
observe: ## Snapshot of maintenance operations (CH + Mimir)
	bash scripts/observe.sh

ps: ## Container status
	docker compose ps
logs: ## Follow the logs
	docker compose logs -f --tail=100

down: ## Stop the stack (keep the volumes)
	docker compose --profile obs down

clean: ## Stop and REMOVE volumes + generated data
	docker compose --profile obs down -v
	rm -f data/*.gz results/*.txt
