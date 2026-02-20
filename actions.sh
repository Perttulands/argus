#!/usr/bin/env bash
set -euo pipefail

# actions.sh — ONLY allowlisted actions that Argus LLM can execute
#
# Security model: The LLM can only trigger these 5 actions.
# Each action validates its inputs before execution.

ALLOWED_SERVICES=()
TELEGRAM_TIMEOUT=10   # seconds for Telegram API calls
TELEGRAM_MAX_RETRIES=2 # retry failed Telegram sends
ARGUS_RELAY_ENABLED="${ARGUS_RELAY_ENABLED:-true}"
ARGUS_RELAY_BIN="${ARGUS_RELAY_BIN:-$HOME/go/bin/relay}"
ARGUS_RELAY_TO="${ARGUS_RELAY_TO:-athena}"
ARGUS_RELAY_FROM="${ARGUS_RELAY_FROM:-argus}"
ARGUS_RELAY_TIMEOUT="${ARGUS_RELAY_TIMEOUT:-5}"
ARGUS_RELAY_FALLBACK_FILE="${ARGUS_RELAY_FALLBACK_FILE:-$HOME/athena/state/argus/relay-fallback.jsonl}"
ACTIONS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARGUS_STATE_DIR="${ARGUS_STATE_DIR:-${SCRIPT_DIR:-$ACTIONS_DIR}/state}"
ARGUS_PROBLEMS_FILE="${ARGUS_PROBLEMS_FILE:-$ARGUS_STATE_DIR/problems.jsonl}"
ARGUS_BEADS_WORKDIR="${ARGUS_BEADS_WORKDIR:-$HOME/athena/workspace}"
ARGUS_BEAD_PRIORITY="${ARGUS_BEAD_PRIORITY:-2}"
ARGUS_BEAD_REPEAT_THRESHOLD="${ARGUS_BEAD_REPEAT_THRESHOLD:-3}"
ARGUS_BEAD_REPEAT_WINDOW_SECONDS="${ARGUS_BEAD_REPEAT_WINDOW_SECONDS:-86400}"
ARGUS_DEDUP_FILE="${ARGUS_DEDUP_FILE:-$ARGUS_STATE_DIR/dedup.json}"
ARGUS_DEDUP_WINDOW="${ARGUS_DEDUP_WINDOW:-3600}"
ARGUS_DEDUP_RETENTION_SECONDS="${ARGUS_DEDUP_RETENTION_SECONDS:-86400}"

normalize_problem_type() {
    local value="${1:-process}"
    case "$value" in
        disk|memory|service|process|swap) echo "$value" ;;
        *) echo "process" ;;
    esac
}

normalize_problem_severity() {
    local value="${1:-info}"
    case "$value" in
        critical|warning|info) echo "$value" ;;
        *) echo "info" ;;
    esac
}

infer_problem_type() {
    local text="${1:-}"
    local lower
    lower=$(echo "$text" | tr '[:upper:]' '[:lower:]')
    case "$lower" in
        *disk*|*space*|*tmp*|*cache*) echo "disk" ;;
        *memory*|*oom*|*rss*) echo "memory" ;;
        *swap*|*thrash*) echo "swap" ;;
        *service*|*systemctl*|*restart*|*gateway*) echo "service" ;;
        *) echo "process" ;;
    esac
}

infer_problem_severity() {
    local text="${1:-}"
    if [[ "$text" =~ [Cc][Rr][Ii][Tt][Ii][Cc][Aa][Ll]|[Ff][Aa][Ii][Ll]|[Dd][Oo][Ww][Nn]|[Uu][Nn][Rr][Ee][Aa][Cc][Hh][Aa][Bb][Ll][Ee]|[Ee][Rr][Rr][Oo][Rr] ]]; then
        echo "critical"
    elif [[ "$text" =~ [Ww][Aa][Rr][Nn]|[Hh][Ii][Gg][Hh] ]]; then
        echo "warning"
    else
        echo "info"
    fi
}

log_problem() {
    local severity
    severity=$(normalize_problem_severity "${1:-info}")
    local problem_type
    problem_type=$(normalize_problem_type "${2:-process}")
    local description="${3:-No description provided}"
    local action_taken="${4:-none}"
    local action_result="${5:-unknown}"
    local bead_id="${6:-null}"

    local host ts
    host=$(hostname -f 2>/dev/null || hostname) # REASON: FQDN may be unavailable; fallback to short hostname.
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    mkdir -p "$(dirname "$ARGUS_PROBLEMS_FILE")"
    touch "$ARGUS_PROBLEMS_FILE"

    jq -cn \
        --arg ts "$ts" \
        --arg severity "$severity" \
        --arg type "$problem_type" \
        --arg description "$description" \
        --arg action_taken "$action_taken" \
        --arg action_result "$action_result" \
        --arg bead_id "$bead_id" \
        --arg host "$host" \
        '{
            ts: $ts,
            severity: $severity,
            type: $type,
            description: $description,
            action_taken: $action_taken,
            action_result: $action_result,
            bead_id: (if ($bead_id == "null" or $bead_id == "") then null else $bead_id end),
            host: $host
        }' >> "$ARGUS_PROBLEMS_FILE"
}

generate_problem_key() {
    local problem_type="${1:-process}"
    local description="${2:-}"
    local hash
    hash=$(printf '%s' "$description" | sha256sum | awk '{print $1}' | cut -c1-16)
    printf '%s:%s\n' "$(normalize_problem_type "$problem_type")" "$hash"
}

problem_occurrences_in_window() {
    local problem_type="${1:-process}"
    local description="${2:-}"
    if [[ ! -f "$ARGUS_PROBLEMS_FILE" ]]; then
        echo 0
        return 0
    fi

    local now cutoff count
    now=$(date -u +%s)
    cutoff=$((now - ARGUS_BEAD_REPEAT_WINDOW_SECONDS))
    count=$(jq -s \
        --arg problem_type "$problem_type" \
        --arg description "$description" \
        --argjson cutoff "$cutoff" \
        '[.[] | select(.type == $problem_type and .description == $description)
        | (.ts | fromdateiso8601? // 0)
        | select(. >= $cutoff)] | length' "$ARGUS_PROBLEMS_FILE" 2>/dev/null || echo 0) # REASON: malformed registry rows should degrade to zero matches.

    if [[ ! "$count" =~ ^[0-9]+$ ]]; then
        count=0
    fi
    echo "$count"
}

action_has_automatic_remediation() {
    local action_type="${1:-}"
    case "$action_type" in
        restart_service|kill_pid|kill_tmux|clean_disk) return 0 ;;
        *) return 1 ;;
    esac
}

find_open_bead_for_problem_key() {
    local problem_key="${1:-}"
    [[ -n "$problem_key" ]] || return 1

    if ! command -v bd >/dev/null 2>&1; then # REASON: bead creation must be a no-op when bd is not installed.
        return 1
    fi

    local open_json
    open_json=$(cd "$ARGUS_BEADS_WORKDIR" && bd list --status open --json 2>/dev/null || echo "[]") # REASON: transient bd failures should not break monitoring.
    jq -r --arg marker "Problem key: ${problem_key}" \
        '.[] | select((.description // "") | contains($marker)) | .id' <<< "$open_json" | head -n1
}

create_bead() {
    local problem_type="${1:-process}"
    local description="${2:-No description provided}"
    local severity="${3:-info}"
    local action_taken="${4:-none}"
    local action_result="${5:-unknown}"
    local problem_key="${6:-}"
    local seen_count="${7:-1}"

    if ! command -v bd >/dev/null 2>&1; then # REASON: bd integration is optional and should degrade gracefully.
        return 0
    fi

    local existing_id
    existing_id=$(find_open_bead_for_problem_key "$problem_key" || true) # REASON: lookup failures should fall back to attempting creation.
    if [[ -n "$existing_id" ]]; then
        echo "$existing_id"
        return 0
    fi

    local host title body bead_id
    host=$(hostname -f 2>/dev/null || hostname) # REASON: FQDN may be unavailable; fallback to short hostname.
    title="[argus] ${problem_type}: ${description}"
    body=$(cat <<EOF
Argus detected an issue that needs human attention.

Type: ${problem_type}
Severity: ${severity}
Description: ${description}
Action taken: ${action_taken}
Action result: ${action_result}
Occurrences in window: ${seen_count}
Host: ${host}

Problem key: ${problem_key}
EOF
)

    bead_id=$(cd "$ARGUS_BEADS_WORKDIR" && bd create \
        --title "$title" \
        --description "$body" \
        --priority "$ARGUS_BEAD_PRIORITY" \
        --labels argus \
        --silent 2>/dev/null || true) # REASON: creation failures should not fail Argus monitoring cycles.

    bead_id=$(echo "$bead_id" | tr -d '[:space:]')
    if [[ "$bead_id" =~ ^[a-zA-Z0-9._-]+$ ]]; then
        echo "$bead_id"
    fi
}

ensure_dedup_file() {
    mkdir -p "$(dirname "$ARGUS_DEDUP_FILE")"
    if [[ ! -f "$ARGUS_DEDUP_FILE" ]]; then
        echo '{"keys":{}}' > "$ARGUS_DEDUP_FILE"
    fi
}

dedup_compact() {
    ensure_dedup_file
    local now tmp_file
    now=$(date -u +%s)
    tmp_file="${ARGUS_DEDUP_FILE}.tmp"

    jq --argjson now "$now" --argjson retention "$ARGUS_DEDUP_RETENTION_SECONDS" '
        .keys = ((.keys // {})
        | with_entries(select((.value.last_seen // 0) >= ($now - $retention))))
    ' "$ARGUS_DEDUP_FILE" > "$tmp_file" 2>/dev/null || echo '{"keys":{}}' > "$tmp_file" # REASON: corrupted dedup state should self-heal to an empty map.
    mv "$tmp_file" "$ARGUS_DEDUP_FILE"
}

dedup_should_suppress() {
    local problem_key="${1:-}"
    [[ -n "$problem_key" ]] || return 1

    dedup_compact
    local now last_seen
    now=$(date -u +%s)
    last_seen=$(jq -r --arg key "$problem_key" '.keys[$key].last_seen // 0' "$ARGUS_DEDUP_FILE" 2>/dev/null || echo 0) # REASON: malformed dedup state should be treated as unsuppressed.
    [[ "$last_seen" =~ ^[0-9]+$ ]] || last_seen=0

    if (( now - last_seen < ARGUS_DEDUP_WINDOW )); then
        return 0
    fi

    local tmp_file
    tmp_file="${ARGUS_DEDUP_FILE}.tmp"
    jq --arg key "$problem_key" --argjson now "$now" '
        .keys = (.keys // {})
        | .keys[$key] = {
            last_seen: $now,
            count: ((.keys[$key].count // 0) + 1)
        }
    ' "$ARGUS_DEDUP_FILE" > "$tmp_file" 2>/dev/null || echo '{"keys":{}}' > "$tmp_file" # REASON: dedup write failures should not block action execution.
    mv "$tmp_file" "$ARGUS_DEDUP_FILE"
    return 1
}

relay_enabled_argus() {
    case "${ARGUS_RELAY_ENABLED,,}" in
        1|true|yes|on) return 0 ;;
        *) return 1 ;;
    esac
}

relay_queue_fallback() {
    local payload="$1"
    mkdir -p "$(dirname "$ARGUS_RELAY_FALLBACK_FILE")"
    printf '%s\n' "$payload" >> "$ARGUS_RELAY_FALLBACK_FILE"
}

relay_publish_problem() {
    local severity="${1:-info}"
    local problem_type="${2:-observation}"
    local message="${3:-}"
    local action_taken="${4:-log}"
    [[ -n "$message" ]] || return 0

    local host timestamp payload
    host=$(hostname -f 2>/dev/null || hostname) # REASON: FQDN may be unavailable; fallback to short hostname.
    timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    payload=$(jq -cn \
        --arg type "alert" \
        --arg source "argus" \
        --arg event "argus.problem" \
        --arg severity "$severity" \
        --arg problem_type "$problem_type" \
        --arg message "$message" \
        --arg action_taken "$action_taken" \
        --arg host "$host" \
        --arg ts "$timestamp" \
        '{type:$type, source:$source, event:$event, severity:$severity, problem_type:$problem_type, message:$message, action_taken:$action_taken, host:$host, timestamp:$ts}') || return 0

    if relay_enabled_argus && [[ -x "$ARGUS_RELAY_BIN" ]]; then
        if timeout "$ARGUS_RELAY_TIMEOUT" "$ARGUS_RELAY_BIN" send "$ARGUS_RELAY_TO" "$payload" \
            --agent "$ARGUS_RELAY_FROM" \
            --priority high \
            --tag "argus,problem,alert" >/dev/null 2>&1; then
            return 0
        fi
    fi

    relay_queue_fallback "$payload"
}

action_restart_service() {
    local service_name="$1"
    local reason="${2:-No reason provided}"

    # Validate service is in allowlist
    local allowed=false
    for svc in "${ALLOWED_SERVICES[@]}"; do
        if [[ "$svc" == "$service_name" ]]; then
            allowed=true
            break
        fi
    done

    if [[ "$allowed" != "true" ]]; then
        echo "BLOCKED: Service '$service_name' not in allowlist (${ALLOWED_SERVICES[*]})" >&2
        return 1
    fi

    echo "Restarting service: $service_name (reason: $reason)"

    # Check current state first
    local current_state
    current_state=$(systemctl is-active "$service_name" 2>/dev/null || echo "unknown") # REASON: inactive units can emit stderr during normal operation.
    echo "  Current state: $current_state"

    if ! systemctl restart "$service_name" 2>&1; then
        echo "ERROR: systemctl restart $service_name failed" >&2
        return 1
    fi

    # Verify the restart succeeded
    sleep 2
    local new_state
    new_state=$(systemctl is-active "$service_name" 2>/dev/null || echo "unknown") # REASON: unavailable units are expected when restart fails.
    if [[ "$new_state" == "active" ]]; then
        echo "Service $service_name restarted successfully (now: $new_state)"
    else
        echo "WARNING: Service $service_name restart may have failed (state: $new_state)" >&2
        return 1
    fi
}

action_kill_pid() {
    local pid="$1"
    local reason="${2:-No reason provided}"

    # Validate PID is numeric
    if [[ ! "$pid" =~ ^[0-9]+$ ]]; then
        echo "BLOCKED: PID '$pid' is not a valid number" >&2
        return 1
    fi

    # Validate PID exists
    if ! ps -p "$pid" > /dev/null 2>&1; then
        echo "ERROR: PID $pid does not exist (may have already exited)" >&2
        return 1
    fi

    # Validate process matches allowed patterns
    local cmdline
    cmdline=$(ps -p "$pid" -o comm= 2>/dev/null || echo "") # REASON: process may exit between checks; empty command is handled.

    if [[ ! "$cmdline" =~ (node|claude|codex) ]]; then
        echo "BLOCKED: PID $pid ($cmdline) does not match allowed patterns (node|claude|codex)" >&2
        return 1
    fi

    echo "Killing process: PID $pid ($cmdline) (reason: $reason)"
    if kill "$pid" 2>/dev/null; then # REASON: process may exit before signal delivery; warning is logged below.
        echo "Process $pid sent SIGTERM"
    else
        echo "WARNING: kill $pid failed (may have already exited)" >&2
    fi
}

action_kill_tmux() {
    local session_name="$1"
    local reason="${2:-No reason provided}"

    # Sanitize session name — prevent injection via tmux target
    if [[ "$session_name" =~ [^a-zA-Z0-9._-] ]]; then
        echo "BLOCKED: Tmux session name '$session_name' contains invalid characters" >&2
        return 1
    fi

    # Check if session exists
    if ! tmux has-session -t "$session_name" 2>/dev/null; then # REASON: missing session is a normal state probe result.
        echo "ERROR: Tmux session '$session_name' does not exist" >&2
        return 1
    fi

    echo "Killing tmux session: $session_name (reason: $reason)"
    tmux kill-session -t "$session_name"
    echo "Tmux session '$session_name' killed"
}

action_alert() {
    local message="$1"

    # Prepend hostname if not already present
    local hostname_tag
    hostname_tag=$(hostname -f 2>/dev/null || hostname) # REASON: FQDN may be unavailable; fallback to short hostname.
    if [[ "$message" != *"$hostname_tag"* ]] && [[ "$message" != *"["* ]]; then
        message="[${hostname_tag}] ${message}"
    fi

    relay_publish_problem "critical" "alert" "$message" "alert" || true # REASON: relay publishing is best-effort and must not block alert handling.

    if [[ -z "${TELEGRAM_BOT_TOKEN:-}" ]] || [[ -z "${TELEGRAM_CHAT_ID:-}" ]]; then
        echo "WARNING: Telegram credentials not configured — alert logged only" >&2
        echo "ALERT (not sent): $message"
        return 0
    fi

    # Build JSON payload safely with jq (prevents injection)
    local payload
    payload=$(jq -n \
        --arg chat_id "$TELEGRAM_CHAT_ID" \
        --arg text "$message" \
        '{chat_id: $chat_id, text: $text, disable_web_page_preview: true}')

    echo "Sending Telegram alert: $message"

    # Retry loop for transient network failures
    local attempt
    for (( attempt = 1; attempt <= TELEGRAM_MAX_RETRIES; attempt++ )); do
        local response http_code
        response=$(curl -s -m "$TELEGRAM_TIMEOUT" -w '\n%{http_code}' -X POST \
            "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
            -H "Content-Type: application/json" \
            -d "$payload" 2>&1) || true # REASON: curl transport failures are retried in-loop without aborting the cycle.

        # Extract HTTP status code (last line)
        http_code=$(echo "$response" | tail -n1)
        response=$(echo "$response" | sed '$d')

        if [[ "$http_code" == "200" ]] && echo "$response" | jq -e '.ok' > /dev/null 2>&1; then
            echo "Alert sent successfully"
            return 0
        fi

        if (( attempt < TELEGRAM_MAX_RETRIES )); then
            echo "Telegram attempt $attempt failed (HTTP $http_code), retrying in 3s..." >&2
            sleep 3
        else
            echo "ERROR: Failed to send Telegram alert after $attempt attempts (HTTP $http_code)" >&2
            # Don't return 1 — alert failure shouldn't fail the cycle
            return 0
        fi
    done
}

action_log() {
    local observation="$1"
    local log_file="${ARGUS_OBSERVATIONS_FILE:-$HOME/athena/state/argus/observations.md}"
    local log_dir
    log_dir=$(dirname "$log_file")

    mkdir -p "$log_dir"

    local timestamp
    timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    # Rotate observations file if it grows too large (> 500KB)
    if [[ -f "$log_file" ]]; then
        local obs_size
        obs_size=$(stat -c%s "$log_file" 2>/dev/null || echo 0) # REASON: unreadable files should not stop observation logging.
        if (( obs_size > 512000 )); then
            mv "$log_file" "${log_file}.old"
            echo "# Argus Observations (rotated at $timestamp)" > "$log_file"
            echo "" >> "$log_file"
        fi
    fi

    echo "- **[$timestamp]** $observation" >> "$log_file"
    echo "Observation logged: $observation"

    local severity
    severity=$(infer_problem_severity "$observation")
    relay_publish_problem "$severity" "observation" "$observation" "log" || true # REASON: relay publishing is optional and non-blocking.

    # Check if this is a repeated problem (same observation 3+ times)
    # Use fixed-string grep to avoid regex injection from observation text
    local key_phrase="${observation:0:50}"
    local repeat_count=0
    if [[ -f "$log_file" ]]; then
        repeat_count=$(grep -cF "$key_phrase" "$log_file" 2>/dev/null || echo 0) # REASON: missing/rotating logs should be treated as zero matches.
    fi

    local problem_script="$HOME/athena/scripts/problem-detected.sh"
    if (( repeat_count >= 3 )) && [[ -x "$problem_script" ]]; then
        # Repeated problem — create a bead (only if no bead exists for this issue)
        local problems_file="$HOME/athena/state/problems.jsonl"
        if ! grep -qF "$key_phrase" "$problems_file" 2>/dev/null; then # REASON: missing problem file means no prior record.
            "$problem_script" "argus" "$observation" "Repeated ${repeat_count}x" \
                >/dev/null 2>&1 || true # REASON: helper script is optional; failures must not break Argus.
        fi
    else
        # First occurrence — just wake Athena
        local wake_script="$HOME/athena/scripts/wake-gateway.sh"
        if [[ -x "$wake_script" ]]; then
            "$wake_script" "Argus observation: $observation" \
                >/dev/null 2>&1 || true # REASON: wake script is optional; failures must not break Argus.
        fi
    fi
}

# Auto-kill orphan node --test processes after repeated detection
ORPHAN_STATE_FILE="${ARGUS_ORPHAN_STATE:-$HOME/athena/state/argus-orphans.json}"
ORPHAN_KILL_THRESHOLD=3

action_check_and_kill_orphan_tests() {
    local dry_run="${1:-false}"
    local orphan_pids
    orphan_pids=$(pgrep -f 'node.*--test' 2>/dev/null || true) # REASON: no matches is expected and should not fail the cycle.

    if [[ -z "$orphan_pids" ]]; then
        # No orphans — reset counter
        if [[ -f "$ORPHAN_STATE_FILE" ]]; then
            rm -f "$ORPHAN_STATE_FILE"
        fi
        return 0
    fi

    local count
    count=$(echo "$orphan_pids" | wc -l)
    local now
    now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    # Read or init state
    local prev_count=0
    local first_seen="$now"
    if [[ -f "$ORPHAN_STATE_FILE" ]]; then
        prev_count=$(jq -r '.count // 0' "$ORPHAN_STATE_FILE" 2>/dev/null || echo 0) # REASON: corrupted state should degrade to safe defaults.
        first_seen=$(jq -r '.first_seen // ""' "$ORPHAN_STATE_FILE" 2>/dev/null || echo "$now") # REASON: missing prior timestamp falls back to now.
        [[ -z "$first_seen" ]] && first_seen="$now"
    fi

    local new_count=$((prev_count + 1))

    # Write state safely with jq
    mkdir -p "$(dirname "$ORPHAN_STATE_FILE")"
    jq -n \
        --arg pattern "node --test" \
        --argjson count "$new_count" \
        --argjson pids "$count" \
        --arg first_seen "$first_seen" \
        --arg last_seen "$now" \
        '{pattern: $pattern, count: $count, pids: $pids, first_seen: $first_seen, last_seen: $last_seen}' \
        > "$ORPHAN_STATE_FILE"

    local argus_log="${LOG_DIR:-${SCRIPT_DIR:-$HOME/argus}/logs}/argus.log"

    if (( new_count >= ORPHAN_KILL_THRESHOLD )); then
        echo "Orphan node --test detected ${new_count}x (threshold: ${ORPHAN_KILL_THRESHOLD}) — auto-killing ${count} processes"
        echo "[${now}] [ACTION] Auto-killing ${count} orphan node --test processes (detected ${new_count}x)" >> "$argus_log"

        if [[ "$dry_run" == "true" ]]; then
            echo "[DRY-RUN] Would kill PIDs: $(echo "$orphan_pids" | tr '\n' ' ')"
            log_problem "warning" "process" "Orphan node --test detected ${new_count}x; dry-run skip" "kill_orphan_tests:${count}" "skipped" "null" || true # REASON: registry writes are best-effort in dry-run mode.
            return 0
        fi

        local pid killed=0
        for pid in $orphan_pids; do
            if kill -TERM "$pid" 2>/dev/null; then # REASON: process may exit concurrently; missed kills are tolerated.
                killed=$((killed + 1))
            fi
        done

        # Wait 5s, then SIGKILL survivors
        sleep 5
        local force_killed=0
        for pid in $orphan_pids; do
            if kill -0 "$pid" 2>/dev/null; then # REASON: existence check may race with process exit.
                kill -9 "$pid" 2>/dev/null || true # REASON: stubborn process may exit before SIGKILL; continue cleanup.
                force_killed=$((force_killed + 1))
                echo "[${now}] [ACTION] SIGKILL sent to stubborn orphan PID ${pid}" >> "$argus_log"
            fi
        done

        # Reset state after kill
        rm -f "$ORPHAN_STATE_FILE"
        echo "Orphan cleanup complete: $killed SIGTERM, $force_killed SIGKILL"
        log_problem "warning" "process" "Auto-killed orphan node --test processes after repeated detection (${new_count}x)" "kill_orphan_tests:${count}" "success" "null" || true # REASON: registry write failures must not block remediation.
    else
        echo "Orphan node --test detected ${new_count}/${ORPHAN_KILL_THRESHOLD} — tracking"
        echo "[${now}] [INFO] Orphan node --test count: ${new_count}/${ORPHAN_KILL_THRESHOLD}" >> "$argus_log"
        log_problem "info" "process" "Orphan node --test detected (${new_count}/${ORPHAN_KILL_THRESHOLD}); tracking" "monitor_orphan_tests:${count}" "skipped" "null" || true # REASON: best-effort telemetry for non-critical tracking path.
    fi
}

# Execute action from JSON
execute_action() {
    local action_json="$1"

    # Validate we got valid JSON
    if ! echo "$action_json" | jq empty 2>/dev/null; then # REASON: invalid JSON parse errors are intentionally replaced with a clean validation error.
        echo "ERROR: Invalid action JSON: $action_json" >&2
        return 1
    fi

    local action_type
    action_type=$(echo "$action_json" | jq -r '.type // "unknown"')
    local target
    target=$(echo "$action_json" | jq -r '.target // empty')
    local reason
    reason=$(echo "$action_json" | jq -r '.reason // "No reason provided"')
    local description="$reason"
    local problem_type="process"
    local severity="info"
    local action_taken="${action_type}:${target}"
    local action_result="success"
    local action_failed=false
    local problem_key
    local recurrence_count=0
    local seen_count=1
    local should_create_bead=false
    local bead_id=""

    case "$action_type" in
        restart_service)
            problem_type="service"
            severity="warning"
            description="Service action for ${target}: ${reason}"
            if ! action_restart_service "$target" "$reason"; then
                action_result="failure"
                severity="critical"
                action_failed=true
            fi
            ;;
        kill_pid)
            problem_type="process"
            severity="warning"
            description="Kill PID ${target}: ${reason}"
            if ! action_kill_pid "$target" "$reason"; then
                action_result="failure"
                severity="critical"
                action_failed=true
            fi
            ;;
        kill_tmux)
            problem_type="process"
            severity="warning"
            description="Kill tmux ${target}: ${reason}"
            if ! action_kill_tmux "$target" "$reason"; then
                action_result="failure"
                severity="critical"
                action_failed=true
            fi
            ;;
        alert)
            local message
            message=$(echo "$action_json" | jq -r '.message // .target // "No message"')
            description="$message"
            problem_type=$(infer_problem_type "$message")
            severity=$(infer_problem_severity "$message")
            action_taken="alert:telegram"
            problem_key=$(generate_problem_key "$problem_type" "$description")
            if dedup_should_suppress "$problem_key"; then
                action_result="suppressed"
                action_taken="alert:suppressed"
            else
                if ! action_alert "$message"; then
                    action_result="failure"
                    severity="critical"
                    action_failed=true
                fi
            fi
            ;;
        log)
            local observation
            observation=$(echo "$action_json" | jq -r '.observation // .target // "No observation"')
            description="$observation"
            problem_type=$(infer_problem_type "$observation")
            severity=$(infer_problem_severity "$observation")
            action_taken="log:observation"
            if ! action_log "$observation"; then
                action_result="failure"
                severity="critical"
                action_failed=true
            fi
            ;;
        *)
            echo "ERROR: Unknown action type '$action_type' — only restart_service, kill_pid, kill_tmux, alert, log are allowed" >&2
            return 1
            ;;
    esac

    if [[ -z "${problem_key:-}" ]]; then
        problem_key=$(generate_problem_key "$problem_type" "$description")
    fi
    recurrence_count=$(problem_occurrences_in_window "$problem_type" "$description")
    if [[ "$recurrence_count" =~ ^[0-9]+$ ]]; then
        seen_count=$((recurrence_count + 1))
    fi

    if [[ "$action_result" == "failure" ]]; then
        should_create_bead=true
    fi
    if (( seen_count >= ARGUS_BEAD_REPEAT_THRESHOLD )); then
        should_create_bead=true
    fi
    if ! action_has_automatic_remediation "$action_type"; then
        should_create_bead=true
    fi

    if [[ "$should_create_bead" == "true" ]]; then
        bead_id=$(create_bead "$problem_type" "$description" "$severity" "$action_taken" "$action_result" "$problem_key" "$seen_count")
    fi

    log_problem "$severity" "$problem_type" "$description" "$action_taken" "$action_result" "$bead_id" || true # REASON: action execution result should return even if registry append fails.

    if [[ "$action_failed" == "true" ]]; then
        return 1
    fi

    return 0
}
