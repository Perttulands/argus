#!/usr/bin/env bash
set -euo pipefail

# actions.sh — ONLY allowlisted actions that Argus LLM can execute

ALLOWED_SERVICES=("openclaw-gateway" "mcp-agent-mail")

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
    systemctl restart "$service_name"
    echo "Service $service_name restarted successfully"
}

action_kill_pid() {
    local pid="$1"
    local reason="${2:-No reason provided}"

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
        echo "ERROR: TELEGRAM_BOT_TOKEN or TELEGRAM_CHAT_ID not set" >&2
        return 1
    fi

    local escaped_message
    escaped_message=$(echo "$message" | jq -Rs .)

    echo "Sending alert to Telegram: $message"

    local response
    response=$(curl -s -X POST \
        "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -H "Content-Type: application/json" \
        -d "{\"chat_id\": \"${TELEGRAM_CHAT_ID}\", \"text\": ${escaped_message}, \"parse_mode\": \"Markdown\"}")

    if echo "$response" | jq -e '.ok' > /dev/null 2>&1; then
        echo "Alert sent successfully"
    else
        echo "ERROR: Failed to send alert: $response" >&2
        return 1
    fi
}

action_log() {
    local observation="$1"
    local log_file="$HOME/.openclaw/workspace/state/argus/observations.md"
    local log_dir
    log_dir=$(dirname "$log_file")

    mkdir -p "$log_dir"

    local timestamp
    timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    echo "Logging observation to $log_file"
    echo "- **[$timestamp]** $observation" >> "$log_file"
    echo "Observation logged successfully"
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
