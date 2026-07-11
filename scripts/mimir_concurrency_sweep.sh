#!/usr/bin/env bash
# Answers: does more client concurrency raise Mimir write throughput, or is the
# server/node the bottleneck? Runs short timed remote_write loads at increasing
# worker counts (a single tsbs_load_prometheus process, --workers = concurrent
# streams; equivalent to N clients for throughput purposes) and records the
# steady-state rate plus the time window (to correlate CPU via SigNoz).
#
# Usage: [RUNTIME=k8s] [SWEEP_WORKERS="8 16 32 48"] [SWEEP_DURATION=90] scripts/mimir_concurrency_sweep.sh
source "$(dirname "$0")/lib.sh"

DUR="${SWEEP_DURATION:-90}"
WORKERS_LIST="${SWEEP_WORKERS:-8 16 32 48}"
OUT="${RESULTS_DIR}/mimir_concurrency_sweep.tsv"
tsbs "printf 'workers\tepoch_start\tepoch_end\toverall_samples_per_s\n' > '${OUT}'"

for W in $WORKERS_LIST; do
  log "Mimir concurrency sweep: workers=${W} for ${DUR}s"
  # Run for DUR seconds (timeout stops it), keep the last 'overall metric/s' value.
  tsbs "S=\$(date +%s); \
    rate=\$(timeout ${DUR} bash -c \"zcat ${DATA_DIR}/${USE_CASE}-prom.dat.gz | tsbs_load_prometheus \
      --adapter-write-url=${MIMIR_WRITE_URL} --use-current-time --workers=${W} --batch-size=10000\" 2>/dev/null \
      | awk -F, 'NF>=4 && \$4+0>0 {r=\$4} END{print r+0}'); \
    E=\$(date +%s); \
    printf '%s\t%s\t%s\t%s\n' '${W}' \"\$S\" \"\$E\" \"\$rate\" | tee -a '${OUT}'"
done

log "Sweep done. Table:"
tsbs "cat '${OUT}'"
log "Correlate CPU per window with SigNoz (k8s.pod.cpu.usage, group by pod) using the epoch columns above."
