#!/usr/bin/env bash
set -euo pipefail

# collectors.sh — metric collection functions for Argus
#
# Each collector is wrapped to never fail fatally (set -e safe).
# A failing collector outputs an error line but does not abort the cycle.

collect_services() {
    echo "=== Services ==="
    for service in openclaw-gateway mcp-agent-mail; do
        local status
        status=$(systemctl is-active "$service" 2>/dev/null || echo "unknown")
        echo "$service: $status"
    done
}

collect_system() {
    echo "=== System ==="
    echo "Memory:"
    free -h 2>/dev/null | grep -E '(Mem|Swap)' || echo "free command failed"
    echo ""
    echo "Disk:"
    df -h / 2>/dev/null | tail -n1 || echo "df command failed"
    echo ""
    echo "Uptime and Load:"
    uptime 2>/dev/null || echo "uptime command failed"
}

collect_processes() {
    echo "=== Processes ==="
    echo "Orphan node --test processes:"
    # Use pgrep -c for count; -f matches full cmdline
    # Note: pgrep returns exit 1 when no matches, so we default to 0
    local orphan_count
    orphan_count=$(pgrep -cf 'node.*--test' 2>/dev/null || echo "0")
    echo "$orphan_count"
    echo ""
    echo "Tmux sessions on openclaw socket:"
    tmux -S /tmp/openclaw-coding-agents.sock list-sessions 2>/dev/null | wc -l || echo "0"
}

collect_athena() {
    echo "=== Athena ==="
    local memory_dir="${ARGUS_MEMORY_DIR:-$HOME/.openclaw/workspace/memory}"
    if [[ -d "$memory_dir" ]]; then
        echo "Memory file modifications:"
        find "$memory_dir" -name "*.md" -type f -printf "%T+ %p\n" 2>/dev/null | sort -r | head -n5 || echo "No .md files found"
    else
        echo "Memory directory not found"
    fi
    echo ""
    echo "Athena API check:"
    curl -s -m 5 http://localhost:9000 2>&1 || echo "Failed to connect"
}

collect_agents() {
    echo "=== Agents ==="
    echo "Standard tmux sessions:"
    tmux list-sessions 2>/dev/null | wc -l || echo "0"
    echo ""
    echo "Session names:"
    tmux list-sessions -F "#{session_name}" 2>/dev/null || echo "No sessions"
    echo ""
    echo "OpenClaw socket sessions:"
    tmux -S /tmp/openclaw-coding-agents.sock list-sessions -F "#{session_name}" 2>/dev/null || echo "No OpenClaw sessions"
}

# Main collection function that calls all collectors.
# Each collector runs in a subshell so a failure in one does not abort others.
collect_all_metrics() {
    echo "===== ARGUS METRICS COLLECTION ====="
    echo "Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo ""

    local collectors=(collect_services collect_system collect_processes collect_athena collect_agents)
    for collector in "${collectors[@]}"; do
        if ! "$collector" 2>&1; then
            echo "ERROR: ${collector} failed"
        fi
        echo ""
    done

    echo "===== END METRICS ====="
}
