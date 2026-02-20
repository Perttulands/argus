#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
PROBLEMS_FILE="$TEST_ROOT/problems.jsonl"
OUTPUT_FILE="$TEST_ROOT/stats.json"

now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
now_hour="$(date -u +%Y-%m-%dT%H:00Z)"
today="$(date -u +%Y-%m-%d)"

cat > "$PROBLEMS_FILE" <<EOF
{"ts":"$now","severity":"critical","type":"service","description":"svc down","action_taken":"restart_service:gateway","action_result":"failure","bead_id":"athena-1","host":"test"}
{"ts":"$now","severity":"warning","type":"disk","description":"disk high","action_taken":"clean_disk:safelist","action_result":"success","bead_id":null,"host":"test"}
{"ts":"$now","severity":"info","type":"memory","description":"mem high","action_taken":"alert:telegram","action_result":"suppressed","bead_id":"athena-2","host":"test"}
EOF

ARGUS_PROBLEMS_FILE="$PROBLEMS_FILE" ARGUS_STATS_WINDOW_DAYS=7 "$ROOT/scripts/argus-stats.sh" "$OUTPUT_FILE"

[[ "$(jq -r '.total_problems' "$OUTPUT_FILE")" == "3" ]] || { echo "total_problems mismatch" >&2; exit 1; }
[[ "$(jq -r '.by_type.service' "$OUTPUT_FILE")" == "1" ]] || { echo "by_type.service mismatch" >&2; exit 1; }
[[ "$(jq -r '.by_severity.critical' "$OUTPUT_FILE")" == "1" ]] || { echo "by_severity.critical mismatch" >&2; exit 1; }
[[ "$(jq -r '.action_results.success' "$OUTPUT_FILE")" == "1" ]] || { echo "action_results.success mismatch" >&2; exit 1; }
[[ "$(jq -r '.action_results.failure' "$OUTPUT_FILE")" == "1" ]] || { echo "action_results.failure mismatch" >&2; exit 1; }
[[ "$(jq -r '.action_results.suppressed' "$OUTPUT_FILE")" == "1" ]] || { echo "action_results.suppressed mismatch" >&2; exit 1; }
[[ "$(jq -r '.daily[0].bucket' "$OUTPUT_FILE")" == "$today" ]] || { echo "daily bucket mismatch" >&2; exit 1; }
[[ "$(jq -r '.hourly[0].bucket' "$OUTPUT_FILE")" == "$now_hour" ]] || { echo "hourly bucket mismatch" >&2; exit 1; }

echo "argus_stats_test: PASS"
