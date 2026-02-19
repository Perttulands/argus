#!/usr/bin/env bash
set -euo pipefail

# collectors.sh — metric collection functions for Argus
#
# Each collector is wrapped to never fail fatally (set -e safe).
# A failing collector outputs an error line but does not abort the cycle.
# Collectors should output clear, parseable data with actual values
# so the LLM can make good decisions.

collect_services() {
    echo "=== Services ==="

    # openclaw-gateway: check ports 18505 (Athena) and 18789 (Mercury) (may run outside systemd)
    echo -n "openclaw-gateway: "
    local gw_http
    gw_http=$(curl -s -o /dev/null -w '%{http_code}' -m 5 http://localhost:18505/ 2>/dev/null) || gw_http="failed"
    if [[ "$gw_http" == "000" || "$gw_http" == "failed" ]]; then
        echo "DOWN (port 18505 unreachable)"
    else
        echo "UP (port 18505, HTTP $gw_http)"
    fi

    # athena-web removed from monitoring (2026-02-19)
}

collect_system() {
    echo "=== System ==="

    # Memory with parsed percentages for LLM
    echo "Memory:"
    if command -v free &>/dev/null; then
        local mem_line
        mem_line=$(free -m 2>/dev/null | grep '^Mem:') || true
        if [[ -n "$mem_line" ]]; then
            local total used avail pct
            total=$(echo "$mem_line" | awk '{print $2}')
            used=$(echo "$mem_line" | awk '{print $3}')
            avail=$(echo "$mem_line" | awk '{print $7}')
            if (( total > 0 )); then
                pct=$(( (used * 100) / total ))
                echo "  Used: ${used}MB / ${total}MB (${pct}%)"
                echo "  Available: ${avail}MB"
            else
                free -h 2>/dev/null | grep -E '(Mem|Swap)' || echo "  free command failed"
            fi
        fi
        # Swap
        local swap_line
        swap_line=$(free -m 2>/dev/null | grep '^Swap:') || true
        if [[ -n "$swap_line" ]]; then
            local swap_total swap_used
            swap_total=$(echo "$swap_line" | awk '{print $2}')
            swap_used=$(echo "$swap_line" | awk '{print $3}')
            if (( swap_total > 0 )); then
                local swap_pct=$(( (swap_used * 100) / swap_total ))
                echo "  Swap: ${swap_used}MB / ${swap_total}MB (${swap_pct}%)"
            else
                echo "  Swap: none configured"
            fi
        fi
    else
        echo "  free command not available"
    fi

    # Disk with parsed percentage
    echo "Disk (/):"
    if command -v df &>/dev/null; then
        local disk_line
        disk_line=$(df -h / 2>/dev/null | tail -n1) || true
        if [[ -n "$disk_line" ]]; then
            echo "  $disk_line"
        else
            echo "  df command failed"
        fi
    fi

    # CPU count (needed for load average interpretation)
    local cpu_count
    cpu_count=$(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo 2>/dev/null || echo "unknown")
    echo "CPU cores: $cpu_count"

    # Load average with context
    echo "Load average:"
    local loadavg
    loadavg=$(cat /proc/loadavg 2>/dev/null || uptime 2>/dev/null || echo "unknown")
    echo "  $loadavg"

    # Uptime
    echo "Uptime:"
    uptime -p 2>/dev/null || uptime 2>/dev/null || echo "  unknown"
}

collect_processes() {
    echo "=== Processes ==="

    # Orphan node --test — use pgrep -c; exclude our own grep
    echo "Orphan node --test processes:"
    local orphan_count
    orphan_count=$(pgrep -cf 'node.*--test' 2>/dev/null) || orphan_count=0
    echo "  Count: $orphan_count"

    # If there are orphans, show the oldest one's age
    if (( orphan_count > 0 )); then
        local oldest_pid
        oldest_pid=$(pgrep -f 'node.*--test' 2>/dev/null | head -1) || true
        if [[ -n "$oldest_pid" ]]; then
            local elapsed
            elapsed=$(ps -p "$oldest_pid" -o etime= 2>/dev/null | tr -d ' ') || true
            [[ -n "$elapsed" ]] && echo "  Oldest process age: $elapsed"
        fi
    fi

    echo "Tmux sessions on openclaw socket:"
    local oc_count
    oc_count=$(tmux -S /tmp/openclaw-coding-agents.sock list-sessions 2>/dev/null | wc -l) || oc_count=0
    oc_count=$(echo "$oc_count" | tr -d '[:space:]')
    echo "  Count: $oc_count"
}

collect_athena() {
    echo "=== Athena ==="
    local memory_dir="${ARGUS_MEMORY_DIR:-$HOME/.openclaw-athena/memory}"
    if [[ -d "$memory_dir" ]]; then
        echo "Memory file modifications (last 5):"
        find "$memory_dir" -name "*.md" -type f -printf "%T+ %p\n" 2>/dev/null | sort -r | head -n5 || echo "  No .md files found"
    else
        echo "Memory directory not found: $memory_dir"
    fi
    # Athena API (port 9000) removed from monitoring (2026-02-19)
}

collect_agents() {
    echo "=== Agents ==="
    echo "Standard tmux sessions:"
    local std_count
    std_count=$(tmux list-sessions 2>/dev/null | wc -l) || std_count=0
    std_count=$(echo "$std_count" | tr -d '[:space:]')
    echo "  Count: $std_count"
    if (( std_count > 0 )); then
        echo "  Names:"
        tmux list-sessions -F "    #{session_name} (#{session_windows} windows, created #{session_created_string})" 2>/dev/null || true
    fi
    echo "OpenClaw socket sessions:"
    local oc_sessions
    oc_sessions=$(tmux -S /tmp/openclaw-coding-agents.sock list-sessions -F "    #{session_name}" 2>/dev/null) || true
    if [[ -n "$oc_sessions" ]]; then
        echo "$oc_sessions"
    else
        echo "  None"
    fi
}

# Main collection function that calls all collectors.
# Each collector runs in a subshell so a failure in one does not abort others.
collect_all_metrics() {
    echo "===== ARGUS METRICS ====="
    echo "Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "Host: $(hostname -f 2>/dev/null || hostname)"
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
