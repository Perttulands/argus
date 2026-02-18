# 👁️ Argus — The The Faithful Hound

![Banner](banner.jpg)


_The ops watchdog that never blinks._

---

In the Odyssey, Argus was Odysseus's dog — the one who waited twenty years and was the only one who recognised his master when he came home. Loyalty that outlasts everything. Our Argus has that same devotion: it watches your server, decides what's wrong, and fixes it before you notice.

Argus is a standalone systemd service that monitors server health every 5 minutes. It collects metrics, feeds them to Claude Haiku for reasoning, and executes a narrow set of allowlisted actions. It can restart services, kill runaway processes, send alerts, and file problem reports — but it can't do anything else. That constraint is the whole point.

You don't want your AI watchdog to be creative. You want it to be correct, boring, and relentless.

## How It Works

```
Every 5 minutes:
  collect metrics → reason with Claude Haiku → parse decision → execute actions → log results
```

Argus collects system metrics (CPU, memory, disk, swap, processes, service health), sends them to an LLM with a decision-making prompt, and acts on the response. The LLM can only execute **5 allowlisted actions** — there's no `exec("arbitrary shell command")` hiding in here.

| Action | What It Does | Safety |
|--------|-------------|--------|
| `restart_service` | Restarts a named service | Service must be in explicit allowlist |
| `kill_pid` | Kills a specific process | Must be numeric, must exist, must match `node\|claude\|codex` |
| `kill_tmux` | Kills a tmux session | Session name sanitized |
| `alert` | Sends a Telegram notification | Hostname auto-prepended, retry on failure |
| `log` | Records an observation | Auto-escalates after 3+ consecutive repeats |

Additionally, orphan `node --test` processes are auto-killed **deterministically** (no LLM involved) after 3 consecutive detections. Some things don't need AI. They need a cron job with opinions.

## Components

| File | Purpose |
|------|---------|
| `argus.sh` | Main loop — metric collection, LLM calls, action execution, log rotation |
| `collectors.sh` | Metric collectors — services, system stats, processes, agent sessions |
| `actions.sh` | The 5 allowlisted action executors with input validation |
| `prompt.md` | System prompt — Argus's brain. Edit this to change what it cares about |
| `argus.service` | Systemd unit with resource limits and security hardening |
| `install.sh` | Idempotent installer |

## Install

```bash
git clone https://github.com/Perttulands/argus.git
cd argus
cp argus.env.example argus.env
# Edit argus.env — add your ANTHROPIC_API_KEY (required)
# Optionally add TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID for alerts
chmod +x install.sh
./install.sh
```

## Usage

```bash
# Run a single cycle (no service needed)
source argus.env && ./argus.sh --once

# Service management
sudo systemctl start|stop|restart|status argus

# Watch it work
tail -f ~/argus/logs/argus.log

# See its last decision
cat ~/argus/logs/last_response.json | jq

# Check cycle health
cat ~/argus/logs/cycle_state.json | jq
```

## Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `ARGUS_INTERVAL` | `300` | Seconds between cycles |
| `ARGUS_OBSERVATIONS_FILE` | (configurable) | Where observations are logged |
| `ARGUS_ORPHAN_STATE` | (configurable) | Orphan process tracking state |

## Adapting for Your Server

Argus is opinionated about what it monitors, but those opinions are easy to change:

1. Edit service names in `collectors.sh`
2. Update `ALLOWED_SERVICES` in `actions.sh`
3. Customize the decision prompt in `prompt.md`
4. Test with `./argus.sh --once` before enabling the service

## Reliability

- Log rotation at 10MB (keeps 3 backups)
- Disk space guard — skips LLM call if < 100MB free
- Telegram alert retry on transient failures
- Self-monitoring — alerts after 3 consecutive cycle failures
- JSON state written via `jq` (no injection from error messages)
- Clean shutdown on SIGTERM/SIGINT
- systemd resource limits: `MemoryMax=1G`

## Security

No arbitrary command execution. Every action is validated:

- PIDs must be numeric, must exist, must match allowed process names
- Service restarts limited to explicit allowlist
- Tmux session names sanitized against injection
- Telegram payloads built with `jq`, not string interpolation
- systemd: `NoNewPrivileges`, `ProtectSystem=strict`, `PrivateTmp`

## Part of [Athena's Agora](https://github.com/Perttulands/athena-workspace)

Argus is one of several tools in the Agora — an autonomous coding and operations system built around AI agents. See the [mythology](https://github.com/Perttulands/athena-workspace/blob/main/mythology.md) for the full story.

## License

MIT
