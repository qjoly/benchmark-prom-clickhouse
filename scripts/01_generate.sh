#!/usr/bin/env bash
# Generate the TSBS dataset twice (same seed/scale/range): one serialization
# for ClickHouse, one for Prometheus/Mimir. Gzipped output in ./data.
source "$(dirname "$0")/lib.sh"
compute_timerange fresh   # anchor a new range on "now" and persist it for 04_gen_queries.sh

gen() {
  local fmt="$1" out="$2"
  log "Generating format=$fmt -> $out"
  tsbs "tsbs_generate_data \
    --use-case='${USE_CASE}' --seed='${SEED}' --scale='${SCALE}' \
    --timestamp-start='${TS_START}' --timestamp-end='${TS_END}' \
    --log-interval='${LOG_INTERVAL}' --format='${fmt}' \
    | gzip > '${out}'"
  tsbs "ls -lh '${out}'"
}

gen clickhouse "${DATA_DIR}/${USE_CASE}-ch.dat.gz"
gen prometheus "${DATA_DIR}/${USE_CASE}-prom.dat.gz"
log "Generation complete."
