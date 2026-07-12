#!/usr/bin/env bash
# Mimir recording rule = the counterpart to the ClickHouse rollup: temporal
# downsampling (1-minute avg per series) pre-computed by the ruler. Posts the rule
# group to the ruler config API.
#
# NB: recording rules only pre-compute GOING FORWARD (no backfill of history), so a
# like-for-like read comparison needs the rule to have been evaluating during a live
# ingestion window. On the single-node sandbox here the freshly-fed current-time data
# was not reliably queryable back (the recent-data vs blocks gap in the caveats), so
# the recorded-read comparison could not be completed; the rule itself loads and
# evaluates cleanly (GET .../api/v1/rules shows health "ok").
#
# Usage: [RUNTIME=k8s] scripts/mimir_rule.sh
source "$(dirname "$0")/lib.sh"

tsbs 'cat > /tmp/rule.yaml <<YAML
name: rollup
interval: 1m
rules:
  - record: usage_user:avg_1m
    expr: avg_over_time(usage_user[1m])
YAML
curl -s -o /dev/null -w "POST rules -> %{http_code}\n" -H "X-Scope-OrgID: anonymous" \
  -H "Content-Type: application/yaml" --data-binary @/tmp/rule.yaml '"${MIMIR_QUERY_URL}"'/config/v1/rules/bench'
log "Rule status:"
tsbs "curl -s -H 'X-Scope-OrgID: anonymous' ${MIMIR_QUERY_URL}/api/v1/rules"
