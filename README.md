# Argus Ops Watchdog

Argus is a standalone systemd service that monitors server health and takes corrective action autonomously. It uses Claude Haiku to reason about system metrics every 5 minutes.

## Architecture

```
Every 5 minutes:
  collect metrics -> send to Claude Haiku -> parse JSON response -> execute actions -> log results
```

- **Standalone**: runs as a systemd service, independent of other systems
- **AI-powered**: Claude Haiku analyzes metrics and decides what to do
- **Safe by design**: LLM can only execute 5 allowlisted actions with input validation
- **Self-monitoring**: tracks its own cycle success/failure and alerts on repeated failures

## Components

| File | Purpose |
|------|---------|
| `argus.sh` | Main monitoring loop, LLM integration, log rotation |
| `collectors.sh` | Metric collection (services, system, processes, Athena, agents) |
| `actions.sh` | 5 allowlisted action executors with validation |
| `prompt.md` | System prompt — the decision-making brain |
| `argus.service` | Systemd unit with resource limits and security hardening |
| `install.sh` | Idempotent installer |

## Monitored Metrics

1. **Services**: `openclaw-gateway`, `mcp-agent-mail` — status and downtime
2. **System**: memory (MB and %), disk, swap, CPU cores, load average, uptime
3. **Processes**: orphan `node --test` count and age, tmux sessions
4. **Athena**: memory file activity, API reachability (localhost:9000)
5. **Agents**: tmux session names and counts

## Allowlisted Actions

The LLM can **only** execute these 5 actions:

| Action | Target | Validation |
|--------|--------|------------|
| `restart_service` | `openclaw-gateway` or `mcp-agent-mail` | Service allowlist |
| `kill_pid` | Specific PID | Must be numeric, must exist, must be node/claude/codex |
| `kill_tmux` | Session name | Must exist, name sanitized |
| `alert` | Telegram message | Hostname auto-prepended, retry on failure |
| `log` | Observation text | Auto-escalates after 3+ repeats |

Additionally, orphan `node --test` processes are auto-killed **deterministically** (no LLM involved) after 3 consecutive detections.

## Installation

### 1. Configure Environment

```bash
cd ~/argus
cp argus.env.example argus.env
nano argus.env
```

Required in `argus.env`:
- `ANTHROPIC_API_KEY` — for Claude API access

Optional:
- `TELEGRAM_BOT_TOKEN` — create bot with @BotFather
- `TELEGRAM_CHAT_ID` — get from `https://api.telegram.org/bot<TOKEN>/getUpdates`

### 2. Install Service

```bash
chmod +x install.sh
./install.sh
```

### 3. Verify

```bash
sudo systemctl status argus
tail -f ~/argus/logs/argus.log
```

## Usage

```bash
# Service management
sudo systemctl start|stop|restart|status argus

# Logs
sudo journalctl -u argus -f           # systemd journal
tail -f ~/argus/logs/argus.log         # application log

# Debug
cat ~/argus/logs/last_response.json | jq  # last LLM decision
cat ~/argus/logs/cycle_state.json | jq    # cycle health

# Test single cycle (without service)
source argus.env && ./argus.sh --once
```

## Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `ARGUS_INTERVAL` | `300` | Seconds between monitoring cycles |
| `ARGUS_MEMORY_DIR` | `~/.openclaw/workspace/memory` | Athena memory directory |
| `ARGUS_OBSERVATIONS_FILE` | `~/.openclaw/workspace/state/argus/observations.md` | Observation log |
| `ARGUS_ORPHAN_STATE` | `~/.openclaw/workspace/state/argus-orphans.json` | Orphan tracking state |

## Reliability Features

- **Log rotation**: argus.log rotates at 10MB, keeps 3 backups
- **Observation rotation**: observations.md rotates at 500KB
- **Disk space guard**: skips LLM call if disk < 100MB free
- **Telegram retry**: retries failed alerts (transient network issues)
- **Self-monitoring**: tracks consecutive failures, alerts after 3
- **JSON safety**: all state files written via `jq` (no injection from error messages)
- **Signal handling**: clean shutdown on SIGTERM/SIGINT
- **Systemd resource limits**: MemoryMax=1G prevents runaway processes

## Security

- No arbitrary command execution — only 5 allowlisted actions
- PID kills require: numeric validation + process exists + name matches `node|claude|codex`
- Service restarts limited to explicit allowlist
- Tmux session names sanitized against injection
- Telegram payloads built with `jq` (not string interpolation)
- systemd: `NoNewPrivileges`, `ProtectSystem=strict`, `PrivateTmp`

## Adapting for Your Server

1. Edit service names in `collectors.sh` (`collect_services`)
2. Update `ALLOWED_SERVICES` in `actions.sh`
3. Customize decision rules in `prompt.md`
4. Test with `./argus.sh --once` before enabling

## License

MIT
