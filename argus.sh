#!/usr/bin/env bash
set -euo pipefail

# argus.sh — main monitoring loop for Argus ops watchdog

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${SCRIPT_DIR}/logs"
PROMPT_FILE="${SCRIPT_DIR}/prompt.md"
SLEEP_INTERVAL=300  # 5 minutes

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

    local response
    if ! response=$(echo "$full_prompt" | claude -p --model haiku --output-format text 2>/dev/null); then
        log ERROR "claude -p call failed"
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

    # Strip markdown code fences if present
    response=$(echo "$response" | sed 's/^```json//;s/^```//')

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
        ((action_count++))
        local action_type
        action_type=$(echo "$action" | jq -r '.type')
        log INFO "  Action $action_count: $action_type"

        if execute_action "$action"; then
            log INFO "  ✓ Action completed successfully"
        else
            log ERROR "  ✗ Action failed"
        fi
    done <<< "$actions"
}

run_monitoring_cycle() {
    log INFO "===== Starting monitoring cycle ====="

    # Collect metrics
    log INFO "Collecting metrics..."
    local metrics
    metrics=$(collect_all_metrics 2>&1)

    # Load system prompt
    if [[ ! -f "$PROMPT_FILE" ]]; then
        log ERROR "Prompt file not found: $PROMPT_FILE"
        return 1
    fi
    local system_prompt
    system_prompt=$(cat "$PROMPT_FILE")

    # Call LLM
    log INFO "Calling claude -p..."
    local llm_response
    if ! llm_response=$(call_llm "$system_prompt" "$metrics"); then
        log ERROR "Failed to get response from LLM"
        return 1
    fi

    # Save raw response for debugging
    echo "$llm_response" > "${LOG_DIR}/last_response.json"

    # Process response and execute actions
    log INFO "Processing LLM response..."
    if ! process_llm_response "$llm_response"; then
        log ERROR "Failed to process LLM response"
        return 1
    fi

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

    # Verify claude is available
    if ! command -v claude &>/dev/null; then
        log ERROR "claude CLI not found. Install Claude Code first."
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
