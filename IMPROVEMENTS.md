# ⚡ Argus Improvements — Dispatches from the Agora

_Five forged upgrades for the Faithful Hound, where ancient vigilance meets neon-lit engineering._

---

## 1. 🏛️ The Oracle's Memory — Cross-Cycle Context Window

**Problem:** Argus is amnesiac. Each 5-minute cycle sends raw metrics to Haiku with zero memory of what it said or did last cycle. The prompt says "don't re-alert for the same ongoing condition," but the LLM has no way to know what it alerted about previously. This leads to duplicate alerts and inability to reason about trends (e.g., memory climbing from 75% → 82% → 89% across cycles).

**Implementation:**
- **`argus.sh` / `run_monitoring_cycle()`**: After `process_llm_response`, extract the `assessment` and `actions[].type` from `last_response.json` and append a summary to a rolling context file (`logs/context_window.jsonl`), keeping the last 6 entries (~30 min of history).
- **`argus.sh` / `run_monitoring_cycle()`**: Before calling `call_llm`, read `context_window.jsonl` and append it to the metrics payload as `=== Recent History ===`.
- **`prompt.md`**: Add a "Recent History" section to the input description, instructing the LLM to use it for dedup and trend detection.
- Cap the file at 6 entries (~2KB) to stay within Haiku's context budget.

**Expected Impact:** Eliminates duplicate alerts, enables trend-based reasoning ("memory has risen 3 cycles in a row"), and makes the "don't re-alert" prompt rule actually enforceable. Minimal cost — ~200 extra input tokens per cycle.

---

## 2. 🔱 Poseidon's Trident — Unify the Bash and Go Watchdog Layers

**Problem:** Argus has two parallel control planes that don't talk to each other. The production logic lives entirely in bash (`argus.sh`, `collectors.sh`, `actions.sh`), while `cmd/argus/main.go` and `internal/watchdog/` implement a proper Go watchdog framework with breadcrumb crash recovery, health endpoints, and panic handling — but its checks are empty stubs (`Run` functions that just log "dry-run: would collect metrics"). The Go layer is a skeleton; the bash layer lacks crash recovery and health endpoints.

**Implementation:**
- **`internal/watchdog/watchdog.go`**: Keep as the orchestration framework (it's well-tested and solid).
- **Create `internal/checks/metrics.go`**: A check that shells out to `collectors.sh` and captures stdout as the metrics payload.
- **Create `internal/checks/evaluate.go`**: A check that calls the Claude API (via `claude -p` or direct HTTP to Anthropic API), parses the JSON response, and dispatches to action handlers.
- **Create `internal/actions/actions.go`**: Go wrappers around the 5 allowlisted actions, porting the validation logic from `actions.sh` (keep bash scripts as fallback/reference).
- **`cmd/argus/main.go`**: Wire the real checks into `wd.SetChecks()` instead of the current no-op lambdas.
- **Retire `argus.sh`** as the main entry point; the Go binary becomes the systemd `ExecStart`.

**Expected Impact:** Gains breadcrumb-based crash recovery (already implemented in Go but unused), `/health` endpoint for external monitoring, proper panic handling, and type-safe action validation. Eliminates the confusing dual-architecture where neither layer is complete.

---

## 3. 🛡️ Athena's Aegis — Action Rate Limiting and Circuit Breaker

**Problem:** Nothing prevents Argus from restarting `athena-web` every single cycle if the LLM keeps deciding it's down. A flapping service could trigger 288 restarts/day. The `action_restart_service` function in `actions.sh` has no cooldown, no rate limit, and no circuit breaker. Same for `action_alert` — a noisy condition could flood Telegram.

**Implementation:**
- **`actions.sh`**: Add a rate-limit file (`logs/action_cooldowns.json`) tracking `{action_type}:{target} → last_executed_timestamp`.
- **`action_restart_service()`**: Before executing, check if the same service was restarted within the last 15 minutes. If so, log a suppression message and return without restarting. After 3 suppressed restarts, send a single escalation alert: "athena-web restart loop detected — manual intervention needed."
- **`action_alert()`**: Track message hashes in `logs/alert_dedup.json` (last 12 entries). Skip sending if the same message hash was sent within the last 30 minutes.
- Use `jq` for all JSON state manipulation (consistent with existing patterns in the codebase).

**Expected Impact:** Prevents restart storms and alert floods. Adds a circuit breaker pattern that escalates to human attention instead of blindly retrying. Critical for production trust — an ops watchdog that can DDoS its own services is worse than no watchdog.

---

## 4. 🔥 Hephaestus's Forge — Structured Metric Collection with Exit Codes

**Problem:** `collect_all_metrics()` in `collectors.sh` produces unstructured text that the LLM must parse. Collector failures are swallowed into the text stream (`echo "ERROR: ${collector} failed"`), making it impossible to programmatically detect degraded collection. The LLM sees the error as just another line of text and may misinterpret it.

**Implementation:**
- **`collectors.sh`**: Have each collector output a JSON object instead of free text. Example for `collect_system`:
  ```json
  {"collector":"system","ok":true,"memory_pct":45,"memory_used_mb":3400,"memory_total_mb":7620,"disk_pct":17,"load_1m":0.15,"cpu_cores":2,"swap_pct":0}
  ```
- **`collect_all_metrics()`**: Aggregate collector outputs into a single JSON array. Failed collectors produce `{"collector":"name","ok":false,"error":"..."}`.
- **`argus.sh`**: Before sending to the LLM, convert the JSON metrics into a formatted text block (so the prompt doesn't need to change), but also save the raw JSON to `logs/last_metrics.json` for programmatic access.
- **`prompt.md`**: No change needed initially — the text rendering preserves the current format. Later, switch the prompt to consume JSON directly for more precise reasoning.

**Expected Impact:** Enables the Go layer (Proposal #2) to consume metrics programmatically, allows threshold-based pre-screening before LLM calls (skip the LLM entirely if all metrics are nominal), and produces a clean audit trail in `last_metrics.json`. Estimated 40% of cycles could skip the LLM call entirely, saving API costs.

---

## 5. 🦉 Nyx's Vigil — Offline Fallback When the LLM Is Unreachable

**Problem:** If the Anthropic API is down or the API key is rate-limited, `call_llm()` fails and the entire cycle is recorded as failed. Argus becomes blind exactly when autonomous action matters most. The `check_disk_space` guard shows the right instinct (skip LLM when disk is low), but there's no equivalent for LLM unavailability.

**Implementation:**
- **`argus.sh`**: After `call_llm` fails, instead of immediately recording a failed cycle, enter a **deterministic fallback mode**:
  1. Parse the collected metrics text using `grep`/`awk` for known critical patterns:
     - `"DOWN"` or `"unreachable"` in the openclaw-gateway line → alert
     - `"inactive"` or `"failed"` for athena-web → restart + alert
     - Memory percentage > 90 → alert
     - Disk percentage > 90 → alert
  2. Execute matched actions using the existing `action_*` functions.
  3. Record cycle state as `"fallback"` (not `"failed"`), so the self-monitor doesn't false-alarm.
- **Create `fallback.sh`**: ~50 lines of pattern-matching logic, sourced by `argus.sh`. Keep it minimal — only the 4 critical rules above.
- **`argus.sh` / `record_cycle_state()`**: Add `"fallback"` as a valid status alongside `"ok"` and `"failed"`.

**Expected Impact:** Argus remains functional during API outages. The deterministic fallback handles the 4 most critical scenarios without AI, while non-critical observations gracefully degrade. Transforms Argus from "LLM-dependent" to "LLM-enhanced" — the hound keeps watch even when the oracle is silent.
