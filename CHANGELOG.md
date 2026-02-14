# Changelog

All notable changes to Argus.

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)

## [0.1.0] - 2026-02-13

### Added
- Standalone systemd ops watchdog service
- AI-powered monitoring using Claude Haiku for decision-making
- 5-minute metric collection and analysis loop
- Service monitoring (openclaw-gateway, mcp-agent-mail)
- System metrics (memory, disk, load, uptime)
- 5 allowlisted corrective actions
- Independent Telegram bot alerting
- Integration with `problem-detected.sh` for auto-bead creation on repeated issues
- Core scripts: `argus.sh`, `collectors.sh`, `actions.sh`, `prompt.md`

### Changed
- Hardcoded host and home paths removed from service/scripts/docs
