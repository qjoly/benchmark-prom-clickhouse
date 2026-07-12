#!/usr/bin/env bash
# Fair read comparison between Mimir (PromQL) and ClickHouse (SQL), with matched
# methodology so neither engine is favoured by the measurement:
#   - BOTH timed over HTTP including result serialization and transfer (Mimir via
#     query_range/JSON, ClickHouse via the HTTP interface with FORMAT JSONCompact).
#     The earlier version timed ClickHouse server-side (no transport), which was
#     unfair to Mimir.
#   - REPS repetitions after WARM warm-ups; reports p50/p95 in ms (not a single shot).
#   - Correct metric names (usage_*), matching what tsbs_load_prometheus stores.
#
# Usage: [RUNTIME=k8s] [READ_REPS=10] [READ_WARMUP=2] scripts/read_gradient.sh
source "$(dirname "$0")/lib.sh"

REPS="${READ_REPS:-10}"; WARM="${READ_WARMUP:-2}"
CH_HTTP="http://${CH_HOST}:8123"

# Data window from ClickHouse (authoritative), anchored at the start of the data.
read -r MINTS MAXTS <<<"$(node_sql "SELECT toUnixTimestamp(min(created_at)), toUnixTimestamp(max(created_at)) FROM ${CH_DB}.cpu" | tr '\t' ' ')"
S=$MINTS; E1=$((MINTS + 3600)); E4=$((MINTS + 14400))
HID="$(node_sql "SELECT id FROM ${CH_DB}.tags WHERE hostname='host_0' LIMIT 1" | tr -d '[:space:]')"
W1="created_at BETWEEN toDateTime($S) AND toDateTime($E1)"
W4="created_at BETWEEN toDateTime($S) AND toDateTime($E4)"
log "Window $(node_sql "SELECT toDateTime($S,'UTC')") .. $(node_sql "SELECT toDateTime($E4,'UTC')") | host_0 id=$HID | reps=$REPS warmup=$WARM"

AWK_PCTL='{a[NR]=$1*1000} END{if(NR==0){print "n/a";exit} i50=int((NR-1)*0.5)+1;i95=int((NR-1)*0.95)+1;printf "%.0f/%.0f", a[i50], a[i95]}'

# ClickHouse over HTTP, JSON serialization, p50/p95 ms. $1 = SQL.
ch() {
  local b; b="$(printf '%s' "$1" | base64 | tr -d '\n')"
  tsbs "q=\$(echo $b | base64 -d); u='${CH_HTTP}/?database=${CH_DB}'; \
    for i in \$(seq 1 $WARM); do curl -s -o /dev/null \"\$u\" --data-binary \"\$q FORMAT JSONCompact\"; done; \
    for i in \$(seq 1 $REPS); do curl -s -o /dev/null -w '%{time_total}\n' \"\$u\" --data-binary \"\$q FORMAT JSONCompact\"; done \
    | sort -n | awk '$AWK_PCTL'"
}
# Mimir over HTTP query_range, p50/p95 ms. $1=promql $2=start $3=end $4=step.
mi() {
  local b; b="$(printf '%s' "$1" | base64 | tr -d '\n')"
  tsbs "q=\$(echo $b | base64 -d); u='${MIMIR_QUERY_URL}/api/v1/query_range'; \
    for i in \$(seq 1 $WARM); do curl -s -o /dev/null --data-urlencode \"query=\$q\" --data-urlencode 'start=$2' --data-urlencode 'end=$3' --data-urlencode 'step=$4' \"\$u\"; done; \
    for i in \$(seq 1 $REPS); do curl -s -o /dev/null -w '%{time_total}\n' --data-urlencode \"query=\$q\" --data-urlencode 'start=$2' --data-urlencode 'end=$3' --data-urlencode 'step=$4' \"\$u\"; done \
    | sort -n | awk '$AWK_PCTL'"
}

printf '\n%-42s | %-18s | %-18s\n' "Query (p50/p95 ms, HTTP both sides)" "Mimir" "ClickHouse"
printf -- '-----------------------------------------------------------------------------------\n'
row() { printf '%-42s | %-18s | %-18s\n' "$1" "$2" "$3"; }

row "L1 single series (1h)" \
  "$(mi "avg_over_time(usage_user{hostname=\"host_0\"}[1m])" "$S" "$E1" 60)" \
  "$(ch "SELECT toStartOfMinute(created_at) t, avg(usage_user) FROM ${CH_DB}.cpu WHERE tags_id=$HID AND $W1 GROUP BY t")"

row "L2 1 metric, all hosts (1h)" \
  "$(mi "avg by (hostname) (avg_over_time(usage_user[1m]))" "$S" "$E1" 60)" \
  "$(ch "SELECT tags_id, toStartOfMinute(created_at) t, avg(usage_user) FROM ${CH_DB}.cpu WHERE $W1 GROUP BY tags_id, t")"

row "L3 1 metric, all hosts (4h)" \
  "$(mi "avg by (hostname) (avg_over_time(usage_user[1m]))" "$S" "$E4" 60)" \
  "$(ch "SELECT tags_id, toStartOfMinute(created_at) t, avg(usage_user) FROM ${CH_DB}.cpu WHERE $W4 GROUP BY tags_id, t")"

echo
echo "Both sides pay HTTP + result serialization + transfer; p50/p95 over $REPS runs after $WARM warm-ups."
