# Flightdeck tests

These tests are local smoke tests for the `flightdeck` skill's harness adapters and daemon wake path.

## Host requirements

- `tmux` 3.x with an active session (full live tests run inside that session)
- Real `pi` binary on `PATH` (or set `PI_BIN=/path/to/pi`) for Pi bridge tests
- GNU bash 5+ (`bash --version`)
- GNU date (`date --version` from coreutils)
- `jq`, `git`, `sha256sum`/coreutils, and the relevant harness CLI for adapter-specific tests (`opencode`, `codex`, etc.)
- `bun` (https://bun.sh) — hard runtime dependency for every flightdeck
  script. Trampolines under `scripts/` exec `bun .../src/bin/<script>.ts`.

## Bun test suite

The TypeScript implementation under `skills/flightdeck/lib/flightdeck-core/` ships a Bun functional test suite:

```bash
cd skills/flightdeck/lib/flightdeck-core
bun test
bun run typecheck
```

## `live-wake.sh`

`./skills/flightdeck/tests/live-wake.sh` is the full daemon wake smoke test. Runtime is normally about 2 minutes.

It exercises the production path end-to-end: pi-bridge registration, `pane-poll`, the daemon `start` run-loop, and the wake delivery into a Pi master.

It asserts that:

1. a real Pi master session registers with `pi-bridge` from an isolated temporary project;
2. `pane-poll --batch -` returns the live bash inner pane from a registry-shaped JSON input (when the test itself is running inside tmux, matching normal local usage);
3. `flightdeck-daemon start --in-tmux-window --master-harness pi` can launch against that master and a bash inner pane;
4. a terminal bell in the inner pane is detected by the daemon fallback path; and
5. the daemon wakes the Pi master through `pi-bridge send` with `/skill:flightdeck watch --from-daemon`, observable in `pi-bridge history`, with `harness=pi via=pi-bridge` in the daemon log. The test fails if that daemon log is absent.

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
