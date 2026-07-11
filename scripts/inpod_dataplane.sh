#!/usr/bin/env bash
# STANDALONE runner executed INSIDE the tsbs pod (no docker/kubectl).
# Designed to be launched detached (setsid/nohup) so it survives kubectl exec
# disconnections during the long steps (generation + 1 Bn ingestion).
#
# Runs in sequence: (wait/validate generation) -> load ClickHouse -> load Mimir
#            -> query generation -> CH read -> Mimir read.
# The ClickHouse cluster lab is launched separately from the laptop (needs kubectl).
set -uo pipefail

: "${USE_CASE:=cpu-only}"; : "${SEED:=123}"; : "${SCALE:=10000}"
: "${LOG_INTERVAL:=10s}"; : "${DURATION_HOURS:=30}"
: "${CH_HOST:=chnode-0.chnode}"; : "${CH_DB:=benchmark}"
: "${CH_WORKERS:=8}"; : "${CH_BATCH_SIZE:=10000}"
: "${PROM_WORKERS:=8}"; : "${PROM_BATCH_SIZE:=10000}"
: "${MIMIR_WRITE_URL:=http://mimir:9009/api/v1/push}"
: "${MIMIR_QUERY_URL:=http://mimir:9009/prometheus}"
: "${QUERY_TYPE:=single-groupby-1-1-1}"; : "${QUERY_COUNT:=1000}"
: "${TS_START:=}"; : "${TS_END:=}"

D=/workspace/data; R=/workspace/results
mkdir -p "$D" "$R"
PHASES="$R/phase_windows.tsv"    # phase<TAB>epoch_start  (to correlate with SigNoz)
log() { printf '[%s] %s\n' "$(date -u +%H:%M:%SZ)" "$*"; }
phase() { printf '%s\t%s\n' "$(date +%s)000" "$*" >> "$PHASES"; log "############ $* ############"; }

CH_FILE="$D/${USE_CASE}-ch.dat.gz"
PROM_FILE="$D/${USE_CASE}-prom.dat.gz"

# 1) Wait for any generation already in progress (started earlier) to finish.
#    NB: pgrep -f (the Linux process name is truncated to 15 chars, -x would fail).
while pgrep -f 'tsbs_generate_data ' >/dev/null 2>&1; do
  log "generation already in progress ($(ls -lh "$PROM_FILE" 2>/dev/null | awk '{print $5}'))... waiting"
  sleep 15
done

# Time range (identical for CH and Prom).
if [ -z "$TS_START" ] || [ -z "$TS_END" ]; then
  TS_END="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  TS_START="$(date -u -d "-${DURATION_HOURS} hours" +%Y-%m-%dT%H:%M:%SZ)"
fi
log "Range: $TS_START -> $TS_END (scale=$SCALE)"

gen_if_needed() {
  local fmt="$1" out="$2"
  if gzip -t "$out" 2>/dev/null; then log "OK (intact, reusing): $out"; return; fi
  log "Generating format=$fmt -> $out"
  tsbs_generate_data --use-case="$USE_CASE" --seed="$SEED" --scale="$SCALE" \
    --timestamp-start="$TS_START" --timestamp-end="$TS_END" \
    --log-interval="$LOG_INTERVAL" --format="$fmt" | gzip > "$out"
}

phase "Dataset generation / validation"
gen_if_needed clickhouse  "$CH_FILE"
gen_if_needed prometheus  "$PROM_FILE"

phase "ClickHouse write"
zcat "$CH_FILE" | tsbs_load_clickhouse --host="$CH_HOST" --db-name="$CH_DB" \
  --workers="$CH_WORKERS" --batch-size="$CH_BATCH_SIZE" --do-create-db=true 2>&1 | tee "$R/load_clickhouse.txt"

phase "Mimir write"
zcat "$PROM_FILE" | tsbs_load_prometheus --adapter-write-url="$MIMIR_WRITE_URL" \
  --workers="$PROM_WORKERS" --batch-size="$PROM_BATCH_SIZE" 2>&1 | tee "$R/load_mimir.txt"

phase "Query generation"
tsbs_generate_queries --use-case="$USE_CASE" --seed="$SEED" --scale="$SCALE" \
  --timestamp-start="$TS_START" --timestamp-end="$TS_END" \
  --queries="$QUERY_COUNT" --query-type="$QUERY_TYPE" --format=clickhouse \
  | gzip > "$D/queries-ch-${QUERY_TYPE}.gz"
tsbs_generate_queries --use-case="$USE_CASE" --seed="$SEED" --scale="$SCALE" \
  --timestamp-start="$TS_START" --timestamp-end="$TS_END" \
  --queries="$QUERY_COUNT" --query-type="$QUERY_TYPE" --format=victoriametrics \
  | gzip > "$D/queries-prom-${QUERY_TYPE}.gz"

phase "ClickHouse read"
zcat "$D/queries-ch-${QUERY_TYPE}.gz" | tsbs_run_queries_clickhouse \
  --hosts="$CH_HOST" --db-name="$CH_DB" --workers="$CH_WORKERS" 2>&1 | tee "$R/query_clickhouse-${QUERY_TYPE}.txt"

phase "Mimir read"
zcat "$D/queries-prom-${QUERY_TYPE}.gz" | tsbs_run_queries_victoriametrics \
  --urls="$MIMIR_QUERY_URL" --workers="$PROM_WORKERS" 2>&1 | tee "$R/query_mimir-${QUERY_TYPE}.txt"

phase "DATA PLANE COMPLETE"
