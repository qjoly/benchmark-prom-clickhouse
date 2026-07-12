#!/usr/bin/env bash
# Read throughput under concurrency (QPS), the workload the serial read_gradient misses.
# Fires C concurrent clients looping a light point query (single series, 1h) for DUR
# seconds against each engine over HTTP, and reports QPS and p50/p95 latency. This is
# where a metrics store is meant to shine (many simultaneous dashboard queries).
#
# Usage: [RUNTIME=k8s] [CONC="1 4 16 64"] [CONC_DUR=12] scripts/read_concurrency.sh
source "$(dirname "$0")/lib.sh"

CONC_LEVELS="${CONC:-1 4 16 64}"; DUR="${CONC_DUR:-12}"
read -r S _ <<<"$(node_sql "SELECT toUnixTimestamp(min(created_at)), 0 FROM ${CH_DB}.cpu" | tr '\t' ' ')"
E=$((S + 3600))
HID="$(node_sql "SELECT id FROM ${CH_DB}.tags WHERE hostname='host_0' LIMIT 1" | tr -d '[:space:]')"

# In-pod worker: args = ENGINE C DUR
POD_SCRIPT='
ENGINE=$1; C=$2; DUR=$3
CHURL="http://'"${CH_HOST}"':8123/?database='"${CH_DB}"'"
MU="'"${MIMIR_QUERY_URL}"'/api/v1/query_range"
SQL="SELECT toStartOfMinute(created_at) t, avg(usage_user) FROM '"${CH_DB}"'.cpu WHERE tags_id='"${HID}"' AND created_at BETWEEN toDateTime('"${S}"') AND toDateTime('"${E}"') GROUP BY t FORMAT JSONCompact"
PROMQL="avg_over_time(usage_user{hostname=\"host_0\"}[1m])"
tmp=$(mktemp)
endt=$(( $(date +%s) + DUR ))
for w in $(seq 1 $C); do
  (
    while [ $(date +%s) -lt $endt ]; do
      if [ "$ENGINE" = ch ]; then
        curl -s -o /dev/null -w "%{time_total}\n" "$CHURL" --data-binary "$SQL"
      else
        curl -s -o /dev/null -w "%{time_total}\n" --data-urlencode "query=$PROMQL" --data-urlencode "start='"${S}"'" --data-urlencode "end='"${E}"'" --data-urlencode "step=60" "$MU"
      fi
    done >> $tmp
  ) &
done
wait
n=$(wc -l < $tmp); sort -n $tmp > $tmp.s
p50=$(awk "NR==int($n*0.50)+1{print \$1*1000}" $tmp.s)
p95=$(awk "NR==int($n*0.95)+1{print \$1*1000}" $tmp.s)
awk "BEGIN{printf \"C=%-3s QPS=%-8.1f p50=%.0fms p95=%.0fms (n=%s)\n\", $C, $n/$DUR, $p50+0, $p95+0, $n}"
'
tsbs "cat > /tmp/conc.sh <<'EOS'
$POD_SCRIPT
EOS"

for ENGINE in mimir ch; do
  echo "=== $ENGINE (single-series point query, ${DUR}s per level) ==="
  for C in $CONC_LEVELS; do
    tsbs "bash /tmp/conc.sh $ENGINE $C $DUR"
  done
done
