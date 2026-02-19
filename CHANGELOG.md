# Changelog

All notable changes to Argus.

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)

## [Unreleased]

### Changed
- README: mythology-forward rewrite — each README now reads like discovering a character in a world

## [0.2.1] - 2026-02-19

### Added
- "For Agents" section in README: install, what-this-is, and runtime usage for agent consumers

## [Unreleased]

### Changed
- README: mythology-forward rewrite — each README now reads like discovering a character in a world

## [0.2.0] - 2026-02-19

### Removed
- athena-web dropped from monitoring round (service, port 9000 check, restart action)
- Athena API reachability check removed from collectors

### Changed
- `prompt.md` updated to reflect reduced service scope
- `actions.sh` cleared allowed services list
- `collectors.sh` removed athena-web systemd and port 9000 checks

## [Unreleased]

### Changed
- README: mythology-forward rewrite — each README now reads like discovering a character in a world

## [0.1.0] - 2026-02-13

### Added
- Standalone systemd ops watchdog service
- AI-powered monitoring using Claude Haiku for decision-making
- 5-minute metric collection and analysis loop
- Service monitoring (openclaw-gateway, athena-web)
- System metrics (memory, disk, load, uptime)
- 5 allowlisted corrective actions
- Independent Telegram bot alerting
- Integration with `problem-detected.sh` for auto-bead creation on repeated issues
- Core scripts: `argus.sh`, `collectors.sh`, `actions.sh`, `prompt.md`

### Changed
- Hardcoded host and home paths removed from service/scripts/docs
