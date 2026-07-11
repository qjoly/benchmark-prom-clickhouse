#!/usr/bin/env bash
# Generate the query files (same use-case/scale/range as the data).
# Two formats: clickhouse (SQL) and victoriametrics (PromQL, Mimir-compatible).
source "$(dirname "$0")/lib.sh"
compute_timerange

genq() {
  local fmt="$1" out="$2"
  log "Generating queries format=$fmt type=$QUERY_TYPE count=$QUERY_COUNT -> $out"
  tsbs "tsbs_generate_queries \
    --use-case='${USE_CASE}' --seed='${SEED}' --scale='${SCALE}' \
    --timestamp-start='${TS_START}' --timestamp-end='${TS_END}' \
    --queries='${QUERY_COUNT}' --query-type='${QUERY_TYPE}' \
    --format='${fmt}' | gzip > '${out}'"
}

genq clickhouse      "${DATA_DIR}/queries-ch-${QUERY_TYPE}.gz"
genq victoriametrics "${DATA_DIR}/queries-prom-${QUERY_TYPE}.gz"
log "Query generation complete."
