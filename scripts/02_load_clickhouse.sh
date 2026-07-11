#!/usr/bin/env bash
# Load the dataset into ClickHouse (chnode1). TSBS creates its single-node schema
# (MergeTree). Here we measure the raw ingestion throughput.
source "$(dirname "$0")/lib.sh"

IN="${DATA_DIR}/${USE_CASE}-ch.dat.gz"
OUT="${RESULTS_DIR}/load_clickhouse.txt"

log "Loading ClickHouse from $IN (host=$CH_HOST db=$CH_DB workers=$CH_WORKERS)"
# NB: the ClickHouse loader connects to native port 9000 (no --port flag).
tsbs "zcat '${IN}' | tsbs_load_clickhouse \
  --host='${CH_HOST}' --db-name='${CH_DB}' \
  --workers='${CH_WORKERS}' --batch-size='${CH_BATCH_SIZE}' \
  --do-create-db=true --do-abort-on-exist=false \
  2>&1 | tee '${OUT}'"

log "ClickHouse storage summary:"
chq "SELECT table, formatReadableSize(sum(bytes_on_disk)) AS disk,
            formatReadableSize(sum(data_uncompressed_bytes)) AS uncompressed,
            round(sum(data_uncompressed_bytes)/sum(bytes_on_disk),2) AS ratio,
            sum(rows) AS rows
     FROM system.parts WHERE database='${CH_DB}' AND active
     GROUP BY table ORDER BY table FORMAT PrettyCompact" \
  || true
log "ClickHouse load complete (see $OUT)."
