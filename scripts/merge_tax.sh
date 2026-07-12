#!/usr/bin/env bash
# ClickHouse "merge tax" under a metrics-like write pattern. A one-shot bulk load
# (large batches) creates few parts and little merging; continuous ingestion of many
# small writes (like scraping) creates many small parts that ClickHouse must merge in
# the background. This loads the SAME slice with a large vs a small batch size and
# reports parts created, merges run, and wall time, to expose that background cost.
#
# Usage: [RUNTIME=k8s] [MERGE_SCALE=2000] [MERGE_HOURS=2] scripts/merge_tax.sh
source "$(dirname "$0")/lib.sh"
DB=bench_merge
SCALE="${MERGE_SCALE:-2000}"; HOURS="${MERGE_HOURS:-2}"

TE="$(tsbs "date -u +%Y-%m-%dT%H:%M:%SZ" | tr -d '\r')"
TS="$(tsbs "date -u -d '-${HOURS} hours' +%Y-%m-%dT%H:%M:%SZ" | tr -d '\r')"
log "Generating slice: scale=$SCALE, ${HOURS}h ($TS -> $TE)"
tsbs "tsbs_generate_data --use-case=cpu-only --seed=7 --scale=$SCALE \
  --timestamp-start='$TS' --timestamp-end='$TE' --log-interval=10s --format=clickhouse \
  | gzip > /workspace/data/merge.dat.gz; ls -lh /workspace/data/merge.dat.gz"

run_batch() {
  local bs="$1"
  node_sql "DROP DATABASE IF EXISTS $DB SYNC" >/dev/null 2>&1
  local t0 t1; t0=$(date +%s)
  local loaded; loaded=$(tsbs "zcat /workspace/data/merge.dat.gz | tsbs_load_clickhouse \
    --host=$CH_HOST --db-name=$DB --do-create-db=true --workers=8 --batch-size=$bs 2>&1 | grep -E 'loaded [0-9].* rows'" | head -1)
  t1=$(date +%s)
  sleep 8   # let a first merge wave run
  local rows parts stats
  rows=$(node_sql "SELECT count() FROM $DB.cpu" | tr -d '[:space:]')
  parts=$(node_sql "SELECT count() FROM system.parts WHERE database='$DB' AND table='cpu' AND active" | tr -d '[:space:]')
  stats=$(node_sql "SELECT countIf(event_type='NewPart') AS new_parts, countIf(event_type='MergeParts') AS merges, round(sumIf(duration_ms, event_type='MergeParts')/1000,1) AS merge_secs FROM system.part_log WHERE database='$DB' AND table='cpu' FORMAT TSV")
  printf 'batch=%-6s wall=%ss rows=%s active_parts=%s | part_log new/merges/merge_secs: %s\n' \
    "$bs" "$((t1 - t0))" "$rows" "$parts" "$stats"
}

log "=== Large batches (one-shot bulk, few parts) ==="
run_batch 10000
log "=== Small batches (continuous/scrape-like, many parts -> heavy merging) ==="
run_batch 200
node_sql "DROP DATABASE IF EXISTS $DB SYNC" >/dev/null 2>&1
