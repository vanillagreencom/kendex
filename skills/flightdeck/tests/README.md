# Flightdeck tests

These tests are local smoke tests for the `flightdeck` skill's harness adapters and daemon wake path.

## Host requirements

- `tmux` 3.x with an active session (full live tests run inside that session)
- Real `pi` binary on `PATH` (or set `PI_BIN=/path/to/pi`) for Pi bridge tests
- GNU bash 5+ (`bash --version`)
- GNU date (`date --version` from coreutils)
- `jq`, `git`, `sha256sum`/coreutils, and the relevant harness CLI for adapter-specific tests (`opencode`, `codex`, etc.)
- `bun` (https://bun.sh) for the TS-port parity test suite and for
  trampolined TS execution. `bun` is a hard runtime dependency on the
  default TS path; only required-for-bash-only setups
  (`FLIGHTDECK_USE_TS=0`) can omit it

## TS-port parity tests

The TS port under `skills/flightdeck/lib/flightdeck-core/` ships a Bun
test suite that asserts byte-for-byte parity between each ported script
and its bash sibling. Run it whenever the bash or TS body of a ported
script changes:

```bash
cd skills/flightdeck/lib/flightdeck-core
bun test
bun run typecheck
```

Parity is required — but not sufficient — before changing any
`FLIGHTDECK_USE_TS*` default. The live wake suite below must also be
green under the same configuration.

## `live-wake.sh`

`./skills/flightdeck/tests/live-wake.sh` is the full daemon wake smoke test. Runtime is normally about 2 minutes.

By default it exercises the **TS trampolines** — the same path that
production uses. To validate the legacy bash sibling for a specific
script, opt out of the TS default before invoking the test:

```bash
# Exercise the bash prompt-classify sibling in live-wake.
FLIGHTDECK_USE_TS_PROMPT_CLASSIFY=0 skills/flightdeck/tests/live-wake.sh

# Exercise every trampoline's bash sibling.
FLIGHTDECK_USE_TS=0 skills/flightdeck/tests/live-wake.sh
```

The `--use-ts` flag is still available as an explicit opt-in for the
daemon `start` sub-action (which keeps its own opt-in gate;
`FLIGHTDECK_USE_TS_DAEMON_START=1` plus the trampoline default). The
bash daemon body remains the default `start` runtime until one full
production cycle on the TS run-loop.

It asserts that:

1. a real Pi master session registers with `pi-bridge` from an isolated temporary project;
2. `pane-poll --batch -` returns the live bash inner pane from a registry-shaped JSON input (when the test itself is running inside tmux, matching normal local usage);
3. `flightdeck-daemon start --in-tmux-window --master-harness pi` can launch against that master and a bash inner pane;
4. a terminal bell in the inner pane is detected by the daemon fallback path; and
5. the daemon wakes the Pi master through `pi-bridge send` with `/skill:flightdeck watch --from-daemon`, observable in `pi-bridge history`, with `harness=pi via=pi-bridge` in the daemon log. The test fails if that daemon log is absent.

Note: step 3 (`flightdeck-daemon start`) defaults to the bash daemon
body even when the other trampolines are on TS. The TS run-loop +
subscriber lifecycle is complete and parity-tested, but its runtime
default is gated on a separate opt-in (`FLIGHTDECK_USE_TS_DAEMON_START=1`
or `FLIGHTDECK_USE_TS=1`) until one full production cycle confirms
stability. Use `live-wake.sh --use-ts` to exercise the TS daemon run
loop end-to-end.

Run full mode from inside tmux:

```bash
skills/flightdeck/tests/live-wake.sh
```

By default it uses the current tmux session, falling back to `VS` when no current session name can be resolved. Override with:

```bash
FD_LIVE_TMUX_SESSION=VS skills/flightdeck/tests/live-wake.sh
```

The test creates `fdlive-*` tmux windows and kills stale `fdlive-*` windows in its `trap EXIT` cleanup. It also uses a visible `[fd] daemon-s<N>` window while the daemon is running, then kills it on exit.

### CI-friendly shape mode

Use `--no-tmux` for a fast smoke check that does not spawn tmux, Pi, or the daemon:

```bash
skills/flightdeck/tests/live-wake.sh --no-tmux
```

Shape mode checks GNU bash/date availability, executable script paths, and bash syntax for the daemon and related scripts.

## Cleaning daemon artifacts

Daemon artifacts live under `${FD_STATE_DIR}`. Without an override, the daemon uses `$XDG_RUNTIME_DIR/flightdeck` when available, otherwise `/tmp/flightdeck-$UID`.

Between local full-mode runs, remove stale flightdeck daemon artifacts for tmux session keys (`s<N>`) if needed:

```bash
rm -f /run/user/$UID/flightdeck/fd-*-s*.* 2>/dev/null || true
rm -f /tmp/flightdeck-$UID/fd-*-s*.* 2>/dev/null || true
```

If a run is interrupted before cleanup, remove leftover test windows from the target tmux session:

```bash
tmux list-windows -t VS -F '#{window_id} #{window_name}' \
  | awk '$2 ~ /^fdlive-/ { print $1 }' \
  | xargs -r -n1 tmux kill-window -t
```
