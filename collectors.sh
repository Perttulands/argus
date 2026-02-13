#!/usr/bin/env bash
set -euo pipefail

# collectors.sh — metric collection functions for Argus

collect_services() {
    echo "=== Services ==="
    for service in openclaw-gateway mcp-agent-mail; do
        status=$(systemctl is-active "$service" 2>&1 || echo "unknown")
        echo "$service: $status"
    done
}

collect_system() {
    echo "=== System ==="
    echo "Memory:"
    free -h | grep -E '(Mem|Swap)'
    echo ""
    echo "Disk:"
    df -h / | tail -n1
    echo ""
    echo "Uptime and Load:"
    uptime
}

collect_processes() {
    echo "=== Processes ==="
    echo "Orphan node --test processes:"
    pgrep -fa 'node.*--test' | wc -l || echo "0"
    echo ""
    echo "Tmux sessions on openclaw socket:"
    tmux -S /tmp/openclaw-coding-agents.sock list-sessions 2>/dev/null | wc -l || echo "0"
}

collect_athena() {
    echo "=== Athena ==="
    memory_dir="$HOME/.openclaw/workspace/memory"
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

# Main collection function that calls all collectors
collect_all_metrics() {
    echo "===== ARGUS METRICS COLLECTION ====="
    echo "Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo ""
    collect_services
    echo ""
    collect_system
    echo ""
    collect_processes
    echo ""
    collect_athena
    echo ""
    collect_agents
    echo "===== END METRICS ====="
}
