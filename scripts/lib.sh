#!/usr/bin/env bash
# Common library: loaded by every script (source scripts/lib.sh).
# The scripts run from the HOST and drive execution either through
# docker compose (RUNTIME=docker, default) or through kubectl (RUNTIME=k8s).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# Load the parameters from .env WITHOUT overwriting variables already present
# in the environment (allows command-line overrides: SCALE=100 make ...).
if [ -f .env ]; then
  while IFS= read -r line; do
    case "$line" in ''|\#*) continue ;; esac
    key=${line%%=*}
    [ -z "${!key+x}" ] && export "$line"
  done < .env
fi

: "${USE_CASE:=cpu-only}"
: "${SEED:=123}"
: "${SCALE:=10000}"
: "${LOG_INTERVAL:=10s}"
: "${DURATION_HOURS:=30}"
: "${CH_PORT:=9000}"; : "${CH_DB:=benchmark}"
: "${CH_WORKERS:=8}"; : "${CH_BATCH_SIZE:=10000}"
: "${PROM_WORKERS:=8}"; : "${PROM_BATCH_SIZE:=10000}"
: "${QUERY_TYPE:=single-groupby-1-1-1}"; : "${QUERY_COUNT:=1000}"

DATA_DIR="/workspace/data"        # path as seen from the tsbs container/pod
RESULTS_DIR="/workspace/results"

DC="docker compose"
RUNTIME="${RUNTIME:-docker}"

# ─── Runtime-specific topology ──────────────────────────────────────────────
if [ "$RUNTIME" = "k8s" ]; then
  : "${K8S_NS:=bench-prom-ch}"
  # Cluster-internal network targets (k8s services).
  CH_HOST="chnode-0.chnode"                       # ClickHouse loader target (DNS)
  MIMIR_BASE="http://mimir:9009"
  MIMIR_WRITE_URL="${MIMIR_BASE}/api/v1/push"
  MIMIR_QUERY_URL="${MIMIR_BASE}/prometheus"
  # ClickHouse pod names (StatefulSet chnode-0..3) for kubectl exec.
  CH_PRIMARY_NODE="chnode-0"
  CH_ALL_NODES="chnode-0 chnode-1 chnode-2 chnode-3"
  : "${REBUILD_VICTIM:=chnode-1}"                 # replica of the same shard as chnode-0
else
  : "${CH_HOST:=chnode1}"
  MIMIR_BASE="http://mimir-gw:9009"
  : "${MIMIR_WRITE_URL:=${MIMIR_BASE}/api/v1/push}"
  : "${MIMIR_QUERY_URL:=${MIMIR_BASE}/prometheus}"
  CH_PRIMARY_NODE="chnode1"
  CH_ALL_NODES="chnode1 chnode2 chnode3 chnode4"
  : "${REBUILD_VICTIM:=chnode2}"
fi

# Helpers -------------------------------------------------------------------
log()  { printf '\033[1;36m[%s]\033[0m %s\n' "$(date -u +%H:%M:%S)" "$*"; }

_k8s_tsbs_pod() { kubectl -n "$K8S_NS" get pod -l app=tsbs -o jsonpath='{.items[0].metadata.name}'; }

# Run a shell command inside the tsbs container/pod (TSBS binaries + curl + zcat).
tsbs() {
  if [ "$RUNTIME" = "k8s" ]; then
    kubectl -n "$K8S_NS" exec -i "$(_k8s_tsbs_pod)" -- bash -lc "$*"
  else
    $DC exec -T tsbs bash -lc "$*"
  fi
}

# clickhouse-client query on a node (docker container name or k8s pod name).
# $1 = query ; $2 = node (default: primary node).
node_sql() {
  local node="${2:-$CH_PRIMARY_NODE}"
  if [ "$RUNTIME" = "k8s" ]; then
    kubectl -n "$K8S_NS" exec -i "$node" -- clickhouse-client -q "$1"
  else
    $DC exec -T "$node" clickhouse-client -q "$1"
  fi
}
# Legacy alias.
chq() { node_sql "$1" "${2:-$CH_PRIMARY_NODE}"; }

# Compute the time range. Anchored on "now" (UTC) unless explicitly overridden
# via TS_START/TS_END in .env - required for Mimir to accept the backfill.
compute_timerange() {
  if [ -n "${TS_START:-}" ] && [ -n "${TS_END:-}" ]; then
    export TS_START TS_END
  else
    TS_END="$(tsbs "date -u +%Y-%m-%dT%H:%M:%SZ" | tr -d '\r')"
    TS_START="$(tsbs "date -u -d '-${DURATION_HOURS} hours' +%Y-%m-%dT%H:%M:%SZ" | tr -d '\r')"
    export TS_START TS_END
  fi
  log "Time range: $TS_START -> $TS_END  (scale=$SCALE, interval=$LOG_INTERVAL)"
}
