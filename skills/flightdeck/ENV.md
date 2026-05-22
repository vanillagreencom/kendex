# Flightdeck environment reference

Reference doc extracted from `SKILL.md`. See [`SKILL.md`](./SKILL.md) for the load-bearing rules; this file holds detailed reference content for on-demand consultation.

## Configuration

Rust dashboard users can press `S` (or `Alt+S`) to open the Settings popup.
Editable values are persisted in
`~/.vstack/flightdeck/projects/<project-id>/settings.toml`;
`flightdeck-dashboard` commands load that file at startup and apply its values
inside the dashboard process without mutating the parent shell. These overrides
are dashboard-scoped: they affect dashboard launch/TUI/daemon behavior, not the
master workflow shell or already-running child panes. Rows marked as
restart-required in the popup take effect on the next dashboard launch or
`flightdeck-dashboard` command.

vstack#227: runtime state (master state JSON, activity sidecar, archives,
terminate summary) lives under
`~/.vstack/flightdeck/projects/<project-id>/runs/<run-id>/`. The legacy
project-local `tmp/flightdeck-*` files are migrated to `.migrated` markers
on first contact with the new helpers. Project tmp/ is no longer Flightdeck's
state surface.

Master-loop env vars consulted by workflows:

| Variable | Default | Purpose |
|----------|---------|---------|
| `FLIGHTDECK_FORCE_MERGE_AFTER_SECS` | `240` | UNKNOWN-state wait threshold before considering force-merge (predicate also requires APPROVED + green + disjoint) |
| `FLIGHTDECK_STATE_DIR` | `tmp` | **DEPRECATED** since vstack#227. Only honored by the legacy migration shim (where to look for pre-existing `flightdeck-state-<S>.json` to fold into the active run). Live state lives under `~/.vstack/flightdeck/projects/<id>/runs/<run-id>/`. The CLI does NOT emit a runtime warning when this env var is set — supervisor wrappers and parity tests rely on empty stderr for non-error invocations. |
| `FLIGHTDECK_RUN_STORE_ROOT` | `$HOME/.vstack/flightdeck` | Override the user-level run store root. Primarily for tests that need an isolated path. |
| `FLIGHTDECK_ACTIVITY_FILE` | unset | Explicit activity JSONL target for wrapper/workflow emitters and `flightdeck-state activity append`; when unset, managed workflows use `activity_path` from master state. |
| `FLIGHTDECK_DEBOUNCE_CYCLES` | `2` | Consecutive poll cycles required for "all-done" termination check |
| `FLIGHTDECK_AUTO_MERGE` | `1` | When `0`, merge-now, force-merge-confirm, and UNKNOWN-timer force-merge transitions escalate instead of auto-answering. For sessions where the human gate is desired (compliance, big-blast-radius PRs) |
| `FLIGHTDECK_AUTO_REBASE` | `0` | GitHub lane only: when `1`, a `BEHIND` PR prompt may answer Update Branch / auto-rebase if all other safety predicates hold. Default `0` escalates. |
| `FLIGHTDECK_PRE_PR_REVIEW` | `1` | GitHub and Plan lanes: when `1`, the `pre-pr-ready-for-review` handler runs `workflows/shared/pre-pr-review.md` before the child opens a PR. When `0`, master writes `tmp/pre-pr-approved.md` immediately on first signal and instructs the child to open the PR, skipping reviewer fan-out. |
| `FLIGHTDECK_PRE_PR_REVIEW_MAX_ROUNDS` | `3` | Maximum review-then-fix iterations before `workflows/shared/pre-pr-review.md` escalates with `paused_for_user.reason="pre-pr-review-loop-stalled"`. |
| `FLIGHTDECK_PRE_PR_REVIEWERS` | unset | Comma-separated reviewer agent names overriding the default reviewer fan-out list in `workflows/shared/pre-pr-review.md` § 2. Names must match installed project agents (`reviewer-arch`, `reviewer-error`, `reviewer-safety`, `reviewer-security`, `reviewer-structure`, `reviewer-test`, `reviewer-doc`, `reviewer-perf`). |
| `FLIGHTDECK_HIJACK_GRACE_SECS` | `90` | Seconds after spawn that master tolerates no linear-orch `workflow-state-<ISSUE>.json` before escalating "orchestration-never-started". Catches hijacked panes / failed launches. |
| `FLIGHTDECK_LAUNCH_MODEL` | unset | Default `open-terminal` / `flightdeck-session --prompt` model override when the workflow/user does not pass `--model`. |
| `FLIGHTDECK_LAUNCH_EFFORT` | unset | Default `open-terminal` / `flightdeck-session --prompt` effort/thinking override when the workflow/user does not pass `--effort`. |
| `FLIGHTDECK_DISABLE_AUTO_RENAME` | `0` | When `1`, `flightdeck-session start` disables tmux `automatic-rename` on the spawned window so the requested title stays sticky. Default off preserves harness-owned title updates. |
| `FLIGHTDECK_ENSURE_DAEMON` | `1` | When `0`, `flightdeck-session start` / `attach` skips the post-registration daemon staleness check + respawn (vstack#213). Use only when the supervising master loop owns daemon lifecycle. |
| `FLIGHTDECK_DAEMON_BIN` | unset | Override the `flightdeck-daemon` trampoline path used by `flightdeck-session ensure_daemon_for_session` and `flightdeck-state archive`'s daemon-stop helper. Mirrors `FLIGHTDECK_DASHBOARD_BIN`; primarily for tests/shims. **Trust model (CWE-829):** the binary is invoked for daemon lifecycle (status/health/stop/start), so a hostile override could misroute wake-arming. Validated to be an absolute path that exists and is executable; both checks fail-closed with stderr. Ownership / world-writable / setuid checks are intentionally deferred so per-test temp-dir shims work without an opt-out env var — production operators should leave this unset and treat it as a developer escape hatch only. |
| `FLIGHTDECK_PANE_REGISTRY_BIN` | unset | Override the `pane-registry` trampoline path used by `flightdeck-session ensure_daemon_for_session`. Test-only escape hatch so failure-injection tests can exercise the registry-probe-fails branch without shadowing the binary via PATH (which would also break the tmux shim). Same trust caveats as `FLIGHTDECK_DAEMON_BIN`. |
| `FLIGHTDECK_ARCHIVE_SKIP_DAEMON_STOP` | `0` | When `1`, `flightdeck-state archive` skips its post-archive `flightdeck-daemon stop` call. The daemon's `--inner` argv still becomes stale after archive, so leave unset unless an operator wants manual daemon control. |
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
| `FD_PI_BIND_SKIP_LOG_INTERVAL_SEC` | `60` | Per-(pane,reason) throttle interval for `[pi-subscriber-bind-skip]` daemon log lines. Lower for more verbose bind-attempt logging during diagnosis; raise to quiet a chronically-unbindable pane. |
| `FD_PI_BIND_SKIP_STUCK_THRESHOLD` | `12` | Consecutive `[pi-subscriber-bind-skip]` ticks for the same pane before the daemon emits a one-shot `[pi-subscriber-bind-stuck]` warning naming the missing adapter fields. Reset when the binder succeeds or the pane is reaped. |
| `FD_SUB_BIND_SKIP_LOG_INTERVAL_SEC` | `60` | Per-(pane,reason) throttle interval for `[{claude,opencode,codex}-subscriber-bind-skip]` daemon log lines (vstack#216). Same shape and semantics as the pi-specific knob above. |
| `FD_SUB_BIND_SKIP_STUCK_THRESHOLD` | `12` | Consecutive bind-skip ticks before the daemon emits a one-shot `[{claude,opencode,codex}-subscriber-bind-stuck]` warning (vstack#216). |
| `FLIGHTDECK_CLAUDE_CHANNELS` | unset (`0`) for linear tracker, defaulted to `1` for `--tracker github --harness claude` (vstack#216) | Opt-in/opt-out for Claude Channels MCP webhook send-path. Explicit `--use-channels` / `--no-channels` flags on `open-terminal` always win. |
| `FLIGHTDECK_CLAUDE_BIN` | unset | Path to a specific `claude` executable to use for channels version/auth probes. When unset, `open-terminal` prefers `/usr/bin/claude` (bypassing shell aliases/wrappers that intercept `claude --version`) then falls back to `type -P claude`. Set this to point at a parallel install, a custom wrapper, or a test fixture; production users normally leave it unset. |


Rust dashboard env vars:

| Variable | Default | Purpose |
|----------|---------|---------|
| `FLIGHTDECK_DASHBOARD` | `1` | When `0`, `flightdeck-dashboard launch` exits `0` silently and `focus-or-launch` reports blocked. When enabled, `flightdeck-session` warns and continues if dashboard startup fails so pane supervision still starts. |
| `FLIGHTDECK_DASHBOARD_WINDOW` | ` FD` | Tmux window name used by dashboard launch/focus hooks. CLI `--window-name` overrides it. |
| `FLIGHTDECK_DASHBOARD_WINDOW_ICON` | `1` | When `0` and no explicit window name is set, use plain `FD` instead of the icon title. |
| `FLIGHTDECK_DASHBOARD_MOTION` | `full` | Animation intensity: `full`, `reduced`, or `off`. `NO_MOTION` / `NO_COLOR` force `off` regardless of this setting. CLI `--motion` overrides it. |
| `FLIGHTDECK_DASHBOARD_THEME` | `moon` | Color theme: `moon`, `dawn`, `pantera`, or `system`. CLI `--theme` overrides it; the theme picker popup changes the live theme for the current run. |
| `FLIGHTDECK_DAEMON_RUST` | `0` | Opt-in to the Rust daemon wake side / subscriber absorption. Default off keeps the canonical TypeScript daemon in charge of wake delivery. |
| `FLIGHTDECK_DASHBOARD_BELL` | `1` | Set to `0` to suppress the terminal bell on a new pause-for-user edge. The launch hook never auto-focuses tmux windows; explicit `focus-or-launch` does. |
| `FLIGHTDECK_DASHBOARD_COST_POLL_SECS` | `5` | Cost-source poll interval in seconds. |
| `FLIGHTDECK_DASHBOARD_PI_HISTORY_EVENTS` | `25` | Number of Pi bridge history events sampled per Pi entry for dashboard cost totals. |
| `FLIGHTDECK_DASHBOARD_PI_HISTORY_TIMEOUT_MS` | `1000` | Per-entry timeout for dashboard Pi cost polling so a slow bridge cannot freeze rendering. |
| `FLIGHTDECK_DASHBOARD_PRICING_FILE` | bundled table | Optional pricing TOML override for dashboard cost calculations; malformed files warn and fall back to bundled rates. |
| `FLIGHTDECK_DASHBOARD_QUICK_FOCUS` | `0` | Set to `1` to let `g` focus the selected tmux window without a confirmation popup. Ignored in read-only history/archive views. |
| `FLIGHTDECK_STATE_BIN` | auto-discovered | Optional path to `flightdeck-state` for dashboard History/run-store integration when skill-dir and `PATH` lookup do not resolve it. |
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
a tick, `FD_ADAPTER_MAX_BUFFER_MB` (default `16`) caps captured adapter
stdout for large Pi histories, and `FD_ADAPTER_FRESHNESS_TTL` (default
`5`) gates freshness probe caching.

Additional tuning:

| Variable | Default | Purpose |
|----------|---------|---------|
| `FD_ADAPTER_READ_TIMEOUT_SEC` | `2` | Bounds per-adapter read subprocesses in `pane-poll` (fractional values honored). Stale adapters fall through to tmux capture rather than wedging the tick. |
| `FD_ADAPTER_MAX_BUFFER_MB` | `16` | Maximum stdout captured from adapter reads such as `pi-bridge history`; prevents Node's default 1 MiB buffer from forcing a tmux fallback on long Pi sessions. |
| `FD_ADAPTER_FRESHNESS_TTL` | `5` | Freshness probe cache TTL in seconds for adapter reads; set `0` to disable cache reuse. |
