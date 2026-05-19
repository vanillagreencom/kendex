# Flightdeck environment reference

Reference doc extracted from `SKILL.md`. See [`SKILL.md`](./SKILL.md) for the load-bearing rules; this file holds detailed reference content for on-demand consultation.

## Configuration

Rust dashboard users can press `S` (or `Alt+S`) to open the Settings popup.
Editable values are persisted in `<project-root>/tmp/flightdeck-settings.toml`;
`flightdeck-dashboard` commands load that file at startup and apply its values
inside the dashboard process without mutating the parent shell. These overrides
are dashboard-scoped: they affect dashboard launch/TUI/daemon behavior, not the
master workflow shell or already-running child panes. Rows marked as
restart-required in the popup take effect on the next dashboard launch or
`flightdeck-dashboard` command.

Master-loop env vars consulted by workflows:

| Variable | Default | Purpose |
|----------|---------|---------|
| `FLIGHTDECK_FORCE_MERGE_AFTER_SECS` | `240` | UNKNOWN-state wait threshold before considering force-merge (predicate also requires APPROVED + green + disjoint) |
| `FLIGHTDECK_STATE_DIR` | `tmp` | Project-relative master-state file directory |
| `FLIGHTDECK_ACTIVITY_FILE` | unset | Explicit activity JSONL target for wrapper/workflow emitters and `flightdeck-state activity append`; when unset, managed workflows use `activity_path` from master state. |
| `FLIGHTDECK_DEBOUNCE_CYCLES` | `2` | Consecutive poll cycles required for "all-done" termination check |
| `FLIGHTDECK_AUTO_MERGE` | `1` | When `0`, merge-now, force-merge-confirm, and UNKNOWN-timer force-merge transitions escalate instead of auto-answering. For sessions where the human gate is desired (compliance, big-blast-radius PRs) |
| `FLIGHTDECK_AUTO_REBASE` | `0` | GitHub lane only: when `1`, a `BEHIND` PR prompt may answer Update Branch / auto-rebase if all other safety predicates hold. Default `0` escalates. |
| `FLIGHTDECK_HIJACK_GRACE_SECS` | `90` | Seconds after spawn that master tolerates no orchestration `workflow-state-<ISSUE>.json` before escalating "orchestration-never-started". Catches hijacked panes / failed launches. |
| `FLIGHTDECK_LAUNCH_MODEL` | unset | Default `open-terminal` / `flightdeck-session --prompt` model override when the workflow/user does not pass `--model`. |
| `FLIGHTDECK_LAUNCH_EFFORT` | unset | Default `open-terminal` / `flightdeck-session --prompt` effort/thinking override when the workflow/user does not pass `--effort`. |
| `FLIGHTDECK_DISABLE_AUTO_RENAME` | `0` | When `1`, `flightdeck-session start` disables tmux `automatic-rename` on the spawned window so the requested title stays sticky. Default off preserves harness-owned title updates. |
| `FLIGHTDECK_OPENCODE_VALIDATE_MODEL` | `1` | When launching OpenCode, require `opencode models` to list the selected provider/model before passing `--model`. Set `0` only for local smoke tests with custom shims. |
| `FLIGHTDECK_PI_ACTIVITY_BROKER` | `1` | Set to `0` to ignore `pi-session-bridge` `vstack_activity` broker rows and rely on legacy Pi wake messages only. |
| `FLIGHTDECK_ENTRY_ID` | auto | Exported by `flightdeck-session start` into spawned panes (and inherited by their tool wrappers). When set, `github.sh` / `linear.sh` / `label-*` activity rows auto-bind `refs.entry_id` so cross-source activity ties back to the tracked entry. Do not set by hand. |

Watchdog gates (operator-facing; see [`WATCHDOGS.md`](./WATCHDOGS.md) for behavior):

| Variable | Default | Purpose |
|----------|---------|---------|
| `VSTACK_AGENT_END_WATCHDOG` | `1` | Toggle for the agent-end watchdog. |
| `VSTACK_AGENT_END_WATCHDOG_GRACE_SEC` | `10` | Grace seconds before synthesizing a `needs_completion` outbox. |
| `VSTACK_STALL_WATCHDOG` | `1` | Toggle for the idle-stall watchdog. |
| `VSTACK_STALL_WATCHDOG_INTERVAL_SEC` | `60` | Poll cadence for idle-stall detection. |
| `VSTACK_STALL_WATCHDOG_THRESHOLD_SEC` | `300` | Bridge-idle threshold before synthesizing a `blocked` outbox. |
| `VSTACK_EDIT_LOOP_DETECTOR` | `1` | Toggle for the edit-loop detector. |
| `VSTACK_EDIT_LOOP_THRESHOLD_N` | `5` | Edit-tool failure count within the window that trips the detector. |
| `VSTACK_EDIT_LOOP_WINDOW_SEC` | `120` | Sliding window for edit-loop counting. |
| `VSTACK_RATE_LIMIT_WATCHDOG` | `1` | Toggle for the rate-limit retry watchdog. |
| `VSTACK_RATE_LIMIT_MAX_ATTEMPTS` | `5` | Maximum retry attempts before surfacing `agent.rate_limit_exhausted`. |
| `VSTACK_RATE_LIMIT_BACKOFF_LADDER` | `60,120,300,600,1800` | Comma-separated seconds per attempt; clamped to `MAX_ATTEMPTS`. |

Daemon hygiene env vars (operator-facing; details in `DEVELOPMENT.md`):

| Variable | Default | Purpose |
|----------|---------|---------|
| `FD_BELL_WAKE_INTERVAL_SEC` | `60` | Per-pane-per-tag bell-wake rate-limit; suppresses storm-y duplicates within the window. |
| `FD_RECONCILE_INTERVAL_SEC` | `5` | Mid-session reconcile cadence: spawn subscribers for newly tracked panes, reap subscribers for departed panes, drop dead `.entries` rows. |
| `FD_HEARTBEAT_OWNER_CGROUP` | `1` | Set to `0` to skip the optional `MemoryCurrent` / `MemoryPeak` cgroup probe attached to heartbeat events. |


Rust dashboard env vars:

| Variable | Default | Purpose |
|----------|---------|---------|
| `FLIGHTDECK_DASHBOARD` | `1` | When `0`, `flightdeck-dashboard launch` exits `0` silently. |
| `FLIGHTDECK_DASHBOARD_WINDOW` | `flightdeck` | Tmux window name used by the dashboard launch hook. |
| `FLIGHTDECK_DASHBOARD_MOTION` | `full` | Animation intensity: `full`, `reduced`, or `off`. `NO_MOTION` / `NO_COLOR` force `off` regardless of this setting. CLI `--motion` overrides it. |
| `FLIGHTDECK_DASHBOARD_THEME` | `moon` | Color theme: `moon`, `dawn`, `pantera`, or `system`. CLI `--theme` overrides it; the theme picker popup changes the live theme for the current run. |
| `FLIGHTDECK_DAEMON_RUST` | `0` | Opt-in to the Rust daemon wake side / subscriber absorption. Default off keeps the canonical TypeScript daemon in charge of wake delivery. |
| `FLIGHTDECK_DASHBOARD_BELL` | `1` | Set to `0` to suppress the terminal bell on a new pause-for-user edge. The dashboard never auto-focuses tmux windows. |
| `FLIGHTDECK_DASHBOARD_COST_POLL_SECS` | `5` | Cost-source poll interval in seconds. |
| `FLIGHTDECK_DASHBOARD_PRICING_FILE` | bundled table | Optional pricing TOML override for dashboard cost calculations; malformed files warn and fall back to bundled rates. |
| `FLIGHTDECK_DASHBOARD_QUICK_FOCUS` | `0` | Set to `1` to let `g` focus the selected tmux window without a confirmation popup. |
| `TMUX_PROBE_TTL` | `5` | Cached `tmux list-panes` TTL used to mark stale dashboard rows. |
| `FLIGHTDECK_DASHBOARD_STALE_WARN_SECS` | `30` | Stale-chip warning threshold in seconds. |
| `FLIGHTDECK_DASHBOARD_STALE_DEAD_SECS` | `300` | Stale/dead chip threshold in seconds. |
| `FLIGHTDECK_DASHBOARD_STOP_GRACE_MS` | `5000` | Advanced daemon stop grace before SIGKILL escalation, in milliseconds. Tests may lower it. |
| `FLIGHTDECK_DASHBOARD_READY_FD` | internal | Readiness pipe fd used by detached daemon startup; not user-configurable. |
| `FLIGHTDECK_DASHBOARD_TEST_WEDGE_SIGNALS` | unset | Test-only hook that wedges signal handling. Do not set in normal sessions. |
| `FLIGHTDECK_DASHBOARD_TEST_SUBSCRIBE_PAUSE_FILE` | unset | Test-only socket subscribe interleaving hook. Do not set in normal sessions. |
| `FLIGHTDECK_DASHBOARD_TEST_SUBSCRIBE_RELEASE_FILE` | unset | Test-only release file for the subscribe interleaving hook. Do not set in normal sessions. |

Daemon tuning (`FD_*`) is in DEVELOPMENT.md. Most `FD_*` knobs run inside the
daemon and do not affect master operation directly, but two are
consulted on the master poll path through the TS `pane-poll`:
`FD_ADAPTER_READ_TIMEOUT_SEC` (default `2`, fractional values honored)
caps each adapter read subprocess so one stale adapter cannot dominate
a tick, and `FD_ADAPTER_FRESHNESS_TTL` (default `5`) gates freshness
probe caching.

Additional tuning:

| Variable | Default | Purpose |
|----------|---------|---------|
| `FD_ADAPTER_READ_TIMEOUT_SEC` | `2` | Bounds per-adapter read subprocesses in `pane-poll` (fractional values honored). Stale adapters fall through to tmux capture rather than wedging the tick. |
| `FD_ADAPTER_FRESHNESS_TTL` | `5` | Freshness probe cache TTL in seconds for adapter reads; set `0` to disable cache reuse. |
