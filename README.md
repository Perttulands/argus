# 👁️ Argus

![Banner](banner.jpg)

*One red eye. Spiked collar. Zero chill.*

---

In the Odyssey, Argus was the dog who waited twenty years for his master to come home. He was old, covered in fleas, lying on a pile of dung, and he was the only living thing in Ithaca that recognized Odysseus. Then he died. Loyalty like that doesn't come with commands. It comes with scars.

Our Argus has the same energy, except instead of waiting on a porch he patrols a Linux server every five minutes and kills anything that shouldn't be there. Spiked bronze collar with tally marks — one for every orphan process that thought it could hide. One eye is normal. The other glows red. A broken chain drags behind him because nobody put Argus on a leash. Nobody could.

You don't want your ops watchdog to be creative. You want it to be correct, boring, and slightly terrifying. Argus is all three.

## How It Works

```
Every 5 minutes:
  collect metrics → ask Claude Haiku what to do → do it → log it → go back to sleep
```

Argus collects system metrics (CPU, memory, disk, swap, processes, service health), sends them to an LLM with a decision-making prompt, and acts on the response. The LLM can only execute **5 allowlisted actions**. That's it. There's no `exec("arbitrary shell command")` hiding in here. Argus is on a leash in exactly one way.

| Action | What It Does | Guardrail |
|--------|-------------|-----------|
| `restart_service` | Restarts a service | Must be in explicit allowlist |
| `kill_pid` | Kills a process | Must match `node\|claude\|codex` |
| `kill_tmux` | Kills a tmux session | Name sanitized against injection |
| `alert` | Sends a Telegram notification | Retry on failure, hostname prepended |
| `log` | Records an observation | Auto-escalates after 3 consecutive repeats |

Orphan `node --test` processes are auto-killed **deterministically** after 3 detections. No LLM involved. Some things don't need AI. They need a cron job with teeth.

## Components

| File | What it does |
|------|-------------|
| `argus.sh` | The main loop. Metrics → LLM → actions → logs. |
| `collectors.sh` | Gathers everything: services, system stats, processes, agents |
| `actions.sh` | The 5 actions. Validated. Sanitized. Paranoid. |
| `prompt.md` | Argus's brain. Edit this to change what he cares about. |
| `argus.service` | Systemd unit with resource limits and security hardening |
| `install.sh` | Idempotent. Run it twice, nothing breaks. |

## Install

```bash
git clone https://github.com/Perttulands/argus.git
cd argus
cp argus.env.example argus.env
# Edit argus.env: ANTHROPIC_API_KEY (required), TELEGRAM_BOT_TOKEN + CHAT_ID (optional)
chmod +x install.sh
./install.sh
```

No compiler. No runtime. No package manager existential crisis. It's bash scripts and an API key.

## Usage

```bash
# Single cycle — see what he sees
source argus.env && ./argus.sh --once

# Let him loose
sudo systemctl start argus

# Watch him work
tail -f ~/argus/logs/argus.log

# See his last decision (what he did and why)
cat ~/argus/logs/last_response.json | jq

# Service management
sudo systemctl start|stop|restart|status argus
```

## Security

No arbitrary command execution. Every input is validated like it's trying to escape.

- PIDs: must be numeric, must exist, must match allowed process names
- Services: explicit allowlist only
- Tmux names: sanitized against injection
- Telegram payloads: built with `jq`, not string concatenation
- systemd: `NoNewPrivileges`, `ProtectSystem=strict`, `PrivateTmp`, `MemoryMax=1G`

## Reliability

- Log rotation at 10MB (3 backups)
- Disk space guard — skips LLM call if < 100MB free
- Self-monitoring — alerts after 3 consecutive failures
- Clean shutdown on SIGTERM/SIGINT
- JSON state via `jq` (no injection from error messages)

## Relay Problem Reports (Optional)

When Relay is available, Argus also publishes structured problem events to Athena:
- Event type: `argus.problem`
- Route: `ARGUS_RELAY_TO` (default: `athena`)
- Sender: `ARGUS_RELAY_FROM` (default: `argus`)

If Relay is unavailable, Argus appends the same event JSON to:
- `ARGUS_RELAY_FALLBACK_FILE` (default: `~/athena/state/argus/relay-fallback.jsonl`)

This keeps Argus operational even during Relay outages.

## For Agents

This repo includes `AGENTS.md` with operational instructions.

```bash
git clone https://github.com/Perttulands/argus.git
cd argus
cp argus.env.example argus.env  # add your API keys
chmod +x install.sh && ./install.sh
sudo systemctl enable --now argus
```

Dependencies: `curl`, `jq`, `bc`, systemd. That's it.

## Part of the Agora

Argus was forged in **[Athena's Agora](https://github.com/Perttulands/athena-workspace)** — an autonomous coding system where AI agents build software and a hound with one red eye makes sure the server doesn't burn down while they do it.

[Truthsayer](https://github.com/Perttulands/truthsayer) watches the code. [Oathkeeper](https://github.com/Perttulands/oathkeeper) watches the promises. [Relay](https://github.com/Perttulands/relay) carries the messages. Argus watches everything else. Between the four of them, the 3am page is someone else's problem.

The [mythology](https://github.com/Perttulands/athena-workspace/blob/main/mythology.md) has the full story.

## License

MIT
