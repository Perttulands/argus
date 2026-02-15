#!/usr/bin/env bash
set -euo pipefail

# actions.sh — ONLY allowlisted actions that Argus LLM can execute

ALLOWED_SERVICES=("openclaw-gateway" "mcp-agent-mail")
TELEGRAM_TIMEOUT=10  # seconds for Telegram API calls

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
        echo "ERROR: Service '$service_name' not in allowlist" >&2
        return 1
    fi

    echo "Restarting service: $service_name (reason: $reason)"
    if ! systemctl restart "$service_name" 2>&1; then
        echo "ERROR: systemctl restart $service_name failed" >&2
        return 1
    fi
    echo "Service $service_name restarted successfully"
}

action_kill_pid() {
    local pid="$1"
    local reason="${2:-No reason provided}"

    # Validate PID is numeric
    if [[ ! "$pid" =~ ^[0-9]+$ ]]; then
        echo "ERROR: PID '$pid' is not a valid number" >&2
        return 1
    fi

    # Validate PID exists and matches allowed process patterns
    if ! ps -p "$pid" > /dev/null 2>&1; then
        echo "ERROR: PID $pid does not exist" >&2
        return 1
    fi

    local cmdline
    cmdline=$(ps -p "$pid" -o comm= 2>/dev/null || echo "")

    if [[ ! "$cmdline" =~ (node|claude|codex) ]]; then
        echo "ERROR: PID $pid ($cmdline) does not match allowed patterns (node|claude|codex)" >&2
        return 1
    fi

    echo "Killing process: PID $pid ($cmdline) (reason: $reason)"
    kill "$pid"
    echo "Process $pid killed successfully"
}

action_kill_tmux() {
    local session_name="$1"
    local reason="${2:-No reason provided}"

    # Check if session exists
    if ! tmux has-session -t "$session_name" 2>/dev/null; then
        echo "ERROR: Tmux session '$session_name' does not exist" >&2
        return 1
    fi

    echo "Killing tmux session: $session_name (reason: $reason)"
    tmux kill-session -t "$session_name"
    echo "Tmux session $session_name killed successfully"
}

action_alert() {
    local message="$1"

    if [[ -z "${TELEGRAM_BOT_TOKEN:-}" ]] || [[ -z "${TELEGRAM_CHAT_ID:-}" ]]; then
        echo "WARNING: TELEGRAM_BOT_TOKEN or TELEGRAM_CHAT_ID not set — alert logged but not sent" >&2
        echo "ALERT (not sent): $message"
        return 0
    fi

    # Build JSON payload safely with jq
    local payload
    payload=$(jq -n \
        --arg chat_id "$TELEGRAM_CHAT_ID" \
        --arg text "$message" \
        '{chat_id: $chat_id, text: $text}')

    echo "Sending alert to Telegram: $message"

    local response http_code
    response=$(curl -s -m "$TELEGRAM_TIMEOUT" -w '\n%{http_code}' -X POST \
        "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -H "Content-Type: application/json" \
        -d "$payload" 2>&1) || true

    # Extract HTTP status code (last line)
    http_code=$(echo "$response" | tail -n1)
    response=$(echo "$response" | sed '$d')

    if [[ "$http_code" == "200" ]] && echo "$response" | jq -e '.ok' > /dev/null 2>&1; then
        echo "Alert sent successfully"
    else
        echo "ERROR: Failed to send Telegram alert (HTTP $http_code): $response" >&2
        return 1
    fi
}

action_log() {
    local observation="$1"
    local log_file="${ARGUS_OBSERVATIONS_FILE:-$HOME/.openclaw/workspace/state/argus/observations.md}"
    local log_dir
    log_dir=$(dirname "$log_file")

    mkdir -p "$log_dir"

    local timestamp
    timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    echo "Logging observation to $log_file"
    echo "- **[$timestamp]** $observation" >> "$log_file"
    echo "Observation logged successfully"

    # Check if this is a repeated problem (same observation 3+ times)
    # Use fixed-string grep to avoid regex injection from observation text
    local key_phrase="${observation:0:50}"
    local repeat_count=0
    if [[ -f "$log_file" ]]; then
        repeat_count=$(grep -cF "$key_phrase" "$log_file" 2>/dev/null || echo 0)
    fi

    local problem_script="$HOME/.openclaw/workspace/scripts/problem-detected.sh"
    if (( repeat_count >= 3 )) && [[ -x "$problem_script" ]]; then
        # Repeated problem — create a bead (only if no bead exists for this issue)
        local problems_file="$HOME/.openclaw/workspace/state/problems.jsonl"
        if ! grep -qF "$key_phrase" "$problems_file" 2>/dev/null; then
            "$problem_script" "argus" "$observation" "Repeated ${repeat_count}x" \
                >/dev/null 2>&1 || true
        fi
    else
        # First occurrence — just wake Athena
        local wake_script="$HOME/.openclaw/workspace/scripts/wake-gateway.sh"
        if [[ -x "$wake_script" ]]; then
            "$wake_script" "Argus observation: $observation" \
                >/dev/null 2>&1 || true
        fi
    fi
}

# Auto-kill orphan node --test processes after repeated detection
ORPHAN_STATE_FILE="${ARGUS_ORPHAN_STATE:-$HOME/.openclaw/workspace/state/argus-orphans.json}"
ORPHAN_KILL_THRESHOLD=3

action_check_and_kill_orphan_tests() {
    local dry_run="${1:-false}"
    local orphan_pids
    orphan_pids=$(pgrep -f 'node.*--test' 2>/dev/null || true)

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
        prev_count=$(jq -r '.count // 0' "$ORPHAN_STATE_FILE" 2>/dev/null || echo 0)
        first_seen=$(jq -r '.first_seen // ""' "$ORPHAN_STATE_FILE" 2>/dev/null || echo "$now")
        [[ -z "$first_seen" ]] && first_seen="$now"
    fi

    local new_count=$((prev_count + 1))

    # Write state
    mkdir -p "$(dirname "$ORPHAN_STATE_FILE")"
    cat > "$ORPHAN_STATE_FILE" <<EOF
{"pattern":"node --test","count":${new_count},"pids":${count},"first_seen":"${first_seen}","last_seen":"${now}"}
EOF

    local argus_log="${LOG_DIR:-${SCRIPT_DIR:-$HOME/argus}/logs}/argus.log"

    if (( new_count >= ORPHAN_KILL_THRESHOLD )); then
        echo "Orphan node --test detected ${new_count}x (threshold: ${ORPHAN_KILL_THRESHOLD}) — auto-killing ${count} processes"
        echo "[${now}] [ACTION] Auto-killing ${count} orphan node --test processes (detected ${new_count}x)" >> "$argus_log"

        if [[ "$dry_run" == "true" ]]; then
            echo "[DRY-RUN] Would kill PIDs: $(echo "$orphan_pids" | tr '\n' ' ')"
            return 0
        fi

        local pid
        for pid in $orphan_pids; do
            kill -TERM "$pid" 2>/dev/null || true
        done

        # Wait 5s, then SIGKILL survivors
        sleep 5
        for pid in $orphan_pids; do
            if kill -0 "$pid" 2>/dev/null; then
                kill -9 "$pid" 2>/dev/null || true
                echo "[${now}] [ACTION] SIGKILL sent to stubborn orphan PID ${pid}" >> "$argus_log"
            fi
        done

        # Reset state after kill
        rm -f "$ORPHAN_STATE_FILE"
        echo "Orphan cleanup complete"
    else
        echo "Orphan node --test detected ${new_count}/${ORPHAN_KILL_THRESHOLD} — tracking"
        echo "[${now}] [INFO] Orphan node --test count: ${new_count}/${ORPHAN_KILL_THRESHOLD}" >> "$argus_log"
    fi
}

# Execute action from JSON
execute_action() {
    local action_json="$1"

    local action_type
    action_type=$(echo "$action_json" | jq -r '.type')
    local target
    target=$(echo "$action_json" | jq -r '.target // empty')
    local reason
    reason=$(echo "$action_json" | jq -r '.reason // "No reason provided"')

    case "$action_type" in
        restart_service)
            action_restart_service "$target" "$reason"
            ;;
        kill_pid)
            action_kill_pid "$target" "$reason"
            ;;
        kill_tmux)
            action_kill_tmux "$target" "$reason"
            ;;
        alert)
            local message
            message=$(echo "$action_json" | jq -r '.message // .target')
            action_alert "$message"
            ;;
        log)
            local observation
            observation=$(echo "$action_json" | jq -r '.observation // .target')
            action_log "$observation"
            ;;
        *)
            echo "ERROR: Unknown action type: $action_type" >&2
            return 1
            ;;
    esac
}
