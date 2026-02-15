#!/usr/bin/env bash
set -euo pipefail

# argus.sh — main monitoring loop for Argus ops watchdog

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${SCRIPT_DIR}/logs"
PROMPT_FILE="${SCRIPT_DIR}/prompt.md"
SLEEP_INTERVAL=300  # 5 minutes
LLM_TIMEOUT=120     # max seconds for claude -p call
CYCLE_STATE_FILE="${LOG_DIR}/cycle_state.json"

# Source helper scripts
source "${SCRIPT_DIR}/collectors.sh"
source "${SCRIPT_DIR}/actions.sh"

# Ensure log directory exists
mkdir -p "$LOG_DIR"

log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp
    timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    echo "[$timestamp] [$level] $message" | tee -a "${LOG_DIR}/argus.log"
}

call_llm() {
    local system_prompt="$1"
    local user_message="$2"

    local full_prompt
    full_prompt=$(printf '%s\n\n---\n\n%s\n\nRespond with ONLY valid JSON. No markdown, no explanation.' "$system_prompt" "$user_message")

    local response exit_code
    response=$(timeout "$LLM_TIMEOUT" bash -c 'echo "$1" | claude -p --model haiku --output-format text 2>/dev/null' _ "$full_prompt") && exit_code=0 || exit_code=$?

    if [[ $exit_code -ne 0 ]]; then
        if [[ $exit_code -eq 124 ]]; then
            log ERROR "claude -p timed out after ${LLM_TIMEOUT}s"
        else
            log ERROR "claude -p call failed (exit code: $exit_code)"
        fi
        return 1
    fi

    if [[ -z "$response" ]]; then
        log ERROR "Empty response from claude -p"
        return 1
    fi

    echo "$response"
}

process_llm_response() {
    local response="$1"

    # Strip markdown code fences if present (```json ... ``` wrapper)
    response=$(echo "$response" | sed '/^```json$/d; /^```$/d')

    # Validate JSON
    if ! echo "$response" | jq empty 2>/dev/null; then
        log ERROR "LLM response is not valid JSON"
        log DEBUG "Response: $response"
        return 1
    fi

    # Extract assessment
    local assessment
    assessment=$(echo "$response" | jq -r '.assessment // "No assessment provided"')
    log INFO "Assessment: $assessment"

    # Extract and log observations
    local observations
    observations=$(echo "$response" | jq -r '.observations[]? // empty')
    if [[ -n "$observations" ]]; then
        log INFO "Observations:"
        while IFS= read -r obs; do
            log INFO "  - $obs"
        done <<< "$observations"
    fi

    # Execute actions
    local actions
    actions=$(echo "$response" | jq -c '.actions[]? // empty')

    if [[ -z "$actions" ]]; then
        log INFO "No actions to execute"
        return 0
    fi

    log INFO "Executing actions:"
    local action_count=0
    while IFS= read -r action; do
        action_count=$((action_count + 1))
        local action_type
        action_type=$(echo "$action" | jq -r '.type')
        log INFO "  Action $action_count: $action_type"

        if execute_action "$action"; then
            log INFO "  Action $action_count completed successfully"
        else
            log ERROR "  Action $action_count failed"
        fi
    done <<< "$actions"
}

# Record cycle outcome for self-monitoring
record_cycle_state() {
    local status="$1"  # ok | failed
    local detail="${2:-}"
    local now
    now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    local prev_failures=0
    if [[ -f "$CYCLE_STATE_FILE" ]]; then
        prev_failures=$(jq -r '.consecutive_failures // 0' "$CYCLE_STATE_FILE" 2>/dev/null || echo 0)
    fi

    local consecutive_failures=0
    if [[ "$status" == "failed" ]]; then
        consecutive_failures=$((prev_failures + 1))
    fi

    cat > "$CYCLE_STATE_FILE" <<-CEOF
{"status":"${status}","timestamp":"${now}","detail":"${detail}","consecutive_failures":${consecutive_failures}}
CEOF
}

# Check if previous cycle failed and include that in metrics
check_previous_cycle() {
    if [[ ! -f "$CYCLE_STATE_FILE" ]]; then
        echo "Previous cycle: no state (first run or state cleared)"
        return 0
    fi

    local prev_status prev_detail prev_ts prev_failures
    prev_status=$(jq -r '.status // "unknown"' "$CYCLE_STATE_FILE" 2>/dev/null || echo "unknown")
    prev_detail=$(jq -r '.detail // ""' "$CYCLE_STATE_FILE" 2>/dev/null || echo "")
    prev_ts=$(jq -r '.timestamp // ""' "$CYCLE_STATE_FILE" 2>/dev/null || echo "")
    prev_failures=$(jq -r '.consecutive_failures // 0' "$CYCLE_STATE_FILE" 2>/dev/null || echo 0)

    if [[ "$prev_status" == "failed" ]]; then
        echo "WARNING: Previous cycle FAILED at ${prev_ts}: ${prev_detail}"
        echo "Consecutive failures: ${prev_failures}"

        # Alert if 3+ consecutive failures
        if (( prev_failures >= 3 )); then
            log ERROR "SELF-MONITOR: ${prev_failures} consecutive cycle failures"
            if [[ -n "${TELEGRAM_BOT_TOKEN:-}" ]] && [[ -n "${TELEGRAM_CHAT_ID:-}" ]]; then
                action_alert "Argus self-monitor: ${prev_failures} consecutive cycle failures. Last error: ${prev_detail}" || true
            fi
        fi
    else
        echo "Previous cycle: ${prev_status} at ${prev_ts}"
    fi
}

run_monitoring_cycle() {
    log INFO "===== Starting monitoring cycle ====="

    # Self-monitoring: check previous cycle state
    log INFO "Checking previous cycle state..."
    local self_check
    self_check=$(check_previous_cycle)
    log INFO "$self_check"

    # Deterministic orphan auto-kill (no LLM needed)
    log INFO "Checking orphan node --test processes..."
    action_check_and_kill_orphan_tests "false" || log ERROR "Orphan check failed"

    # Collect metrics
    log INFO "Collecting metrics..."
    local metrics
    metrics=$(collect_all_metrics 2>&1)

    # Append self-monitoring info to metrics
    metrics=$(printf '%s\n\n=== Argus Self-Monitor ===\n%s' "$metrics" "$self_check")

    # Load system prompt
    if [[ ! -f "$PROMPT_FILE" ]]; then
        log ERROR "Prompt file not found: $PROMPT_FILE"
        record_cycle_state "failed" "Prompt file missing"
        return 1
    fi
    local system_prompt
    system_prompt=$(cat "$PROMPT_FILE")

    # Substitute hostname placeholder
    local hostname
    hostname=$(hostname -f 2>/dev/null || hostname)
    system_prompt="${system_prompt//<YOUR_HOSTNAME>/$hostname}"

    # Call LLM
    log INFO "Calling claude -p..."
    local llm_response
    if ! llm_response=$(call_llm "$system_prompt" "$metrics"); then
        log ERROR "Failed to get response from LLM"
        record_cycle_state "failed" "LLM call failed"
        return 1
    fi

    # Save raw response for debugging
    echo "$llm_response" > "${LOG_DIR}/last_response.json"

    # Process response and execute actions
    log INFO "Processing LLM response..."
    if ! process_llm_response "$llm_response"; then
        log ERROR "Failed to process LLM response"
        record_cycle_state "failed" "LLM response processing failed"
        return 1
    fi

    record_cycle_state "ok"
    log INFO "===== Monitoring cycle completed ====="
}

main() {
    log INFO "Argus ops watchdog starting..."

    # Check for --once flag
    local run_once=false
    if [[ "${1:-}" == "--once" ]]; then
        run_once=true
        log INFO "Running in single-shot mode (--once)"
    fi

    # Verify dependencies
    local missing=()
    for cmd in claude jq curl; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        log ERROR "Missing required commands: ${missing[*]}"
        exit 1
    fi

    # Run monitoring loop
    if [[ "$run_once" == "true" ]]; then
        run_monitoring_cycle || log ERROR "Monitoring cycle failed"
    else
        log INFO "Starting continuous monitoring loop (${SLEEP_INTERVAL}s interval)"
        while true; do
            if ! run_monitoring_cycle; then
                log ERROR "Monitoring cycle failed, continuing..."
            fi
            log INFO "Sleeping for ${SLEEP_INTERVAL} seconds..."
            sleep "$SLEEP_INTERVAL"
        done
    fi
}

# Handle signals gracefully
trap 'log INFO "Received signal, shutting down..."; exit 0' SIGTERM SIGINT

main "$@"
