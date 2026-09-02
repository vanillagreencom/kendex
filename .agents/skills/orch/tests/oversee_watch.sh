#!/usr/bin/env bash
# Regression tests for the GitHub side of orch/scripts/oversee-watch, and for
# the failures that take the whole process down. The pane side — window-gone,
# lane-exited, usage-limit, lane-asking, idle-after-return — is in the two
# lane suites. Tracker events are in oversee_watch_triage.sh. All use the
# shared lib/oversee-watch-harness.sh sandbox.
#
# oversee-watch is the overseer's single blocking watch: it loops until the
# fleet needs a hand and prints one wake, with one EVENT line or one line per
# merged or triage item. Covered here:
#   1.  pr-watch: on the fleet's first run attention present at start is a
#       baseline (no event, one stderr note, context on the next event); that
#       baseline persists, so a line appearing between two runs is the next
#       run's first-pass event and a standing line is not; a NEW `<pr> <kind>`
#       line mid-run is the event; a head-only change is not; GH_REPO reaches
#       pr-watch and its argv is exactly --heal, for every repo; a
#       heal-dispatched line is never a key — alone, re-attributed to another
#       PR, or alone on a repo that is not the first reduced — while the
#       gate-stale beside it still fires and is the only key baselined; an
#       error key preempts a repo's opening pass while every other kind there
#       still baselines silently;
#       rc≠0 with no lines is a global failure (exit 2); attention
#       at start does not starve a lane's question; the state file is
#       rewritten after every pass, and an uncreatable state dir or an
#       unreadable state file exits 2 naming the path; the reducer runs for
#       every --repo, with per-repo baselines and repo-prefixed lines on both
#       streams, no baseline advances until the whole pass has reduced, a repo
#       named for the first time baselines its standing attention in either
#       ordering, the context header carries the highest status across repos, a
#       global failure names its repo, a repeated --repo exits 2 naming the
#       spelling given, --repo=VALUE is the same option, and a fleet of more
#       than one repo is told which repo `merged` reads
#   2.  merged: an --item's PR merged at/after --since fires; a PR merged
#       BEFORE --since, a non-item branch, and a non-item conventional branch
#       do not; a fork's PR on the same head branch name does not; item ids
#       match branches case-insensitively; no --since means no floor; no
#       --item skips the check with a note; gh stderr noise on success does
#       not break the JSON parse
#   3.  heartbeat after --max-loops with the open PR list
#   4.  gh auth failure exits 2; a stale env token falls through to the
#       project GH_BOT_TOKEN; a failing pr list exits 2 (never a quiet 0)
#   5.  lanes given outside tmux exit 2
#   6.  a missing pr-watch.sh is a stderr note, not a failure
#   7.  --help exits 0, names the probe it runs, and states both liveness
#       rules including the unusable-probe path
set -euo pipefail

# shellcheck source=lib/oversee-watch-harness.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/oversee-watch-harness.sh"

echo "=== oversee-watch ==="

# --- 1. pr-watch -----------------------------------------------------------
# 1a. attention present at start: baseline, not the event
new_case prwatch_baseline
printf '12\tabcdef01\tthreads-open\t2 unresolved\n' > "$STUB_DIR/prwatch.out"
printf '1' > "$STUB_DIR/prwatch.rc"
err="$TMP_ROOT/e1a"
out="$(run_watch -- 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "0" "attention at start exits 0" "$err"
assert_eq "$(head -1 <<<"$out")" "EVENT heartbeat loops=2 interval=0s since=none" "attention at start is not the event (heartbeat is)" "$err"
assert_contains "$out" "pr-watch rc=1" "latest pr-watch state is appended to the event" "$err"
assert_contains "$out" "threads-open" "pr-watch lines follow the context header" "$err"
assert_contains "$(cat "$err")" "pr-watch attention present at start" "baseline is noted once on stderr"
assert_eq "$(grep -c 'attention present at start' "$err")" "1" "baseline note printed once, not per pass"
assert_eq "$(cat "$STUB_DIR/prwatch.repo")" "owner/repo" "GH_REPO is exported to pr-watch" "$err"
# --heal is what makes gate-stale self-healing instead of overseer hand-work:
# without it the writer only converges on the cron floor. Matched WHOLE, not as
# a substring: pr-watch.sh rejects an unknown flag with exit 2, so a near miss
# like --healing-only dies on every pass while a substring assertion stays
# green.
assert_eq "$(cat "$STUB_DIR/prwatch.args")" "--heal" "pr-watch is invoked with --heal" "$err"

# 1b. a NEW <pr> <kind> line mid-run is the event
new_case prwatch_new
printf '0' > "$STUB_DIR/prwatch.rc.1"
printf '12\tabcdef01\tthreads-open\t2 unresolved\n' > "$STUB_DIR/prwatch.out.2"
printf '1' > "$STUB_DIR/prwatch.rc.2"
err="$TMP_ROOT/e1b"
out="$(run_watch -- 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "0" "new pr-watch line exits 0" "$err"
assert_eq "$(head -1 <<<"$out")" "EVENT pr-watch rc=1" "a new attention line mid-run is the event" "$err"
assert_contains "$out" "threads-open" "pr-watch output follows the event line" "$err"

# 1c. the same <pr> <kind> under a new head is not new (a lane pushed)
new_case prwatch_head_moved
printf '12\taaaa0000\tthreads-open\t2 unresolved\n' > "$STUB_DIR/prwatch.out.1"
printf '12\tbbbb0000\tthreads-open\t1 unresolved\n' > "$STUB_DIR/prwatch.out.2"
printf '1' > "$STUB_DIR/prwatch.rc"
err="$TMP_ROOT/e1c"
out="$(run_watch -- 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT heartbeat loops=2 interval=0s since=none" "same pr+kind under a new head is not an event" "$err"
assert_contains "$out" "bbbb0000" "context carries the LATEST pr-watch output" "$err"

# 1d. a new kind on an already-baselined PR is new
new_case prwatch_new_kind
printf '12\taaaa0000\tthreads-open\t2 unresolved\n' > "$STUB_DIR/prwatch.out.1"
printf '12\taaaa0000\tthreads-open\t2 unresolved\n12\taaaa0000\tdisarmed\tauto-merge off\n' > "$STUB_DIR/prwatch.out.2"
printf '1' > "$STUB_DIR/prwatch.rc"
err="$TMP_ROOT/e1d"
out="$(run_watch -- 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT pr-watch rc=1" "a new kind on a baselined PR is the event" "$err"

# 1d'. heal-dispatched is the reducer's own note, never a key of its own: alone
# it is not an event, and the once-per-invocation dispatch re-attributing to a
# different PR mints nothing either.
new_case prwatch_heal_alone
printf '0' > "$STUB_DIR/prwatch.rc.1"
printf '12\taaaa0000\theal-dispatched\twriter workflow dispatched\n' > "$STUB_DIR/prwatch.out.2"
printf '1' > "$STUB_DIR/prwatch.rc.2"
err="$TMP_ROOT/e1d2"
out="$(run_watch -- 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT heartbeat loops=2 interval=0s since=none" "a lone heal-dispatched line is not an event" "$err"
assert_contains "$out" "heal-dispatched" "the heal-dispatched line still rides along as context" "$err"

new_case prwatch_heal_reattributed
printf '12\taaaa0000\tgate-stale\tpredicate disagrees\n12\taaaa0000\theal-dispatched\twriter workflow dispatched\n' > "$STUB_DIR/prwatch.out.1"
printf '12\taaaa0000\tgate-stale\tpredicate disagrees\n34\tcccc0000\theal-dispatched\twriter workflow dispatched\n' > "$STUB_DIR/prwatch.out.2"
printf '1' > "$STUB_DIR/prwatch.rc"
err="$TMP_ROOT/e1d3"
out="$(run_watch -- 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT heartbeat loops=2 interval=0s since=none" "the one dispatch moving to another PR is not an event" "$err"

# 1d''. the gate-stale beside it is still the event it always was, and the
# baseline the pass commits holds the gate-stale key alone.
new_case prwatch_heal_with_stale
printf '0' > "$STUB_DIR/prwatch.rc.1"
printf '12\taaaa0000\tgate-stale\tpredicate disagrees\n12\taaaa0000\theal-dispatched\twriter workflow dispatched\n' > "$STUB_DIR/prwatch.out.2"
printf '1' > "$STUB_DIR/prwatch.rc.2"
err="$TMP_ROOT/e1d4"
out="$(run_watch -- 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT pr-watch rc=1" "gate-stale beside a heal-dispatched line is still the event" "$err"
assert_contains "$out" "heal-dispatched" "the event carries the heal-dispatched companion" "$err"
assert_eq "$(cat "$STATE_DIR/owner_repo__none")" "$(printf '12\tgate-stale')" \
  "the committed baseline holds the gate-stale key alone" "$err"

# 1d'''. the reduction is per repo, so the exclusion has to hold on a repo that
# is not the first one reduced.
new_case prwatch_heal_alone_second_repo
printf '0' > "$STUB_DIR/prwatch.rc.owner_repo"
printf '0' > "$STUB_DIR/prwatch.rc.other_repo.1"
printf '7\tbbbb0000\theal-dispatched\twriter workflow dispatched\n' > "$STUB_DIR/prwatch.out.other_repo.2"
printf '1' > "$STUB_DIR/prwatch.rc.other_repo.2"
err="$TMP_ROOT/e1d5"
out="$(run_watch -- --repo owner/repo --repo other/repo 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT heartbeat loops=2 interval=0s since=none" "a lone heal-dispatched line on the second repo is not an event" "$err"
assert_eq "$(sort -u "$STUB_DIR/prwatch.args.all" | cut -f2 | sort -u)" "--heal" \
  "every repo's pass is invoked with --heal" "$err"

# 1d''''. an error key preempts a repo's opening pass. Every other kind
# standing at start is that repo's baseline, but a failed writer dispatch
# baselined at start is never news again, and the overseer would hear nothing
# until the heartbeat.
new_case prwatch_error_first_pass
printf '12\taaaa0000\tgate-stale\tpredicate disagrees\n12\taaaa0000\terror\twriter dispatch failed for '"'"'Review gate writer'"'"'\n' > "$STUB_DIR/prwatch.out"
printf '1' > "$STUB_DIR/prwatch.rc"
err="$TMP_ROOT/e1d6"
out="$(run_watch -- 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "0" "an error at start exits 0" "$err"
assert_eq "$(head -1 <<<"$out")" "EVENT pr-watch rc=1" "an error line at start is the event, not the baseline" "$err"
assert_contains "$out" "writer dispatch failed" "the event carries the failed dispatch" "$err"
assert_eq "$(grep -c 'attention present at start' "$err")" "0" "the baseline note does not stand in for the error event"

# The companion: without an error key the opening pass still baselines
# silently, so the preemption above is scoped to error and nothing else.
new_case prwatch_no_error_first_pass
printf '12\taaaa0000\tgate-stale\tpredicate disagrees\n12\taaaa0000\theal-dispatched\twriter workflow dispatched\n' > "$STUB_DIR/prwatch.out"
printf '1' > "$STUB_DIR/prwatch.rc"
err="$TMP_ROOT/e1d7"
out="$(run_watch -- 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT heartbeat loops=2 interval=0s since=none" "a first pass with no error key still baselines" "$err"
assert_eq "$(grep -c 'attention present at start' "$err")" "1" "the ordinary first-pass note still covers the non-error keys"

# 1e'. a line that clears and later recurs is a rising edge again
new_case prwatch_recur
printf '12\taaaa0000\tthreads-open\t2 unresolved\n' > "$STUB_DIR/prwatch.out.1"
printf '1' > "$STUB_DIR/prwatch.rc.1"
printf '0' > "$STUB_DIR/prwatch.rc.2"
printf '12\tbbbb0000\tthreads-open\t1 unresolved\n' > "$STUB_DIR/prwatch.out.3"
printf '1' > "$STUB_DIR/prwatch.rc.3"
err="$TMP_ROOT/e1e2"
out="$(run_watch -- --max-loops 3 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT pr-watch rc=1" "a cleared pr+kind that recurs is an event again" "$err"

# 1e. rc≠0 with no per-PR lines is pr-watch's global failure: exit 2
new_case prwatch_global
printf '2' > "$STUB_DIR/prwatch.rc"
printf 'pr-watch: GH_REPO is not set\n' > "$STUB_DIR/prwatch.err"
err="$TMP_ROOT/e1e"
out="$(run_watch -- 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "2" "pr-watch rc=2 with no lines exits 2" "$err"
assert_eq "$out" "" "pr-watch global failure prints no EVENT" "$err"
assert_contains "$(cat "$err")" "pr-watch failed for owner/repo (rc=2) with no per-PR lines" "global failure is named on stderr"
assert_contains "$(cat "$err")" "GH_REPO is not set" "pr-watch stderr is surfaced"

# 1f. attention at start does not starve a lane's question
new_case prwatch_no_starve
printf '12\tabcdef01\tthreads-open\t2 unresolved\n' > "$STUB_DIR/prwatch.out"
printf '1' > "$STUB_DIR/prwatch.rc"
printf 'Do you want to proceed?\n   ❯ 1. Yes\n     2. No\n' > "$STUB_DIR/pane-gh-2.txt"
err="$TMP_ROOT/e1f"
out="$(run_watch -- gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT lane-asking gh-2" "a lane question is seen despite standing pr-watch attention" "$err"
assert_contains "$out" "pr-watch rc=1" "the question event still carries the pr-watch context" "$err"

# 1g. the baseline persists across runs of the same fleet: the overseer exits
# on every event and re-runs the watch, so a line that appears BETWEEN two runs
# is the next run's first-pass event, while a standing line stays baseline
new_case prwatch_cross_run
printf '12\tabcdef01\tthreads-open\t2 unresolved\n' > "$STUB_DIR/prwatch.out"
printf '1' > "$STUB_DIR/prwatch.rc"
err="$TMP_ROOT/e1g1"
out="$(run_watch -- --since 2026-08-15T09:00:00Z 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT heartbeat loops=2 interval=0s since=2026-08-15T09:00:00Z" \
  "run 1 of a fleet: attention at start is the baseline, not the event" "$err"

# run 2, same fleet (same repo and --since): PR 12 alone is not news
err="$TMP_ROOT/e1g2"
out="$(run_watch -- --since 2026-08-15T09:00:00Z 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT heartbeat loops=2 interval=0s since=2026-08-15T09:00:00Z" \
  "run 2: a key carried over from run 1 is not an event" "$err"
assert_not_contains "$out" "EVENT pr-watch" "run 2 with no new key never fires pr-watch" "$err"

# run 3: PR 34 showed up while the overseer was handling something else
printf '12\tabcdef01\tthreads-open\t2 unresolved\n34\t99887766\tthreads-open\t1 unresolved\n' > "$STUB_DIR/prwatch.out"
err="$TMP_ROOT/e1g3"
out="$(run_watch -- --since 2026-08-15T09:00:00Z 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "0" "cross-run rising edge exits 0" "$err"
assert_eq "$(head -1 <<<"$out")" "EVENT pr-watch rc=1" \
  "attention arriving between two runs is the next run's first-pass event" "$err"
assert_contains "$out" "99887766" "the new PR's line follows the event" "$err"
assert_not_contains "$(cat "$err")" "attention present at start" \
  "a persisted baseline replaces the start-of-run note"

# 1h. the state file is rewritten after every pass — the pass's keys, and the
# empty set when the reducer reports nothing
new_case prwatch_state_file
printf '12\tabcdef01\tthreads-open\t2 unresolved\n' > "$STUB_DIR/prwatch.out"
printf '1' > "$STUB_DIR/prwatch.rc"
err="$TMP_ROOT/e1h1"
out="$(run_watch -- 2>"$err")" && rc=0 || rc=$?
assert_eq "$(ls -1 "$STATE_DIR" 2>/dev/null | wc -l | tr -d '[:space:]')" "1" "one state file for the one repo, no temp left behind" "$err"
state_file="$STATE_DIR/owner_repo__none"
assert_eq "$([[ -f "$state_file" ]] && echo yes || echo no)" "yes" "the state file is keyed on the repo and --since" "$err"
assert_eq "$(cat "$state_file")" "$(printf '12\tthreads-open')" "the state file holds the pass's <pr> <kind> keys" "$err"

printf '0' > "$STUB_DIR/prwatch.rc"
: > "$STUB_DIR/prwatch.out"
err="$TMP_ROOT/e1h2"
out="$(run_watch -- 2>"$err")" && rc=0 || rc=$?
assert_eq "$([[ -f "$state_file" ]] && echo yes || echo no)" "yes" "the state file survives a clean pass" "$err"
assert_eq "$(cat "$state_file" 2>/dev/null; echo x)" "x" "a pass with no attention empties the state file" "$err"

# 1i. a state directory that cannot be created is a hard failure, never a
# silent fallback to in-process-only memory
new_case prwatch_state_unwritable
printf 'not a directory\n' > "$STUB_DIR/blocker"
err="$TMP_ROOT/e1i"
out="$(run_watch OVERSEE_WATCH_STATE_DIR="$STUB_DIR/blocker/state" -- 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "2" "an uncreatable state dir exits 2" "$err"
assert_eq "$out" "" "state dir failure prints no EVENT" "$err"
assert_contains "$(cat "$err")" "$STUB_DIR/blocker/state" "the failure names the state dir path"

# 1j. an unreadable state file is exit 2 naming the path, not a raw `cat`
# error under set -e. Root reads anything, so the case cannot run there.
new_case prwatch_state_unreadable
if [[ "$(id -u)" -eq 0 ]]; then
  printf '  skip  unreadable state file (running as root)\n'
else
  printf '12\tabcdef01\tthreads-open\t2 unresolved\n' > "$STUB_DIR/prwatch.out"
  printf '1' > "$STUB_DIR/prwatch.rc"
  err="$TMP_ROOT/e1j1"
  out="$(run_watch -- 2>"$err")" && rc=0 || rc=$?
  state_file="$STATE_DIR/owner_repo__none"
  chmod 000 "$state_file"
  err="$TMP_ROOT/e1j2"
  out="$(run_watch -- 2>"$err")" && rc=0 || rc=$?
  chmod 600 "$state_file"
  assert_eq "$rc" "2" "an unreadable state file exits 2" "$err"
  assert_eq "$out" "" "an unreadable state file prints no EVENT" "$err"
  assert_contains "$(cat "$err")" "cannot read the pr-watch state file: $state_file" \
    "the failure names the state file path"
fi

# 1j'. a state file that cannot be written exits 2, on the staging guard here
# and on the rename if that guard is ever dropped. Root writes anywhere, so the
# case cannot run there.
new_case prwatch_state_unwritable_file
if [[ "$(id -u)" -eq 0 ]]; then
  printf '  skip  unwritable state file (running as root)\n'
else
  printf '12\tabcdef01\tthreads-open\t2 unresolved\n' > "$STUB_DIR/prwatch.out"
  printf '1' > "$STUB_DIR/prwatch.rc"
  # A read-only directory in the state file's place: staging rejects the target
  # before any temp is written, and the mode keeps the rename failing too if
  # that guard is ever dropped. The discard has nothing to remove on this pass
  # (one repo, no temp yet), so 1m run 4 owns that behaviour.
  mkdir -p "$STATE_DIR/owner_repo__none"
  chmod 500 "$STATE_DIR/owner_repo__none"
  err="$TMP_ROOT/e1j3"
  out="$(run_watch -- 2>"$err")" && rc=0 || rc=$?
  chmod 700 "$STATE_DIR/owner_repo__none"
  assert_eq "$rc" "2" "a state file that cannot be written exits 2" "$err"
  assert_eq "$out" "" "a failed state write on a pass with no event prints no EVENT" "$err"
  assert_contains "$(cat "$err")" "could not write the pr-watch state file" \
    "the failure names what could not be written"
fi

# 1k. the reducer covers EVERY --repo: attention on a second repo is the event,
# every repo's latest lines reach the context prefixed with the repo they came
# from, and each repo keeps its own baseline. Red when the reducer runs for the
# first --repo alone: the second repo is never reduced, so its rising edge is
# invisible and the pass falls through to the heartbeat.
new_case prwatch_multi_repo
printf '12\taaaa0000\tthreads-open\t2 unresolved\n' > "$STUB_DIR/prwatch.out.owner_repo"
printf '1' > "$STUB_DIR/prwatch.rc.owner_repo"
# other/repo is clear on pass 1 and grows a thread on pass 2, so the event
# cannot be owner/repo's standing line — which is pass 1's baseline.
printf '0' > "$STUB_DIR/prwatch.rc.other_repo.1"
printf '7\tbbbb0000\tthreads-open\t1 unresolved\n' > "$STUB_DIR/prwatch.out.other_repo.2"
printf '1' > "$STUB_DIR/prwatch.rc.other_repo.2"
printf 'pr-watch: 1 PR could not be read\n' > "$STUB_DIR/prwatch.err.other_repo"
err="$TMP_ROOT/e1k"
out="$(run_watch -- --repo owner/repo --repo other/repo 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "0" "a second repo's attention exits 0" "$err"
assert_eq "$(head -1 <<<"$out")" "EVENT pr-watch rc=1" \
  "attention on a second --repo is the event" "$err"
assert_contains "$out" "$(printf 'other/repo\t7\tbbbb0000\tthreads-open')" \
  "the second repo's line carries its repo" "$err"
assert_contains "$out" "$(printf 'owner/repo\t12\taaaa0000\tthreads-open')" \
  "every repo's latest lines reach the event's context" "$err"
assert_contains "$out" "$(printf 'other/repo\tpr-watch: 1 PR could not be read')" \
  "the reducer's stderr carries its repo too" "$err"
assert_contains "$(cat "$STUB_DIR/prwatch.repos")" "other/repo" \
  "the reducer is run for the second repo" "$err"
assert_eq "$(ls -1 "$STATE_DIR" 2>/dev/null | wc -l | tr -d '[:space:]')" "2" \
  "each repo keeps its own baseline file" "$err"
assert_eq "$(cat "$STATE_DIR/other_repo__none")" "$(printf '7\tthreads-open')" \
  "the second repo's baseline holds its own keys" "$err"

# 1l. one repo's global failure names that repo, and a repeated --repo is a
# usage error rather than a double reduction over one state file
new_case prwatch_multi_repo_failure
printf '2' > "$STUB_DIR/prwatch.rc.other_repo"
printf 'pr-watch: GH_REPO is not set\n' > "$STUB_DIR/prwatch.err.other_repo"
err="$TMP_ROOT/e1l1"
out="$(run_watch -- --repo owner/repo --repo other/repo 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "2" "a global pr-watch failure on any repo exits 2" "$err"
assert_eq "$out" "" "a global failure on any repo prints no EVENT" "$err"
assert_contains "$(cat "$err")" "pr-watch failed for other/repo (rc=2)" \
  "the global failure names the repo it came from" "$err"

new_case prwatch_repo_twice
err="$TMP_ROOT/e1l2"
out="$(run_watch -- --repo owner/repo --repo Owner/Repo 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "2" "the same repository twice, differing only in case, exits 2" "$err"
assert_eq "$out" "" "a repeated --repo prints no EVENT" "$err"
assert_contains "$(cat "$err")" "--repo 'Owner/Repo' given twice" \
  "the usage error names the argument as the caller spelled it" "$err"

# one canonical spelling: the dedupe, the state file, and GH_REPO agree
new_case prwatch_repo_case_canonical
printf '12\taaaa0000\tthreads-open\t2 unresolved\n' > "$STUB_DIR/prwatch.out"
printf '1' > "$STUB_DIR/prwatch.rc"
err="$TMP_ROOT/e1l3"
out="$(run_watch -- --repo Owner/Repo 2>"$err")" && rc=0 || rc=$?
assert_eq "$(cat "$STUB_DIR/prwatch.repo")" "owner/repo" \
  "the repo reaches pr-watch in one canonical spelling" "$err"
assert_eq "$([[ -f "$STATE_DIR/owner_repo__none" ]] && echo yes || echo no)" "yes" \
  "and its baseline is keyed on that same spelling" "$err"

# 1m. the pass advances no baseline until every repo has been reduced: a later
# repo's global failure must not consume an earlier repo's undelivered event
new_case prwatch_multi_repo_transactional
printf '0' > "$STUB_DIR/prwatch.rc.owner_repo"
printf '0' > "$STUB_DIR/prwatch.rc.other_repo"
err="$TMP_ROOT/e1m1"
out="$(run_watch -- --repo owner/repo --repo other/repo 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT heartbeat loops=2 interval=0s since=none" \
  "run 1: a clear fleet reaches the heartbeat" "$err"

# run 2: owner/repo raises a line, then other/repo fails globally
printf '12\taaaa0000\tthreads-open\t2 unresolved\n' > "$STUB_DIR/prwatch.out.owner_repo"
printf '1' > "$STUB_DIR/prwatch.rc.owner_repo"
printf '2' > "$STUB_DIR/prwatch.rc.other_repo"
printf 'pr-watch: HTTP 502: bad gateway\n' > "$STUB_DIR/prwatch.err.other_repo"
err="$TMP_ROOT/e1m2"
out="$(run_watch -- --repo owner/repo --repo other/repo 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "2" "run 2: a global failure on a later repo exits 2" "$err"
assert_eq "$out" "" "run 2 prints no EVENT" "$err"
assert_eq "$([[ -f "$STATE_DIR/owner_repo__none" ]] && echo yes || echo no)" "yes" \
  "the earlier repo's baseline file is still there after the pass dies" "$err"
assert_eq "$(cat "$STATE_DIR/owner_repo__none"; echo x)" "x" \
  "a pass that dies leaves the earlier repo's baseline where the last complete pass left it" "$err"

# run 3: other/repo recovers and owner/repo's line is still a rising edge
rm -f "$STUB_DIR/prwatch.err.other_repo"
printf '0' > "$STUB_DIR/prwatch.rc.other_repo"
err="$TMP_ROOT/e1m3"
out="$(run_watch -- --repo owner/repo --repo other/repo 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT pr-watch rc=1" \
  "the event the failing pass could not print is still an event" "$err"
assert_contains "$out" "$(printf 'owner/repo\t12\taaaa0000\tthreads-open')" \
  "and it carries the line that was never delivered" "$err"

# run 4: a state file that cannot be written is judged AFTER the event it would
# have consumed is printed. Root writes anywhere, so the run is skipped there.
if [[ "$(id -u)" -eq 0 ]]; then
  printf '  skip  event printed before the baselines are flushed (running as root)\n'
else
  rm -f "$STATE_DIR/other_repo__none"
  mkdir -p "$STATE_DIR/other_repo__none"
  chmod 500 "$STATE_DIR/other_repo__none"
  printf '12\taaaa0000\tthreads-open\t2 unresolved\n34\tcccc0000\tthreads-open\t1 unresolved\n' > "$STUB_DIR/prwatch.out.owner_repo"
  err="$TMP_ROOT/e1m4"
  out="$(run_watch -- --repo owner/repo --repo other/repo 2>"$err")" && rc=0 || rc=$?
  chmod 700 "$STATE_DIR/other_repo__none"
  assert_eq "$rc" "2" "run 4: a state file that cannot be written exits 2" "$err"
  assert_eq "$(head -1 <<<"$out")" "EVENT pr-watch rc=1" \
    "the event is delivered before any baseline is written" "$err"
  assert_contains "$out" "$(printf 'owner/repo\t34\tcccc0000\tthreads-open')" \
    "and it carries the line that raised it" "$err"
  assert_contains "$(cat "$err")" "could not write the pr-watch state file" \
    "the write failure is still reported"
  assert_eq "$(cat "$STATE_DIR/owner_repo__none")" "$(printf '12\tthreads-open')" \
    "the baseline of the repo that raised the event does not advance over it" "$err"
  assert_eq "$(ls -1 "$STATE_DIR" | grep -c '\.tmp$' || true)" "0" \
    "a staging failure discards the temp an earlier repo already staged" "$err"

  # run 5: everything healthy again — the event run 4 raised is still an event
  chmod 700 "$STATE_DIR/other_repo__none"
  rmdir "$STATE_DIR/other_repo__none"
  err="$TMP_ROOT/e1m5"
  out="$(run_watch -- --repo owner/repo --repo other/repo 2>"$err")" && rc=0 || rc=$?
  assert_eq "$(head -1 <<<"$out")" "EVENT pr-watch rc=1" \
    "the run after a failed state write reports that event again" "$err"
  assert_contains "$out" "$(printf 'owner/repo\t34\tcccc0000\tthreads-open')" \
    "and carries the line whose baseline never advanced" "$err"
fi

# 1n. each repo's rising edge is measured against its OWN baseline: a standing
# line on one repo is not news again because a clear repo shares the pass
new_case prwatch_per_repo_baseline
printf '0' > "$STUB_DIR/prwatch.rc.owner_repo"
printf '7\tbbbb0000\tthreads-open\t1 unresolved\n' > "$STUB_DIR/prwatch.out.other_repo"
printf '1' > "$STUB_DIR/prwatch.rc.other_repo"
err="$TMP_ROOT/e1n"
out="$(run_watch -- --repo owner/repo --repo other/repo 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT heartbeat loops=2 interval=0s since=none" \
  "a standing line beside a clear repo is not re-reported" "$err"
assert_not_contains "$out" "EVENT pr-watch" "no repo reads another repo's baseline" "$err"

# 1o. the context header carries the highest status across the repos, whichever
# repo returned it
new_case prwatch_rc_fold
printf '12\taaaa0000\tthreads-open\t2 unresolved\n' > "$STUB_DIR/prwatch.out.owner_repo"
printf '1' > "$STUB_DIR/prwatch.rc.owner_repo"
printf '0' > "$STUB_DIR/prwatch.rc.other_repo"
err="$TMP_ROOT/e1o"
out="$(run_watch -- --repo owner/repo --repo other/repo 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT heartbeat loops=2 interval=0s since=none" \
  "attention on the first repo alone is that repo's baseline" "$err"
assert_contains "$out" "pr-watch rc=1" \
  "a clear repo reduced last does not erase the fleet's status" "$err"
assert_contains "$out" "$(printf 'owner/repo\t12\taaaa0000\tthreads-open')" \
  "and the attention line still reaches the context" "$err"

# 1p. every repo is reduced even once an earlier one has news
new_case prwatch_every_repo_reduced
printf '0' > "$STUB_DIR/prwatch.rc.owner_repo.1"
printf '12\taaaa0000\tthreads-open\t2 unresolved\n' > "$STUB_DIR/prwatch.out.owner_repo.2"
printf '1' > "$STUB_DIR/prwatch.rc.owner_repo.2"
printf '7\tbbbb0000\tthreads-open\t1 unresolved\n' > "$STUB_DIR/prwatch.out.other_repo"
printf '1' > "$STUB_DIR/prwatch.rc.other_repo"
err="$TMP_ROOT/e1p"
out="$(run_watch -- --repo owner/repo --repo other/repo 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT pr-watch rc=1" "the first repo's new line is the event" "$err"
assert_contains "$out" "$(printf 'other/repo\t7\tbbbb0000\tthreads-open')" \
  "a repo reduced after the one with news still reaches the context" "$err"
assert_eq "$(cat "$STATE_DIR/other_repo__none")" "$(printf '7\tthreads-open')" \
  "and the same pass writes its baseline" "$err"

# 1q. a fleet that names a NEW repo on a later run baselines that repo's
# standing attention rather than letting it preempt the lane checks
new_case prwatch_new_repo_baseline
printf '12\taaaa0000\tthreads-open\t2 unresolved\n' > "$STUB_DIR/prwatch.out.owner_repo"
printf '1' > "$STUB_DIR/prwatch.rc.owner_repo"
err="$TMP_ROOT/e1q1"
out="$(run_watch -- --repo owner/repo 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT heartbeat loops=2 interval=0s since=none" \
  "run 1: one repo, its attention at start is that repo's baseline" "$err"

printf '7\tbbbb0000\tthreads-open\t1 unresolved\n' > "$STUB_DIR/prwatch.out.other_repo"
printf '1' > "$STUB_DIR/prwatch.rc.other_repo"
err="$TMP_ROOT/e1q2"
out="$(run_watch -- --repo owner/repo --repo other/repo 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT heartbeat loops=2 interval=0s since=none" \
  "a repo named for the first time baselines its standing attention" "$err"
assert_not_contains "$out" "EVENT pr-watch" "the newly named repo never preempts the lane checks" "$err"
assert_eq "$(grep -c 'attention present at start' "$err")" "1" "exactly one baseline note on that run"
assert_contains "$(cat "$err")" "attention present at start for other/repo" \
  "and the note names the repo that has no baseline yet"
assert_eq "$(ls -1 "$STATE_DIR" 2>/dev/null | wc -l | tr -d '[:space:]')" "2" \
  "the newly named repo gets its own baseline file" "$err"

# 1r. the mirror ordering: a baselined repo's genuinely new line is still an
# event when a repo with no baseline is named ahead of it
new_case prwatch_new_repo_first
printf '12\taaaa0000\tthreads-open\t2 unresolved\n' > "$STUB_DIR/prwatch.out.owner_repo"
printf '1' > "$STUB_DIR/prwatch.rc.owner_repo"
err="$TMP_ROOT/e1r1"
out="$(run_watch -- --repo owner/repo 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT heartbeat loops=2 interval=0s since=none" \
  "run 1: the one repo baselines its standing line" "$err"

printf '7\tbbbb0000\tthreads-open\t1 unresolved\n' > "$STUB_DIR/prwatch.out.other_repo"
printf '1' > "$STUB_DIR/prwatch.rc.other_repo"
printf '12\taaaa0000\tthreads-open\t2 unresolved\n34\tcccc0000\tthreads-open\t1 unresolved\n' > "$STUB_DIR/prwatch.out.owner_repo"
err="$TMP_ROOT/e1r2"
out="$(run_watch -- --repo other/repo --repo owner/repo 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT pr-watch rc=1" \
  "a baselined repo's new line is an event behind a repo named for the first time" "$err"
assert_contains "$out" "$(printf 'owner/repo\t34\tcccc0000\tthreads-open')" \
  "and the event carries that line" "$err"

# 1s. --repo=VALUE is the same option: two of them are a two-repo fleet, and an
# empty value is the parser's usage error
new_case prwatch_repo_equals
printf '12\taaaa0000\tthreads-open\t2 unresolved\n' > "$STUB_DIR/prwatch.out.owner_repo"
printf '1' > "$STUB_DIR/prwatch.rc.owner_repo"
printf '0' > "$STUB_DIR/prwatch.rc.other_repo.1"
printf '7\tbbbb0000\tthreads-open\t1 unresolved\n' > "$STUB_DIR/prwatch.out.other_repo.2"
printf '1' > "$STUB_DIR/prwatch.rc.other_repo.2"
err="$TMP_ROOT/e1s1"
out="$(run_watch -- --repo=owner/repo --repo=other/repo 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT pr-watch rc=1" \
  "the = spelling builds the same two-repo fleet" "$err"
assert_contains "$out" "$(printf 'other/repo\t7\tbbbb0000\tthreads-open')" \
  "and reduces the second repo the same way" "$err"

new_case prwatch_repo_equals_empty
err="$TMP_ROOT/e1s2"
out="$(run_watch -- --repo= 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "2" "an empty --repo= exits 2" "$err"
assert_eq "$out" "" "an empty --repo= prints no EVENT" "$err"
assert_contains "$(cat "$err")" "--repo requires a value" "the parser names the option missing its value"

# 1t. a fleet of more than one repo is told what the checks below the reducer
# do NOT cover — and the note names only the checks this run actually performs
new_case prwatch_coverage_note
err="$TMP_ROOT/e1t1"
out="$(run_watch -- --repo owner/repo --repo other/repo --item issue-5 2>"$err")" && rc=0 || rc=$?
assert_contains "$(cat "$err")" \
  "the reducer covers owner/repo other/repo; the merged check and the heartbeat's open-PR list read owner/repo only" \
  "a multi-repo fleet is told which repo the merged check reads"
err="$TMP_ROOT/e1t2"
out="$(run_watch -- 2>"$err")" && rc=0 || rc=$?
assert_not_contains "$(cat "$err")" "the reducer covers" "a one-repo fleet gets no coverage note"

# no --item: the note must not explain a merged check this run skipped
err="$TMP_ROOT/e1t3"
out="$(run_watch -- --repo owner/repo --repo other/repo 2>"$err")" && rc=0 || rc=$?
assert_contains "$(cat "$err")" \
  "the reducer covers owner/repo other/repo; the heartbeat's open-PR list reads owner/repo only" \
  "the note drops the merged check when the run skipped it"
assert_not_contains "$(cat "$err")" "the merged check and" \
  "a skipped check is never claimed as covered"

# no pr-watch: the note must not claim a reducer this run skipped
err="$TMP_ROOT/e1t4"
out="$(run_watch OVERSEE_WATCH_PR_WATCH="$TMP_ROOT/bin/absent-pr-watch.sh" -- --repo owner/repo --repo other/repo --item issue-5 2>"$err")" && rc=0 || rc=$?
assert_contains "$(cat "$err")" \
  "the merged check and the heartbeat's open-PR list read owner/repo only" \
  "the note still names what the merged check reads without the reducer"
assert_not_contains "$(cat "$err")" "the reducer covers" \
  "and never claims a reducer that is not installed"

# 1u. the repository resolved from `gh repo view` — the documented default,
# reached only when no --repo is given — is canonicalized like any other: the
# merged check matches its owner, pr-watch is handed one spelling, and the
# baseline is keyed on it
new_case default_repo_canonical
printf 'VanillaGreenCom/Kendex\n' > "$STUB_DIR/repoview.txt"
cat > "$STUB_DIR/merged.json" <<'EOF'
[
  {"number": 5, "headRefName": "issue-5", "headRepositoryOwner": {"login": "VanillaGreenCom"}, "mergedAt": "2026-08-15T10:00:00Z"}
]
EOF
printf '12\taaaa0000\tthreads-open\t2 unresolved\n' > "$STUB_DIR/prwatch.out"
printf '1' > "$STUB_DIR/prwatch.rc"
err="$TMP_ROOT/e1u"
out="$(run_watch -- --no-repo --since 2026-08-15T09:00:00Z --item issue-5 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "0" "a default-resolved repository exits 0" "$err"
assert_contains "$out" "EVENT merged 5 issue-5" \
  "a repository resolved from gh repo view still fires merged" "$err"
assert_eq "$(cat "$STUB_DIR/prwatch.repo")" "vanillagreencom/kendex" \
  "and reaches pr-watch in the canonical spelling" "$err"
assert_eq "$([[ -f "$STATE_DIR/vanillagreencom_kendex__2026-08-15T09_00_00Z" ]] && echo yes || echo no)" "yes" \
  "and keys its baseline on that same spelling" "$err"

# --- 3. merged, with item, since, and case controls -------------------------
new_case merged
cat > "$STUB_DIR/merged.json" <<'EOF'
[
  {"number": 5, "headRefName": "issue-5",   "mergedAt": "2026-08-15T10:00:00Z"},
  {"number": 6, "headRefName": "issue-6",   "mergedAt": "2026-08-15T08:00:00Z"},
  {"number": 7, "headRefName": "feature-x", "mergedAt": "2026-08-15T10:30:00Z"},
  {"number": 8, "headRefName": "vst-8",     "mergedAt": "2026-08-15T09:00:00Z"},
  {"number": 9, "headRefName": "issue-9",   "mergedAt": "2026-08-15T10:45:00Z"}
]
EOF
err="$TMP_ROOT/e2"
out="$(run_watch -- --since 2026-08-15T09:00:00Z --item issue-5 --item issue-6 --item VST-8 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "0" "merged exits 0" "$err"
assert_contains "$out" "EVENT merged 5 issue-5" "an item's PR merged after --since fires" "$err"
assert_contains "$out" "EVENT merged 8 vst-8" "an item's PR merged exactly at --since fires; id matches branch case-insensitively" "$err"
assert_not_contains "$out" "EVENT merged 6" "an item's PR merged before --since does not fire" "$err"
assert_not_contains "$out" "EVENT merged 7" "a non-item branch does not fire" "$err"
assert_not_contains "$out" "EVENT merged 9" "a conventional issue-N branch that is not a live item does not fire" "$err"
assert_eq "$(grep -c '^EVENT' <<<"$out")" "2" "one EVENT line per merged PR, nothing else" "$err"

# no --since: no floor, so a merge that landed before this run still fires
err="$TMP_ROOT/e2b"
out="$(run_watch -- --item issue-5 --item issue-6 2>"$err")" && rc=0 || rc=$?
assert_contains "$out" "EVENT merged 6 issue-6" "without --since a merge from before the run fires (no moving floor)" "$err"
assert_eq "$(grep -c '^EVENT' <<<"$out")" "2" "both item PRs fire, nothing else" "$err"

# busy repo: the item's PR is older than 60 newer merges — a single listing
# window would drop it; the per-item --head query still finds it
err="$TMP_ROOT/e2c"
jq -n '[range(1; 61) | {number: (100 + .), headRefName: ("noise-" + (.|tostring)), mergedAt: "2026-08-15T12:00:00Z"}] + [{number: 5, headRefName: "issue-5", mergedAt: "2026-08-15T10:00:00Z"}]' > "$STUB_DIR/merged.json"
out="$(run_watch -- --since 2026-08-15T09:00:00Z --item issue-5 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "0" "busy-repo merged exits 0" "$err"
assert_contains "$out" "EVENT merged 5 issue-5" "an item's merge beyond a newest-60 window still fires (per-item --head query)" "$err"


# no --item: merged check skipped with a note; a merged PR is not an event
: > "$STUB_DIR/gh.calls"
err="$TMP_ROOT/e2c"
out="$(run_watch -- --since 2026-08-15T09:00:00Z 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT heartbeat loops=2 interval=0s since=2026-08-15T09:00:00Z" "no --item reaches the heartbeat" "$err"
assert_contains "$(cat "$err")" "no --item given; skipping the merged check" "no --item is noted on stderr"
assert_eq "$(grep -c 'merged' "$STUB_DIR/gh.calls" || true)" "0" "no --item never lists merged PRs"

# gh stderr noise on a successful list does not reach the JSON parse
touch "$STUB_DIR/noisy"
err="$TMP_ROOT/e2d"
out="$(run_watch -- --since 2026-08-15T09:00:00Z --item issue-5 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "0" "gh stderr noise on success still exits 0" "$err"
assert_eq "$out" "EVENT merged 5 issue-5" "gh stderr noise does not corrupt the merged list" "$err"

# a fork's PR carries the same head branch NAME, and --head matches by name
new_case merged_fork
cat > "$STUB_DIR/merged.json" <<'EOF'
[
  {"number": 42, "headRefName": "issue-5", "headRepositoryOwner": {"login": "forker"}, "mergedAt": "2026-08-15T10:00:00Z"}
]
EOF
err="$TMP_ROOT/e2e"
out="$(run_watch -- --since 2026-08-15T09:00:00Z --item issue-5 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "0" "a fork-only merged list still exits 0" "$err"
assert_eq "$(head -1 <<<"$out")" "EVENT heartbeat loops=2 interval=0s since=2026-08-15T09:00:00Z" "a fork PR on the item's branch name is not a merge" "$err"
assert_not_contains "$out" "EVENT merged" "a same-named fork branch never fires merged" "$err"

# the owner comparison is case-insensitive: GitHub logins are, and --repo's
# casing is the caller's
new_case merged_owner_case
cat > "$STUB_DIR/merged.json" <<'EOF'
[
  {"number": 5, "headRefName": "issue-5", "headRepositoryOwner": {"login": "VanillaGreenCom"}, "mergedAt": "2026-08-15T10:00:00Z"}
]
EOF
err="$TMP_ROOT/e2f"
out="$(run_watch -- --repo vanillagreencom/x --since 2026-08-15T09:00:00Z --item issue-5 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "0" "mixed-case owner exits 0" "$err"
assert_contains "$out" "EVENT merged 5 issue-5" "an owner login differing only in case still fires merged" "$err"


# --- 5. heartbeat ----------------------------------------------------------
new_case heartbeat
printf '9\tissue-9\tfix the thing\n' > "$STUB_DIR/open.txt"
err="$TMP_ROOT/e5"
out="$(run_watch -- --item issue-9 gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "0" "heartbeat exits 0" "$err"
assert_contains "$out" "EVENT heartbeat" "heartbeat after --max-loops with no event" "$err"
assert_contains "$out" "issue-9" "open PR list follows the heartbeat" "$err"
assert_eq "$(grep -c 'merged' "$STUB_DIR/gh.calls")" "2" "merged check ran once per loop (2 loops)" "$err"

# --- 6. auth and listing failures ------------------------------------------
new_case auth_fail
touch "$STUB_DIR/auth-fail"
err="$TMP_ROOT/e6a"
out="$(run_watch -- 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "2" "gh auth failure exits 2" "$err"
assert_contains "$(cat "$err")" "no working GitHub auth path" "auth failure is named on stderr"
assert_eq "$out" "" "auth failure prints no EVENT" "$err"

# a stale env token with no keyring falls through to the project GH_BOT_TOKEN
new_case auth_bot_fallback
touch "$STUB_DIR/auth-fail"
err="$TMP_ROOT/e6b"
out="$(run_watch GH_TOKEN=ghp_stale0000 GH_BOT_TOKEN=ghp_bot00000 -- 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "0" "stale GH_TOKEN + no keyring + valid GH_BOT_TOKEN watches" "$err"
assert_contains "$out" "EVENT heartbeat" "bot-token fallback reaches the heartbeat" "$err"

# the same stale token with no bot token still fails closed
err="$TMP_ROOT/e6c"
out="$(run_watch GH_TOKEN=ghp_stale0000 -- 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "2" "stale GH_TOKEN with no other path exits 2" "$err"

new_case list_fail
touch "$STUB_DIR/list-fail"
err="$TMP_ROOT/e6d"
out="$(run_watch -- --item issue-1 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "2" "failing pr list exits 2" "$err"
assert_contains "$(cat "$err")" "gh pr list --state merged failed" "pr list failure is named on stderr"
assert_contains "$(cat "$err")" "HTTP 502" "gh stderr is surfaced with the failure"

# --- 7. lanes outside tmux -------------------------------------------------
new_case no_tmux
err="$TMP_ROOT/e7"
out="$(run_watch TMUX= -- gh-1 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "2" "lanes without \$TMUX exit 2" "$err"
assert_contains "$(cat "$err")" "not inside tmux" "missing tmux is named on stderr"

# --- 8. missing pr-watch is a note, not a failure ---------------------------
new_case no_prwatch
err="$TMP_ROOT/e8"
out="$(run_watch OVERSEE_WATCH_PR_WATCH="$TMP_ROOT/nope/pr-watch.sh" -- 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "0" "missing pr-watch still watches (heartbeat)" "$err"
assert_contains "$out" "EVENT heartbeat" "missing pr-watch reaches the heartbeat" "$err"
assert_contains "$(cat "$err")" "pr-watch.sh not found" "missing pr-watch is noted once on stderr"
assert_eq "$(grep -c 'pr-watch.sh not found' "$err")" "1" "note printed exactly once, not per loop"

# --- 9. --help -------------------------------------------------------------
err="$TMP_ROOT/e9"
out="$(run_watch -- --help 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "0" "--help exits 0" "$err"
assert_contains "$out" "EVENT lane-asking" "--help documents the event kinds" "$err"
assert_contains "$out" "reports no" \
  "--help states the probe that keeps a wrapped lane out of lane-exited" "$err"
assert_contains "$out" "pgrep -P" \
  "--help names the probe the code actually runs" "$err"
assert_contains "$out" "not an answer" \
  "--help states that an unusable probe keeps the lane watched" "$err"
assert_contains "$out" "last user turn on its screen" \
  "--help states where a limit banner has to sit to count" "$err"
assert_contains "$out" "earlier repository baselines may already have advanced" \
  "--help documents a partial multi-repo state commit" "$err"
assert_contains "$out" "Only baselines that did not advance repeat" \
  "--help does not promise every event repeats after a write failure" "$err"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
