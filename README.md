# Argus Ops Watchdog

Argus is a standalone systemd service that monitors the health of the <YOUR_HOSTNAME> server and takes corrective action when needed. It's completely independent of OpenClaw and uses Claude Haiku to reason about system metrics.

## Architecture

- **Standalone service**: Runs as systemd service, not part of OpenClaw
- **AI-powered**: Uses Anthropic's Claude Haiku for decision-making
- **Safe by design**: Can only execute allowlisted actions
- **5-minute loop**: Collects metrics, analyzes with LLM, executes actions
- **Independent alerting**: Uses its own Telegram bot for notifications

## Components

### Core Scripts

- **argus.sh**: Main monitoring loop and API integration
- **collectors.sh**: Metric collection functions
- **actions.sh**: Allowlisted action execution (only 5 actions permitted)
- **prompt.md**: System prompt for the LLM

### Configuration

- **argus.service**: Systemd service definition
- **argus.env**: Environment variables (API keys, Telegram config)

## Monitored Metrics

1. **Services**: `openclaw-gateway`, `mcp-agent-mail` status
2. **System**: Memory, disk, load, uptime
3. **Processes**: Orphan node --test processes, tmux sessions
4. **Athena**: Memory file modifications, API health at localhost:9000
5. **Agents**: Tmux session counts and names

## Allowlisted Actions

The LLM can **ONLY** execute these 5 actions:

1. **restart_service**: Restart `openclaw-gateway` or `mcp-agent-mail`
2. **kill_pid**: Kill a specific PID (must be node|claude|codex process)
3. **kill_tmux**: Kill a specific tmux session
4. **alert**: Send Telegram message to operator
5. **log**: Append observation to `$HOME/.openclaw/workspace/state/argus/observations.md`

## Installation

### 1. Configure Environment

```bash
cd $HOME/argus
cp argus.env.example argus.env
nano argus.env  # Add your ANTHROPIC_API_KEY
```

Required:
- `ANTHROPIC_API_KEY`: Get from https://console.anthropic.com/

Optional (for alerts):
- `TELEGRAM_BOT_TOKEN`: Create bot with @BotFather
- `TELEGRAM_CHAT_ID`: Message bot, then visit https://api.telegram.org/bot<TOKEN>/getUpdates

### 2. Install Service

```bash
chmod +x install.sh
./install.sh
```

This will:
- Make scripts executable
- Validate environment configuration
- Install systemd service
- Enable and optionally start the service

### 3. Verify Installation

```bash
# Check service status
sudo systemctl status argus

# View logs
sudo journalctl -u argus -f

# Or view application logs
tail -f logs/argus.log
```

## Usage

### Service Management

```bash
# Start/stop/restart
sudo systemctl start argus
sudo systemctl stop argus
sudo systemctl restart argus

# View status
sudo systemctl status argus

# View logs
sudo journalctl -u argus -f              # systemd logs
tail -f $HOME/argus/logs/argus.log  # application logs
```

### Manual Testing

Run a single monitoring cycle without starting the service:

```bash
cd $HOME/argus
source argus.env  # Load environment variables
./argus.sh --once
```

This is useful for:
- Testing configuration changes
- Verifying API connectivity
- Debugging collector functions
- Validating LLM responses

### Monitoring Logs

```bash
# Follow application logs
tail -f $HOME/argus/logs/argus.log

# View last LLM response
cat $HOME/argus/logs/last_response.json | jq

# Check observations log
cat $HOME/.openclaw/workspace/state/argus/observations.md
```

## Decision Logic

Argus follows these guidelines:

- **Conservative**: Only acts when there's a clear problem
- **Services down**: Automatically restarts inactive services
- **Orphan processes**: Kills stuck node --test processes
- **Resource critical**: Alerts if memory/disk >90%
- **Stale sessions**: Logs but doesn't kill tmux sessions unless problematic
- **Always observes**: Records significant findings to observations.md
- **Alerts sparingly**: Only for critical issues requiring human attention

## Example Scenarios

### Scenario 1: Service Failure

**Metrics**: `openclaw-gateway: inactive`

**LLM Response**:
```json
{
  "assessment": "Gateway service is down, restarting",
  "actions": [
    {"type": "restart_service", "target": "openclaw-gateway", "reason": "Service inactive"},
    {"type": "log", "observation": "Gateway down, auto-restart initiated"},
    {"type": "alert", "message": "🚨 Gateway restarted by Argus"}
  ]
}
```

### Scenario 2: Orphan Process

**Metrics**: `Orphan node --test processes: 5`

**LLM Response**:
```json
{
  "assessment": "Multiple orphan test processes detected",
  "actions": [
    {"type": "kill_pid", "target": "12345", "reason": "Orphan node --test process"},
    {"type": "log", "observation": "Cleaned up 5 orphan test processes"}
  ]
}
```

### Scenario 3: All Healthy

**Metrics**: All services active, resources normal

**LLM Response**:
```json
{
  "assessment": "All systems operational",
  "actions": [],
  "observations": [
    "All services healthy",
    "Resources within normal range",
    "No orphan processes"
  ]
}
```

## Security Design

- **No arbitrary execution**: LLM cannot run shell commands
- **Strict allowlist**: Only 5 action types permitted
- **Input validation**: Actions validate targets before execution
- **Process filtering**: kill_pid only works on node|claude|codex
- **Service allowlist**: restart_service only works on specific services
- **Logging**: All actions logged with reasons

## Troubleshooting

### Service Won't Start

```bash
# Check logs
sudo journalctl -u argus -n 50

# Verify environment
cat $HOME/argus/argus.env

# Test manually
cd $HOME/argus
source argus.env
./argus.sh --once
```

### API Errors

```bash
# Check API key is set
grep ANTHROPIC_API_KEY $HOME/argus/argus.env

# Test API connectivity
curl -H "x-api-key: $ANTHROPIC_API_KEY" \
     -H "anthropic-version: 2023-06-01" \
     https://api.anthropic.com/v1/messages
```

### Action Failures

Check logs for specific error messages:

```bash
# View recent failures
grep ERROR $HOME/argus/logs/argus.log | tail -n 20

# Check last LLM response
cat $HOME/argus/logs/last_response.json | jq
```

## Development

### Adding New Metrics

Edit `collectors.sh` and add a new `collect_*` function. Remember to call it in `collect_all_metrics()`.

### Adding New Actions

**⚠️ Warning**: Only add actions after careful security review.

1. Add function to `actions.sh` with proper validation
2. Update allowlist in `execute_action()`
3. Update `prompt.md` to document the new action
4. Test thoroughly with `--once` mode

### Modifying Decision Logic

Edit `prompt.md` to change how Argus responds to different scenarios. The LLM will follow the guidelines you specify.

## Files and Directories

```
$HOME/argus/
├── argus.sh              # Main script
├── collectors.sh         # Metric collectors
├── actions.sh            # Action executors
├── prompt.md             # LLM system prompt
├── argus.service         # Systemd unit
├── argus.env             # Environment config (not in git)
├── argus.env.example     # Example config
├── install.sh            # Installation script
├── README.md             # This file
└── logs/
    ├── argus.log         # Application logs
    └── last_response.json # Last LLM response

$HOME/.openclaw/workspace/state/argus/
└── observations.md       # Observation log
```

## License

MIT

## Contributing

This is a personal ops tool for <YOUR_HOSTNAME>. If you're adapting it for your own server:

1. Update service names in `collectors.sh`
2. Modify action allowlists in `actions.sh`
3. Customize decision guidelines in `prompt.md`
4. Test extensively with `--once` before enabling the service

---

**Argus**: Ever-watchful guardian of <YOUR_HOSTNAME> 🛡️
