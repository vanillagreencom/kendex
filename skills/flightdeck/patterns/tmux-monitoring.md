# Tmux monitoring patterns

Pane targeting, bell handling, and capture-pane idioms for safely observing any tracked entry (adhoc session or issue pane) launched via `flightdeck-session` or `open-terminal`.

> **Fallback path notice:** all four supported harnesses (opencode, claude code, pi, codex) have a wired adapter — `pane-poll` and `pane-respond` route data through HTTP / Unix-socket / WS rather than tmux capture-pane / send-keys. The tmux primitives below remain the **fallback path** for panes whose bridge metadata is absent OR whose recorded metadata is stale. Adapter args (`pane-registry oc-attach-args` / `cc-channel-args` / `pi-bridge-args` / `cx-bridge-args`) gate on per-harness freshness probes — `oc_adapter_is_fresh` (oc server pid alive + `GET /session/<id>/message` succeeds), `cc_adapter_is_fresh` (transcript exists + webhook `/healthz` succeeds), `pi_bridge_is_fresh` (pid alive + socket exists + protocol matches), `cx_adapter_is_fresh` (`codex-bridge list --url <ws>` succeeds). HTTP/WebSocket results are cached for `FD_ADAPTER_FRESHNESS_TTL` seconds. The default TS `pane-poll` additionally caps each adapter read subprocess at `FD_ADAPTER_READ_TIMEOUT_SEC` (default 2s, fractional values honored) so a stale adapter cannot dominate a poll tick; the timeout is independent of — and applies after — the freshness probe cache. `pane-poll` applies the same probes to its direct spawn-file fallback before using metadata from `oc-spawn-*`, `cc-spawn-*`, `pi-spawn-*`, or `cx-spawn-*`. When a probe fails, args are empty and the daemon falls back to capture-pane polling rather than marking the pane subscribed against a dead adapter. Daemon and scripts log `<adapter>-unavailable: <reason>` before falling through, never silent.

## New tmux tab/window requests

When the user asks to test in a "new tmux tab" or "new tmux window", create a new tmux window in the current tmux session. Never split the active pane for a managed Flightdeck session: splits make ownership and pane-index assumptions ambiguous, and the active pane can drift when harnesses spawn child panes.

Use `scripts/flightdeck-session start` for ad-hoc launches and `scripts/flightdeck-session attach` for existing panes. The launcher uses `tmux new-window`, records immutable `%pane_id` and `#{window_id}` metadata, sets `FLIGHTDECK_MANAGED=1` / `FLIGHTDECK_CHILD_PANE=1`, and registers a `TrackedEntry` through `pane-registry init-entry`. Communicate through the recorded harness adapter (`pi-bridge`, OpenCode HTTP, Claude channels, Codex bridge) before falling back to tmux capture/send-keys.

## Pane-0 rule

**Always target the explicit pane index `<session>:<window>.0` for orchestrator-pane reads.**

`tmux capture-pane -t <session>:<window>` (no `.<pane>` suffix) defaults to the **currently active pane** of that window. When the per-issue agent inside a spawned window has itself spawned sub-agent panes (e.g., opencode's `Iced Task` sub-agent, claude code's parallel sub-agent panes, codex worker panes), the active pane is often one of those sub-agent panes — NOT the per-issue orchestrator's main TUI.

Capturing the wrong pane misses the per-issue orchestrator's prompt. Symptom: flightdeck thinks the issue is idle when it's actually waiting for a response.

### The rule

```bash
# WRONG — captures whatever pane happens to be active
tmux capture-pane -t HT:cc-463 -p

# RIGHT — captures the orchestrator pane explicitly
tmux capture-pane -t HT:cc-463.0 -p -S -200
```

### When pane 0 isn't the orchestrator

Pane indices follow tmux's `pane-base-index` option — commonly `0`, but some configs use `1`. `pane-registry init` queries the option and uses it as the default index, so the registry entry is correct on first try when the orchestrator is in the default position.

Some TUIs lay out their main UI on a non-default pane regardless. At registry init, fingerprint each window's panes:

```bash
for pane_idx in $(tmux list-panes -t <session>:<window> -F '#{pane_index}'); do
  buf=$(tmux capture-pane -t <session>:<window>.$pane_idx -p -S -50)
  if echo "$buf" | grep -qE '(❯ |claude code|opencode|codex>|■■■)' ; then
    orchestrator_pane=$pane_idx
    break
  fi
done
```

Persist BOTH `pane_target` (`"HT:cc-463.0"`) and the immutable `pane_id` (`"%403"`) in master state. `pane-registry init` resolves and stores both at spawn time; reconcile / drift recovery keep them in sync. The daemon and pane-poll prefer `pane_id` because pi/codex auto-rename their tmux window once the TUI starts, which breaks any `pane_target`-only lookup once the window name changes.

### Stable-id rule for destructive ops (#16)

**Never derive a destructive tmux target from `pane_target`.** tmux reuses window indices after a window is destroyed, so the recorded `pane_target` (`session:window-index.pane-index`) is only valid for the lifetime of the original pane. A stripped `WINDOW_TARGET="${pane_target%.*}"` produces a session:window-index string that may now point to a completely different window — e.g. the long-running `flightdeck-daemon` window, or the user's editor window. Calling `tmux kill-window` against that derived target destroys the unrelated workload.

Destructive teardown (`kill-window`, `kill-pane`, anything that removes panes/windows) MUST use the stable `pane_id` (`%N`) recorded at init time:

```bash
# WRONG — derives a reusable index; can kill the daemon after window reuse (#16)
WINDOW_TARGET="${pane_target%.*}"
tmux kill-window -t "$WINDOW_TARGET"

# RIGHT — stable id; only ever targets the originally-registered pane
if tmux list-panes -a -F '#{pane_id}' | grep -qFx "$pane_id"; then
  window_id=$(tmux display-message -t "$pane_id" -p '#{window_id}')
  pane_count=$(tmux list-panes -t "$window_id" -F '#{pane_id}' | wc -l)
  if [[ "$pane_count" == "1" ]]; then
    tmux kill-window -t "$window_id"
  else
    tmux kill-pane -t "$pane_id"
  fi
fi
```

When `pane_id` is gone, the original pane is already destroyed; do NOT fall back to `pane_target` to "clean up". Either the issue is already terminal (`merged|aborted|dead`) and the window is already closed (no-op), or the registry has drifted and the caller must escalate. The shared implementation lives at `scripts/pane-registry teardown-window <ISSUE>` (alias `teardown-entry <ENTRY_ID>` for the TrackedEntry schema) and is what `workflows/linear/close-issue.md` § 4 calls; do not reimplement the kill path inline. The helper distinguishes every outcome via exit code: `0` success/already-closed, `1` issue-not-registered, `3` registry-drift (pane gone + non-terminal), `4` policy-refusal (pane alive + non-terminal; pass `--force` to override), `5` kill-failed (post-kill liveness check still finds the pane), `6` registry-read-failure. Callers must distinguish `1` from `6` — the former is idempotent, the latter is state corruption.

The same rule applies to capture-pane reads during the close-issue two-signal check: prefer `pane_id`. A stale `pane_target` would feed an unrelated window's text into the signal accumulator and could either mask a real termination or trip a false positive on the wrong content.

**Bell-clear is not destructive.** `pane-respond` derives `WINDOW_TARGET="${TARGET%.*}"` to call `pane-clear-bell`, which only performs a paired `tmux select-window` (focus flip back to origin). Even against a recycled target this is at worst a brief UI flicker on an unrelated window; nothing is killed. The stable-id rule above applies specifically to destructive ops — `kill-window`, `kill-pane`, and anything else that removes panes or windows. The `pane-respond` send itself targets whatever the caller passed (callers should pass `pane_id` whenever possible; the registry's `list --format inner-panes` already prefers `pane_id`).

### Reconcile-time backfill guard (#16)

`pane-registry reconcile` opportunistically backfills `pane_id` for legacy entries that recorded only `pane_target`. tmux reuses window indices after a window is destroyed, so a stale `pane_target` may now resolve to an unrelated window; adopting its `pane_id` into the registry would silently graft that window onto the issue, and the next `teardown-window` call would then kill it. Window names are mutable (pi/codex auto-rename their windows; users can rename arbitrarily; duplicate names are allowed), so a single window-name comparison is too weak.

The backfill requires the AND of two independent invariants:

1. `#{window_name}` at the recorded `pane_target` == registered `window`.
2. `#{pane_current_path}` at the recorded `pane_target` is `worktree` or starts with `worktree/`. The cwd-anchor is harder to spoof: agents launch with cwd pinned to their worktree, and a window-index collision with an identical-worktree-prefix is vanishingly unlikely.

If either check has hard evidence of mismatch — a non-empty observed value that disagrees — reconcile MUST NOT adopt the pane id AND MUST NOT silently drop the entry. Instead it emits a single `reconciled: drift detected for N entr...` line on stderr and leaves the entry untouched so the operator can investigate. The drift gate covers both the index-reuse case from #16 and the rarer case of a user reusing a window name across workspaces.

When neither check has enough data to disprove identity (e.g. either field empty), reconcile falls through to adoption — a benign cwd-changed-by-user pane would still get caught by `teardown-window`'s separate liveness check against the adopted `pane_id`.

If fingerprinting fails (no sentinel matches on any pane), default to pane 0 and log a warning. Pane 0 is right for opencode and claude code in standard layouts.

### Capture-pane scrollback depth

Use `-S -200` for prompt classification. This captures the last 200 lines, enough to see the full prompt (most TUI prompts are <30 lines) plus surrounding context. Going deeper is wasteful; going shallower can miss multi-screen prompts (e.g., multi-issue audit prompts).

```bash
tmux capture-pane -t <session>:<window>.0 -p -S -200
```

## Atomic bell clearing

After every response sent to a pane, clear the window's bell flag. Otherwise the user's tmux status bar continues to show "needs attention" for a prompt the master already handled.

### The chained-command idiom

```bash
ORIG=$(tmux display-message -p '#{window_id}')
tmux select-window -t <session>:<window> \; select-window -t $ORIG
```

The `\;` chains both `select-window` calls in a single tmux command. The client coalesces them; the intermediate state is never rendered. Result: the bell flag clears (because tmux clears flags on window-view) but the user sees no flicker, even if attached.

### Standard pattern after every response

```bash
# 1. Send the response
tmux send-keys -t <session>:<window>.0 "<RESPONSE>" Enter

# 2. Clear the bell atomically
ORIG=$(tmux display-message -p '#{window_id}')
tmux select-window -t <session>:<window> \; select-window -t $ORIG
```

Encoded in `scripts/pane-clear-bell` and called automatically by `scripts/pane-respond` after every send-keys.

## Window state flags reference

Built-in flags from `tmux list-windows`:

| Flag | Per-window field | Meaning |
|------|------------------|---------|
| `*` | `window_active` | Currently focused (only useful for "which is the user looking at") |
| `-` | `window_last_flag` | Last-focused (previous nav) |
| `#` | `window_bell_flag` | Bell character received → likely needs attention |
| `!` | `window_activity_flag` | Output activity since last view (requires `monitor-activity on`) |
| `~` | `window_silence_flag` | No output for N seconds (requires `monitor-silence N`) |

Flightdeck's primary signal is `window_bell_flag`. The daemon fallback path reads `window_bell_flag`, `window_activity_flag`, and `pane_in_mode` from the same per-tick `tmux list-panes -aF` metadata cache it uses to resolve immutable pane ids, so it does not call `tmux display-message` once per fallback pane. If a project has `monitor-silence` enabled, `window_silence_flag` is a useful secondary signal for detecting stuck panes.

Quick scan command:

```bash
tmux list-windows -t <session> -F '#{window_index}:#{window_name} bell=#{window_bell_flag} activity=#{window_activity_flag} silence=#{window_silence_flag}'
```

## Send-keys quirks to be aware of

- **Bracketed paste vs typing**: long inputs (rebase guidance payloads) should use `tmux load-buffer + paste-buffer` or `send-keys -l` to avoid keybinding interpretation in the receiving TUI.
- **Enter key**: `tmux send-keys ... Enter` is portable. `\n` in the payload string does NOT submit; the literal `Enter` token does.
- **Multi-line payloads**: prefer `load-buffer` + `paste-buffer` for anything over ~200 chars; long send-keys can be misinterpreted by some TUIs as paste-bracketed input.

## Per-harness signals

Per-harness adapters live in `pane-respond` (sending), `pane-poll` (reading), and the daemon's per-pane subscribers. The watch loop calls `pane-poll --batch -` once per cycle with the registry JSON so tmux metadata is resolved once, then uses legacy single-pane mode only for targeted drift re-polls/manual debugging. With an adapter wired, structured input/output replaces tmux capture-pane / send-keys for that pane; tmux remains the documented fallback.

### Send path (script: `pane-respond`)

| Harness | Adapter | Tmux fallback |
|---------|---------|---------------|
| Claude Code | Channels MCP webhook POST (opt-in via `--use-channels` / `FLIGHTDECK_CLAUDE_CHANNELS=1`) | `tmux load-buffer + paste-buffer + Enter`, plus arrow-nav for `--option N` (Numbers are NOT shortcuts; they're buffered as text). |
| opencode | `opencode run --attach --format json` to the per-pane HTTP server. `--option N` sends bare digit as message text; `--question` posts to `POST /question/<id>/{reply,reject}`. | Tmux paste-buffer for free text. `--option` not supported (no digit-key tmux mechanic for opencode). |
| pi | `pi-bridge send --pid <PID> --auto <msg>` via the Unix-socket session bridge. Slash dispatch supports client-side `/skill:<name>` and prompt-template expansion plus own-pane tmux paste for extension/TUI commands. `--question` uses `pi-bridge answer|reject`; `--answer-text` maps to the `pi-questions` custom/free-type answer when `allowCustom=true`. | Tmux send-keys fallback for daemon pi-master wakes; for true modal key-driving use `--keys-allow-tmux` and the inline UI keys. |
| codex | `codex-bridge send --url <ws> --thread <TID>` via the JSON-RPC client to `codex app-server` | Tmux paste-buffer fallback |

### Read path (script: `pane-poll` + daemon subscribers)

| Harness | Adapter | Tmux fallback |
|---------|---------|---------------|
| Claude Code | Tail `~/.claude/projects/<encoded-cwd>/<uuid>.jsonl` for assistant `stop_reason` events | `tmux capture-pane -p -S -200` |
| opencode | `GET /session/<id>/message` → last assistant text. Daemon also polls `GET /question` for the question tool, backing off unchanged polls up to `FD_OC_BACKOFF_MAX_SEC` and resetting on new question ids, hash change, or a cached bell marker (the daemon clears that bell flag after touching the marker to avoid repeated resets). | `tmux capture-pane -p -S -200` |
| pi | `pi-bridge history` / `pi-bridge stream` filtered for assistant `turn_end`; `pi-session-bridge` `vstack_activity` events from `Symbol.for("vstack.pi.activity")` append activity-only `pi-activity-broker` rows when `FLIGHTDECK_PI_ACTIVITY_BROKER` is not `0`; `pi-questions` opens emit canonical `pi-question` events; blocked/failed/needs-completion `pi-agents-tmux` inner completions emit advisory `pi-subagent-completion` events for the outer orchestrator only; `pi-background-tasks` exit messages (`customType=vstack-background-tasks:event`, `details.eventType=exit`) emit canonical `pi-bg-task-exit` events with producer `sequence` for tasks spawned with `notifyOnExit: true` (the default) so a terminal bg_task wakes the watcher even when the agent's own follow-up turn does not fire (vstack#15); non-exit bg-task messages emit activity-only `pi-bg-task-activity` rows and do not wake; tasks explicitly opted out of `notifyOnExit` still write the `message_end` entry but the bg_task handler honors the opt-out and does not nudge. Flightdeck must not route tools or bridge sends directly to inner agent panes. | `tmux capture-pane -p -S -200` |
| codex | `codex-bridge turns` / stream filtered for `thread/status/changed → idle` | `tmux capture-pane -p -S -200` |

### Idle / quiescent indicator (handler: `close-issue.md` § 1)

When an adapter is active, "idle" is observed structurally (turn-end event with no follow-up tool calls within debounce). For tmux fallback only:

| Harness | Tmux-fallback signal |
|---------|----------------------|
| Claude Code | `* Idle` line near buffer end, no input cursor waiting |
| opencode / pi / codex | Adapter-driven; tmux fallback uses bell-cleared + hash-stable buffer for two consecutive polls |

### Destroyed-CWD failure pattern (handler: `close-issue.md` § 1)

Inner pane's shell is dead because the worktree was removed mid-session. Subsequent tool calls fail to set cwd.

| Harness | Signal |
|---------|--------|
| Claude Code | `Path does not exist` in tool error including a worktree path; OR explicit `SESSION CWD DESTROYED` message |
| opencode / pi / codex | Adapter HTTP/socket call returns connection error (server up but session dead) — caller logs `<adapter>-unavailable: cwd-destroyed` and treats the issue as `dead` |

To add an adapter for a new harness:
1. Verify the actual contract by inspecting the harness in interactive use (server endpoints, socket protocol, or keystroke mechanic).
2. Implement the adapter in `lib/flightdeck-core/src/bin/<script>.ts` plus any helper modules under `src/adapters/`, `src/paths/`, etc.
3. Register the new adapter in the corresponding dispatch site.
4. Update both tables above with the mechanic.
5. Add a functional test under `lib/flightdeck-core/tests/parity/`.
6. Add a smoke test under `skills/flightdeck/tests/<harness>-smoke` and update `tests/live-wake.sh` if the wake path is affected.
7. Reflect any new user-facing env var in `skills/flightdeck/README.md` and every env var in `skills/flightdeck/ENV.md`.
