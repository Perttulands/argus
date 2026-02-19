# 👁️ Argus — The Hound That Never Sleeps

![Banner](banner.jpg)

_One red eye. Always open. Your server's last line of defense._

---

There's a dog in the Agora with a spiked bronze collar and scars across his muzzle. One eye is normal. The other glows red — a scanner that sweeps the server every five minutes, cataloguing everything that breathes. A broken chain drags behind him. Nobody put Argus on a leash. Nobody could.

In the Odyssey, Argus was the dog who waited twenty years for Odysseus and was the only one who recognised his master when he came home. That kind of loyalty doesn't need commands. Our Argus has the same devotion, except instead of waiting on a porch, he patrols a Linux server, decides what's wrong, and fixes it before you notice. He's killed more orphan processes than he can count — the tally marks on his collar prove it.

You don't want your AI watchdog to be creative. You want it to be correct, boring, and relentless. Argus is all three.

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

Orphan `node --test` processes are auto-killed **deterministically** (no LLM involved) after 3 consecutive detections. Some things don't need AI. They need a cron job with opinions.

## Components

| File | Purpose |
|------|---------|
| `argus.sh` | Main loop — metric collection, LLM calls, action execution, log rotation |
| `collectors.sh` | Metric collectors — services, system stats, processes, agent sessions |
| `actions.sh` | The 5 allowlisted action executors with input validation |
| `prompt.md` | System prompt — Argus's brain. Edit this to change what he cares about |
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

# Watch him work
tail -f ~/argus/logs/argus.log

# See his last decision
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

Argus is opinionated about what he monitors, but those opinions are easy to change:

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

## For Agents

This repo includes `AGENTS.md`. Your agent knows what to do.

```bash
cd ~/argus
cp argus.env.example argus.env
# Add ANTHROPIC_API_KEY, TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID to argus.env
chmod +x install.sh
./install.sh
sudo systemctl enable --now argus
```

Dependencies: `curl`, `jq`, `bc`, systemd. That's it. No compiler, no runtime, no existential dread.

## 🏛️ Part of the Agora

Argus was forged in **[Athena's Agora](https://github.com/Perttulands/athena-workspace)** — an autonomous coding system where AI agents build software under the watch of Greek gods and cyberpunk engineering.

There are others in the Agora. [Hermes](https://github.com/Perttulands/relay) carries the messages. [Truthsayer](https://github.com/Perttulands/truthsayer) enforces the law. [Oathkeeper](https://github.com/Perttulands/oathkeeper) checks the receipts. Argus keeps the lights on while they work.

Read the [mythology](https://github.com/Perttulands/athena-workspace/blob/main/mythology.md) if you want the full story.

## License

MIT
