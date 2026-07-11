#!/usr/bin/env bash
# Fair read comparison (mirrored queries) between Mimir (PromQL) and ClickHouse (SQL).
#
# Why this exists: TSBS's `victoriametrics` query generator targets metric names
# `cpu_usage_*`, but `tsbs_load_prometheus` stores them WITHOUT the measurement
# prefix (`usage_*`). Mixing the two makes every Mimir query match nothing (empty
# results in ~2 ms), which silently invalidates the read comparison. This script
# runs hand-written queries with the CORRECT names on both engines, along an
# "index-escape" gradient: single series -> fan-out over all series.
#
# Usage: [RUNTIME=k8s] scripts/read_gradient.sh
source "$(dirname "$0")/lib.sh"

METRICS="usage_user usage_system usage_idle usage_nice usage_iowait usage_irq usage_softirq usage_steal usage_guest usage_guest_nice"

# Raw exec helpers with timing (runtime-aware) ------------------------------
# ClickHouse: returns server-side elapsed seconds (clickhouse-client --time).
ch_time() {
  if [ "$RUNTIME" = "k8s" ]; then
    kubectl -n "$K8S_NS" exec -i "$CH_PRIMARY_NODE" -- clickhouse-client --time -q "$1 FORMAT Null" 2>&1 | tail -1
  else
    $DC exec -T "$CH_PRIMARY_NODE" clickhouse-client --time -q "$1 FORMAT Null" 2>&1 | tail -1
  fi
}
# Mimir: query_range; prints "HTTP <code> <seconds>s". $2=start $3=end $4=step.
mimir_time() {
  local q="$1" s="$2" e="$3" step="$4"
  tsbs "curl -s -o /dev/null -w '%{http_code} %{time_total}s' \
    --data-urlencode 'query=${q}' --data-urlencode 'start=${s}' \
    --data-urlencode 'end=${e}' --data-urlencode 'step=${step}' \
    '${MIMIR_QUERY_URL}/api/v1/query_range'"
}

# Derive the data time window from ClickHouse (авторitative) -----------------
# Anchor windows at the START of the dataset: that data is reliably shipped to
# object-storage blocks, so it survives a Mimir restart and is served by the
# store-gateway (recent data may only live in ingesters, which are wiped on restart).
read -r MINTS MAXTS <<<"$(node_sql "SELECT toUnixTimestamp(min(created_at)), toUnixTimestamp(max(created_at)) FROM ${CH_DB}.cpu" | tr '\t' ' ')"
H1_S=$MINTS;   H1_E=$((MINTS + 3600))          # first 1h of data
H12_S=$MINTS;  H12_E=$((MINTS + 14400))        # first 4h of data (wide scan)
ch_dt() { node_sql "SELECT toDateTime($1, 'UTC')"; }   # epoch -> 'YYYY-MM-DD HH:MM:SS'
W1="created_at BETWEEN toDateTime($H1_S,'UTC') AND toDateTime($H1_E,'UTC')"
W12="created_at BETWEEN toDateTime($H12_S,'UTC') AND toDateTime($H12_E,'UTC')"
HID="$(node_sql "SELECT id FROM ${CH_DB}.tags WHERE hostname='host_0' LIMIT 1")"

log "Data window: $(ch_dt $H1_S) -> $(ch_dt $H12_E)  | host_0 id=$HID"
SUM10="$(for m in $METRICS; do printf 'sum(%s)+' "$m"; done | sed 's/+$//')"
AVGU="avg(usage_user)"

printf '\n%-52s | %-22s | %s\n' "Query" "Mimir (PromQL)" "ClickHouse (SQL)"
printf -- '---------------------------------------------------------------------------------------------\n'

row() { printf '%-52s | %-22s | %s s\n' "$1" "$2" "$3"; }

# L1 — single series (1 host, 1 metric, 1h @1m). Mimir sweet spot.
M="$(mimir_time "avg_over_time(usage_user{hostname=\"host_0\"}[1m])" "$H1_S" "$H1_E" 60)"
C="$(ch_time "SELECT toStartOfMinute(created_at) t, avg(usage_user) FROM ${CH_DB}.cpu WHERE tags_id=$HID AND $W1 GROUP BY t")"
row "L1 single-series (1 host,1 metric,1h)" "$M" "$C"

# L2 — 1 metric, ALL hosts, avg by host, 1h @1m.
M="$(mimir_time "avg by (hostname) (avg_over_time(usage_user[1m]))" "$H1_S" "$H1_E" 60)"
C="$(ch_time "SELECT tags_id, toStartOfMinute(created_at) t, avg(usage_user) FROM ${CH_DB}.cpu WHERE $W1 GROUP BY tags_id, t")"
row "L2 1 metric, all hosts (1h)" "$M" "$C"

# L3 — 1 metric, ALL hosts, avg by host, 4h @1m (wide scan).
M="$(mimir_time "avg by (hostname) (avg_over_time(usage_user[1m]))" "$H12_S" "$H12_E" 60)"
C="$(ch_time "SELECT tags_id, toStartOfMinute(created_at) t, avg(usage_user) FROM ${CH_DB}.cpu WHERE $W12 GROUP BY tags_id, t")"
row "L3 1 metric, all hosts (4h)" "$M" "$C"

# L4 — full analytical scan: 10 metrics over all hosts.
# NB: in PromQL, range functions drop __name__, so a single expression over the 10
# metrics collapses to identical labelsets ("same labelset" error). We therefore run
# the Mimir side as a per-metric sum of one representative metric and flag the rest.
M="$(mimir_time "sum(avg_over_time(usage_user[1m]))" "$H1_S" "$H1_E" 60) (1 metric only*)"
C="$(ch_time "SELECT toStartOfMinute(created_at) t, $SUM10 FROM ${CH_DB}.cpu WHERE $W1 GROUP BY t")"
row "L4 full scan 10 metrics, all hosts (1h)" "$M" "$C"

echo
echo "* PromQL cannot aggregate across multiple metric names in one expression"
echo "  (functions strip __name__ -> label collision). ClickHouse does it in one query."
