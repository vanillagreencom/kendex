# shellcheck shell=bash
#
# Virtual clock for the waiter suites: PATH stubs for `date` and `sleep` that
# put a poll budget under the suite's control instead of the machine's.
#
# The waiters read wall time only as `date +%s` and wait only through `sleep`,
# so owning those two commands makes every budget exact. A sleep advances the
# clock and returns; a poll costs nothing unless a stub is told to charge for it
# by sleeping itself. What the cases then assert is arithmetic over the clock
# the waiter keeps, and it lands on the same number however slow the machine is.
#
# Two things follow. Deadline cases stop racing the runner: on wall time a suite
# running a few-second budget has no margin worth the name, and once a poll
# costs a large fraction of a second the deadline arrives before the poll that
# was meant to land inside it — a contended CI runner and a busy developer box
# both produce that, and it is what made the confirmation suite eject merge
# groups (KEN-879). And no poll budget is spent in real time, which is the
# minutes these suites used to cost the shard.
#
# The clock is seeded once, at install, and runs forward for the whole suite.
# Every waiter takes its own start time at process start and derives its budget
# from that, so no case reads an absolute time and nothing needs a reset
# between runs.
#
# Sourced, never run: the runners glob tests/*.sh, so the `lib/` prefix keeps
# this file out of the run. Sourcing defines the functions and nothing else; a
# suite calls `virtual_clock_install` once its stub bin directory exists.
#
# Escape hatch: a case that needs a REAL sleep — one proving a bounded wait
# around a hang, say — runs with `STUB_CLOCK=` in its environment. Both stubs
# fall through to the real command when STUB_CLOCK is unset or empty, so the
# exemption is per-case and needs no second PATH. A STUB_CLOCK that is set but
# names no file is the other thing entirely — a clock that broke rather than one
# waived — and both stubs refuse it rather than degrade to wall time.

# Install the stubs into <bin_dir> and start the clock in <clock_file>.
# Exports STUB_CLOCK, STUB_REAL_DATE and STUB_REAL_SLEEP, so any subshell the
# suite runs the waiter in inherits them without threading them through. Called
# for effect during setup: every failure below exits the suite rather than
# returning, so no caller can continue with the budgets back on wall time.
virtual_clock_install() {
  local bin_dir="$1" clock_file="$2"
  [[ -d "$bin_dir" ]] || { echo "virtual clock: no stub bin directory at $bin_dir" >&2; exit 1; }
  STUB_REAL_DATE="$(command -v date)"
  STUB_REAL_SLEEP="$(command -v sleep)"
  if [[ ! -x "$STUB_REAL_DATE" || ! -x "$STUB_REAL_SLEEP" ]]; then
    echo "virtual clock: no external date/sleep for the stubs to fall back on" >&2
    exit 1
  fi
  STUB_CLOCK="$clock_file"
  export STUB_CLOCK STUB_REAL_DATE STUB_REAL_SLEEP

  cat > "$bin_dir/date" <<'EOF'
#!/usr/bin/env bash
# `+%s` is the clock a waiter keeps its budget on. Every other form is the real
# date, so a timestamp a script prints is still a real timestamp.
if [[ "${1:-}" == "+%s" ]]; then
  if [[ -n "${STUB_CLOCK:-}" ]]; then
    [[ -f "$STUB_CLOCK" ]] || { echo "virtual clock: STUB_CLOCK names no file: $STUB_CLOCK" >&2; exit 1; }
    cat "$STUB_CLOCK"
    exit 0
  fi
fi
exec "$STUB_REAL_DATE" "$@"
EOF
  chmod +x "$bin_dir/date"

  cat > "$bin_dir/sleep" <<'EOF'
#!/usr/bin/env bash
# Whole seconds advance the clock and return; that is every wait a waiter and
# its gh stub make. Anything else is a real sleep, so an unexpected fractional
# wait still waits rather than silently passing.
if [[ "${1:-}" =~ ^[0-9]+$ ]]; then
  if [[ -n "${STUB_CLOCK:-}" ]]; then
    [[ -f "$STUB_CLOCK" ]] || { echo "virtual clock: STUB_CLOCK names no file: $STUB_CLOCK" >&2; exit 1; }
    printf '%s' "$(( $(cat "$STUB_CLOCK") + $1 ))" > "$STUB_CLOCK"
    exit 0
  fi
fi
exec "$STUB_REAL_SLEEP" "$@"
EOF
  chmod +x "$bin_dir/sleep"

  # Prove the stubs work before any case leans on them: a timestamp no real
  # clock returns, read back through them and then advanced. A stub that was
  # never written, is not executable, or declines to read the clock answers with
  # the real epoch and fails here instead of quietly spending every budget in
  # wall time. It proves the stubs at bin_dir, not the PATH a suite later runs
  # its waiter under.
  local probe=1000000 seen
  printf '%s' "$probe" > "$STUB_CLOCK"
  seen="$(PATH="$bin_dir:$PATH" date +%s)"
  [[ "$seen" == "$probe" ]] \
    || { echo "virtual clock: date +%s answered $seen, not the seeded $probe" >&2; exit 1; }
  PATH="$bin_dir:$PATH" sleep 5
  seen="$(PATH="$bin_dir:$PATH" date +%s)"
  [[ "$seen" == "$((probe + 5))" ]] \
    || { echo "virtual clock: a 5s sleep left the clock at $seen, not $((probe + 5))" >&2; exit 1; }

  _virtual_clock_seed
}

# Start the clock at the real epoch, so anything reading an absolute time still
# reads a plausible one and the suite moves it from there.
_virtual_clock_seed() {
  "${STUB_REAL_DATE:?virtual clock not installed}" +%s > "${STUB_CLOCK:?virtual clock not installed}"
}
