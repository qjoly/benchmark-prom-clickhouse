#!/usr/bin/env bash
# Leverage a ClickHouse optimization the raw comparison deliberately skips: a
# materialized-view-style rollup (AggregatingMergeTree, 1-minute avg per host).
# Creates + backfills it from `cpu`, then compares "avg per host" read latency on the
# raw table vs the rollup, over a small window and the full range. Shows where a rollup
# pays off (large scans) and where it does not (small windows, raw scan already fast).
#
# Mimir's counterpart is recording rules (the ruler); those only pre-compute going
# forward, so they cannot be backfilled onto this historical dataset for a like-for-like.
#
# Usage: [RUNTIME=k8s] scripts/ch_rollup.sh
source "$(dirname "$0")/lib.sh"

node_sql "CREATE TABLE IF NOT EXISTS ${CH_DB}.cpu_1m
  (tags_id UInt32, minute DateTime, avg_usage_user AggregateFunction(avg, Nullable(Float64)))
  ENGINE = AggregatingMergeTree ORDER BY (tags_id, minute)" >/dev/null 2>&1
cnt="$(node_sql "SELECT count() FROM ${CH_DB}.cpu_1m" | tr -d '[:space:]')"
if [ "${cnt:-0}" = "0" ]; then
  log "Backfilling rollup cpu_1m from cpu ..."
  node_sql "INSERT INTO ${CH_DB}.cpu_1m SELECT tags_id, toStartOfMinute(created_at), avgState(usage_user) FROM ${CH_DB}.cpu GROUP BY tags_id, minute" >/dev/null 2>&1
fi
log "rollup rows: $(node_sql "SELECT count() FROM ${CH_DB}.cpu_1m" | tr -d '[:space:]')"

read -r S MAX <<<"$(node_sql "SELECT toUnixTimestamp(min(created_at)), toUnixTimestamp(max(created_at)) FROM ${CH_DB}.cpu" | tr '\t' ' ')"
E4=$((S + 14400))

bench() {  # $1 = SQL -> p50 ms over 6 runs (HTTP, 2 warm-ups)
  local b; b="$(printf '%s' "$1" | base64 | tr -d '\n')"
  tsbs "q=\$(echo $b | base64 -d); u='http://${CH_HOST}:8123/?database=${CH_DB}'; \
    for i in 1 2; do curl -s -o /dev/null \"\$u\" --data-binary \"\$q FORMAT JSONCompact\"; done; \
    for i in \$(seq 1 6); do curl -s -o /dev/null -w '%{time_total}\n' \"\$u\" --data-binary \"\$q FORMAT JSONCompact\"; done \
    | sort -n | awk '{a[NR]=\$1*1000} END{printf \"%.0f ms\", a[3]}'"
}

printf '\n%-40s | %-12s | %-12s\n' "avg usage_user per host" "raw (cpu)" "rollup (cpu_1m)"
printf -- '----------------------------------------------------------------------\n'
printf '%-40s | %-12s | %-12s\n' "4h window (scan ~14M vs ~2.4M)" \
  "$(bench "SELECT tags_id, avg(usage_user) FROM ${CH_DB}.cpu WHERE created_at BETWEEN toDateTime($S) AND toDateTime($E4) GROUP BY tags_id")" \
  "$(bench "SELECT tags_id, avgMerge(avg_usage_user) FROM ${CH_DB}.cpu_1m WHERE minute BETWEEN toDateTime($S) AND toDateTime($E4) GROUP BY tags_id")"
printf '%-40s | %-12s | %-12s\n' "full range (scan 108M vs 18M)" \
  "$(bench "SELECT tags_id, avg(usage_user) FROM ${CH_DB}.cpu GROUP BY tags_id")" \
  "$(bench "SELECT tags_id, avgMerge(avg_usage_user) FROM ${CH_DB}.cpu_1m GROUP BY tags_id")"
