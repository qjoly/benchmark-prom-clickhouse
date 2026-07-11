#!/usr/bin/env bash
# ClickHouse cluster operations lab based on the data loaded by TSBS.
#
# TSBS creates a single-node schema (MergeTree) on chnode1. This script:
#   setup       -> recreates the metric table as ReplicatedMergeTree (ON CLUSTER)
#                  + a Distributed table, then copies the data into it
#                  (=> sharding across 2 shards + replication RF=2).
#   compaction  -> observes parts / merges, forces OPTIMIZE FINAL, measures
#                  the compaction gain (number of parts, compression).
#   rebuild     -> destroys a replica's copy (chnode2) and rebuilds it
#                  from its peer via Keeper; times the rebuild.
#   status      -> cluster state (replicas, parts, lag).
#
# Usage: scripts/clickhouse_cluster_ops.sh {setup|compaction|rebuild|status|all}
source "$(dirname "$0")/lib.sh"

CLUSTER=bench_cluster
SRC_TABLE="${METRIC_TABLE:-cpu}"          # metric table created by TSBS
LOCAL="${SRC_TABLE}_repl_local"           # local ReplicatedMergeTree (per shard)
DIST="${SRC_TABLE}_repl"                  # Distributed table
ZKPATH="/clickhouse/tables/{shard}/${LOCAL}"

# SQL on a given node (default: primary node), raw output. Delegates to node_sql (lib.sh).
sql() { node_sql "$1" "${2:-$CH_PRIMARY_NODE}"; }

# Introspect a table (columns/partition/sort) on a node -> globals I_COLS/I_PART/I_SORT.
introspect() {
  local db="$1" tbl="$2" node="${3:-$CH_PRIMARY_NODE}"
  I_PART="$(sql "SELECT partition_key FROM system.tables WHERE database='${db}' AND name='${tbl}'" "$node")"
  I_SORT="$(sql "SELECT sorting_key  FROM system.tables WHERE database='${db}' AND name='${tbl}'" "$node")"
  I_COLS="$(sql "SELECT arrayStringConcat(groupArray(name || ' ' || type), ', ')
                 FROM (SELECT name, type FROM system.columns
                       WHERE database='${db}' AND table='${tbl}' ORDER BY position)" "$node")"
}

# Emit the CREATE of the local ReplicatedMergeTree table. $1 = "ON CLUSTER ..." or empty.
local_repl_ddl() {
  local on_cluster="$1" part_clause=""
  [ -n "$I_PART" ] && part_clause="PARTITION BY (${I_PART})"
  printf "CREATE TABLE IF NOT EXISTS %s.%s %s (%s) ENGINE = ReplicatedMergeTree('%s', '{replica}') %s ORDER BY (%s)" \
    "$CH_DB" "$LOCAL" "$on_cluster" "$I_COLS" "$ZKPATH" "$part_clause" "$I_SORT"
}

setup() {
  log "Introspecting the TSBS schema ($CH_DB.$SRC_TABLE)..."
  introspect "$CH_DB" "$SRC_TABLE"
  log "  columns   : ${I_COLS}"
  log "  PARTITION : ${I_PART:-<none>}"
  log "  ORDER BY  : ${I_SORT}"

  # TSBS only creates the database on chnode1: we create it across the whole cluster.
  log "Creating database ${CH_DB} ON CLUSTER ${CLUSTER}"
  sql "CREATE DATABASE IF NOT EXISTS ${CH_DB} ON CLUSTER ${CLUSTER}"

  log "Creating Replicated table ON CLUSTER ${CLUSTER}: ${CH_DB}.${LOCAL}"
  sql "$(local_repl_ddl "ON CLUSTER ${CLUSTER}")"

  log "Creating Distributed table: ${CH_DB}.${DIST} (sharding cityHash64(tags_id))"
  sql "CREATE TABLE IF NOT EXISTS ${CH_DB}.${DIST} ON CLUSTER ${CLUSTER}
       AS ${CH_DB}.${LOCAL}
       ENGINE = Distributed('${CLUSTER}', '${CH_DB}', '${LOCAL}', cityHash64(tags_id))"

  log "Copying data ${SRC_TABLE} -> ${DIST} (fan-out across shards + replication)..."
  sql "INSERT INTO ${CH_DB}.${DIST} SELECT * FROM ${CH_DB}.${SRC_TABLE}"
  log "setup complete."
  status
}

status() {
  log "== Row distribution per shard/replica =="
  sql "SELECT hostName() AS node, count() AS rows
       FROM clusterAllReplicas('${CLUSTER}', ${CH_DB}.${LOCAL}) GROUP BY node ORDER BY node FORMAT PrettyCompact" || true
  log "== Active parts and storage (system.parts, all nodes) =="
  sql "SELECT hostName() AS node, count() AS active_parts,
              formatReadableSize(sum(bytes_on_disk)) AS disk,
              round(sum(data_uncompressed_bytes)/sum(bytes_on_disk),2) AS ratio, sum(rows) AS rows
       FROM clusterAllReplicas('${CLUSTER}', system.parts)
       WHERE database='${CH_DB}' AND table='${LOCAL}' AND active
       GROUP BY node ORDER BY node FORMAT PrettyCompact" || true
  log "== Replication queue (0 = up to date) =="
  sql "SELECT hostName() AS node, count() AS queue
       FROM clusterAllReplicas('${CLUSTER}', system.replication_queue)
       WHERE database='${CH_DB}' AND table='${LOCAL}' GROUP BY node ORDER BY node FORMAT PrettyCompact" || true
}

compaction() {
  log "== Parts BEFORE compaction =="
  sql "SELECT count() AS parts, formatReadableSize(sum(bytes_on_disk)) AS disk,
              round(sum(data_uncompressed_bytes)/sum(bytes_on_disk),2) AS compression_ratio
       FROM system.parts WHERE database='${CH_DB}' AND table='${LOCAL}' AND active FORMAT PrettyCompact"
  log "== Merges in progress (system.merges) =="
  sql "SELECT hostName() AS node, count() AS running_merges
       FROM clusterAllReplicas('${CLUSTER}', system.merges)
       WHERE database='${CH_DB}' AND table='${LOCAL}' GROUP BY node FORMAT PrettyCompact" || true

  log "OPTIMIZE TABLE ${LOCAL} ON CLUSTER FINAL (forced merge)... (may be long)"
  local t0 t1
  t0=$(date +%s)
  sql "OPTIMIZE TABLE ${CH_DB}.${LOCAL} ON CLUSTER ${CLUSTER} FINAL"
  t1=$(date +%s)
  log "OPTIMIZE complete in $((t1 - t0))s."

  log "== Parts AFTER compaction =="
  sql "SELECT count() AS parts, formatReadableSize(sum(bytes_on_disk)) AS disk,
              round(sum(data_uncompressed_bytes)/sum(bytes_on_disk),2) AS compression_ratio
       FROM system.parts WHERE database='${CH_DB}' AND table='${LOCAL}' AND active FORMAT PrettyCompact"
}

rebuild() {
  local victim="$REBUILD_VICTIM"   # replica of the same shard as the primary node
  log "== Rebuilding replica ${victim} =="
  local before
  before="$(sql "SELECT count() FROM system.parts WHERE database='${CH_DB}' AND table='${LOCAL}' AND active" "$victim")"
  log "Parts on ${victim} before: ${before}"

  # Rebuild the DDL from the surviving replica (primary node) - avoids a
  # fragile round-trip of create_table_query through the shell.
  introspect "$CH_DB" "$LOCAL" "$CH_PRIMARY_NODE"

  log "DROP the replica's local copy (data stays on chnode1 + Keeper)..."
  sql "DROP TABLE IF EXISTS ${CH_DB}.${LOCAL} SYNC" "$victim"

  log "Recreating the table on ${victim} -> triggers re-fetch of parts from the peer..."
  local t0
  t0=$(date +%s)
  sql "$(local_repl_ddl "")" "$victim"
  sql "SYSTEM RESTART REPLICA ${CH_DB}.${LOCAL}" "$victim" || true

  log "Tracking the rebuild (system.replicated_fetches / replication_queue)..."
  local target
  target="$(sql "SELECT count() FROM system.parts WHERE database='${CH_DB}' AND table='${LOCAL}' AND active" "$CH_PRIMARY_NODE")"
  while :; do
    local now fetches queue
    now="$(sql "SELECT count() FROM system.parts WHERE database='${CH_DB}' AND table='${LOCAL}' AND active" "$victim")"
    fetches="$(sql "SELECT count() FROM system.replicated_fetches WHERE database='${CH_DB}' AND table='${LOCAL}'" "$victim")"
    queue="$(sql "SELECT count() FROM system.replication_queue WHERE database='${CH_DB}' AND table='${LOCAL}'" "$victim")"
    printf '  parts %s/%s  fetches_in_progress=%s  queue=%s\n' "$now" "$target" "$fetches" "$queue"
    [ "$queue" = "0" ] && [ "$fetches" = "0" ] && [ "$now" -ge "$target" ] && break
    sleep 3
  done
  local t1; t1=$(date +%s)
  log "Replica ${victim} rebuilt in $((t1 - t0))s (parts: ${before} -> ${target})."
}

case "${1:-all}" in
  setup)      setup ;;
  status)     status ;;
  compaction) compaction ;;
  rebuild)    rebuild ;;
  all)        setup; compaction; rebuild ;;
  *) echo "Usage: $0 {setup|status|compaction|rebuild|all}"; exit 1 ;;
esac
