#!/usr/bin/env bash
# Run the read queries against ClickHouse and measure latency/throughput.
source "$(dirname "$0")/lib.sh"

IN="${DATA_DIR}/queries-ch-${QUERY_TYPE}.gz"
OUT="${RESULTS_DIR}/query_clickhouse-${QUERY_TYPE}.txt"

log "ClickHouse read: $QUERY_TYPE ($QUERY_COUNT queries, workers=$CH_WORKERS)"
# --hosts (plural): comma-separated list (distributed reads possible).
tsbs "zcat '${IN}' | tsbs_run_queries_clickhouse \
  --hosts='${CH_HOST}' --db-name='${CH_DB}' --workers='${CH_WORKERS}' \
  2>&1 | tee '${OUT}'"
log "ClickHouse read complete (see $OUT)."
