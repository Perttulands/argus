#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
PROBLEMS_FILE="$TEST_ROOT/problems.jsonl"
PATTERN_OUTPUT_FILE="$TEST_ROOT/pattern-analysis.json"
FALLBACK_FILE="$TEST_ROOT/relay-summary-fallback.jsonl"

now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
cat > "$PROBLEMS_FILE" <<EOF
{"ts":"$now","severity":"warning","type":"disk","description":"disk high","action_taken":"clean_disk:safelist","action_result":"success","bead_id":null,"host":"test"}
EOF

FAKE_BIN="$TEST_ROOT/bin"
mkdir -p "$FAKE_BIN"
export PATH="$FAKE_BIN:$PATH"
export FAKE_CURL_LOG="$TEST_ROOT/curl.log"
touch "$FAKE_CURL_LOG"

cat > "$FAKE_BIN/relay" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 1
EOF
chmod +x "$FAKE_BIN/relay"

cat > "$FAKE_BIN/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "$*" >> "$FAKE_CURL_LOG"
echo '{"ok":true}'
EOF
chmod +x "$FAKE_BIN/curl"

output=$(
    ARGUS_PROBLEMS_FILE="$PROBLEMS_FILE" \
    ARGUS_PATTERN_OUTPUT_FILE="$PATTERN_OUTPUT_FILE" \
    ARGUS_RELAY_BIN="$FAKE_BIN/relay" \
    ARGUS_RELAY_SUMMARY_FALLBACK_FILE="$FALLBACK_FILE" \
    TELEGRAM_BOT_TOKEN="test-token" \
    TELEGRAM_CHAT_ID="1234" \
    "$ROOT/scripts/relay-summary.sh"
)

[[ "$output" == *"Argus daily summary"* ]] || { echo "summary output missing" >&2; exit 1; }
[[ -f "$FALLBACK_FILE" ]] || { echo "fallback summary file missing" >&2; exit 1; }
[[ "$(wc -l < "$FALLBACK_FILE")" -ge 1 ]] || { echo "fallback summary file empty" >&2; exit 1; }
[[ "$(wc -l < "$FAKE_CURL_LOG")" -ge 1 ]] || { echo "telegram fallback was not attempted" >&2; exit 1; }

echo "relay_summary_test: PASS"
