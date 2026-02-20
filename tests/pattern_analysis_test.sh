#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
PROBLEMS_FILE="$TEST_ROOT/problems.jsonl"
OUTPUT_FILE="$TEST_ROOT/pattern-analysis.json"

today="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
yesterday="$(date -u -d '1 day ago' +%Y-%m-%dT%H:%M:%SZ)"

cat > "$PROBLEMS_FILE" <<EOF
{"ts":"$today","severity":"warning","type":"service","description":"Service action for gateway: down","action_taken":"restart_service:gateway","action_result":"failure","bead_id":null,"host":"test"}
{"ts":"$today","severity":"warning","type":"service","description":"Service action for gateway: down","action_taken":"restart_service:gateway","action_result":"failure","bead_id":null,"host":"test"}
{"ts":"$today","severity":"warning","type":"service","description":"Service action for gateway: down","action_taken":"restart_service:gateway","action_result":"failure","bead_id":null,"host":"test"}
{"ts":"$yesterday","severity":"warning","type":"disk","description":"Disk cleanup triggered; reclaimed_bytes=0","action_taken":"clean_disk:safelist","action_result":"success","bead_id":null,"host":"test"}
{"ts":"$today","severity":"warning","type":"disk","description":"Disk cleanup triggered; reclaimed_bytes=0","action_taken":"clean_disk:safelist","action_result":"success","bead_id":null,"host":"test"}
{"ts":"$today","severity":"warning","type":"disk","description":"Disk usage critical","action_taken":"alert:telegram","action_result":"success","bead_id":null,"host":"test"}
EOF

ARGUS_PROBLEMS_FILE="$PROBLEMS_FILE" \
ARGUS_PATTERN_OUTPUT_FILE="$OUTPUT_FILE" \
ARGUS_PATTERN_WINDOW_DAYS=7 \
"$ROOT/scripts/pattern-analysis.sh" >/dev/null

patterns=$(jq -r '.patterns | length' "$OUTPUT_FILE")
if [[ ! "$patterns" =~ ^[0-9]+$ ]] || (( patterns == 0 )); then
    echo "expected non-zero patterns" >&2
    exit 1
fi

jq -e '.patterns[] | select(.type=="service_restart_spike")' "$OUTPUT_FILE" >/dev/null
jq -e '.patterns[] | select(.type=="disk_pressure_trend")' "$OUTPUT_FILE" >/dev/null

echo "pattern_analysis_test: PASS"
