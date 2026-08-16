#!/usr/bin/env bash
# The wrapper launches its full-decision-table replays from inside the
# fixture blocks, so an early exit from a later block leaves replays running.
# This proves the wrapper's teardown owns the whole replay TREE: after a
# forced early exit, no replay descendant survives — not the selftest, and
# not the layer below it that a per-pid kill cannot reach.
#
# Both variants are the wrapper itself, edited by exact line, so what is
# proven is the shipped teardown and not a copy of its shape. The second
# variant removes teardown's pid tracking and its wait — the pre-fix
# behaviour — and must leave survivors, so the first variant's green is
# never a check that cannot fail.
#
# Deterministic by construction: the injected abort blocks until the probe
# tree has recorded itself, and teardown waits for every replay before it
# returns, so survivors are counted after the last descendant is reaped,
# never in a race with it.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRAPPER="$TEST_DIR/review-predicate-selftest.test.sh"

fail=0
note() { echo "FAIL: $1"; fail=1; }

[ -f "$WRAPPER" ] || { echo "FAIL: wrapper not found: $WRAPPER"; exit 1; }

work="$(mktemp -d)"
marker="rg-teardown-$$"
export RG_TEARDOWN_PIDS="$work/pids"
export RG_TEARDOWN_READY="$work/ready"
export RG_TEARDOWN_TIMEOUT="$work/timeout"
: >"$RG_TEARDOWN_PIDS"

# Recorded pids that are still running AS THIS PROBE TREE. Matching the
# marker in argv as well as the pid means a reused pid cannot read as a
# survivor.
alive() {
  local n=0 p args
  while read -r p; do
    [ -n "$p" ] || continue
    args="$(ps -p "$p" -o args= 2>/dev/null || true)"
    case "$args" in
      *"$marker"*) n=$((n + 1)) ;;
    esac
  done <"$RG_TEARDOWN_PIDS"
  echo "$n"
}

reap() {
  [ -f "$RG_TEARDOWN_PIDS" ] || return 0
  while read -r p; do
    [ -n "$p" ] || continue
    kill -KILL "$p" 2>/dev/null || true
  done <"$RG_TEARDOWN_PIDS"
}
trap 'reap; rm -rf "$work"' EXIT

mkdir -p "$work/bin"
probe="$work/bin/$marker-probe"
descendant="$work/bin/$marker-descendant"
waiter="$work/bin/$marker-wait"

# The selftest stand-in. Its descendant stands for the gh-shim/jq layer:
# a child of the selftest, two levels below the pid the wrapper records.
cat >"$probe" <<PROBE
#!/usr/bin/env bash
echo \$\$ >>"\$RG_TEARDOWN_PIDS"
"$descendant" &
wait
PROBE
# The loop keeps this alive without leaving a long sleep behind when the
# leaking variant's survivors are reaped by pid.
cat >"$descendant" <<'DESCENDANT'
#!/usr/bin/env bash
echo $$ >>"$RG_TEARDOWN_PIDS"
: >"$RG_TEARDOWN_READY"
while :; do sleep 1; done
DESCENDANT
# Ready means BOTH pids are recorded, so the abort below always fires
# against a fully-up tree. A timeout leaves a marker instead of letting the
# survivor count pass on a tree that never started.
cat >"$waiter" <<'WAITER'
#!/usr/bin/env bash
i=0
while [ ! -f "$RG_TEARDOWN_READY" ]; do
  i=$((i + 1))
  if [ "$i" -gt 400 ]; then
    : >"$RG_TEARDOWN_TIMEOUT"
    exit 0
  fi
  sleep 0.05
done
WAITER
chmod +x "$probe" "$descendant" "$waiter"

# The exact wrapper lines each edit rewrites. A miss is not silent: awk
# records how many times each fired and the counts are asserted below.
L_SELFTEST='SELFTEST="$(cd "$TEST_DIR/../scripts" && pwd)/review-predicate-selftest.sh"'
L_ABORT='replay defaults "$work/defaults"'
L_RECORD='  replay_pids="$replay_pids $!"'
L_WAIT='  wait 2>/dev/null || true'

# variant OUT NEUTER — the wrapper with its selftest replaced by the probe
# and an abort injected right after the first replay launch; NEUTER=1 also
# strips teardown's pid tracking and its wait.
variant() {
  local out="$1" neuter="$2"
  awk -v stub="$probe" -v waiter="$waiter" -v neuter="$neuter" \
      -v l_self="$L_SELFTEST" -v l_abort="$L_ABORT" \
      -v l_rec="$L_RECORD" -v l_wait="$L_WAIT" -v counts="$out.counts" '
    $0 == l_self { print "SELFTEST=\"" stub "\""; n_self++; next }
    $0 == l_abort { print; print "\"" waiter "\""; print "exit 9"; n_abort++; next }
    neuter == "1" && $0 == l_rec { print "  :"; n_rec++; next }
    neuter == "1" && $0 == l_wait { print "  :"; n_wait++; next }
    { print }
    END { print (n_self + 0) " " (n_abort + 0) " " (n_rec + 0) " " (n_wait + 0) > counts }
  ' "$WRAPPER" >"$out"
  chmod +x "$out"
}

# run VARIANT — a fresh probe tree per run; echoes the variant's exit status.
run_variant() {
  local script="$1" rc=0
  : >"$RG_TEARDOWN_PIDS"
  rm -f "$RG_TEARDOWN_READY" "$RG_TEARDOWN_TIMEOUT"
  bash "$script" >"$script.out" 2>&1 || rc=$?
  echo "$rc"
}

owning="$work/owning.test.sh"
leaking="$work/leaking.test.sh"
variant "$owning" 0
variant "$leaking" 1
owning_counts="$(cat "$owning.counts")"
leaking_counts="$(cat "$leaking.counts")"
[ "$owning_counts" = "1 1 0 0" ] \
  || note "the owning variant's edits did not apply as expected (self abort record wait = $owning_counts) — the wrapper's lines moved"
[ "$leaking_counts" = "1 1 1 1" ] \
  || note "the leaking variant's edits did not apply as expected (self abort record wait = $leaking_counts) — the wrapper's lines moved"

if [ "$fail" -eq 0 ]; then
  # --- the assertion: an early exit leaves no replay descendant behind ----
  rc="$(run_variant "$owning")"
  recorded="$(grep -c . "$RG_TEARDOWN_PIDS" || true)"
  survivors="$(alive)"
  if [ -f "$RG_TEARDOWN_TIMEOUT" ]; then
    note "the probe tree never came up within the abort's wait — the survivor count below would prove nothing"
  elif [ "$rc" != "9" ]; then
    cat "$owning.out"
    note "the owning variant did not reach its injected abort (exit $rc)"
  elif [ "$recorded" -lt 2 ]; then
    note "expected the probe and its descendant to record 2 pids, got $recorded"
  elif [ "$survivors" -ne 0 ]; then
    note "teardown left $survivors replay descendant(s) running after an early exit"
  fi

  # --- the control: the same check must SEE a leaked tree ----------------
  rc="$(run_variant "$leaking")"
  survivors="$(alive)"
  if [ -f "$RG_TEARDOWN_TIMEOUT" ]; then
    note "the probe tree never came up for the leaking variant"
  elif [ "$rc" != "9" ]; then
    cat "$leaking.out"
    note "the leaking variant did not reach its injected abort (exit $rc)"
  elif [ "$survivors" -eq 0 ]; then
    note "a wrapper with teardown's pid tracking removed left no survivors — the survivor check cannot fail, so the assertion above is vacuous"
  fi
  reap
fi

if [ "$fail" -ne 0 ]; then
  echo "review-predicate-selftest-teardown.test: FAIL"
  exit 1
fi
echo "pass: review-predicate-selftest teardown owns the replay tree"
