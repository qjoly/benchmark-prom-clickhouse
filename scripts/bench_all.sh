#!/usr/bin/env bash
# Run the full benchmark end to end: generation -> write -> read (both
# systems) then ClickHouse cluster operations lab. Results in ./results.
source "$(dirname "$0")/lib.sh"
here="$(dirname "$0")"

log "############ 1/6  Dataset generation ############"
bash "$here/01_generate.sh"

log "############ 2/6  ClickHouse write ############"
bash "$here/02_load_clickhouse.sh"

log "############ 3/6  Mimir write ############"
bash "$here/03_load_mimir.sh"

log "############ 4/6  Query generation ############"
bash "$here/04_gen_queries.sh"

log "############ 5/7  Read - ClickHouse (TSBS) ############"
bash "$here/05_query_clickhouse.sh"
# NB: 06_query_mimir.sh uses TSBS victoriametrics queries (metric names cpu_usage_*),
# which do NOT match what tsbs_load_prometheus stores (usage_*) -> empty results.
# It is kept for reference only; the authoritative cross-engine read comparison is
# the mirrored gradient below (correct names, same semantics on both engines).
bash "$here/06_query_mimir.sh" || true

log "############ 6/7  Read - mirrored gradient (Mimir vs ClickHouse) ############"
bash "$here/read_gradient.sh"

log "############ 7/7  ClickHouse cluster operations ############"
bash "$here/clickhouse_cluster_ops.sh" all

log "Done. Compare the throughputs/latencies in ./results:"
$DC exec -T tsbs bash -lc "ls -1 ${RESULTS_DIR}" || true
