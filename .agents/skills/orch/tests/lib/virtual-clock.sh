# shellcheck shell=bash
#
# Virtual clock for the waiter suites: PATH stubs for `date` and `sleep` that
# put the wait budget under the suite's control instead of the machine's.
#
# The waiters (approval-wait, ci-wait, queue-wait) read wall time only as
# `date +%s` and wait only through `sleep`, so owning those two commands makes
# every budget exact. A sleep advances the clock and returns; a poll costs
# nothing unless a stub is told to charge for it by sleeping itself. What the
# cases then assert is arithmetic over the clock the waiter keeps, and it lands
# on the same number however slow the machine is.
#
# Two things follow. Deadline cases stop racing the runner: on wall time a suite
# running a few-second budget has no margin worth the name, and once a poll
# costs a large fraction of a second the deadline arrives before the poll that
# was meant to land inside it — a contended CI runner and a busy developer box
# both produce that, and it is what made the confirmation suite eject merge
# groups (KEN-879). And the budgets stop being spent in real time, which is the
# minutes these suites used to cost the shard.
#
# Sourced, never run: the runners glob tests/*.sh, so the `lib/` prefix keeps
# this file out of the run. Sourcing defines the functions and nothing else; a
# suite calls `virtual_clock_install` once its stub bin directory exists.
#
# Escape hatch: a case that needs a REAL sleep — one proving a bounded wait
# around a hang, say — runs with `STUB_CLOCK=` in its environment. Both stubs
# fall through to the real command when the clock file is unset or missing, so
# the exemption is per-case and needs no second PATH.

# Install the stubs into <bin_dir> and start the clock in <clock_file>.
# Exports STUB_CLOCK, STUB_REAL_DATE and STUB_REAL_SLEEP, so any subshell the
# suite runs the waiter in inherits them without threading them through.
virtual_clock_install() {
  local bin_dir="$1" clock_file="$2"
  [[ -d "$bin_dir" ]] || { echo "virtual clock: no stub bin directory at $bin_dir" >&2; return 1; }
  STUB_REAL_DATE="$(command -v date)"
  STUB_REAL_SLEEP="$(command -v sleep)"
  if [[ ! -x "$STUB_REAL_DATE" || ! -x "$STUB_REAL_SLEEP" ]]; then
    echo "virtual clock: no external date/sleep for the stubs to fall back on" >&2
    return 1
  fi
  STUB_CLOCK="$clock_file"
  export STUB_CLOCK STUB_REAL_DATE STUB_REAL_SLEEP

  cat > "$bin_dir/date" <<'EOF'
#!/usr/bin/env bash
# `+%s` is the clock a waiter keeps its budget on. Every other form is the real
# date, so a timestamp a script prints is still a real timestamp.
if [[ "${1:-}" == "+%s" && -f "${STUB_CLOCK:-}" ]]; then
  cat "$STUB_CLOCK"
  exit 0
fi
exec "$STUB_REAL_DATE" "$@"
EOF
  chmod +x "$bin_dir/date"

  cat > "$bin_dir/sleep" <<'EOF'
#!/usr/bin/env bash
# Whole seconds advance the clock and return; that is every wait a waiter and
# its gh stub make. Anything else is a real sleep, so an unexpected fractional
# wait still waits rather than silently passing.
if [[ "${1:-}" =~ ^[0-9]+$ && -f "${STUB_CLOCK:-}" ]]; then
  printf '%s' "$(( $(cat "$STUB_CLOCK") + $1 ))" > "$STUB_CLOCK"
  exit 0
fi
exec "$STUB_REAL_SLEEP" "$@"
EOF
  chmod +x "$bin_dir/sleep"

  virtual_clock_reset
}

# Restart the clock at the real epoch, so anything reading an absolute time
# still reads a plausible one and each run moves the clock from there. Call it
# before every run whose elapsed arithmetic is asserted.
virtual_clock_reset() {
  "${STUB_REAL_DATE:?virtual clock not installed}" +%s > "${STUB_CLOCK:?virtual clock not installed}"
}
