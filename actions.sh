#!/usr/bin/env bash
set -euo pipefail

# actions.sh — ONLY allowlisted actions that Argus LLM can execute
#
# Security model: The LLM can only trigger these 5 actions.
# Each action validates its inputs before execution.

ALLOWED_SERVICES=()
TELEGRAM_TIMEOUT=10   # seconds for Telegram API calls
TELEGRAM_MAX_RETRIES=2 # retry failed Telegram sends

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
    current_state=$(systemctl is-active "$service_name" 2>/dev/null || echo "unknown")
    echo "  Current state: $current_state"

    if ! systemctl restart "$service_name" 2>&1; then
        echo "ERROR: systemctl restart $service_name failed" >&2
        return 1
    fi

    # Verify the restart succeeded
    sleep 2
    local new_state
    new_state=$(systemctl is-active "$service_name" 2>/dev/null || echo "unknown")
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
    cmdline=$(ps -p "$pid" -o comm= 2>/dev/null || echo "")

    if [[ ! "$cmdline" =~ (node|claude|codex) ]]; then
        echo "BLOCKED: PID $pid ($cmdline) does not match allowed patterns (node|claude|codex)" >&2
        return 1
    fi

    echo "Killing process: PID $pid ($cmdline) (reason: $reason)"
    if kill "$pid" 2>/dev/null; then
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
    if ! tmux has-session -t "$session_name" 2>/dev/null; then
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
    hostname_tag=$(hostname -f 2>/dev/null || hostname)
    if [[ "$message" != *"$hostname_tag"* ]] && [[ "$message" != *"["* ]]; then
        message="[${hostname_tag}] ${message}"
    fi

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
            -d "$payload" 2>&1) || true

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
        obs_size=$(stat -c%s "$log_file" 2>/dev/null || echo 0)
        if (( obs_size > 512000 )); then
            mv "$log_file" "${log_file}.old"
            echo "# Argus Observations (rotated at $timestamp)" > "$log_file"
            echo "" >> "$log_file"
        fi
    fi

    echo "- **[$timestamp]** $observation" >> "$log_file"
    echo "Observation logged: $observation"

    # Check if this is a repeated problem (same observation 3+ times)
    # Use fixed-string grep to avoid regex injection from observation text
    local key_phrase="${observation:0:50}"
    local repeat_count=0
    if [[ -f "$log_file" ]]; then
        repeat_count=$(grep -cF "$key_phrase" "$log_file" 2>/dev/null || echo 0)
    fi

    local problem_script="$HOME/athena/scripts/problem-detected.sh"
    if (( repeat_count >= 3 )) && [[ -x "$problem_script" ]]; then
        # Repeated problem — create a bead (only if no bead exists for this issue)
        local problems_file="$HOME/athena/state/problems.jsonl"
        if ! grep -qF "$key_phrase" "$problems_file" 2>/dev/null; then
            "$problem_script" "argus" "$observation" "Repeated ${repeat_count}x" \
                >/dev/null 2>&1 || true
        fi
    else
        # First occurrence — just wake Athena
        local wake_script="$HOME/athena/scripts/wake-gateway.sh"
        if [[ -x "$wake_script" ]]; then
            "$wake_script" "Argus observation: $observation" \
                >/dev/null 2>&1 || true
        fi
    fi
}

# Auto-kill orphan node --test processes after repeated detection
ORPHAN_STATE_FILE="${ARGUS_ORPHAN_STATE:-$HOME/athena/state/argus-orphans.json}"
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
            return 0
        fi

        local pid killed=0
        for pid in $orphan_pids; do
            if kill -TERM "$pid" 2>/dev/null; then
                killed=$((killed + 1))
            fi
        done

        # Wait 5s, then SIGKILL survivors
        sleep 5
        local force_killed=0
        for pid in $orphan_pids; do
            if kill -0 "$pid" 2>/dev/null; then
                kill -9 "$pid" 2>/dev/null || true
                force_killed=$((force_killed + 1))
                echo "[${now}] [ACTION] SIGKILL sent to stubborn orphan PID ${pid}" >> "$argus_log"
            fi
        done

        # Reset state after kill
        rm -f "$ORPHAN_STATE_FILE"
        echo "Orphan cleanup complete: $killed SIGTERM, $force_killed SIGKILL"
    else
        echo "Orphan node --test detected ${new_count}/${ORPHAN_KILL_THRESHOLD} — tracking"
        echo "[${now}] [INFO] Orphan node --test count: ${new_count}/${ORPHAN_KILL_THRESHOLD}" >> "$argus_log"
    fi
}

# Execute action from JSON
execute_action() {
    local action_json="$1"

    # Validate we got valid JSON
    if ! echo "$action_json" | jq empty 2>/dev/null; then
        echo "ERROR: Invalid action JSON: $action_json" >&2
        return 1
    fi

    local action_type
    action_type=$(echo "$action_json" | jq -r '.type // "unknown"')
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
            message=$(echo "$action_json" | jq -r '.message // .target // "No message"')
            action_alert "$message"
            ;;
        log)
            local observation
            observation=$(echo "$action_json" | jq -r '.observation // .target // "No observation"')
            action_log "$observation"
            ;;
        *)
            echo "ERROR: Unknown action type '$action_type' — only restart_service, kill_pid, kill_tmux, alert, log are allowed" >&2
            return 1
            ;;
    esac
}
