#!/usr/bin/env bash
# The wrapper launches its full-decision-table replays from inside the
# fixture blocks, so an early exit from a later block leaves replays running.
# This proves the wrapper's teardown owns the whole replay TREE — the
# selftest and the layer below it that a per-pid kill cannot reach — on both
# arms that reach teardown: an early exit, and a signal.
#
# Every variant is the wrapper itself, edited by exact line, so what is
# proven is the shipped teardown and not a copy of its shape. Three of them
# exist to make the other two falsifiable: with teardown's signalling
# removed, with its group kill narrowed to a per-pid kill, and with the
# post-launch `set +m` removed, the assertions below must go red.
#
# The abort fires after TWO replays are outstanding, so teardown's loop is
# proven past n=1, and survivors are polled to zero against a deadline
# rather than sampled once — bash's own wait reaps only the replay subshell,
# never the descendant being counted.
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
# Two replays, each a probe plus its descendant.
RG_TEARDOWN_REPLAYS=2
export RG_TEARDOWN_EXPECT=4
: >"$RG_TEARDOWN_PIDS"
JOBCONTROL_MARK="JOBCONTROL-LEFT-ENABLED"

# is_ours PID — still running AND still carrying our marker in argv. Every
# read and every kill goes through this, so a recycled number can neither
# read as a survivor nor be killed by this test's own cleanup.
is_ours() {
  # -ww: BSD/macOS ps truncates to 79 columns off a terminal, and the marker
  # sits at the tail of a long temp path.
  case "$(ps -ww -p "$1" -o args= 2>/dev/null || true)" in
    *"$marker"*) return 0 ;;
  esac
  return 1
}

alive() {
  local n=0 p
  while read -r p; do
    [ -n "$p" ] || continue
    if is_ours "$p"; then
      n=$((n + 1))
    fi
  done <"$RG_TEARDOWN_PIDS"
  echo "$n"
}

# alive_settled — alive() polled to zero against a deadline, echoing what
# remained. kill(2) queues the signal to every group member before it
# returns, but the members still have to run; sampling once would race that.
alive_settled() {
  local i=0 n
  n="$(alive)"
  while [ "$n" -ne 0 ] && [ "$i" -lt 60 ]; do
    i=$((i + 1))
    sleep 0.05
    n="$(alive)"
  done
  echo "$n"
}

reap() {
  [ -f "$RG_TEARDOWN_PIDS" ] || return 0
  local p
  while read -r p; do
    [ -n "$p" ] || continue
    if is_ours "$p"; then
      kill -KILL "$p" 2>/dev/null || true
    fi
  done <"$RG_TEARDOWN_PIDS"
}
trap 'reap; rm -rf "$work"' EXIT

mkdir -p "$work/bin"
probe="$work/bin/$marker-probe"
descendant="$work/bin/$marker-descendant"
waiter="$work/bin/$marker-wait"
stubborn="$work/bin/$marker-stubborn-probe"

# The selftest stand-in. Its descendant stands for the gh-shim/jq layer:
# a child of the selftest, two levels below the job the wrapper signals.
cat >"$probe" <<PROBE
#!/usr/bin/env bash
echo \$\$ >>"\$RG_TEARDOWN_PIDS"
"$descendant" &
wait
PROBE
# The loop keeps this alive without leaving a long sleep behind when the
# leaking variants' survivors are reaped by pid.
cat >"$descendant" <<'DESCENDANT'
#!/usr/bin/env bash
echo $$ >>"$RG_TEARDOWN_PIDS"
while :; do sleep 1; done
DESCENDANT
# Both replay trees must be fully recorded before the abort fires, or the
# survivor counts would be measuring a tree that never started. A timeout
# leaves a marker rather than letting that pass quietly.
cat >"$waiter" <<'WAITER'
#!/usr/bin/env bash
i=0
while [ "$(grep -c . "$RG_TEARDOWN_PIDS" || true)" -lt "$RG_TEARDOWN_EXPECT" ]; do
  i=$((i + 1))
  if [ "$i" -gt 400 ]; then
    : >"$RG_TEARDOWN_TIMEOUT"
    exit 0
  fi
  sleep 0.05
done
WAITER
# A probe that IGNORES TERM, so its group outlives the TERM sweep and only
# the KILL escalation can clear it. Its descendant still dies on TERM; the
# group stays up because this one does not.
cat >"$stubborn" <<STUBBORN
#!/usr/bin/env bash
trap '' TERM
echo \$\$ >>"\$RG_TEARDOWN_PIDS"
"$descendant" &
while :; do sleep 1; done
STUBBORN
chmod +x "$probe" "$descendant" "$waiter" "$stubborn"

# The exact wrapper lines each edit rewrites. A miss is not silent: awk
# records how many times each fired and the counts are asserted per variant.
L_SELFTEST='SELFTEST="$(cd "$TEST_DIR/../scripts" && pwd)/review-predicate-selftest.sh"'
L_ABORT='replay modetypo "$work/modetypo" REVIEW_GATE_MODE=offf'
L_SWEEP='    sweep_replays "$leaders"'
L_KILL='    kill "-$sig" "-$p" 2>/dev/null || kill "-$sig" "$p" 2>/dev/null || true'
L_SETPLUSM='  set +m'
L_POLLS='settle_polls=100'

# variant OUT MODE EDITS [STUB] — the wrapper with its selftest replaced by
# STUB (the ordinary probe unless given) and an abort injected once two
# replays are outstanding. MODE is `exit` for the early-exit arm, or the
# name of a signal the wrapper sends itself for the trap arm. EDITS is a
# space-separated set: `leak` neuters teardown's sweep, `perpid` narrows its
# group kill to the leader pid, `nojc` drops the post-launch `set +m`, and
# `fast` shrinks the settle budget for variants that would otherwise spend
# it twice over.
variant() {
  local out="$1" mode="$2" edits=" $3 " stub="${4:-$probe}"
  awk -v stub="$stub" -v waiter="$waiter" -v mark="$JOBCONTROL_MARK" \
      -v mode="$mode" -v edits="$edits" \
      -v l_self="$L_SELFTEST" -v l_abort="$L_ABORT" -v l_sweep="$L_SWEEP" \
      -v l_kill="$L_KILL" -v l_setplusm="$L_SETPLUSM" -v l_polls="$L_POLLS" \
      -v counts="$out.counts" '
    $0 == l_self { print "SELFTEST=\"" stub "\""; n_self++; next }
    $0 == l_abort {
      print
      print "\"" waiter "\""
      # Job control must be off again the moment replay() returns; the
      # variant with `set +m` removed is what proves this can fail.
      print "case \"$-\" in *m*) echo \"" mark "\" ;; esac"
      if (mode == "exit") { print "exit 9" }
      else { print "kill -" mode " $$"; print "exit 99" }
      n_abort++
      next
    }
    index(edits, " leak ") && $0 == l_sweep { print "    :"; n_leak++; next }
    index(edits, " perpid ") && $0 == l_kill { print "    kill \"-$sig\" \"$p\" 2>/dev/null || true"; n_perpid++; next }
    index(edits, " nojc ") && $0 == l_setplusm { print "  :"; n_nojc++; next }
    index(edits, " fast ") && $0 == l_polls { print "settle_polls=2"; n_fast++; next }
    { print }
    END {
      print (n_self + 0) " " (n_abort + 0) " " (n_leak + 0) \
        " " (n_perpid + 0) " " (n_nojc + 0) " " (n_fast + 0) > counts
    }
  ' "$WRAPPER" >"$out"
  chmod +x "$out"
}

# run VARIANT — a fresh probe tree per run; echoes the variant's exit status.
# TMPDIR is a private empty dir so the variant's own scratch dir is the only
# thing in it, which is what lets the caller assert teardown removed it.
run_variant() {
  local script="$1" rc=0
  : >"$RG_TEARDOWN_PIDS"
  rm -f "$RG_TEARDOWN_READY" "$RG_TEARDOWN_TIMEOUT"
  rm -rf "$script.tmpdir"
  mkdir -p "$script.tmpdir"
  TMPDIR="$script.tmpdir" bash "$script" >"$script.out" 2>&1 || rc=$?
  echo "$rc"
}

# started VARIANT — the run reached its abort with both trees up. Anything
# else makes the survivor count below meaningless, so it is named, not
# swallowed.
started() {
  local script="$1" rc="$2" want="$3" recorded left
  if [ -f "$RG_TEARDOWN_TIMEOUT" ]; then
    note "$(basename "$script"): the probe trees never came up within the abort's wait"
    return 1
  fi
  if [ "$rc" != "$want" ]; then
    cat "$script.out"
    note "$(basename "$script"): expected exit $want, got $rc"
    return 1
  fi
  recorded="$(grep -c . "$RG_TEARDOWN_PIDS" || true)"
  if [ "$recorded" -lt "$RG_TEARDOWN_EXPECT" ]; then
    note "$(basename "$script"): expected $RG_TEARDOWN_EXPECT recorded pids across two replay trees, got $recorded"
    return 1
  fi
  # Teardown removes the scratch dir on every arm it reaches, re-entered or
  # not, so the private TMPDIR must come back empty.
  left="$(ls -A "$script.tmpdir" 2>/dev/null | wc -l)"
  if [ "$left" -ne 0 ]; then
    note "$(basename "$script"): teardown left its scratch dir behind"
    return 1
  fi
  return 0
}

#       out                            mode  edits           stub
variant "$work/owning.test.sh"          exit  ""
variant "$work/sigterm.test.sh"         TERM  ""
variant "$work/sighup.test.sh"          HUP   ""
variant "$work/leaking.test.sh"         exit  "leak"
variant "$work/perpid.test.sh"          exit  "perpid fast"
variant "$work/nojobcontrol.test.sh"    exit  "nojc"
variant "$work/stubborn.test.sh"        exit  ""              "$stubborn"
for spec in "owning 1 1 0 0 0 0" "sigterm 1 1 0 0 0 0" "sighup 1 1 0 0 0 0" \
            "leaking 1 1 1 0 0 0" "perpid 1 1 0 1 0 1" "nojobcontrol 1 1 0 0 1 0" \
            "stubborn 1 1 0 0 0 0"; do
  name="${spec%% *}"
  want="${spec#* }"
  got="$(cat "$work/$name.test.sh.counts")"
  [ "$got" = "$want" ] \
    || note "$name variant's edits did not apply as expected (got '$got', want '$want') — the wrapper's lines moved"
done

if [ "$fail" -eq 0 ]; then
  # --- the early-exit arm: no replay descendant survives ------------------
  rc="$(run_variant "$work/owning.test.sh")"
  if started "$work/owning.test.sh" "$rc" 9; then
    survivors="$(alive_settled)"
    [ "$survivors" -eq 0 ] \
      || note "teardown left $survivors replay descendant(s) running after an early exit"
    if grep -q "$JOBCONTROL_MARK" "$work/owning.test.sh.out"; then
      note "the wrapper left job control enabled after a replay launch — a terminal signal would reach the foreground command instead of teardown"
    fi
    # An abort that kills replays mid-flight must say so, with the count it
    # actually had in flight — a silent one reads like a completed run.
    grep -q "aborting with $RG_TEARDOWN_REPLAYS replay(s) in flight" "$work/owning.test.sh.out" \
      || note "an abort with $RG_TEARDOWN_REPLAYS replays in flight did not report them on stderr"
  fi

  # --- the signal arms: the same, reached through the trap ----------------
  # HUP is here because putting each replay in its own process group is what
  # takes them out of the runner's group: nothing but these traps cleans up.
  for arm in "sigterm TERM" "sighup HUP"; do
    v="$work/${arm%% *}.test.sh"
    sig="${arm#* }"
    rc="$(run_variant "$v")"
    if started "$v" "$rc" 130; then
      survivors="$(alive_settled)"
      [ "$survivors" -eq 0 ] \
        || note "teardown left $survivors replay descendant(s) running after a SIG$sig"
    fi
  done

  # --- control: the survivor check must SEE a leaked tree -----------------
  rc="$(run_variant "$work/leaking.test.sh")"
  if started "$work/leaking.test.sh" "$rc" 9; then
    survivors="$(alive)"
    [ "$survivors" -eq "$RG_TEARDOWN_EXPECT" ] \
      || note "a wrapper with teardown's signalling removed left $survivors of $RG_TEARDOWN_EXPECT descendants — the survivor check cannot fail across both trees, so the assertions above are vacuous"
    reap
  fi

  # --- control: group semantics, not per-pid ------------------------------
  rc="$(run_variant "$work/perpid.test.sh")"
  if started "$work/perpid.test.sh" "$rc" 9; then
    survivors="$(alive)"
    [ "$survivors" -gt 0 ] \
      || note "a wrapper signalling each replay's pid instead of its process group left no survivors — the group kill is no longer what reaches the descendants"
    reap
  fi

  # --- control: the job-control probe must SEE a left-on -m ---------------
  rc="$(run_variant "$work/nojobcontrol.test.sh")"
  if started "$work/nojobcontrol.test.sh" "$rc" 9; then
    grep -q "$JOBCONTROL_MARK" "$work/nojobcontrol.test.sh.out" \
      || note "a wrapper with the post-launch 'set +m' removed did not trip the job-control probe — the probe cannot fail, so the check above is vacuous"
    survivors="$(alive_settled)"
    [ "$survivors" -eq 0 ] || reap
  fi

  # --- the KILL escalation, on a tree that ignores TERM -------------------
  # The probe here refuses TERM, so the settle budget has to expire and the
  # escalation has to fire — the branch and the budget are otherwise
  # executed by no test at all. The run must still end, and end cleanly.
  started_at="$SECONDS"
  rc="$(run_variant "$work/stubborn.test.sh")"
  elapsed=$((SECONDS - started_at))
  if started "$work/stubborn.test.sh" "$rc" 9; then
    survivors="$(alive_settled)"
    [ "$survivors" -eq 0 ] \
      || note "a replay tree that ignores TERM survived teardown — the KILL escalation did not reach it"
    grep -q "replay(s) survived TERM" "$work/stubborn.test.sh.out" \
      || note "teardown escalated to KILL without reporting it"
    [ "$elapsed" -lt 25 ] \
      || note "teardown took ${elapsed}s against a TERM-ignoring replay tree — the settle budget is not bounding it"
    reap
  fi
fi

if [ "$fail" -ne 0 ]; then
  echo "review-predicate-selftest-teardown.test: FAIL"
  exit 1
fi
echo "pass: review-predicate-selftest teardown owns the replay tree (early-exit and signal arms)"
