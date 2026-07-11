#!/usr/bin/env bash
# Snapshot of the maintenance operations of both systems.
# Handy to run during/after a load (watch -n5 scripts/observe.sh).
source "$(dirname "$0")/lib.sh"

echo "======================= ClickHouse ======================="
node_sql "
  SELECT hostName() AS node, database AS db, table,
         count() AS active_parts,
         formatReadableSize(sum(bytes_on_disk)) AS disk,
         round(sum(data_uncompressed_bytes)/sum(bytes_on_disk),2) AS ratio
  FROM clusterAllReplicas('bench_cluster', system.parts)
  WHERE active AND database='${CH_DB}'
  GROUP BY node, db, table ORDER BY node, table FORMAT PrettyCompact" || true

echo "--- merges in progress ---"
node_sql "
  SELECT hostName() AS node, table, elapsed, progress, num_parts, result_part_name
  FROM clusterAllReplicas('bench_cluster', system.merges)
  ORDER BY node FORMAT PrettyCompact" || true

echo
echo "========================= Mimir =========================="
echo "--- compactor & TSDB ---"
tsbs "curl -s ${MIMIR_BASE}/metrics \
  | grep -E '^(cortex_compactor_runs_(started|completed)_total|cortex_ingester_memory_series|cortex_ingester_tsdb_compactions_total|cortex_ingester_tsdb_out_of_order_samples_appended_total) ' || true"

echo "--- blocks shipped / loaded (appear after TSDB flush -> object) ---"
tsbs "curl -s ${MIMIR_BASE}/metrics \
  | grep -E '^(cortex_ingester_shipper_uploads_total|cortex_bucket_blocks_count|cortex_bucket_store_blocks_loaded) ' || true"
