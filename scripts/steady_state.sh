#!/usr/bin/env bash
# Steady-state continuous ingestion: load the ClickHouse dataset with SMALL batches
# (scrape-like), sampling active parts and running merges over time, to show whether
# ClickHouse keeps pace (bounded parts) under a continuous small-write pattern and at
# what background-merge cost. Contrast with the one-shot bulk load.
#
# Runs the load + sampling inside the tsbs pod (queries ClickHouse over HTTP :8123),
# detached, then prints the time series and the merge totals.
#
# Usage: [RUNTIME=k8s] [STEADY_BATCH=200] scripts/steady_state.sh
source "$(dirname "$0")/lib.sh"
BATCH="${STEADY_BATCH:-200}"
CH_HTTP="http://${CH_HOST}:8123"

tsbs "cat > /workspace/steady.sh <<'EOS'
#!/usr/bin/env bash
CH=${CH_HTTP}; DB=bench_steady; R=/workspace/results
q(){ curl -s \"\$CH/\" --data-binary \"\$1\"; }
rm -f \$R/steady_done \$R/steady.tsv \$R/steady_merges.txt
q \"DROP DATABASE IF EXISTS \$DB SYNC\" >/dev/null 2>&1
( zcat ${DATA_DIR}/${USE_CASE}-ch.dat.gz | tsbs_load_clickhouse --host=${CH_HOST} --db-name=\$DB --do-create-db=true --workers=8 --batch-size=${BATCH} > \$R/steady_load.txt 2>&1; echo DONE > \$R/steady_done ) &
printf 't_s\tactive_parts\trunning_merges\trows_M\n' > \$R/steady.tsv
t0=\$(date +%s)
while [ ! -f \$R/steady_done ]; do
  ap=\$(q \"SELECT count() FROM system.parts WHERE database='\$DB' AND active\" | tr -d '[:space:]')
  rmg=\$(q \"SELECT count() FROM system.merges WHERE database='\$DB'\" | tr -d '[:space:]')
  rw=\$(q \"SELECT round(sum(rows)/1e6,1) FROM system.parts WHERE database='\$DB' AND active\" | tr -d '[:space:]')
  printf '%s\t%s\t%s\t%s\n' \"\$((\$(date +%s)-t0))\" \"\${ap:-0}\" \"\${rmg:-0}\" \"\${rw:-0}\" >> \$R/steady.tsv
  sleep 20
done
q \"SELECT countIf(event_type='NewPart') new, countIf(event_type='MergeParts') merges, round(sumIf(duration_ms,event_type='MergeParts')/1000,1) merge_s FROM system.part_log WHERE database='\$DB' FORMAT TSV\" > \$R/steady_merges.txt 2>&1
echo 'STEADY DONE' >> \$R/steady.tsv
EOS"
tsbs "setsid bash /workspace/steady.sh >/dev/null 2>&1 </dev/null & disown; true"
log "Continuous load started (batch=${BATCH}). Sampling; this runs until the full dataset is loaded."
while ! tsbs "grep -q 'STEADY DONE' /workspace/results/steady.tsv 2>/dev/null && echo y" | grep -q y; do sleep 30; done
log "Done. Time series:"
tsbs "cat /workspace/results/steady.tsv"
log "loaded / merge totals (new parts, merges, merge core-seconds):"
tsbs "grep -E 'loaded' /workspace/results/steady_load.txt; cat /workspace/results/steady_merges.txt"
