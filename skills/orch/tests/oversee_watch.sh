#!/usr/bin/env bash
# Tests for the GitHub side of orch/scripts/oversee-watch, and for
# the failures that take the whole process down. The pane side is in the three
# lane suites: window-gone, lane-exited, lane-asking and idle-after-return in
# oversee_watch_lanes.sh, prompt state across runs in
# oversee_watch_lane_asking.sh, and usage-limit with usage-limit-passed in
# oversee_watch_usage_limit.sh. Tracker events are in oversee_watch_triage.sh. All use the
# shared lib/oversee-watch-harness.sh sandbox.
#
# oversee-watch is the overseer's single blocking watch: it loops until the
# fleet needs a hand and prints one wake carrying every event the pass found,
# one EVENT line each, and exits once. Covered here:
#   1.  pr-watch: on the fleet's first run oversee-watch: reducer-baseline is a
#       baseline (no event, one stderr note, context on the next event); that
#       baseline persists, so a line appearing between two runs is the next
#       run's first-pass event and a standing line is not; an unseen `<pr> <kind>`
#       line mid-run is the event; a head-only change is not; GH_REPO reaches
#       pr-watch and its argv is exactly --heal, for every repo; a
#       heal-dispatched line is never a key — alone, re-attributed to another
#       PR, or alone on a repo that is not the first reduced — while the
#       gate-stale beside it still fires and is the only key baselined; an
#       error key preempts a repo's opening pass while every other kind there
#       still baselines silently;
#       rc≠0 with no lines is a global failure (exit 2); attention
#       at start does not starve a lane's question, and a new line and a
#       question on one pass are both reported, the control being the
#       reducer's early exit restored; the state file is
#       rewritten after every pass, and an uncreatable state dir or an
#       unreadable state file exits 2 naming the path; the reducer runs for
#       every --repo, with per-repo baselines and repo-prefixed lines on both
#       streams, no baseline advances until the whole pass has reduced, a repo
#       named for the first time baselines its standing attention in either
#       ordering, the context header carries the highest status across repos, a
#       global failure names its repo, a repeated --repo exits 2 naming the
#       spelling given, and --repo=VALUE is the same option
#   2.  merged: an --item's PR merged at/after --since fires, naming its
#       repo; a PR merged BEFORE --since, a non-item branch, and a non-item
#       conventional branch do not; a fork's PR on the same head branch name
#       does not; item ids match branches case-insensitively; no --since
#       means no floor; no --item skips the check with a note; gh stderr
#       noise on success does not break the JSON parse; a PR merged in a
#       non-first --repo fires, the fork rejection holding per repo, red with
#       the lookup narrowed to the first repo; a merged item still in --item
#       is reported once across runs while a further PR on its branch is
#       news, red with the row never kept
#   2b. handoff: an --item whose state carries `.handoff` with no
#       `.resumed_at` fires once, with the record, read from the checkout's
#       state directory even when the item has a worktree; a state
#       without the key and a resumed record fire nothing; a re-run before
#       the relaunch stamps the record fires nothing; the must-fail control
#       is the emit arm removed
#   3.  heartbeat after --max-loops with every --repo's open PR list, each
#       line prefixed with its repo, red with the list narrowed to the first
#   4.  gh auth failure exits 2; a stale env token falls through to the
#       project GH_BOT_TOKEN; a failing pr list exits 2 (never a quiet 0)
#   5.  lanes given outside tmux exit 2
#   6.  a missing pr-watch.sh is a stderr note, not a failure; inside tmux an
#       --item with no lane window is a stderr note naming the pane checks
#       skipped, once, and outside tmux or without --item there is none
#   7.  --help exits 0
#   8.  --repeat re-reads the oversee state before every pass: every running
#       lane record is an item, its window a lane and its mail_root a hosted
#       root, a done record is none of them, a hosted lane recorded between
#       passes is read by the next pass with no restart, and the run ends on
#       the state it cannot read or parse; red with the state read once,
#       before the loop; a --hosted item no record names and a repeated
#       --repo end it before any pass, red with the parent's check removed; a window is reported gone
#       on the pass that first misses it and again after tmux lists it in
#       between, red with the absence never cleared; a pass that fails before
#       reporting leaves the absence for the next pass, red with the absence
#       recorded before the pass runs; each repeat-mode refusal exits 2 with
#       its keyed first line
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"

# shellcheck source=lib/oversee-watch-harness.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/oversee-watch-harness.sh"

echo "=== oversee-watch ==="

# --- 1. pr-watch -----------------------------------------------------------
# 1a. oversee-watch: reducer-baseline: baseline, not the event
new_case prwatch_baseline
printf '12\tabcdef01\tthreads-open\t2 unresolved\n' > "$STUB_DIR/prwatch.out"
printf '1' > "$STUB_DIR/prwatch.rc"
err="$TMP_ROOT/e1a"
out="$(run_watch -- 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "0" "attention at start exits 0" "$err"
assert_eq "$(head -1 <<<"$out")" "EVENT heartbeat loops=2 interval=0s since=none" "attention at start is not the event (heartbeat is)" "$err"
assert_contains "$out" "pr-watch rc=1" "latest pr-watch state is appended to the event" "$err"
assert_contains "$out" "threads-open" "pr-watch lines follow the context header" "$err"
assert_contains "$(cat "$err")" "oversee-watch: reducer-baseline repo=owner/repo exit=1 count=1" "baseline is noted once on stderr"
assert_eq "$(grep -c 'oversee-watch: reducer-baseline' "$err")" "1" "baseline note printed once, not per pass"
assert_eq "$(cat "$STUB_DIR/prwatch.repo")" "owner/repo" "GH_REPO is exported to pr-watch" "$err"
# --heal is what makes gate-stale self-healing instead of overseer hand-work:
# without it the writer only converges on the cron floor. Matched WHOLE, not as
# a substring: pr-watch.sh rejects an unknown flag with exit 2, so a near miss
# like --healing-only dies on every pass while a substring assertion stays
# green.
assert_eq "$(cat "$STUB_DIR/prwatch.args")" "--heal" "pr-watch is invoked with --heal" "$err"

# 1b. an unseen <pr> <kind> line mid-run is the event
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

# 1d. an unseen kind on an already-baselined PR is unseen
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
printf '12\taaaa0000\tgate-stale\tpredicate disagrees\n12\taaaa0000\terror\tE_WRITER_DISPATCH for '"'"'Review gate writer'"'"'\n' > "$STUB_DIR/prwatch.out"
printf '1' > "$STUB_DIR/prwatch.rc"
err="$TMP_ROOT/e1d6"
out="$(run_watch -- 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "0" "an error at start exits 0" "$err"
assert_eq "$(head -1 <<<"$out")" "EVENT pr-watch rc=1" "an error line at start is the event, not the baseline" "$err"
assert_contains "$out" "E_WRITER_DISPATCH" "the event carries the failed dispatch" "$err"
assert_eq "$(grep -c 'oversee-watch: reducer-baseline' "$err")" "0" "the baseline note does not stand in for the error event"

# The companion: without an error key the opening pass still baselines
# silently, so the preemption above is scoped to error and nothing else.
new_case prwatch_no_error_first_pass
printf '12\taaaa0000\tgate-stale\tpredicate disagrees\n12\taaaa0000\theal-dispatched\twriter workflow dispatched\n' > "$STUB_DIR/prwatch.out"
printf '1' > "$STUB_DIR/prwatch.rc"
err="$TMP_ROOT/e1d7"
out="$(run_watch -- 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT heartbeat loops=2 interval=0s since=none" "a first pass with no error key still baselines" "$err"
assert_eq "$(grep -c 'oversee-watch: reducer-baseline' "$err")" "1" "the ordinary first-pass note still covers the non-error keys"

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
printf 'E_REDUCER_AUTH\n' > "$STUB_DIR/prwatch.err"
err="$TMP_ROOT/e1e"
out="$(run_watch -- 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "2" "pr-watch rc=2 with no lines exits 2" "$err"
assert_eq "$out" "" "pr-watch global failure prints no EVENT" "$err"
assert_contains "$(cat "$err")" "oversee-watch: reducer-failed repo=owner/repo exit=2" "global failure is named on stderr"
assert_contains "$(cat "$err")" "E_REDUCER_AUTH" "pr-watch stderr is surfaced"

# 1f. attention at start does not starve a lane's question
new_case prwatch_no_starve
printf '12\tabcdef01\tthreads-open\t2 unresolved\n' > "$STUB_DIR/prwatch.out"
printf '1' > "$STUB_DIR/prwatch.rc"
printf 'Do you want to proceed?\n   ❯ 1. Yes\n     2. No\n' > "$STUB_DIR/pane-gh-2.txt"
err="$TMP_ROOT/e1f"
out="$(run_watch -- gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT lane-asking gh-2" "a lane question is seen despite standing pr-watch attention" "$err"
assert_contains "$out" "pr-watch rc=1" "the question event still carries the pr-watch context" "$err"

# 1f'. a new reducer line and a lane's question on the SAME pass are both
# reported, as one block: the pr-watch event opens it with its reducer lines,
# the asking line follows with its dialog, the reducer lines are not
# repeated as trailing context, and the pass exits once. Before, the pass
# left on the reducer line and the question waited for a pass on which no PR
# moved.
new_case prwatch_and_asking_same_pass
printf '0' > "$STUB_DIR/prwatch.rc.1"
printf '12\tabcdef01\tthreads-open\t2 unresolved\n' > "$STUB_DIR/prwatch.out.2"
printf '1' > "$STUB_DIR/prwatch.rc.2"
printf 'Do you want to proceed?\n   ❯ 1. Yes\n     2. No\n' > "$STUB_DIR/pane-gh-2.2.txt"
err="$TMP_ROOT/e1f2"
out="$(run_watch -- gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "0" "a reducer line beside a question exits 0" "$err"
assert_eq "$(sed -n '1p;2p;3p' <<<"$out")" "$(printf 'EVENT pr-watch rc=1\nowner/repo\t12\tabcdef01\tthreads-open\t2 unresolved\nEVENT lane-asking gh-2')" \
  "the block opens with the reducer event and its line, the asking line next" "$err"
assert_contains "$out" "❯ 1. Yes" "the asking line carries its dialog" "$err"
assert_eq "$(grep -c 'threads-open' <<<"$out")" "1" "the reducer line is printed once, never again as trailing context" "$err"
assert_not_contains "$out" "EVENT heartbeat" "the pass with events exits before any heartbeat" "$err"

# The must-fail control: the reducer arm's early exit restored. The mutant
# leaves the pass on the new reducer line, so the same fleet reads as pr-watch
# alone; the copy must differ from the source or the control proves nothing.
# The copy keeps orch's place in a skills tree: its libraries resolve the
# github skill beside it.
REDUCER_MUTANT_DIR="$TMP_ROOT/reducer-mutant"
mkdir -p "$REDUCER_MUTANT_DIR/orch"
cp -R "$REPO_ROOT/skills/orch/scripts" "$REDUCER_MUTANT_DIR/orch/scripts"
ln -s "$REPO_ROOT/skills/github" "$REDUCER_MUTANT_DIR/github"
sed 's/^  PASS_EVENT=1$/  exit 0/' "$REPO_ROOT/skills/orch/scripts/lib/pr-watch-pass.sh" > "$REDUCER_MUTANT_DIR/orch/scripts/lib/pr-watch-pass.sh"
assert_eq "$(cmp -s "$REDUCER_MUTANT_DIR/orch/scripts/lib/pr-watch-pass.sh" "$REPO_ROOT/skills/orch/scripts/lib/pr-watch-pass.sh" && echo same || echo differs)" "differs" \
  "control: the mutant really restores the reducer arm's early exit"
new_case prwatch_and_asking_same_pass_mutant
printf '0' > "$STUB_DIR/prwatch.rc.1"
printf '12\tabcdef01\tthreads-open\t2 unresolved\n' > "$STUB_DIR/prwatch.out.2"
printf '1' > "$STUB_DIR/prwatch.rc.2"
printf 'Do you want to proceed?\n   ❯ 1. Yes\n     2. No\n' > "$STUB_DIR/pane-gh-2.2.txt"
err="$TMP_ROOT/e1f3"
out="$(WATCH_BIN="$REDUCER_MUTANT_DIR/orch/scripts/oversee-watch" run_watch -- gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT pr-watch rc=1" "control: the mutant still reports the reducer line" "$err"
assert_not_contains "$out" "EVENT lane-asking" "control: with the early exit restored the question goes unreported" "$err"

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
assert_not_contains "$(cat "$err")" "oversee-watch: reducer-baseline" \
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
  assert_contains "$(cat "$err")" "oversee-watch: state-read-failed path=$state_file" \
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
  assert_contains "$(cat "$err")" "oversee-watch: state-target-invalid" \
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
printf 'E_REDUCER_READ count=1\n' > "$STUB_DIR/prwatch.err.other_repo"
err="$TMP_ROOT/e1k"
out="$(run_watch -- --repo owner/repo --repo other/repo 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "0" "a second repo's attention exits 0" "$err"
assert_eq "$(head -1 <<<"$out")" "EVENT pr-watch rc=1" \
  "attention on a second --repo is the event" "$err"
assert_contains "$out" "$(printf 'other/repo\t7\tbbbb0000\tthreads-open')" \
  "the second repo's line carries its repo" "$err"
assert_contains "$out" "$(printf 'owner/repo\t12\taaaa0000\tthreads-open')" \
  "every repo's latest lines reach the event's context" "$err"
assert_contains "$out" "$(printf 'other/repo\tE_REDUCER_READ count=1')" \
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
printf 'E_REDUCER_AUTH\n' > "$STUB_DIR/prwatch.err.other_repo"
err="$TMP_ROOT/e1l1"
out="$(run_watch -- --repo owner/repo --repo other/repo 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "2" "a global pr-watch failure on any repo exits 2" "$err"
assert_eq "$out" "" "a global failure on any repo prints no EVENT" "$err"
assert_contains "$(cat "$err")" "oversee-watch: reducer-failed repo=other/repo exit=2" \
  "the global failure names the repo it came from" "$err"

new_case prwatch_repo_twice
err="$TMP_ROOT/e1l2"
out="$(run_watch -- --repo owner/repo --repo Owner/Repo 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "2" "the same repository twice, differing only in case, exits 2" "$err"
assert_eq "$out" "" "a repeated --repo prints no EVENT" "$err"
assert_contains "$(cat "$err")" "oversee-watch: repo-duplicate repo=Owner/Repo" \
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
# repo's global failure must not consume a prior repo's undelivered event
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
  assert_contains "$(cat "$err")" "oversee-watch: state-target-invalid" \
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

# 1p. every repo is reduced even once a prior one has news
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

# 1q. a fleet that names an additional repo on a later run baselines that repo's
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
assert_eq "$(grep -c 'oversee-watch: reducer-baseline' "$err")" "1" "exactly one baseline note on that run"
assert_contains "$(cat "$err")" "oversee-watch: reducer-baseline repo=other/repo exit=1 count=1" \
  "and the note names the repo that has no baseline yet"
assert_eq "$(ls -1 "$STATE_DIR" 2>/dev/null | wc -l | tr -d '[:space:]')" "2" \
  "the newly named repo gets its own baseline file" "$err"

# 1r. the mirror ordering: a baselined repo's genuinely unseen line is still an
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
assert_contains "$(cat "$err")" "oversee-watch: missing-value option=--repo" "the parser names the option missing its value"

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
assert_contains "$out" "EVENT merged 5 issue-5 vanillagreencom/kendex" \
  "a repository resolved from gh repo view still fires merged, naming the repo" "$err"
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
new_case merged_busy
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
assert_contains "$(cat "$err")" "oversee-watch: items-omitted count=0 skipped=merged,handoff" "no --item is noted on stderr"
assert_eq "$(grep -c 'merged' "$STUB_DIR/gh.calls" || true)" "0" "no --item never lists merged PRs"

# gh stderr noise on a successful list does not reach the JSON parse
new_case merged_noisy
cat > "$STUB_DIR/merged.json" <<'EOF'
[
  {"number": 5, "headRefName": "issue-5", "mergedAt": "2026-08-15T10:00:00Z"}
]
EOF
touch "$STUB_DIR/noisy"
err="$TMP_ROOT/e2d"
out="$(run_watch -- --since 2026-08-15T09:00:00Z --item issue-5 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "0" "gh stderr noise on success still exits 0" "$err"
assert_eq "$out" "EVENT merged 5 issue-5 owner/repo" "gh stderr noise does not corrupt the merged list" "$err"

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

# the merged lookup runs against EVERY --repo: a consumer-repo PR on the item's
# branch fires, naming its repo, and a fork's PR on that name in that repo is
# rejected against that repo's owner. Red when the lookup reads the first
# --repo alone: the second repo is never asked, and the pass falls through to
# the heartbeat.
new_case merged_second_repo
printf '[]\n' > "$STUB_DIR/merged.owner_repo.json"
cat > "$STUB_DIR/merged.other_repo.json" <<'EOF'
[
  {"number": 77, "headRefName": "issue-5", "headRepositoryOwner": {"login": "other"}, "mergedAt": "2026-08-15T10:00:00Z"},
  {"number": 78, "headRefName": "issue-5", "headRepositoryOwner": {"login": "forker"}, "mergedAt": "2026-08-15T10:30:00Z"}
]
EOF
err="$TMP_ROOT/e2g"
out="$(run_watch -- --repo owner/repo --repo other/repo --since 2026-08-15T09:00:00Z --item issue-5 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "0" "a merge in the second repo exits 0" "$err"
assert_eq "$(head -1 <<<"$out")" "EVENT merged 77 issue-5 other/repo" \
  "an item's PR merged in a non-first --repo is the event, naming that repo" "$err"
assert_not_contains "$out" "EVENT merged 78" "a fork's PR in the second repo is rejected against that repo's owner" "$err"
assert_eq "$(grep -c -- '--head issue-5 --state merged' "$STUB_DIR/gh.calls")" "2" \
  "the one pass asked both repos for the item's branch" "$err"

# The must-fail control: the lookup narrowed to the first --repo. The copy
# keeps orch's place in a skills tree: its libraries resolve the github skill
# beside it.
MERGED_MUTANT_DIR="$TMP_ROOT/merged-mutant"
mkdir -p "$MERGED_MUTANT_DIR/orch"
cp -R "$REPO_ROOT/skills/orch/scripts" "$MERGED_MUTANT_DIR/orch/scripts"
ln -s "$REPO_ROOT/skills/github" "$MERGED_MUTANT_DIR/github"
sed 's/^    for repo in "${REPOS\[@\]}"; do$/    for repo in "${REPOS[0]}"; do/' "$REPO_ROOT/skills/orch/scripts/oversee-watch" > "$MERGED_MUTANT_DIR/orch/scripts/oversee-watch"
assert_eq "$(cmp -s "$MERGED_MUTANT_DIR/orch/scripts/oversee-watch" "$REPO_ROOT/skills/orch/scripts/oversee-watch" && echo same || echo differs)" "differs" \
  "control: the mutant really narrows the merged lookup to the first repo"
new_case merged_second_repo_mutant
printf '[]\n' > "$STUB_DIR/merged.owner_repo.json"
cat > "$STUB_DIR/merged.other_repo.json" <<'EOF'
[
  {"number": 77, "headRefName": "issue-5", "headRepositoryOwner": {"login": "other"}, "mergedAt": "2026-08-15T10:00:00Z"}
]
EOF
err="$TMP_ROOT/e2g2"
out="$(WATCH_BIN="$MERGED_MUTANT_DIR/orch/scripts/oversee-watch" run_watch -- --repo owner/repo --repo other/repo --since 2026-08-15T09:00:00Z --item issue-5 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT heartbeat loops=2 interval=0s since=2026-08-15T09:00:00Z" \
  "control: with the lookup on the first repo alone the second repo's merge goes unreported" "$err"

# a merged item still in --item is reported once across runs: the overseer
# exits on the event and re-runs the watch, and the same PR is not news
# again; a further PR merged on the same branch is. Red when the row is never
# kept.
new_case merged_once_across_runs
cat > "$STUB_DIR/merged.json" <<'EOF'
[
  {"number": 5, "headRefName": "issue-5", "mergedAt": "2026-08-15T10:00:00Z"}
]
EOF
err="$TMP_ROOT/e2h1"
out="$(run_watch -- --since 2026-08-15T09:00:00Z --item issue-5 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT merged 5 issue-5 owner/repo" "run 1: the merge is the event" "$err"
assert_eq "$(grep -c "$(printf 'merged\tissue-5\towner/repo#5')" "$STATE_DIR/owner_repo__2026-08-15T09_00_00Z")" "1" \
  "the committed baseline keys the delivered PR by item" "$err"
err="$TMP_ROOT/e2h2"
out="$(run_watch -- --since 2026-08-15T09:00:00Z --item issue-5 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT heartbeat loops=2 interval=0s since=2026-08-15T09:00:00Z" \
  "run 2: the same merged PR, the item still in --item, is not news again" "$err"
assert_not_contains "$out" "EVENT merged" "a re-run carries no second merged line" "$err"
cat > "$STUB_DIR/merged.json" <<'EOF'
[
  {"number": 9, "headRefName": "issue-5", "mergedAt": "2026-08-15T11:00:00Z"},
  {"number": 5, "headRefName": "issue-5", "mergedAt": "2026-08-15T10:00:00Z"}
]
EOF
err="$TMP_ROOT/e2h3"
out="$(run_watch -- --since 2026-08-15T09:00:00Z --item issue-5 2>"$err")" && rc=0 || rc=$?
assert_eq "$out" "EVENT merged 9 issue-5 owner/repo" "run 3: a further PR on the branch is the event, and the first is not repeated beside it" "$err"

# The must-fail control: the row never kept, so every run reads as the first.
sed 's/^    state="$(lane_row_set merged "$state" "$item" "$keys")"$/    state="$(lane_row_clear merged "$state" "$item")"/' \
  "$REPO_ROOT/skills/orch/scripts/oversee-watch" > "$MERGED_MUTANT_DIR/orch/scripts/oversee-watch"
assert_eq "$(cmp -s "$MERGED_MUTANT_DIR/orch/scripts/oversee-watch" "$REPO_ROOT/skills/orch/scripts/oversee-watch" && echo same || echo differs)" "differs" \
  "control: the mutant really drops the merged row"
new_case merged_once_across_runs_mutant
cat > "$STUB_DIR/merged.json" <<'EOF'
[
  {"number": 5, "headRefName": "issue-5", "mergedAt": "2026-08-15T10:00:00Z"}
]
EOF
err="$TMP_ROOT/e2h4"
out="$(WATCH_BIN="$MERGED_MUTANT_DIR/orch/scripts/oversee-watch" run_watch -- --since 2026-08-15T09:00:00Z --item issue-5 2>"$err")" && rc=0 || rc=$?
err="$TMP_ROOT/e2h5"
out="$(WATCH_BIN="$MERGED_MUTANT_DIR/orch/scripts/oversee-watch" run_watch -- --since 2026-08-15T09:00:00Z --item issue-5 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT merged 5 issue-5 owner/repo" \
  "control: with the row dropped the re-run delivers the same merge again" "$err"


# --- 2b. handoff -----------------------------------------------------------
# handoff_record ITEM [RESUMED_AT] — the checkout's state carrying
# the fixed-shape record, stamped resumed when RESUMED_AT is given.
handoff_record() {
  mkdir -p "$STUB_DIR/wt-$1"
  mkdir -p "$CASE_REPO_ROOT/tmp"
  jq -nc --arg r "${2:-}" '{cycles: 0, handoff: ({written_at: "2026-09-06T05:00:00Z", merged: ["#2210"], remaining: ["merge-pr § 5"], branch: "ken-1", worktree: "/w", open_pr: 2218, traps: []} + (if $r == "" then {} else {resumed_at: $r} end))}' \
    > "$CASE_REPO_ROOT/tmp/workflow-state-$1.json"
}
HEARTBEAT="EVENT heartbeat loops=2 interval=0s since=none"

new_case handoff_absent
mkdir -p "$STUB_DIR/wt-KEN-1"
mkdir -p "$CASE_REPO_ROOT/tmp"
printf '{"cycles":0}\n' > "$CASE_REPO_ROOT/tmp/workflow-state-KEN-1.json"
err="$TMP_ROOT/e2b1"
out="$(run_watch -- --item KEN-1 2>"$err")" && rc=0 || rc=$?
assert_eq "rc=$rc first=$(head -1 <<<"$out")" "rc=0 first=$HEARTBEAT" "a state without the key fires nothing" "$err"

new_case handoff_once
handoff_record KEN-1
mkdir -p "$STUB_DIR/wt-KEN-1/tmp"
printf '{"cycles":0}\n' > "$STUB_DIR/wt-KEN-1/tmp/workflow-state-KEN-1.json"
err="$TMP_ROOT/e2b2"
out="$(run_watch -- --item KEN-1 2>"$err")" && rc=0 || rc=$?
assert_eq "rc=$rc first=$(head -1 <<<"$out")" "rc=0 first=EVENT handoff KEN-1" "a record with no resumed_at is the event" "$err"
assert_contains "$out" '"remaining":["merge-pr § 5"]' "the record follows the event line" "$err"
assert_contains "$(cat "$STUB_DIR/workflow-state.args")" "--state-dir $CASE_REPO_ROOT/tmp handoff-standing KEN-1" "the record is read from the checkout state" "$err"
assert_eq "$(grep -c "$(printf 'handoff\tKEN-1\t')" "$STATE_DIR/owner_repo__none")" "1" "the committed baseline keys the record" "$err"
# The same fleet re-run before the relaunch has stamped the record.
err="$TMP_ROOT/e2b3"
out="$(run_watch -- --item KEN-1 2>"$err")" && rc=0 || rc=$?
assert_eq "rc=$rc first=$(head -1 <<<"$out")" "rc=0 first=$HEARTBEAT" "the same record is reported once" "$err"
assert_not_contains "$out" "EVENT handoff" "a re-run carries no second handoff line" "$err"

MUTANT_DIR="$TMP_ROOT/mutant"
mkdir -p "$MUTANT_DIR/orch"
cp -R "$REPO_ROOT/skills/orch/scripts" "$MUTANT_DIR/orch/scripts"
ln -s "$REPO_ROOT/skills/github" "$MUTANT_DIR/github"
assert_eq "$(grep -Fc -- '--state-dir "$ITEM_STATE_DIR" handoff-standing "$item"' "$REPO_ROOT/skills/orch/scripts/oversee-watch")" "1" "path control finds the handoff read"
sed 's|--state-dir "$ITEM_STATE_DIR" handoff-standing "$item"|--state-dir "$STUB_DIR/wt-$item/tmp" handoff-standing "$item"|' "$REPO_ROOT/skills/orch/scripts/oversee-watch" > "$MUTANT_DIR/orch/scripts/oversee-watch-path"
chmod +x "$MUTANT_DIR/orch/scripts/oversee-watch-path"
new_case handoff_path_mutant
handoff_record KEN-1
mkdir -p "$STUB_DIR/wt-KEN-1/tmp"
printf '{"cycles":0}\n' > "$STUB_DIR/wt-KEN-1/tmp/workflow-state-KEN-1.json"
err="$TMP_ROOT/e2b2mut"
out="$(WATCH_BIN="$MUTANT_DIR/orch/scripts/oversee-watch-path" run_watch -- --item KEN-1 2>"$err")" && rc=0 || rc=$?
assert_eq "rc=$rc first=$(head -1 <<<"$out")" "rc=0 first=$HEARTBEAT" "control: a worktree state read loses the checkout handoff" "$err"

new_case handoff_no_worktree
handoff_record KEN-1
rm -rf "$STUB_DIR/wt-KEN-1"
err="$TMP_ROOT/e2b4"
out="$(run_watch -- --item KEN-1 2>"$err")" && rc=0 || rc=$?
assert_eq "rc=$rc first=$(head -1 <<<"$out")" "rc=0 first=EVENT handoff KEN-1" "an item with no worktree is read from this checkout's state" "$err"
assert_contains "$(cat "$STUB_DIR/workflow-state.args")" "--state-dir $CASE_REPO_ROOT/tmp handoff-standing KEN-1" "and the read names this checkout's state directory" "$err"

new_case handoff_resumed
handoff_record KEN-1 2026-09-06T05:10:00Z
err="$TMP_ROOT/e2b5"
out="$(run_watch -- --item KEN-1 2>"$err")" && rc=0 || rc=$?
assert_eq "rc=$rc first=$(head -1 <<<"$out")" "rc=0 first=$HEARTBEAT" "a resumed record fires nothing" "$err"

# `none` is the one verdict that means no record stands. Every other verdict,
# and every run that wrote no verdict at all, is a state this pass could not
# read; reading one as `none` would clear the row and drop the event for a lane
# that has already handed off and exited. Three answers reach it: an install
# older than the verb, a script its settings loader killed before the verb ran
# — which is why a status is no answer here — and the verb's own `unreadable`.
# Each is driven through the seam the harness hands `handoff-standing` to,
# leaving every other workflow-state call whole.
old_state_reader() { # PATH STATUS STDOUT STDERR — an orch install answering STATUS
  printf '#!/bin/sh\n[ -z "%s" ] || printf "%%s\\n" "%s"\nprintf "%%s\\n" "%s" >&2\nexit %s\n' \
    "$3" "$3" "$4" "$2" > "$1"
  chmod +x "$1"
}
for row in "1||workflow-state: unknown-command arg1=handoff-standing|an install older than the verb" \
           "2||.env.local: line 1: syntax error near unexpected token|a script its settings loader killed before the verb" \
           "0|workflow-state: handoff-standing=unreadable|jq: error: Invalid numeric literal|the verb's own unreadable verdict"; do
  status=${row%%|*}; rest=${row#*|}
  answer=${rest%%|*}; rest=${rest#*|}
  cause=${rest%%|*}; label=${rest#*|}
  new_case "handoff_unread_$status"
  # A standing record committed first, so the row this case must not lose
  # exists before the failing read: with no prior row, "not cleared" would
  # hold against a pass that cleared everything.
  handoff_record KEN-1
  err="$TMP_ROOT/e2b-unread-$status-seed"
  out="$(run_watch -- --item KEN-1 2>"$err")" && rc=0 || rc=$?
  assert_eq "rc=$rc first=$(head -1 <<<"$out")" "rc=0 first=EVENT handoff KEN-1" \
    "$label: the record is reported while the verb still answers" "$err"
  KEYED="$(grep -c "$(printf 'handoff\tKEN-1\t')" "$STATE_DIR/owner_repo__none")"
  assert_eq "$KEYED" "1" "$label: and its row is committed" "$err"

  READER="$STUB_DIR/old-workflow-state"
  old_state_reader "$READER" "$status" "$answer" "$cause"
  err="$TMP_ROOT/e2b-unread-$status"
  out="$(run_watch REAL_WORKFLOW_STATE="$READER" -- --item KEN-1 2>"$err")" && rc=0 || rc=$?
  assert_eq "rc=$rc stderr=$(grep -c "oversee-watch: handoff-read-failed item=KEN-1" "$err") cause=$(grep -cxF -- "$cause" "$err")" \
    "rc=2 stderr=1 cause=1" \
    "$label: the pass refuses and names the item, with the reader's words under it" "$err"
  assert_not_contains "$out" "EVENT handoff" "$label: and reports no handoff it could not read" "$err"
  assert_eq "$(grep -c "$(printf 'handoff\tKEN-1\t')" "$STATE_DIR/owner_repo__none")" "1" \
    "$label: the standing row survives, so the next readable pass still owes the event" "$err"
done

# The must-fail control: the clause widened to take a status in place of the
# verdict, so an install older than the verb reads as "no record stands". The
# row is then cleared and the lane that handed off is never reported.
assert_eq "$(grep -Fc 'if [[ "$rc" -eq 0 && "$answer" == "$verdict=none" ]]; then' "$REPO_ROOT/skills/orch/scripts/oversee-watch")" "1" \
  "control finds the one clause that owns the no-record test"
sed 's/if \[\[ "\$rc" -eq 0 && "\$answer" == "\$verdict=none" \]\]; then/if [[ "$rc" -ne 0 || "$answer" == "$verdict=none" ]]; then/' \
  "$REPO_ROOT/skills/orch/scripts/oversee-watch" > "$MUTANT_DIR/orch/scripts/oversee-watch-rc1"
chmod +x "$MUTANT_DIR/orch/scripts/oversee-watch-rc1"
assert_eq "$(cmp -s "$MUTANT_DIR/orch/scripts/oversee-watch-rc1" "$REPO_ROOT/skills/orch/scripts/oversee-watch" && echo same || echo differs)" \
  "differs" "control: the widened-clause mutant really differs from the script"
new_case handoff_unread_mutant
handoff_record KEN-1
err="$TMP_ROOT/e2b-mut-seed"
out="$(WATCH_BIN="$MUTANT_DIR/orch/scripts/oversee-watch-rc1" run_watch -- --item KEN-1 2>"$err")" && rc=0 || rc=$?
assert_eq "rc=$rc first=$(head -1 <<<"$out")" "rc=0 first=EVENT handoff KEN-1" \
  "control: the mutant reports a standing record as usual" "$err"
READER="$STUB_DIR/old-workflow-state"
old_state_reader "$READER" 1 "" "workflow-state: unknown-command arg1=handoff-standing"
err="$TMP_ROOT/e2b-mut"
out="$(WATCH_BIN="$MUTANT_DIR/orch/scripts/oversee-watch-rc1" run_watch REAL_WORKFLOW_STATE="$READER" -- --item KEN-1 2>"$err")" && rc=0 || rc=$?
assert_eq "rc=$rc first=$(head -1 <<<"$out")" "rc=0 first=$HEARTBEAT" \
  "control: widened back, an old install reads as no record and the pass passes" "$err"
assert_eq "$(grep -c "$(printf 'handoff\tKEN-1\t')" "$STATE_DIR/owner_repo__none")" "0" \
  "control: and the row of a lane that had handed off is cleared" "$err"

# The must-fail control: the emit arm removed. The mutant keeps every read
# and row and never reaches the event, so the once case above reads as a
# heartbeat against it; the copy must differ from the source or the control
# proves nothing.
# The copy keeps orch's place in a skills tree: its libraries resolve the
# github skill beside it.
sed 's/^    \[\[ "\$key" != "\$prior" \]\] || continue$/    continue/' "$REPO_ROOT/skills/orch/scripts/oversee-watch" > "$MUTANT_DIR/orch/scripts/oversee-watch"
assert_eq "$(cmp -s "$MUTANT_DIR/orch/scripts/oversee-watch" "$REPO_ROOT/skills/orch/scripts/oversee-watch" && echo same || echo differs)" "differs" "control: the mutant really removes the emit arm"
new_case handoff_mutant
handoff_record KEN-1
err="$TMP_ROOT/e2b6"
out="$(WATCH_BIN="$MUTANT_DIR/orch/scripts/oversee-watch" run_watch -- --item KEN-1 2>"$err")" && rc=0 || rc=$?
assert_eq "rc=$rc first=$(head -1 <<<"$out")" "rc=0 first=$HEARTBEAT" "control: without the emit arm the same record is never reported" "$err"

# --- 5. heartbeat ----------------------------------------------------------
new_case heartbeat
printf '9\tissue-9\tfix the thing\n' > "$STUB_DIR/open.txt"
err="$TMP_ROOT/e5"
out="$(run_watch -- --item issue-9 gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "0" "heartbeat exits 0" "$err"
assert_contains "$out" "EVENT heartbeat" "heartbeat after --max-loops with no event" "$err"
assert_contains "$out" "$(printf 'owner/repo\t9\tissue-9\tfix the thing')" "open PR list follows the heartbeat, each line prefixed with its repo" "$err"
assert_eq "$(grep -c 'merged' "$STUB_DIR/gh.calls")" "2" "merged check ran once per loop (2 loops)" "$err"

# every --repo's open PRs follow the heartbeat; red with the list narrowed to
# the first repo
new_case heartbeat_multi_repo
printf '9\tissue-9\tfix the thing\n' > "$STUB_DIR/open.owner_repo.txt"
printf '77\tissue-9\tconsumer side\n' > "$STUB_DIR/open.other_repo.txt"
err="$TMP_ROOT/e5b"
out="$(run_watch -- --repo owner/repo --repo other/repo 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT heartbeat loops=2 interval=0s since=none" "a two-repo fleet reaches the heartbeat" "$err"
assert_contains "$out" "$(printf 'other/repo\t77\tissue-9\tconsumer side')" "the second repo's open PRs follow the heartbeat too" "$err"
assert_contains "$out" "$(printf 'owner/repo\t9\tissue-9\tfix the thing')" "beside the first repo's" "$err"
sed 's/^  for repo in "${REPOS\[@\]}"; do$/  for repo in "${REPOS[0]}"; do/' "$REPO_ROOT/skills/orch/scripts/oversee-watch" > "$MERGED_MUTANT_DIR/orch/scripts/oversee-watch"
assert_eq "$(cmp -s "$MERGED_MUTANT_DIR/orch/scripts/oversee-watch" "$REPO_ROOT/skills/orch/scripts/oversee-watch" && echo same || echo differs)" "differs" \
  "control: the mutant really narrows the heartbeat's open-PR list to the first repo"
new_case heartbeat_multi_repo_mutant
printf '9\tissue-9\tfix the thing\n' > "$STUB_DIR/open.owner_repo.txt"
printf '77\tissue-9\tconsumer side\n' > "$STUB_DIR/open.other_repo.txt"
err="$TMP_ROOT/e5c"
out="$(WATCH_BIN="$MERGED_MUTANT_DIR/orch/scripts/oversee-watch" run_watch -- --repo owner/repo --repo other/repo 2>"$err")" && rc=0 || rc=$?
assert_not_contains "$out" "consumer side" "control: with the list on the first repo alone the second repo's PRs are missing" "$err"

# --- 6. auth and listing failures ------------------------------------------
new_case auth_fail
touch "$STUB_DIR/auth-fail"
err="$TMP_ROOT/e6a"
out="$(run_watch -- 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "2" "gh auth failure exits 2" "$err"
assert_contains "$(cat "$err")" "oversee-watch: auth-failed service=github" "auth failure is named on stderr"
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
assert_contains "$(cat "$err")" "oversee-watch: pr-list-failed repo=owner/repo state=merged" "pr list failure is named on stderr"
assert_contains "$(cat "$err")" "HTTP 502" "gh stderr is surfaced with the failure"

# --- 7. lanes outside tmux -------------------------------------------------
new_case no_tmux
err="$TMP_ROOT/e7"
out="$(run_watch TMUX= -- gh-1 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "2" "lanes without \$TMUX exit 2" "$err"
assert_contains "$(cat "$err")" "oversee-watch: tmux-missing lanes=gh-1" "missing tmux is named on stderr"

# --- 8. missing pr-watch is a note, not a failure ---------------------------
new_case no_prwatch
err="$TMP_ROOT/e8"
out="$(run_watch OVERSEE_WATCH_PR_WATCH="$TMP_ROOT/nope/pr-watch.sh" -- 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "0" "missing pr-watch still watches (heartbeat)" "$err"
assert_contains "$out" "EVENT heartbeat" "missing pr-watch reaches the heartbeat" "$err"
assert_contains "$(cat "$err")" "oversee-watch: reducer-missing" "missing pr-watch is noted once on stderr"
assert_eq "$(grep -c 'oversee-watch: reducer-missing' "$err")" "1" "note printed exactly once, not per loop"

# --- 8b. inside tmux, --item with no lane window is a note naming the pane
# checks skipped, once; outside tmux, or with no --item, or with a window,
# nothing is noted
NOTE_NO_LANE="oversee-watch: lanes-omitted count=0"
new_case no_lane_window_note
err="$TMP_ROOT/e8b1"
out="$(run_watch -- --item issue-5 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "0" "an --item with no lane window still watches" "$err"
assert_eq "$(grep -c "$NOTE_NO_LANE" "$err")" "1" "inside tmux the skipped pane checks are named once on stderr"
assert_contains "$(cat "$err")" "active=pr-watch,merged,triage,handoff" "and the note says what still runs"
err="$TMP_ROOT/e8b2"
out="$(run_watch TMUX= -- --item issue-5 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "0" "outside tmux an --item with no lane window still watches" "$err"
assert_not_contains "$(cat "$err")" "oversee-watch: lanes-omitted" "outside tmux nothing is noted"
err="$TMP_ROOT/e8b3"
out="$(run_watch -- 2>"$err")" && rc=0 || rc=$?
assert_not_contains "$(cat "$err")" "oversee-watch: lanes-omitted" "with no --item the note does not fire"
err="$TMP_ROOT/e8b4"
out="$(run_watch -- --item issue-5 gh-1 2>"$err")" && rc=0 || rc=$?
assert_not_contains "$(cat "$err")" "oversee-watch: lanes-omitted" "with a lane window the note does not fire"
# The must-fail control: the note deleted.
sed '/ow_message lanes-omitted /d' "$REPO_ROOT/skills/orch/scripts/oversee-watch" > "$MERGED_MUTANT_DIR/orch/scripts/oversee-watch"
assert_eq "$(cmp -s "$MERGED_MUTANT_DIR/orch/scripts/oversee-watch" "$REPO_ROOT/skills/orch/scripts/oversee-watch" && echo same || echo differs)" "differs" \
  "control: the mutant really deletes the note"
new_case no_lane_window_note_mutant
err="$TMP_ROOT/e8b5"
out="$(WATCH_BIN="$MERGED_MUTANT_DIR/orch/scripts/oversee-watch" run_watch -- --item issue-5 2>"$err")" && rc=0 || rc=$?
assert_not_contains "$(cat "$err")" "oversee-watch: lanes-omitted" "control: without the note an --item with no window skips the pane checks in silence"

# --- 8c. repeat mode re-reads the oversee state before every pass ----------
# The fleet is the state's `lanes[]` records with status running: each is an
# --item, its window a lane window, and its mail_root a --hosted entry when its
# host is set. The handoff read runs once per item per pass under --max-loops
# 1, so its wrapper counts passes and rewrites the state between them; a run
# ends on the state it cannot read.
lane_record() { # ITEM WINDOW HOST MAIL_ROOT STATUS
  jq -cn --arg item "$1" --arg window "$2" --arg host "$3" --arg root "$4" --arg status "$5" \
    '{item: $item, window: $window, host: $host, mail_root: $root, account: null, surface: "tmux", model: null, session_id: null, launched_at: "2026-08-15T10:00:00Z", status: $status} | map_values(if . == "" then null else . end)'
}
write_state() { # PATH RECORD...
  local path="$1"
  shift
  printf '%s\n' "$@" | jq -s '{issue_id: "oversee", triaged: [], lanes: .}' > "$path"
}
FIXTURE_HOST="$REPO_ROOT/skills/orch/tests/fixtures/lane-host"
REMOTE_ROOT=/srv/lane/ken-10
# The hosted lane's disk: a worktree whose .git names its clone, and one ask
# in its mailbox. The root exists nowhere on this disk, so a pass that read
# the lane locally would find no mailbox and say nothing.
remote_disk() { # DIR
  mkdir -p "$1$REMOTE_ROOT/tmp/lane-mail/KEN-10"
  printf 'gitdir: /srv/clone/.git/worktrees/ken-10\n' > "$1$REMOTE_ROOT/.git"
  printf '{"id":"remote-1","kind":"ask","at":"t","text":"Hosted question"}\n' > "$1$REMOTE_ROOT/tmp/lane-mail/KEN-10/to-overseer.jsonl"
}
# The handoff read's wrapper: at the pass count NAMED, run one shell line
# against the case's state, then answer as the stub does. The state goes
# through `unlink`, so a second removal is an error rather than a silent
# no-op.
swap_state() { # LINE...  — one `COUNT) COMMAND ;;` case arm per argument
  {
    printf '#!/usr/bin/env bash\ncase "$(grep -c '"'"' handoff-standing '"'"' "$STUB_DIR/workflow-state.args" 2>/dev/null)" in\n'
    printf '  %s\n' "$@"
    printf 'esac\nexec "$STUB_DIR/../../bin/workflow-state-stub.sh" "$@"\n'
  } > "$STUB_DIR/swap-state.sh"
  chmod +x "$STUB_DIR/swap-state.sh"
}
# A sleep stub for the repeat loop's own sleep, which runs LINE. The pass and
# its helpers sleep too, on lock polls, so a call the repeat loop did not name
# as its delay (OVERSEE_WATCH_SLEEP=repeat) does nothing.
repeat_sleep_stub() { # LINE...
  mkdir -p "$STUB_DIR/bin"
  {
    printf '#!/usr/bin/env bash\n[[ "${OVERSEE_WATCH_SLEEP:-}" == repeat ]] || exit 0\n'
    printf '%s\n' "$@"
  } > "$STUB_DIR/bin/sleep"
  chmod +x "$STUB_DIR/bin/sleep"
}
# A fleet of one local lane, one hosted lane and one closed lane. The wrapper
# takes the state away once pass 2 has started, so pass 2 runs whole and the
# third read ends the run.
fleet_case() { # NAME [WATCH_BIN]
  new_case "$1"
  printf 'gh-1\ngh-2\nKEN-10\n' > "$STUB_DIR/windows.txt"
  printf '⏺ working on it\n' > "$STUB_DIR/pane-KEN-10.txt"
  printf 'ssh\n' > "$STUB_DIR/cmd-KEN-10.txt"
  remote_disk "$STUB_DIR/remote"
  write_state "$STUB_DIR/state.json" "$(lane_record issue-1 gh-1 '' /w/issue-1 running)" \
    "$(lane_record KEN-10 KEN-10 /srv/provider "$REMOTE_ROOT" running)" "$(lane_record issue-3 gh-3 '' /w/issue-3 done)"
  swap_state '2) unlink "$STUB_DIR/state.json" ;;'
  err="$TMP_ROOT/e-$1"
  out="$(WATCH_BIN="${2:-}" run_watch OVERSEE_WATCH_WORKFLOW_STATE="$STUB_DIR/swap-state.sh" ORCH_LANE_HOST="$FIXTURE_HOST" \
    LANE_HOST_STUB_LOG="$STUB_DIR/host.log" LANE_HOST_STUB_DIR="$STUB_DIR/remote" -- --max-loops 1 \
    --repeat 0 --state "$STUB_DIR/state.json" 2>"$err" </dev/null)" && rc=0 || rc=$?
  REPEAT_ITEMS="$(awk '$(NF-1) == "handoff-standing" { printf "%s%s", sep, $NF; sep = " " }' "$STUB_DIR/workflow-state.args")"
  REPEAT_EVENTS="$(awk '/^EVENT / { printf "%s%s", sep, $2; sep = " " }' <<<"$out")"
}
fleet_case repeat_state_fleet
assert_eq "$rc" "2" "repeat mode ends on a state it cannot read" "$err"
assert_contains "$(cat "$err")" "oversee-watch: state-unreadable option=--state" "the refusal names the state file"
assert_eq "$REPEAT_ITEMS" "issue-1 KEN-10 issue-1 KEN-10" "every running record is an item on every pass, and a done record is not" "$err"
assert_eq "$REPEAT_EVENTS" "lane-question heartbeat" "the hosted lane's ask is read through its record's root, once" "$err"
assert_contains "$out" "EVENT lane-question KEN-10 remote-1" "the hosted mailbox is the record's mail_root on the record's host" "$err"
assert_eq "gh-1=$(cat "$STUB_DIR/cmd-gh-1.calls") KEN-10=$(cat "$STUB_DIR/cmd-KEN-10.calls") gh-3=$(cat "$STUB_DIR/cmd-gh-3.calls" 2>/dev/null || echo none)" \
  "gh-1=2 KEN-10=2 gh-3=none" "every running record's window is read on every pass, and a done record's is not" "$err"
assert_eq "$(grep '^oversee-watch: fleet-read ' "$err")" "oversee-watch: fleet-read items=2 windows=2 hosted=1 dropped=1 path=$STUB_DIR/state.json" \
  "the set the passes carry is named once, with the done record counted as dropped, and not again while it stands" "$err"

custom_close_case() { # NAME [WATCH_BIN]
  local name="$1" bin="${2:-}" custom
  new_case "$name"
  custom="$STUB_DIR/custom"
  mkdir -p "$custom" "$STUB_DIR/remote/srv/lane/issue-2" \
    "$STUB_DIR/remote/srv/clone/tmp/lane-mail/issue-2"
  printf 'gh-2\n' > "$STUB_DIR/windows.txt"
  printf 'bash\n' > "$STUB_DIR/cmd-gh-2.txt"
  printf 'gitdir: /srv/clone/.git/worktrees/issue-2\n' > "$STUB_DIR/remote/srv/lane/issue-2/.git"
  printf '{"handoff":{"written_at":"t"}}\n' > "$STUB_DIR/remote/srv/clone/tmp/workflow-state-issue-2.json"
  printf '[{"number":2,"headRefName":"issue-2","mergedAt":"2026-09-20T00:00:00Z"}]\n' > "$STUB_DIR/merged.json"
  write_state "$custom/workflow-state-oversee.json" \
    "$(lane_record issue-2 gh-2 /srv/provider /srv/lane/issue-2 running)"
  repeat_sleep_stub \
    'n=0; [[ ! -f "$STUB_DIR/repeat.calls" ]] || n="$(cat "$STUB_DIR/repeat.calls")"' \
    'n=$((n + 1)); printf "%s\n" "$n" > "$STUB_DIR/repeat.calls"' \
    'case "$n" in 1) rm -rf -- "$STUB_DIR/remote/srv/lane/issue-2" ;; 2) unlink "$STUB_DIR/custom/workflow-state-oversee.json" ;; esac'
  err="$TMP_ROOT/e-$name"
  out="$(WATCH_BIN="$bin" run_watch ORCH_LANE_HOST="$FIXTURE_HOST" LANE_HOST_STUB_LOG="$STUB_DIR/host.log" \
    LANE_HOST_STUB_DIR="$STUB_DIR/remote" PATH="$STUB_DIR/bin:$TMP_ROOT/bin:$PATH" -- --max-loops 1 \
    --since 2026-09-19T00:00:00Z --repeat 0 --state "$custom/workflow-state-oversee.json" 2>"$err" </dev/null)" && rc=0 || rc=$?
}
custom_close_case repeat_state_custom_close
assert_eq "$rc" "2" "the custom-state repeat run ends after its state is removed" "$err"
assert_eq "$(cat "$STUB_DIR/lane-close.args")" "--state-dir $STUB_DIR/custom issue-2" \
  "repeat mode gives automatic close the explicit fleet state directory" "$err"
assert_eq "$(grep -cF -- "--state-dir $STUB_DIR/custom handoff-standing issue-2" "$STUB_DIR/workflow-state.args" || true)" "0" \
  "the fleet directory does not replace the hosted item's workflow-state directory" "$err"

fleet_dir_handoff='    OVERSEE_WATCH_FLEET_STATE_DIR="$fleet_state_dir" \'
assert_eq "$(grep -cxF -- "$fleet_dir_handoff" "$REPO_ROOT/skills/orch/scripts/oversee-watch")" "1" \
  "control: the repeat pass has one fleet-state identity handoff"
FLEET_DIR_HANDOFF="$fleet_dir_handoff" awk '$0 == ENVIRON["FLEET_DIR_HANDOFF"] { next } { print }' \
  "$REPO_ROOT/skills/orch/scripts/oversee-watch" > "$MERGED_MUTANT_DIR/orch/scripts/oversee-watch"
assert_eq "$(cmp -s "$MERGED_MUTANT_DIR/orch/scripts/oversee-watch" "$REPO_ROOT/skills/orch/scripts/oversee-watch" && echo same || echo differs)" "differs" \
  "control: the fleet identity handoff mutant differs from the script"
custom_close_case repeat_state_custom_close_defaulted "$MERGED_MUTANT_DIR/orch/scripts/oversee-watch"
assert_eq "$(cat "$STUB_DIR/lane-close.args")" "--state-dir $CASE_REPO_ROOT/tmp issue-2" \
  "control: without the fleet identity handoff automatic close falls back to the checkout state" "$err"

# A fleet closed out to no running record is named, not watched in silence:
# one done record reads as items=0 with the record counted dropped, the pass
# still heartbeats, and the run ends when the sleep stub takes the state away.
new_case repeat_state_all_done
write_state "$STUB_DIR/state.json" "$(lane_record issue-3 gh-3 '' /w/issue-3 done)"
repeat_sleep_stub 'unlink "$STUB_DIR/state.json"'
err="$TMP_ROOT/e-repeat_state_all_done"
out="$(run_watch PATH="$STUB_DIR/bin:$TMP_ROOT/bin:$PATH" -- --max-loops 1 --repeat 0 --state "$STUB_DIR/state.json" 2>"$err" </dev/null)" && rc=0 || rc=$?
assert_eq "rc=$rc note=$(grep '^oversee-watch: fleet-read ' "$err" | sed 's/ path=.*//' | paste -sd '|' -) unreadable=$(grep -c '^oversee-watch: state-unreadable option=--state' "$err") events=$(awk '/^EVENT / { printf "%s%s", sep, $2; sep = " " }' <<<"$out")" \
  "rc=2 note=oversee-watch: fleet-read items=0 windows=0 hosted=0 dropped=1 unreadable=1 events=heartbeat" \
  "a state whose every record is done is named as an empty fleet, heartbeats, and ends on the state taken away" "$err"
# A repeat delay that cannot be slept ends the watch with its cause named,
# never with a bare exit status: the stub fails the delay after the first pass.
new_case repeat_sleep_fails
write_state "$STUB_DIR/state.json" "$(lane_record issue-1 '' '' /w/issue-1 running)"
repeat_sleep_stub 'exit 3'
err="$TMP_ROOT/e-repeat_sleep_fails"
out="$(run_watch PATH="$STUB_DIR/bin:$TMP_ROOT/bin:$PATH" -- --max-loops 1 --repeat 0 --state "$STUB_DIR/state.json" 2>"$err" </dev/null)" && rc=0 || rc=$?
assert_eq "rc=$rc named=$(grep -c '^oversee-watch: sleep-failed secs=0$' "$err") events=$(awk '/^EVENT / { printf "%s%s", sep, $2; sep = " " }' <<<"$out")" \
  "rc=2 named=1 events=heartbeat" "a failed repeat delay ends the watch as sleep-failed after the pass it followed" "$err"
# The must-fail control: the bare sleep, whose failure is the watch's own exit.
sleep_line='    OVERSEE_WATCH_SLEEP=repeat sleep "$REPEAT" || die sleep-failed "" "secs=$REPEAT"'
assert_eq "$(grep -cxF -- "$sleep_line" "$REPO_ROOT/skills/orch/scripts/oversee-watch")" "1" "control: the guarded delay is one line to strip"
awk -v line="$sleep_line" '$0 == line { print "    OVERSEE_WATCH_SLEEP=repeat sleep \"$REPEAT\""; next } { print }' \
  "$REPO_ROOT/skills/orch/scripts/oversee-watch" > "$MERGED_MUTANT_DIR/orch/scripts/oversee-watch"
new_case repeat_sleep_fails_unguarded
write_state "$STUB_DIR/state.json" "$(lane_record issue-1 '' '' /w/issue-1 running)"
repeat_sleep_stub 'exit 3'
err="$TMP_ROOT/e-repeat_sleep_fails_unguarded"
WATCH_BIN="$MERGED_MUTANT_DIR/orch/scripts/oversee-watch" run_watch PATH="$STUB_DIR/bin:$TMP_ROOT/bin:$PATH" -- --max-loops 1 --repeat 0 --state "$STUB_DIR/state.json" >/dev/null 2>"$err" </dev/null && rc=0 || rc=$?
assert_eq "rc=$rc named=$(grep -c '^oversee-watch: sleep-failed' "$err")" "rc=3 named=0" "control: unguarded, the failed delay is a silent exit with the stub's status" "$err"
# A local lane whose worktree sits outside the watch's own checkout (a
# proposal sweep launched from a source repository) has its mailbox read at
# the root its record carries, never in this checkout.
new_case repeat_state_local_root
LOCAL_ROOT="$TMP_ROOT/elsewhere/ken-11"
mkdir -p "$LOCAL_ROOT/tmp/lane-mail/KEN-11"
git -C "$LOCAL_ROOT" init -q
printf '{"id":"local-1","kind":"ask","at":"t","text":"Local question"}\n' > "$LOCAL_ROOT/tmp/lane-mail/KEN-11/to-overseer.jsonl"
write_state "$STUB_DIR/state.json" "$(lane_record KEN-11 '' '' "$LOCAL_ROOT" running)"
repeat_sleep_stub 'unlink "$STUB_DIR/state.json"'
err="$TMP_ROOT/e-repeat_state_local_root"
out="$(run_watch PATH="$STUB_DIR/bin:$TMP_ROOT/bin:$PATH" -- --max-loops 1 --repeat 0 --state "$STUB_DIR/state.json" 2>"$err" </dev/null)" && rc=0 || rc=$?
assert_eq "rc=$rc events=$(awk '/^EVENT / { printf "%s%s", sep, $2; sep = " " }' <<<"$out") asked=$(grep -c '^EVENT lane-question KEN-11 local-1' <<<"$out" || true)" \
  "rc=2 events=lane-question asked=1" "a local record's mail_root outside this checkout is where its mailbox is read" "$err"
# The must-fail control: the local root not carried, so the mailbox is looked
# for in this checkout and the ask is never seen.
root_carry='    elif [[ -n "$root" ]]; then ROOTS+=("$item=$root"); fi'
assert_eq "$(grep -cxF -- "$root_carry" "$REPO_ROOT/skills/orch/scripts/oversee-watch")" "1" "control: the local root carry is one line to drop"
awk -v carry="$root_carry" '$0 == carry { print "    fi"; next } { print }' \
  "$REPO_ROOT/skills/orch/scripts/oversee-watch" > "$MERGED_MUTANT_DIR/orch/scripts/oversee-watch"
new_case repeat_state_local_root_dropped
printf '{"id":"local-1","kind":"ask","at":"t","text":"Local question"}\n' > "$LOCAL_ROOT/tmp/lane-mail/KEN-11/to-overseer.jsonl"
write_state "$STUB_DIR/state.json" "$(lane_record KEN-11 '' '' "$LOCAL_ROOT" running)"
repeat_sleep_stub 'unlink "$STUB_DIR/state.json"'
err="$TMP_ROOT/e-repeat_state_local_root_dropped"
out="$(WATCH_BIN="$MERGED_MUTANT_DIR/orch/scripts/oversee-watch" run_watch PATH="$STUB_DIR/bin:$TMP_ROOT/bin:$PATH" -- --max-loops 1 --repeat 0 --state "$STUB_DIR/state.json" 2>"$err" </dev/null)" && rc=0 || rc=$?
assert_eq "rc=$rc events=$(awk '/^EVENT / { printf "%s%s", sep, $2; sep = " " }' <<<"$out")" "rc=2 events=heartbeat" \
  "control: with the root dropped the pass reads an empty mailbox in this checkout and heartbeats over the ask" "$err"
# A --hosted entry passed by hand for an item the state also records hosted
# is merged by item, the state's root winning: the pass is not refused as
# hosted-duplicate, and the ask is read at the recorded root.
new_case repeat_state_hosted_merge
printf 'gh-1\ngh-2\nKEN-10\n' > "$STUB_DIR/windows.txt"
printf '⏺ working on it\n' > "$STUB_DIR/pane-KEN-10.txt"
printf 'ssh\n' > "$STUB_DIR/cmd-KEN-10.txt"
remote_disk "$STUB_DIR/remote"
write_state "$STUB_DIR/state.json" "$(lane_record KEN-10 KEN-10 /srv/provider "$REMOTE_ROOT" running)"
repeat_sleep_stub 'unlink "$STUB_DIR/state.json"'
err="$TMP_ROOT/e-repeat_state_hosted_merge"
out="$(run_watch ORCH_LANE_HOST="$FIXTURE_HOST" LANE_HOST_STUB_LOG="$STUB_DIR/host.log" LANE_HOST_STUB_DIR="$STUB_DIR/remote" \
  PATH="$STUB_DIR/bin:$TMP_ROOT/bin:$PATH" -- --max-loops 1 --repeat 0 --state "$STUB_DIR/state.json" --hosted KEN-10=/srv/other 2>"$err" </dev/null)" && rc=0 || rc=$?
assert_eq "rc=$rc dup=$(grep -c 'hosted-duplicate' "$err") carried=$(grep -o '^oversee-watch: fleet-read items=[0-9]* windows=[0-9]* hosted=[0-9]*' "$err" | head -1) events=$(awk '/^EVENT / { printf "%s%s", sep, $2; sep = " " }' <<<"$out")" \
  "rc=2 dup=0 carried=oversee-watch: fleet-read items=1 windows=1 hosted=1 events=lane-question" \
  "a hand-passed hosted entry and the state's record for one item merge as one, the state's root read" "$err"
# The must-fail control: the hand-passed entry appended beside the state's,
# which check_item_set refuses before any pass.
hosted_merge='  for line in ${GIVEN_HOSTED[@]+"${GIVEN_HOSTED[@]}"}; do route_listed "${line%%=*}" || HOSTED+=("$line"); done'
assert_eq "$(grep -cxF -- "$hosted_merge" "$REPO_ROOT/skills/orch/scripts/oversee-watch")" "1" "control: the hosted merge is one line to unguard"
awk -v merge="$hosted_merge" '$0 == merge { print "  for line in ${GIVEN_HOSTED[@]+\"${GIVEN_HOSTED[@]}\"}; do HOSTED+=(\"$line\"); done"; next } { print }' \
  "$REPO_ROOT/skills/orch/scripts/oversee-watch" > "$MERGED_MUTANT_DIR/orch/scripts/oversee-watch"
new_case repeat_state_hosted_merge_unguarded
write_state "$STUB_DIR/state.json" "$(lane_record KEN-10 KEN-10 /srv/provider "$REMOTE_ROOT" running)"
repeat_sleep_stub 'unlink "$STUB_DIR/state.json"'
err="$TMP_ROOT/e-repeat_state_hosted_merge_unguarded"
out="$(WATCH_BIN="$MERGED_MUTANT_DIR/orch/scripts/oversee-watch" run_watch PATH="$STUB_DIR/bin:$TMP_ROOT/bin:$PATH" -- --max-loops 1 --repeat 0 --state "$STUB_DIR/state.json" --hosted KEN-10=/srv/other 2>"$err" </dev/null)" && rc=0 || rc=$?
assert_eq "rc=$rc dup=$(grep -c '^oversee-watch: hosted-duplicate item=KEN-10' "$err") events=$(awk '/^EVENT / { printf "%s%s", sep, $2; sep = " " }' <<<"$out")" "rc=2 dup=1 events=" \
  "control: unmerged, the two entries for one item end the watch as hosted-duplicate before any pass" "$err"
# A hand-passed hosted route for an item whose record is local is displaced by
# the record: the mailbox is read on this disk at the recorded root, and
# lane-host is never asked for it. A log lane-host never wrote is zero reads.
host_cats() { [[ -f "$STUB_DIR/host.log" ]] || { echo 0; return; }; grep -c '^cat ' "$STUB_DIR/host.log" || true; }
new_case repeat_state_route_crossed
CROSSED_ROOT="$TMP_ROOT/elsewhere/ken-12"
mkdir -p "$CROSSED_ROOT/tmp/lane-mail/KEN-12"
git -C "$CROSSED_ROOT" init -q
printf '{"id":"local-2","kind":"ask","at":"t","text":"Crossed question"}\n' > "$CROSSED_ROOT/tmp/lane-mail/KEN-12/to-overseer.jsonl"
write_state "$STUB_DIR/state.json" "$(lane_record KEN-12 '' '' "$CROSSED_ROOT" running)"
repeat_sleep_stub 'unlink "$STUB_DIR/state.json"'
err="$TMP_ROOT/e-repeat_state_route_crossed"
out="$(run_watch ORCH_LANE_HOST="$FIXTURE_HOST" LANE_HOST_STUB_LOG="$STUB_DIR/host.log" LANE_HOST_STUB_DIR="$STUB_DIR/remote" \
  PATH="$STUB_DIR/bin:$TMP_ROOT/bin:$PATH" -- --max-loops 1 --repeat 0 --state "$STUB_DIR/state.json" --hosted KEN-12=/srv/other 2>"$err" </dev/null)" && rc=0 || rc=$?
assert_eq "rc=$rc asked=$(grep -c '^EVENT lane-question KEN-12 local-2' <<<"$out" || true) host_reads=$(host_cats)" \
  "rc=2 asked=1 host_reads=0" "a hand-passed hosted route yields to the item's local record: read on this disk, never through lane-host" "$err"
# The must-fail control: the hand-passed hosted entry tested against hosted
# records only, so the local record leaves it standing and lane-host is asked.
route_check='  local_root "$1"'
assert_eq "$(grep -cxF -- "$route_check" "$REPO_ROOT/skills/orch/scripts/oversee-watch")" "1" "control: the cross-type check is one line to blank"
awk -v check="$route_check" '$0 == check { print "  LOCAL_ROOT=\"\""; next } { print }' \
  "$REPO_ROOT/skills/orch/scripts/oversee-watch" > "$MERGED_MUTANT_DIR/orch/scripts/oversee-watch"
new_case repeat_state_route_crossed_unchecked
printf '{"id":"local-2","kind":"ask","at":"t","text":"Crossed question"}\n' > "$CROSSED_ROOT/tmp/lane-mail/KEN-12/to-overseer.jsonl"
write_state "$STUB_DIR/state.json" "$(lane_record KEN-12 '' '' "$CROSSED_ROOT" running)"
repeat_sleep_stub 'unlink "$STUB_DIR/state.json"'
err="$TMP_ROOT/e-repeat_state_route_crossed_unchecked"
out="$(WATCH_BIN="$MERGED_MUTANT_DIR/orch/scripts/oversee-watch" run_watch ORCH_LANE_HOST="$FIXTURE_HOST" LANE_HOST_STUB_LOG="$STUB_DIR/host.log" LANE_HOST_STUB_DIR="$STUB_DIR/remote" \
  PATH="$STUB_DIR/bin:$TMP_ROOT/bin:$PATH" -- --max-loops 1 --repeat 0 --state "$STUB_DIR/state.json" --hosted KEN-12=/srv/other 2>"$err" </dev/null)" && rc=0 || rc=$?
assert_eq "asked=$(grep -c '^EVENT lane-question KEN-12 local-2' <<<"$out" || true) host_reads=$([[ "$(host_cats)" -gt 0 ]] && echo some || echo none)" \
  "asked=0 host_reads=some" "control: unchecked across types, the stale hosted route wins and the ask on this disk is never read" "$err"
# A hosted lane joining between passes is carried by the next pass with no
# restart: pass 1 sees the local lane alone and its handoff read records the
# hosted lane, pass 2 reads that lane's ask, pass 3 finds it drained, and the
# read of pass 4 ends the run. A sleep stub ends a watch that never re-reads
# the state, which the read-once control would otherwise run for ever.
joins_case() { # NAME [WATCH_BIN]
  new_case "$1"
  repeat_sleep_stub 'n=0; [[ ! -f "$STUB_DIR/sleep.calls" ]] || n="$(cat "$STUB_DIR/sleep.calls")"' \
    'n=$((n + 1)); printf "%s" "$n" > "$STUB_DIR/sleep.calls"' \
    '[[ "$n" -lt 4 ]] || kill -TERM "$PPID"'
  printf 'gh-1\ngh-2\nKEN-10\n' > "$STUB_DIR/windows.txt"
  printf '⏺ working on it\n' > "$STUB_DIR/pane-KEN-10.txt"
  printf 'ssh\n' > "$STUB_DIR/cmd-KEN-10.txt"
  remote_disk "$STUB_DIR/remote"
  write_state "$STUB_DIR/state.json" "$(lane_record issue-1 gh-1 '' /w/issue-1 running)"
  lane_record KEN-10 KEN-10 /srv/provider "$REMOTE_ROOT" running > "$STUB_DIR/hosted.json"
  swap_state "'' | 0) jq --slurpfile h \"\$STUB_DIR/hosted.json\" '.lanes += \$h' \"\$STUB_DIR/state.json\" > \"\$STUB_DIR/state.next\" && mv \"\$STUB_DIR/state.next\" \"\$STUB_DIR/state.json\" ;;" \
    '3) unlink "$STUB_DIR/state.json" ;;'
  err="$TMP_ROOT/e-$1"
  out="$(WATCH_BIN="${2:-}" run_watch OVERSEE_WATCH_WORKFLOW_STATE="$STUB_DIR/swap-state.sh" ORCH_LANE_HOST="$FIXTURE_HOST" \
    LANE_HOST_STUB_LOG="$STUB_DIR/host.log" LANE_HOST_STUB_DIR="$STUB_DIR/remote" PATH="$STUB_DIR/bin:$TMP_ROOT/bin:$PATH" -- --max-loops 1 \
    --repeat 0 --state "$STUB_DIR/state.json" 2>"$err" </dev/null)" && rc=0 || rc=$?
  REPEAT_EVENTS="$(awk '/^EVENT / { printf "%s%s", sep, $2; sep = " " }' <<<"$out")"
}
joins_case repeat_state_hosted_joins
assert_eq "$rc" "2" "the joining run ends on the state it cannot read" "$err"
assert_eq "$REPEAT_EVENTS" "heartbeat lane-question heartbeat" "a hosted lane recorded between passes is read by the next pass, with no restart" "$err"
assert_eq "$(grep '^oversee-watch: fleet-read ' "$err" | sed 's/ path=.*//' | paste -sd '|' -)" \
  "oversee-watch: fleet-read items=1 windows=1 hosted=0 dropped=0|oversee-watch: fleet-read items=2 windows=2 hosted=1 dropped=0" \
  "the set is named again on the re-read that changes it, and not on the one that does not" "$err"
# The must-fail control: the last set never remembered, so the note names
# every pass rather than a change.
carried_keep='    FLEET_CARRIED="${carried[*]}"'
assert_eq "$(grep -cxF -- "$carried_keep" "$REPO_ROOT/skills/orch/scripts/oversee-watch")" "1" "control: the remembered set is one line to drop"
awk -v keep="$carried_keep" '$0 == keep { print "      :"; next } { print }' \
  "$REPO_ROOT/skills/orch/scripts/oversee-watch" > "$MERGED_MUTANT_DIR/orch/scripts/oversee-watch"
joins_case repeat_state_fleet_unremembered "$MERGED_MUTANT_DIR/orch/scripts/oversee-watch"
assert_eq "$(grep -c '^oversee-watch: fleet-read ' "$err")" "6" "control: with no remembered set every read names the fleet again" "$err"
# The must-fail control: the wrapper's read moved out of its loop, so it names
# the fleet it launched the first pass with and never reads the state again.
wrapper_read='    fleet_merge'
assert_eq "$(grep -cxF -- "$wrapper_read" "$REPO_ROOT/skills/orch/scripts/oversee-watch")" "1" "control: the wrapper's read is one line to move"
awk -v read="$wrapper_read" '$0 == read { next } { print } /^  check_repo_set$/ { print read }' \
  "$REPO_ROOT/skills/orch/scripts/oversee-watch" > "$MERGED_MUTANT_DIR/orch/scripts/oversee-watch"
assert_eq "$(cmp -s "$MERGED_MUTANT_DIR/orch/scripts/oversee-watch" "$REPO_ROOT/skills/orch/scripts/oversee-watch" && echo same || echo differs)" "differs" \
  "control: the mutant really moves the read"
joins_case repeat_state_read_once "$MERGED_MUTANT_DIR/orch/scripts/oversee-watch"
assert_eq "$(grep '^oversee-watch: fleet-read ' "$err" | sed 's/ path=.*//' | paste -sd '|' -)" \
  "oversee-watch: fleet-read items=1 windows=1 hosted=0 dropped=0" \
  "control: read once, the wrapper names only the fleet it launched the first pass with" "$err"
# A record that lands or closes between two loops of ONE pass moves that
# pass's fleet with it, with no restart of the pass or of the watch. The
# handoff read of loop 1 makes the change and the repeat delay then takes the
# state away and ends the run. Three loops are allowed, so a pass that re-read
# nothing would heartbeat instead.
#
# `joins` appends the hosted record; loop 2 carries it and reads its ask.
# `departs` starts with the record and closes it; the hosted mailbox is
# emptied first, since a lane with mail would deliver it in loop 1 and end the
# pass before the loop that must no longer carry the lane ever runs.
mid_pass_case() { # NAME joins|departs [WATCH_BIN]
  new_case "$1"
  printf 'gh-1\nKEN-10\n' > "$STUB_DIR/windows.txt"
  printf '⏺ working on it\n' > "$STUB_DIR/pane-KEN-10.txt"
  printf 'ssh\n' > "$STUB_DIR/cmd-KEN-10.txt"
  remote_disk "$STUB_DIR/remote"
  if [[ "$2" == joins ]]; then
    write_state "$STUB_DIR/state.json" "$(lane_record issue-1 gh-1 '' /w/issue-1 running)"
    lane_record KEN-10 KEN-10 /srv/provider "$REMOTE_ROOT" running > "$STUB_DIR/hosted.json"
    swap_state "'' | 0) jq --slurpfile h \"\$STUB_DIR/hosted.json\" '.lanes += \$h' \"\$STUB_DIR/state.json\" > \"\$STUB_DIR/state.next\" && mv \"\$STUB_DIR/state.next\" \"\$STUB_DIR/state.json\" ;;"
  else
    write_state "$STUB_DIR/state.json" "$(lane_record issue-1 gh-1 '' /w/issue-1 running)" \
      "$(lane_record KEN-10 KEN-10 /srv/provider "$REMOTE_ROOT" running)"
    unlink "$STUB_DIR/remote$REMOTE_ROOT/tmp/lane-mail/KEN-10/to-overseer.jsonl"
    swap_state "'' | 0) jq '(.lanes[] | select(.item == \"KEN-10\") | .status) = \"done\"' \"\$STUB_DIR/state.json\" > \"\$STUB_DIR/state.next\" && mv \"\$STUB_DIR/state.next\" \"\$STUB_DIR/state.json\" ;;"
  fi
  repeat_sleep_stub 'unlink "$STUB_DIR/state.json"'
  err="$TMP_ROOT/e-$1"
  out="$(WATCH_BIN="${3:-}" run_watch OVERSEE_WATCH_WORKFLOW_STATE="$STUB_DIR/swap-state.sh" ORCH_LANE_HOST="$FIXTURE_HOST" \
    LANE_HOST_STUB_LOG="$STUB_DIR/host.log" LANE_HOST_STUB_DIR="$STUB_DIR/remote" PATH="$STUB_DIR/bin:$TMP_ROOT/bin:$PATH" \
    -- --max-loops 3 --repeat 0 --state "$STUB_DIR/state.json" 2>"$err" </dev/null)" && rc=0 || rc=$?
  MID_EVENTS="$(awk '/^EVENT / { printf "%s%s", sep, $2; sep = " " }' <<<"$out")"
  MID_ITEMS="$(awk '$(NF-1) == "handoff-standing" { printf "%s%s", sep, $NF; sep = " " }' "$STUB_DIR/workflow-state.args")"
  MID_MAIL_READS="$(grep -c -- "/tmp/lane-mail/KEN-10/to-overseer.jsonl" "$STUB_DIR/host.log" || true)"
}
mid_pass_case repeat_state_joins_mid_pass joins
assert_eq "$rc" "2" "the mid-pass run ends on the state it cannot read" "$err"
assert_eq "$MID_ITEMS" "issue-1 issue-1 KEN-10" "the loop after the record lands carries it, without the pass returning first" "$err"
assert_eq "$MID_EVENTS" "lane-question" "that loop reads the joined lane's ask, in the pass the first loop started" "$err"
assert_contains "$out" "EVENT lane-question KEN-10 remote-1" "the ask is read at the record's own root, on the record's host" "$err"
assert_eq "$(grep '^oversee-watch: fleet-read ' "$err" | sed 's/ path=.*//' | paste -sd '|' -)" \
  "oversee-watch: fleet-read items=1 windows=1 hosted=0 dropped=0|oversee-watch: fleet-read items=2 windows=2 hosted=1 dropped=0" \
  "the wrapper names the set it launched the pass with, and the pass names the set its own re-read changed" "$err"
# The must-fail control: the pass's per-loop read removed, leaving the set it
# was launched with.
loop_read='  [[ -z "$STATE_FILE" ]] || { fleet_merge; require_item_helpers; }'
assert_eq "$(grep -cxF -- "$loop_read" "$REPO_ROOT/skills/orch/scripts/oversee-watch")" "1" "control: the pass's per-loop read is one line to remove"
grep -vxF -- "$loop_read" "$REPO_ROOT/skills/orch/scripts/oversee-watch" > "$MERGED_MUTANT_DIR/orch/scripts/oversee-watch"
mid_pass_case repeat_state_joins_mid_pass_mutant joins "$MERGED_MUTANT_DIR/orch/scripts/oversee-watch"
assert_eq "$MID_ITEMS" "issue-1 issue-1 issue-1" "control: read once per pass, the lane that joined is outside every loop of that pass" "$err"
assert_eq "$MID_EVENTS" "heartbeat" "control: read once per pass, the joined lane's ask is never read and the pass heartbeats over it" "$err"
# The other half: a record closed between two loops leaves that pass's fleet.
# The wrapper hands the pass only what argv gave it, so nothing outside the
# state puts the closed item back.
mid_pass_case repeat_state_departs_mid_pass departs
assert_eq "$rc" "2" "the departure run ends on the state it cannot read" "$err"
assert_eq "$MID_ITEMS" "issue-1 KEN-10 issue-1 issue-1" "the loops after the record closes no longer carry it, without the pass returning first" "$err"
assert_eq "$MID_MAIL_READS" "1" "the closed lane's mailbox is read in the loop that carried it and never again" "$err"
assert_eq "$MID_EVENTS" "heartbeat" "the closed lane produces no event after it leaves the fleet" "$err"
# The must-fail control: the wrapper hands the pass its merged fleet again, so
# the pass's own argv puts the closed item back on every later loop.
argv_hosted='    for line in ${GIVEN_HOSTED[@]+"${GIVEN_HOSTED[@]}"}; do args+=(--hosted "$line"); done'
argv_roots='    for line in ${GIVEN_ROOTS[@]+"${GIVEN_ROOTS[@]}"}; do args+=(--root "$line"); done'
argv_items='    for line in ${GIVEN_ITEMS[@]+"${GIVEN_ITEMS[@]}"}; do args+=(--item "$line"); done'
for handoff_line in "$argv_hosted" "$argv_roots" "$argv_items"; do
  assert_eq "$(grep -cxF -- "$handoff_line" "$REPO_ROOT/skills/orch/scripts/oversee-watch")" "1" \
    "control: the argv-only handoff is one line to widen: ${handoff_line##*args+=(}"
done
awk -v h="$argv_hosted" -v r="$argv_roots" -v i="$argv_items" '
  $0 == h { print "    for line in ${HOSTED[@]+\"${HOSTED[@]}\"}; do args+=(--hosted \"$line\"); done"; next }
  $0 == r { print "    for line in ${ROOTS[@]+\"${ROOTS[@]}\"}; do args+=(--root \"$line\"); done"; next }
  $0 == i { print "    for line in ${ITEMS[@]+\"${ITEMS[@]}\"}; do args+=(--item \"$line\"); done"; next }
  { print }' "$REPO_ROOT/skills/orch/scripts/oversee-watch" > "$MERGED_MUTANT_DIR/orch/scripts/oversee-watch"
assert_eq "$(cmp -s "$MERGED_MUTANT_DIR/orch/scripts/oversee-watch" "$REPO_ROOT/skills/orch/scripts/oversee-watch" && echo same || echo differs)" "differs" \
  "control: the mutant really widens the handoff"
mid_pass_case repeat_state_departs_mid_pass_mutant departs "$MERGED_MUTANT_DIR/orch/scripts/oversee-watch"
assert_eq "$MID_ITEMS" "issue-1 KEN-10 issue-1 KEN-10 issue-1 KEN-10" "control: handed the merged fleet, the pass carries the closed lane on every loop" "$err"
assert_eq "$MID_MAIL_READS" "3" "control: handed the merged fleet, the closed lane's mailbox is drained on every loop" "$err"
# An argument a pass would refuse ends repeat mode before any pass. The sleep
# stub takes the state away, so a watch that ran the pass and slept anyway
# ends too, on a second refusal.
refused_case() { # NAME WATCH_BIN ARGS...
  local name="$1" bin="$2"
  shift 2
  new_case "$name"
  write_state "$STUB_DIR/state.json" "$(lane_record issue-1 '' '' /w/issue-1 running)"
  repeat_sleep_stub 'unlink "$STUB_DIR/state.json"'
  err="$TMP_ROOT/e-$name"
  WATCH_BIN="$bin" run_watch PATH="$STUB_DIR/bin:$TMP_ROOT/bin:$PATH" -- --repeat 0 \
    --state "$STUB_DIR/state.json" "$@" >/dev/null 2>"$err" </dev/null && rc=0 || rc=$?
  REFUSED_KEYS="$(grep '^oversee-watch:' "$err" || true)"
}
refused_case repeat_hosted_item_gone "" --hosted issue-2=host:/x
assert_eq "$rc" "2" "a --hosted item no running record names ends repeat mode" "$err"
assert_eq "$REFUSED_KEYS" "oversee-watch: hosted-unknown-item item=issue-2" "it ends on that refusal before any pass runs" "$err"
# The must-fail control: the parent's check of the pass set removed.
assert_eq "$(grep -c '^  check_item_set$' "$REPO_ROOT/skills/orch/scripts/oversee-watch")" "1" "control: the pass-set check is one line to remove"
sed '/^  check_item_set$/d' "$REPO_ROOT/skills/orch/scripts/oversee-watch" > "$MERGED_MUTANT_DIR/orch/scripts/oversee-watch"
refused_case repeat_hosted_item_gone_mutant "$MERGED_MUTANT_DIR/orch/scripts/oversee-watch" --hosted issue-2=host:/x
assert_contains "$REFUSED_KEYS" "oversee-watch: state-unreadable option=--state" "control: unchecked, the failing pass is followed by a sleep and another read" "$err"
refused_case repeat_repo_duplicate "" --repo owner/repo --repo Owner/Repo
assert_eq "$rc" "2" "a repeated --repo ends repeat mode" "$err"
assert_eq "$REFUSED_KEYS" "oversee-watch: repo-duplicate repo=Owner/Repo" "it ends on that refusal before any pass runs" "$err"
# The must-fail control: the parent's check of the repository set removed.
assert_eq "$(grep -c '^  check_repo_set$' "$REPO_ROOT/skills/orch/scripts/oversee-watch")" "1" "control: the repository-set check is one line to remove"
sed '/^  check_repo_set$/d' "$REPO_ROOT/skills/orch/scripts/oversee-watch" > "$MERGED_MUTANT_DIR/orch/scripts/oversee-watch"
refused_case repeat_repo_duplicate_mutant "$MERGED_MUTANT_DIR/orch/scripts/oversee-watch" --repo owner/repo --repo Owner/Repo
assert_contains "$REFUSED_KEYS" "oversee-watch: state-unreadable option=--state" "control: unchecked, the refused pass is followed by a sleep and another read" "$err"
# A record's window across five passes: listed, gone, still gone, listed
# again, gone again. The handoff read counts passes as above and moves the
# window in and out of the tmux stub's list; after the fifth pass the state
# goes, and the run ends on it.
windows_case() { # NAME [WATCH_BIN]
  new_case "$1"
  write_state "$STUB_DIR/state.json" "$(lane_record issue-1 lane-x '' /w/issue-1 running)"
  printf 'gh-1\nlane-x\n' > "$STUB_DIR/windows.txt"
  printf '⏺ working on it\n' > "$STUB_DIR/pane-lane-x.txt"
  printf 'claude\n' > "$STUB_DIR/cmd-lane-x.txt"
  swap_state "'' | 3) printf 'gh-1\\n' > \"\$STUB_DIR/windows.txt\" ;;" \
    "2) printf 'gh-1\\nlane-x\\n' > \"\$STUB_DIR/windows.txt\" ;;" \
    '4) unlink "$STUB_DIR/state.json" ;;'
  err="$TMP_ROOT/e-$1"
  out="$(WATCH_BIN="${2:-}" run_watch OVERSEE_WATCH_WORKFLOW_STATE="$STUB_DIR/swap-state.sh" -- --max-loops 1 \
    --repeat 0 --state "$STUB_DIR/state.json" 2>"$err" </dev/null)" && rc=0 || rc=$?
  WINDOW_EVENTS="$(awk '/^EVENT / { printf "%s%s", sep, $2; sep = " " }' <<<"$out")"
  WINDOW_NOTES="$(grep -c '^oversee-watch: window-absent lane=lane-x$' "$err" || true)"
}
windows_case repeat_windows
assert_eq "$rc" "2" "repeat mode ends on a state it cannot read" "$err"
assert_contains "$(cat "$err")" "oversee-watch: state-unreadable option=--state" "the refusal names the state file"
assert_eq "$WINDOW_EVENTS" "heartbeat window-gone heartbeat heartbeat window-gone" \
  "a window is reported gone on the pass that first misses it, and again once tmux listed it in between" "$err"
assert_eq "$WINDOW_NOTES" "2" "each absence carries one window-absent note" "$err"
# The must-fail control: the reported absence never cleared when tmux lists the
# window again.
gone_clear='        gone="$(grep -vxF -- "$line" <<<"$gone" || :)"'
assert_eq "$(grep -cxF -- "$gone_clear" "$REPO_ROOT/skills/orch/scripts/oversee-watch")" "1" "control: the absence clear is one line to remove"
awk -v clear="$gone_clear" '$0 == clear { print "        :"; next } { print }' \
  "$REPO_ROOT/skills/orch/scripts/oversee-watch" > "$MERGED_MUTANT_DIR/orch/scripts/oversee-watch"
windows_case repeat_windows_mutant "$MERGED_MUTANT_DIR/orch/scripts/oversee-watch"
assert_eq "$WINDOW_EVENTS" "heartbeat window-gone heartbeat heartbeat heartbeat" "control: never cleared, the second absence is not reported" "$err"
# A pass that carries an absent window and fails before check_lanes reports
# nothing, so the absence rides on: pass 1's pr-watch fails, pass 2 reports
# window-gone, pass 3 leaves the window out, and the handoff read of pass 3
# takes the state away.
recovery_case() { # NAME [WATCH_BIN]
  new_case "$1"
  write_state "$STUB_DIR/state.json" "$(lane_record issue-1 lane-x '' /w/issue-1 running)"
  printf '1' > "$STUB_DIR/prwatch.rc.1"
  swap_state '1) unlink "$STUB_DIR/state.json" ;;'
  err="$TMP_ROOT/e-$1"
  out="$(WATCH_BIN="${2:-}" run_watch OVERSEE_WATCH_WORKFLOW_STATE="$STUB_DIR/swap-state.sh" -- --max-loops 1 \
    --repeat 0 --state "$STUB_DIR/state.json" 2>"$err" </dev/null)" && rc=0 || rc=$?
  WINDOW_EVENTS="$(awk '/^EVENT / { printf "%s%s", sep, $2; sep = " " }' <<<"$out")"
  WINDOW_NOTES="$(grep -c '^oversee-watch: window-absent lane=lane-x$' "$err" || true)"
}
recovery_case repeat_window_after_failed_pass
assert_eq "$rc" "2" "the recovery run ends on the state" "$err"
assert_contains "$(cat "$err")" "oversee-watch: reducer-failed" "the pass carrying the first absence fails before check_lanes"
assert_eq "$WINDOW_EVENTS" "window-gone heartbeat" "the next pass still reports window-gone, and the one after leaves it out" "$err"
assert_eq "$WINDOW_NOTES" "1" "the absence is noted once across the failed pass and the one that reports it" "$err"
# The must-fail control: the absence recorded before the pass runs, whatever it exits.
gone_commit='    [[ "$pass_rc" -ne 0 ]] || gone+="$pending"'
assert_eq "$(grep -cxF -- "$gone_commit" "$REPO_ROOT/skills/orch/scripts/oversee-watch")" "1" "control: the absence commit is one line to move"
awk -v commit="$gone_commit" '$0 == commit { next } $0 == "    pass_rc=0" { print "    gone+=\"$pending\"" } { print }' \
  "$REPO_ROOT/skills/orch/scripts/oversee-watch" > "$MERGED_MUTANT_DIR/orch/scripts/oversee-watch"
recovery_case repeat_window_after_failed_pass_mutant "$MERGED_MUTANT_DIR/orch/scripts/oversee-watch"
assert_eq "$WINDOW_EVENTS" "heartbeat heartbeat" "control: recorded before the failed pass, the absence is never reported" "$err"
# A --skip-lane the caller passes beside --repeat reaches the pass, which
# re-reads the record naming that window: the window tmux does not list is
# left alone rather than reported gone every pass. The handoff read of pass 1
# takes the state away, so the next read ends the run.
caller_skip_case() { # NAME [WATCH_BIN]
  new_case "$1"
  write_state "$STUB_DIR/state.json" "$(lane_record issue-1 lane-x '' /w/issue-1 running)"
  swap_state '1) unlink "$STUB_DIR/state.json" ;;'
  err="$TMP_ROOT/e-$1"
  out="$(WATCH_BIN="${2:-}" run_watch OVERSEE_WATCH_WORKFLOW_STATE="$STUB_DIR/swap-state.sh" -- --max-loops 1 \
    --repeat 0 --state "$STUB_DIR/state.json" --skip-lane lane-x 2>"$err" </dev/null)" && rc=0 || rc=$?
  WINDOW_EVENTS="$(awk '/^EVENT / { printf "%s%s", sep, $2; sep = " " }' <<<"$out")"
  WINDOW_NOTES="$(grep -c '^oversee-watch: window-absent lane=lane-x$' "$err" || true)"
}
caller_skip_case repeat_caller_skip_lane
assert_eq "$rc" "2" "the caller-skip run ends on the state it cannot read" "$err"
assert_eq "$WINDOW_EVENTS" "heartbeat heartbeat" "a caller's --skip-lane leaves the window unwatched in every pass, not reported gone" "$err"
assert_eq "$WINDOW_NOTES" "0" "the window the caller skipped is never noted absent" "$err"
# The must-fail control: the caller's skips not forwarded, so the pass carries
# the window its own state read names.
skip_forward='    for line in ${SKIP_LANES[@]+"${SKIP_LANES[@]}"}; do args+=(--skip-lane "$line"); done'
assert_eq "$(grep -cxF -- "$skip_forward" "$REPO_ROOT/skills/orch/scripts/oversee-watch")" "1" "control: the caller-skip forward is one line to remove"
grep -vxF -- "$skip_forward" "$REPO_ROOT/skills/orch/scripts/oversee-watch" > "$MERGED_MUTANT_DIR/orch/scripts/oversee-watch"
caller_skip_case repeat_caller_skip_lane_mutant "$MERGED_MUTANT_DIR/orch/scripts/oversee-watch"
assert_eq "$WINDOW_EVENTS" "window-gone window-gone" "control: unforwarded, every pass watches the window the caller skipped and reports it gone again" "$err"
# Repeat-mode refusals, `label|env|args|first stderr line|detail line
# holds`: each exits 2 with nothing on stdout, and a state-invalid refusal's
# third line, the tool detail under the explanation, carries the filter rule
# that refused it. %S is the case's stub
# directory, whose state.json holds one running lane at window lane-x,
# bad.json the JSON null, the one non-object jq indexes without complaint,
# nolanes.json a lanes object, and noitem.json a running record with no item.
# The sleep stub takes every state away, so a copy that carries a refused
# state past the read ends on the next read as state-unreadable instead of
# looping.
refusal_case() { # LABEL ENV ARGS [WATCH_BIN]
  local label="$1" env="$2" args="$3" bin="${4:-}"
  new_case repeat_refusal
  write_state "$STUB_DIR/state.json" "$(lane_record issue-1 lane-x '' /w/issue-1 running)"
  printf 'null\n' > "$STUB_DIR/bad.json"
  printf '{"lanes":{}}\n' > "$STUB_DIR/nolanes.json"
  printf '{"lanes":[{"window":"gh-9","status":"running"}]}\n' > "$STUB_DIR/noitem.json"
  repeat_sleep_stub 'rm -f "$STUB_DIR/state.json" "$STUB_DIR/bad.json" "$STUB_DIR/nolanes.json" "$STUB_DIR/noitem.json"'
  err="$TMP_ROOT/e-repeat-refusal"
  # shellcheck disable=SC2086
  out="$(WATCH_BIN="$bin" run_watch PATH="$STUB_DIR/bin:$TMP_ROOT/bin:$PATH" $env -- ${args//%S/$STUB_DIR} 2>"$err" </dev/null)" && rc=0 || rc=$?
}
for row in \
  "an invalid --repeat||--repeat 1x --state %S/state.json|oversee-watch: repeat-invalid value=1x|" \
  "--repeat without --state||--repeat 0|oversee-watch: state-required option=--repeat|" \
  "--skip-lane without --state||--skip-lane lane-x|oversee-watch: state-required option=--skip-lane|" \
  "a --state lane outside tmux|TMUX=|--repeat 0 --state %S/state.json|oversee-watch: tmux-missing lanes=lane-x|" \
  "a state that is not an object||--repeat 0 --state %S/bad.json|oversee-watch: state-invalid option=--state path=%S/bad.json|state-type expected=object actual=null" \
  "a state whose lanes is not an array||--repeat 0 --state %S/nolanes.json|oversee-watch: state-invalid option=--state path=%S/nolanes.json|lanes-type expected=array actual=object" \
  "a running record with no item||--repeat 0 --state %S/noitem.json|oversee-watch: state-invalid option=--state path=%S/noitem.json|lane-field field=item value=null"; do
  IFS='|' read -r label env args want detail <<<"$row"
  refusal_case "$label" "$env" "$args"
  assert_eq "$rc" "2" "$label: exits 2" "$err"
  assert_eq "$out" "" "$label: prints nothing on stdout" "$err"
  assert_eq "$(sed -n 1p "$err")" "${want//%S/$STUB_DIR}" "$label: names its key and value first" "$err"
  [[ -z "$detail" ]] || assert_contains "$(sed -n 3p "$err")" "$detail" "$label: the detail line names the rule that refused it"
done
# The must-fail controls, one per filter rule: a copy with that rule's arm
# replaced by the identity carries the refused state past the read as a fleet
# of no lane, runs a pass over nothing, and ends on the state the sleep stub
# took away.
filter_control() { # LABEL ARM_LINE IDENTITY STATE
  local label="$1" arm="$2" identity="$3" state="$4"
  assert_eq "$(grep -cxF -- "$arm" "$REPO_ROOT/skills/orch/scripts/oversee-watch")" "1" "control: the $label arm is one line to replace"
  # The arm text reaches awk through the environment: a -v assignment
  # processes escape sequences, and the arms' \( is read as a plain ( by GNU
  # awk, so the line would never match and the mutant would be the script.
  ARM="$arm" IDENTITY="$identity" awk '$0 == ENVIRON["ARM"] { print ENVIRON["IDENTITY"]; next } { print }' \
    "$REPO_ROOT/skills/orch/scripts/oversee-watch" > "$MERGED_MUTANT_DIR/orch/scripts/oversee-watch"
  assert_eq "$(cmp -s "$MERGED_MUTANT_DIR/orch/scripts/oversee-watch" "$REPO_ROOT/skills/orch/scripts/oversee-watch" && echo same || echo differs)" "differs" \
    "control: the $label mutant really replaces the arm"
  refusal_case "$label" "" "--max-loops 1 --repeat 0 --state %S/$state" "$MERGED_MUTANT_DIR/orch/scripts/oversee-watch"
  assert_eq "rc=$rc carried=$(grep -o '^oversee-watch: fleet-read items=[0-9]*' "$err" | paste -sd '|' -) unreadable=$(grep -c '^oversee-watch: state-unreadable option=--state' "$err") events=$(awk '/^EVENT / { printf "%s%s", sep, $2; sep = " " }' <<<"$out")" \
    "rc=2 carried=oversee-watch: fleet-read items=0 unreadable=1 events=heartbeat" \
    "control: without the $label rule the refused state is watched as an empty fleet until it is gone" "$err"
}
filter_control state-type '  if type != "object" then error("state-type expected=object actual=\(type)") else . end' '  .' bad.json
filter_control lanes-type '  | (.lanes // []) | if type != "array" then error("lanes-type expected=array actual=\(type)") else . end' '  | (.lanes // [])' nolanes.json
filter_control lane-field '  | if ((.item? | type) == "string" and (.item | length) > 0) then . else error("lane-field field=item value=\(.item | tojson)") end' '  | .' noitem.json

# --- 9. --help -------------------------------------------------------------
err="$TMP_ROOT/e9"
out="$(run_watch -- --help 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "0" "--help exits 0" "$err"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
