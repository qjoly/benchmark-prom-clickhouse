#!/usr/bin/env bash
# Load the dataset into the Mimir cluster via remote_write (TSBS adapter).
# Distribution/replication (RF=3) and MinIO storage are handled by Mimir.
source "$(dirname "$0")/lib.sh"

IN="${DATA_DIR}/${USE_CASE}-prom.dat.gz"
OUT="${RESULTS_DIR}/load_mimir.txt"

log "Loading Mimir from $IN -> $MIMIR_WRITE_URL (workers=$PROM_WORKERS)"
# --adapter-write-url: remote_write endpoint (protobuf snappy). /api/v1/push on Mimir.
# The timestamps stay those of the dataset (anchored on "now" by 01_generate.sh),
# so within Mimir's out_of_order_time_window. Otherwise: --use-current-time.
tsbs "zcat '${IN}' | tsbs_load_prometheus \
  --adapter-write-url='${MIMIR_WRITE_URL}' \
  --workers='${PROM_WORKERS}' --batch-size='${PROM_BATCH_SIZE}' \
  2>&1 | tee '${OUT}'"

log "Mimir load complete (see $OUT)."
