#!/usr/bin/env bash
# Run the PromQL queries against Mimir via the TSBS VictoriaMetrics runner.
# The runner concatenates the base URL + the embedded Path (/api/v1/query_range),
# which yields Mimir's correct PromQL path: .../prometheus/api/v1/query_range.
source "$(dirname "$0")/lib.sh"

IN="${DATA_DIR}/queries-prom-${QUERY_TYPE}.gz"
OUT="${RESULTS_DIR}/query_mimir-${QUERY_TYPE}.txt"

log "Mimir read: $QUERY_TYPE ($QUERY_COUNT queries, workers=$PROM_WORKERS) -> $MIMIR_QUERY_URL"
tsbs "zcat '${IN}' | tsbs_run_queries_victoriametrics \
  --urls='${MIMIR_QUERY_URL}' --workers='${PROM_WORKERS}' \
  2>&1 | tee '${OUT}'"
log "Mimir read complete (see $OUT)."
