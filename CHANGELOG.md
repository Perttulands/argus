# Changelog

All notable changes to Argus.

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)

## [Unreleased]

### Added
- ARG-001 (2026-02-20): Added structured problem registry logging to `state/problems.jsonl` for all LLM-triggered actions and deterministic orphan-process handling, including severity/type/action metadata for reliable diagnostics and `jq` querying.
- ARG-001 (2026-02-20): Documented the problem registry schema and validation command in `README.md`.
- ARG-002 (2026-02-20): Added automatic bead creation workflow in `actions.sh` with trigger conditions (failed action, repeated issue, no-auto-fix), bead deduplication by problem key, and `bead_id` persistence in problem records.
- ARG-002 (2026-02-20): Documented Argus bead creation behavior and added a regression test with mocked `bd` interactions.
- ARG-003 (2026-02-20): Added problem-key deduplication (`state/dedup.json`) with configurable suppression window (`ARGUS_DEDUP_WINDOW`, default 1 hour) and automatic dedup state compaction.
- ARG-003 (2026-02-20): Suppressed repeated alert actions now log `action_result: suppressed` in `state/problems.jsonl`, with regression coverage for dedup behavior.
- ARG-004 (2026-02-20): Added `clean_disk` action with hardcoded safe cleanup targets (`/tmp`, `/var/tmp`, selected `~/.cache` directories, and log archives), configurable age threshold, and before/after disk alerts.
- ARG-004 (2026-02-20): Disk cleanup records now include reclaimed-byte context in the problem registry, with dry-run regression coverage for cleanup logging behavior.
- ARG-005 (2026-02-20): Added memory-hog identification and enrichment for memory alerts/problem records (process, PID, RSS, `%MEM`, runtime, and kill-candidate hint).
- ARG-005 (2026-02-20): System collector now reports top memory hog context at high memory pressure and includes cgroup memory context when available.

## [2026-02-20]

### Added
- Optional Relay problem publishing in `actions.sh` with configurable route/sender/timeout and automatic JSONL fallback when Relay is unavailable.

### Changed
- Documented Relay problem publishing setup in `README.md` and `argus.env.example`.

## [0.2.1] - 2026-02-19

### Added
- "For Agents" section in README: install, what-this-is, and runtime usage for agent consumers

### Changed
- README: mythology-forward rewrite to align with other Athena tool docs.

## [0.2.0] - 2026-02-19

### Removed
- athena-web dropped from monitoring round (service, port 9000 check, restart action)
- Athena API reachability check removed from collectors

### Changed
- `prompt.md` updated to reflect reduced service scope
- `actions.sh` cleared allowed services list
- `collectors.sh` removed athena-web systemd and port 9000 checks

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
