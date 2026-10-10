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
#       line mid-run is the event; an ordinary head-only change is not; GH_REPO reaches
#       pr-watch and its argv is empty, for every repo; an
#       error and refresh-ready keys preempt a repo's opening pass; each new
#       refresh-ready head is news, while every other kind there
#       still baselines silently;
#       rc≠0 with no lines is a global failure (exit 2); attention
#       at start does not starve a lane's question, and a new line and a
#       question on one pass are both reported, the watch's one must-fail
#       control being the reducer's early exit restored; the state file is
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
#       non-first --repo fires, the fork rejection holding per repo; a merged
#       item still in --item is reported once across runs while a further PR
#       on its branch is news; a parked record's own merge prints
#       parked-merged and closes nothing, its must-fail control being the
#       close restored, the heartbeat names it again while the record still
#       reads parked, its control being that repeat removed, a failed read
#       of its merged row there exits 2 naming the row, its control being
#       the read's return removed, two parked records both merged are each
#       handed on at the merge and at the heartbeat, their controls being
#       each loop cut to its first record, and another
#       merge on its branch, or none yet, hands nothing on at the merge or
#       the heartbeat, its control being the heartbeat's membership test
#       removed
#   2b. handoff: an --item whose state carries `.handoff` with no
#       `.resumed_at` fires once, with the record, read from the checkout's
#       state directory even when the item has a worktree; a state
#       without the key and a resumed record fire nothing; a re-run before
#       the relaunch stamps the record fires nothing
#   3.  heartbeat after --max-loops with every --repo's open PR list, each
#       line prefixed with its repo
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
#       the state it cannot read or parse; a --hosted item no record names and
#       a repeated --repo end it before any pass, repeat mode's one must-fail
#       control being the parent's pass-set check removed; a window is
#       reported gone on the pass that first misses it and again after tmux
#       lists it in between; a pass that fails before reporting leaves the
#       absence for the next pass; each repeat-mode refusal exits 2 with its
#       keyed first line
#   8d. ORCH_CONNECTED_REPOS: each listed repository is read by the merged
#       lookup and the heartbeat's open pull request list after the --repo
#       values or the resolved default, in repeat mode too, once and in one
#       spelling, with the append's control; a setting orch-env cannot read
#       exits 2 before any pass, in repeat mode with no --repo too, each with
#       its control
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"

# shellcheck source=lib/oversee-watch-harness.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/oversee-watch-harness.sh"
# mutant_scripts and mutate_file, the two halves of the controls below.
# shellcheck source=lib/growth-state.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/growth-state.sh"

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
# Matched WHOLE: pr-watch.sh rejects an unknown flag with exit 2, so a flag it
# does not take dies on every pass.
assert_eq "$(cat "$STUB_DIR/prwatch.args")" "" "pr-watch is invoked with no flag" "$err"

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

# 1d'. the reduction is per repo, so the argv holds for a repo that is not the
# first one reduced.
new_case prwatch_args_every_repo
printf '0' > "$STUB_DIR/prwatch.rc"
err="$TMP_ROOT/e1d5"
out="$(run_watch -- --repo owner/repo --repo other/repo 2>"$err")" && rc=0 || rc=$?
assert_eq "$(cut -f1 "$STUB_DIR/prwatch.args.all" | sort -u | paste -sd, -)" "other/repo,owner/repo" \
  "every repo is reduced" "$err"
assert_eq "$(cut -f2 "$STUB_DIR/prwatch.args.all" | sort -u)" "" \
  "every repo's pass is invoked with no flag" "$err"

# 1d''. an error key preempts a repo's opening pass. Ordinary attention
# standing at start is that repo's baseline, but a failed read baselined at
# start is never news again, and the overseer would hear nothing until the
# heartbeat.
new_case prwatch_error_first_pass
printf '12\taaaa0000\tthreads-open\t2 unresolved\n12\taaaa0000\terror\tE_REVIEW_STATE read failed\n' > "$STUB_DIR/prwatch.out"
printf '1' > "$STUB_DIR/prwatch.rc"
err="$TMP_ROOT/e1d6"
out="$(run_watch -- 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "0" "an error at start exits 0" "$err"
assert_eq "$(head -1 <<<"$out")" "EVENT pr-watch rc=1" "an error line at start is the event, not the baseline" "$err"
assert_contains "$out" "E_REVIEW_STATE" "the event carries the failed read" "$err"
assert_eq "$(grep -c 'oversee-watch: reducer-baseline' "$err")" "0" "the baseline note does not stand in for the error event"

# The companion: ordinary non-error attention still baselines silently.
new_case prwatch_no_error_first_pass
printf '12\taaaa0000\tthreads-open\t2 unresolved\n12\taaaa0000\tdisarmed\tauto-merge off\n' > "$STUB_DIR/prwatch.out"
printf '1' > "$STUB_DIR/prwatch.rc"
err="$TMP_ROOT/e1d7"
out="$(run_watch -- 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT heartbeat loops=2 interval=0s since=none" "a first pass with no error key still baselines" "$err"
assert_eq "$(grep -c 'oversee-watch: reducer-baseline' "$err")" "1" "the ordinary first-pass note still covers the non-error keys"

# A workflow-created refresh has no lane. Its green head must wake even on
# the opening pass, and each replacement head needs another app approval.
for mode in opening replacement; do
  new_case "prwatch_refresh_$mode"
  printf '12\taaaa0000\trefresh-ready\tCI passed\n' > "$STUB_DIR/prwatch.out.1"
  printf '12\tbbbb0000\trefresh-ready\tCI passed\n' > "$STUB_DIR/prwatch.out.2"
  printf '1' > "$STUB_DIR/prwatch.rc"
  if [[ "$mode" == replacement ]]; then
    mkdir -p "$STATE_DIR"
    printf '12\trefresh-ready:aaaa0000\n' > "$STATE_DIR/owner_repo__none"
  fi
  err="$TMP_ROOT/refresh-$mode.err"
  out="$(run_watch -- 2>"$err")" && rc=0 || rc=$?
  assert_eq "$(head -1 <<<"$out")" "EVENT pr-watch rc=1" "refresh $mode wakes without an owning lane" "$err"
  if [[ "$mode" == opening ]]; then
    assert_contains "$out" "aaaa0000" "the opening refresh head wakes immediately" "$err"
  else
    assert_contains "$out" "bbbb0000" "the replacement refresh head is news" "$err"
  fi
done

REFRESH_SCRIPTS="$(mutant_scripts refresh-opening-mutant/orch lib/pr-watch-pass.sh)" || exit 1
ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/refresh-opening-mutant/github"
mutate_file "$REFRESH_SCRIPTS/lib/pr-watch-pass.sh" '$2 == "error" || $2 ~ /^refresh-ready:/' '$2 == "error"'
new_case prwatch_refresh_opening_control
printf '12\taaaa0000\trefresh-ready\tCI passed\n' > "$STUB_DIR/prwatch.out"
printf '1' > "$STUB_DIR/prwatch.rc"
err="$TMP_ROOT/refresh-opening-control.err"
out="$(WATCH_BIN="$REFRESH_SCRIPTS/oversee-watch" run_watch -- 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT heartbeat loops=2 interval=0s since=none" "control: a baselined ready refresh has no immediate event" "$err"

REFRESH_SCRIPTS="$(mutant_scripts refresh-head-mutant/orch lib/pr-watch-pass.sh)" || exit 1
ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/refresh-head-mutant/github"
mutate_file "$REFRESH_SCRIPTS/lib/pr-watch-pass.sh" '($3 == "refresh-ready" ? ":" $2 : "")' '""'
new_case prwatch_refresh_head_control
printf '12\taaaa0000\trefresh-ready\tCI passed\n' > "$STUB_DIR/prwatch.out.1"
printf '12\tbbbb0000\trefresh-ready\tCI passed\n' > "$STUB_DIR/prwatch.out.2"
printf '1' > "$STUB_DIR/prwatch.rc"
mkdir -p "$STATE_DIR"
printf '12\trefresh-ready\n' > "$STATE_DIR/owner_repo__none"
err="$TMP_ROOT/refresh-head-control.err"
out="$(WATCH_BIN="$REFRESH_SCRIPTS/oversee-watch" run_watch -- 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT heartbeat loops=2 interval=0s since=none" "control: an unbound key loses the replacement refresh head" "$err"

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

# The watch's one must-fail control: the reducer arm's early exit restored.
# The mutant leaves the pass on the new reducer line, so the same fleet reads
# as pr-watch alone. The copy keeps orch's place in a skills tree: its
# libraries resolve the github skill beside it.
REDUCER_MUTANT_DIR="$TMP_ROOT/reducer-mutant"
REDUCER_SCRIPTS="$(mutant_scripts reducer-mutant/orch lib/pr-watch-pass.sh)" || exit 1
ln -s "$REPO_ROOT/skills/github" "$REDUCER_MUTANT_DIR/github"
mutate_file "$REDUCER_SCRIPTS/lib/pr-watch-pass.sh" '  PASS_EVENT=1' '  exit 0'
new_case prwatch_and_asking_same_pass_mutant
printf '0' > "$STUB_DIR/prwatch.rc.1"
printf '12\tabcdef01\tthreads-open\t2 unresolved\n' > "$STUB_DIR/prwatch.out.2"
printf '1' > "$STUB_DIR/prwatch.rc.2"
printf 'Do you want to proceed?\n   ❯ 1. Yes\n     2. No\n' > "$STUB_DIR/pane-gh-2.2.txt"
err="$TMP_ROOT/e1f3"
out="$(WATCH_BIN="$REDUCER_SCRIPTS/oversee-watch" run_watch -- gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
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
assert_eq "$(find "$STATE_DIR" -maxdepth 1 -type f ! -name '*.mail' 2>/dev/null | wc -l | tr -d '[:space:]')" "1" "one state file for the one repo, no temp left behind" "$err"
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
assert_eq "$(find "$STATE_DIR" -maxdepth 1 -type f ! -name '*.mail' 2>/dev/null | wc -l | tr -d '[:space:]')" "2" \
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
assert_eq "$(find "$STATE_DIR" -maxdepth 1 -type f ! -name '*.mail' 2>/dev/null | wc -l | tr -d '[:space:]')" "2" \
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

# a merged item still in --item is reported once across runs: the overseer
# exits on the event and re-runs the watch, and the same PR is not news
# again; a further PR merged on the same branch is.
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

# A Claude cloud session pushes to claude/..., a branch naming no item: its
# pull request is the item's by the key in its title's scope, and the line
# names the item's branch. Eleven later pull requests only mention KEN-50 in
# a body, ahead of it in the search's page. #51 names KEN-500, another item;
# #53 is another item's whose title mentions KEN-50; #54 is a revert title;
# #55 closes KEN-30 and mentions KEN-50 after it. #52 is on the item's branch
# and names it too, so the branch list and the search both return it.
merged_cloud_fixture() {
  jq -n '[range(70; 59; -1) | {number: ., headRefName: "claude/mention-\(.)", title: "chore: \(.)",
      body: "Follow-up to KEN-50.", mergedAt: "2026-08-15T11:00:00Z"}]
    + [{number: 55, headRefName: "claude/fix-e", title: "chore: e", body: "- Closes KEN-30 - Follow-up to KEN-50", mergedAt: "2026-08-15T10:50:00Z"},
       {number: 54, headRefName: "claude/revert", title: "Revert \"fix(KEN-50): a\"", mergedAt: "2026-08-15T10:45:00Z"},
       {number: 53, headRefName: "ken-1805", title: "refactor(KEN-1805): x before KEN-50 grows it", mergedAt: "2026-08-15T10:40:00Z"},
       {number: 52, headRefName: "ken-50", title: "fix(KEN-50): c", mergedAt: "2026-08-15T10:35:00Z"},
       {number: 51, headRefName: "claude/fix-b", title: "fix(KEN-500): b", mergedAt: "2026-08-15T10:30:00Z"},
       {number: 50, headRefName: "claude/fix-a", title: "fix(KEN-50): a", mergedAt: "2026-08-15T10:00:00Z"}]' > "$STUB_DIR/merged.json"
}
MERGED_CLOUD_WANT="0|EVENT merged 52 ken-50 owner/repo
EVENT merged 50 ken-50 owner/repo"
new_case merged_cloud_branch
merged_cloud_fixture
err="$TMP_ROOT/e2i"
out="$(run_watch -- --since 2026-08-15T09:00:00Z --item KEN-50 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc|$out" "$MERGED_CLOUD_WANT" \
  "a claude/ pull request whose title scope names the item is its merged event, once each, and mentions, other items and reverts are not" "$err"
# Rows, tab-separated: case, oversee-watch text, its replacement, want. Each
# reddens the case above: the search narrowed to the item's branch, a
# ten-row page the mentions fill, and the two lists not de-duplicated.
while IFS=$'\t' read -r name old new want; do
  bin="$(mutant_scripts "cloud-$name/orch" oversee-watch)/oversee-watch" || exit 1
  ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/cloud-$name/github"
  mutate_file "$bin" "$old" "$new"
  new_case "merged_cloud_$name"
  merged_cloud_fixture
  out="$(WATCH_BIN="$bin" run_watch -- --since 2026-08-15T09:00:00Z --item KEN-50 2>"$err")" && rc=0 || rc=$?
  assert_eq "$rc|$out" "${want//\\n/$'\n'}" "control: $name" "$err"
done <<'ROWS'
head_narrowed	--search "$search" --state merged	--search "$search" --head "$branch" --state merged	0|EVENT merged 52 ken-50 owner/repo
page_of_ten	--limit "$MERGED_SEARCH_PAGE" --json	--limit 10 --json	0|EVENT merged 52 ken-50 owner/repo
no_dedup	add // [] | reduce .[] as $row ([]; if any(.[]; .number == $row.number) then . else . + [$row] end)	add // []	0|EVENT merged 52 ken-50 owner/repo\nEVENT merged 52 ken-50 owner/repo\nEVENT merged 50 ken-50 owner/repo
ROWS
# A search page that reaches its limit may hold the item's pull request past
# it, so the pass exits 2 rather than judge a partial list.
new_case merged_search_full
jq -n '[range(1000) | {number: (2000 + .), headRefName: "claude/m-\(.)", title: "chore", body: "Follow-up to KEN-50.", mergedAt: "2026-08-15T11:00:00Z"}]' > "$STUB_DIR/merged.json"
out="$(run_watch -- --since 2026-08-15T09:00:00Z --item KEN-50 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc|$out|$(grep -c '^oversee-watch: merged-search-truncated repo=owner/repo item=KEN-50 limit=1000$' "$err" || true)" "2||1" \
  "a key search that fills its page exits 2 naming the repository, the item and the limit" "$err"
FULL_MUTANT="$(mutant_scripts cloud-full/orch oversee-watch)/oversee-watch" || exit 1
ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/cloud-full/github"
mutate_file "$FULL_MUTANT" '[[ "$rows" -lt "$MERGED_SEARCH_PAGE" ]] ||' 'true ||'
out="$(WATCH_BIN="$FULL_MUTANT" run_watch -- --since 2026-08-15T09:00:00Z --item KEN-50 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc|$(grep -c '^EVENT merged' <<<"$out" || true)" "0|0" "control: with the page check removed a full page is judged as whole and the pass exits 0" "$err"

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

# A lane root a --root entry names: its record stands only in that root's own
# tmp, read with the root passed as the worktree; a torn file there is reported
# by the path the verdict names. CONTENT is that file's content.
handoff_root() { # NAME CONTENT [WATCH]
  new_case "$1"
  mkdir -p "$STUB_DIR/wt-KEN-1" "$CASE_REPO_ROOT/tmp" "$STUB_DIR/root-KEN-1/tmp"
  printf '{"cycles":0}\n' > "$CASE_REPO_ROOT/tmp/workflow-state-KEN-1.json"
  printf '%s\n' "$2" > "$STUB_DIR/root-KEN-1/tmp/workflow-state-KEN-1.json"
  err="$TMP_ROOT/e-$1"
  out="$(WATCH_BIN="${3:-}" run_watch -- --item KEN-1 --root "KEN-1=$STUB_DIR/root-KEN-1" 2>"$err")" && rc=0 || rc=$?
  ROOT_READ="first=$(head -1 <<<"$out") worktree=$(grep -cF -- "handoff-standing KEN-1 --worktree $STUB_DIR/root-KEN-1" "$STUB_DIR/workflow-state.args" || :)"
}
handoff_root handoff_root_record '{"handoff":{"written_at":"t"}}'
assert_eq "rc=$rc $ROOT_READ" "rc=0 first=EVENT handoff KEN-1 worktree=1" \
  "a record only in the --root lane's tmp is the event, read with that root as the worktree" "$err"
handoff_root handoff_root_torn '{"handoff":'
assert_eq "rc=$rc failed=$(grep -c "^oversee-watch: handoff-read-failed item=KEN-1 path=$STUB_DIR/root-KEN-1/tmp/workflow-state-KEN-1.json\$" "$err")" \
  "rc=2 failed=1" "a torn state file in the lane root's tmp is reported by that file's path" "$err"
ROOT_MUTANT_DIR="$TMP_ROOT/root-mutant"
ROOT_MUTANT="$(mutant_scripts root-mutant/orch oversee-watch)/oversee-watch" || exit 1
ln -s "$REPO_ROOT/skills/github" "$ROOT_MUTANT_DIR/github"
mutate_file "$ROOT_MUTANT" '    ITEM_WORKTREE="$LOCAL_ROOT"' '    ITEM_WORKTREE=""'
handoff_root handoff_root_control '{"handoff":{"written_at":"t"}}' "$ROOT_MUTANT"
assert_eq "rc=$rc $ROOT_READ" "rc=0 first=$HEARTBEAT worktree=0" \
  "control: a watch passing no --root worktree misses the record in that root's tmp" "$err"

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
# that has already handed off and exited. Four answers reach it: an install
# older than the verb, a script its settings loader killed before the verb ran
# — which is why a status is no answer here — the verb's own `unreadable`, and
# a `stands` with no record under it, which the verb never prints whole.
# Each is driven through the seam the harness hands `handoff-standing` to,
# leaving every other workflow-state call whole.
old_state_reader() { # PATH STATUS STDOUT STDERR — an orch install answering STATUS
  printf '#!/bin/sh\n[ -z "%s" ] || printf "%%s\\n" "%s"\nprintf "%%s\\n" "%s" >&2\nexit %s\n' \
    "$3" "$3" "$4" "$2" > "$1"
  chmod +x "$1"
}
for row in "1||workflow-state: unknown-command arg1=handoff-standing|an install older than the verb" \
           "2||.env.local: line 1: syntax error near unexpected token|a script its settings loader killed before the verb" \
           "0|workflow-state: handoff-standing=unreadable|jq: error: Invalid numeric literal|the verb's own unreadable verdict" \
           "0|workflow-state: handoff-standing=stands|workflow-state: output cut short|a stands verdict with no record under it"; do
  status=${row%%|*}; rest=${row#*|}
  answer=${rest%%|*}; rest=${rest#*|}
  cause=${rest%%|*}; label=${rest#*|}
  unread_row=$((${unread_row:-0} + 1))
  new_case "handoff_unread_$unread_row"
  # A standing record committed first, so the row this case must not lose
  # exists before the failing read: with no prior row, "not cleared" would
  # hold against a pass that cleared everything.
  handoff_record KEN-1
  err="$TMP_ROOT/e2b-unread-$unread_row-seed"
  out="$(run_watch -- --item KEN-1 2>"$err")" && rc=0 || rc=$?
  assert_eq "rc=$rc first=$(head -1 <<<"$out")" "rc=0 first=EVENT handoff KEN-1" \
    "$label: the record is reported while the verb still answers" "$err"
  KEYED="$(grep -c "$(printf 'handoff\tKEN-1\t')" "$STATE_DIR/owner_repo__none")"
  assert_eq "$KEYED" "1" "$label: and its row is committed" "$err"

  READER="$STUB_DIR/old-workflow-state"
  old_state_reader "$READER" "$status" "$answer" "$cause"
  err="$TMP_ROOT/e2b-unread-$unread_row"
  # The security-alert check reads the fleet state through the same reader
  # and would print its words a second time; this row is the handoff read's.
  out="$(run_watch REAL_WORKFLOW_STATE="$READER" ORCH_SECURITY_ALERTS=off -- --item KEN-1 2>"$err")" && rc=0 || rc=$?
  assert_eq "rc=$rc stderr=$(grep -c "oversee-watch: handoff-read-failed item=KEN-1" "$err") cause=$(grep -cxF -- "$cause" "$err")" \
    "rc=2 stderr=1 cause=1" \
    "$label: the pass refuses and names the item, with the reader's words under it" "$err"
  assert_not_contains "$out" "EVENT handoff" "$label: and reports no handoff it could not read" "$err"
  assert_eq "$(grep -c "$(printf 'handoff\tKEN-1\t')" "$STATE_DIR/owner_repo__none")" "1" \
    "$label: the standing row survives, so the next readable pass still owes the event" "$err"
done

# The handoff read's failure is reported once while it stands, and a read
# that succeeded makes the next one news again: fail, fail, succeed, fail.
handoff_flap() {
  local run
  local -a env
  new_case handoff_flap
  handoff_record KEN-1
  old_state_reader "$STUB_DIR/old-workflow-state" 1 "" "workflow-state: unknown-command arg1=handoff-standing"
  FLAP=""
  FLAP_BEATS=()
  for run in fail fail ok fail; do
    env=()
    [[ "$run" == ok ]] || env=(REAL_WORKFLOW_STATE="$STUB_DIR/old-workflow-state")
    FLAP_BEATS+=("$(run_watch ${env[@]+"${env[@]}"} -- --item KEN-1 2>"$STUB_DIR/flap.err" || true)")
    FLAP+="$(grep -c 'oversee-watch: handoff-read-failed item=KEN-1' "$STUB_DIR/flap.err" || :)"
  done
}
handoff_flap
assert_eq "reports=$FLAP" "reports=1001" "a handoff read failure is reported once, and again after a read that succeeded"
# The second run's failure stands quiet, and its heartbeat still names it:
# the row is the long pass's, in the baseline this process reads from disk.
assert_eq "$(grep -c '^  failing KEN-1 handoff-read-failed ' <<<"${FLAP_BEATS[1]}" || :)" "1" \
  "a quiet run's heartbeat names the lane whose handoff read still fails"

# A lane's mail read fails, stands into the next run, and lifts inside it; the
# handoff it wrote is read by the long pass after the read that succeeded,
# not skipped for the rest of the run for a failure the mail pass no longer
# has.
cat > "$TMP_ROOT/bin/lane-mail-flaky.sh" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == drain ]]; then
  n=$(( $(cat "$STUB_DIR/flaky.n" 2>/dev/null || echo 0) + 1 ))
  printf '%s' "$n" > "$STUB_DIR/flaky.n"
  if [[ -n "${FLAKY_ALWAYS:-}" || "$n" -le 1 ]]; then
    printf 'lane-mail: lock-failed=/srv/box\nThe refusal.\n' >&2
    exit 2
  fi
fi
exec "$REAL_LANE_MAIL" "$@"
EOF
chmod +x "$TMP_ROOT/bin/lane-mail-flaky.sh"
failure_lifts() {
  local -a flaky=(OVERSEE_WATCH_LANE_MAIL="$TMP_ROOT/bin/lane-mail-flaky.sh"
    REAL_LANE_MAIL="$REPO_ROOT/skills/orch/scripts/lane-mail")
  new_case handoff_after_lift
  handoff_record KEN-1
  run_watch "${flaky[@]}" FLAKY_ALWAYS=1 -- --item KEN-1 >/dev/null 2>&1 || true
  unlink "$STUB_DIR/flaky.n"
  LIFTED="$(run_watch "${flaky[@]}" -- --item KEN-1 2>"$TMP_ROOT/e-lifted")" || true
}
failure_lifts
assert_eq "$(head -1 <<<"$LIFTED")" "EVENT handoff KEN-1" \
  "a lane whose standing mail failure lifts mid-run has its handoff read by the next long pass" "$TMP_ROOT/e-lifted"

# --- 5. heartbeat ----------------------------------------------------------
new_case heartbeat
printf '9\tissue-9\tfix the thing\n' > "$STUB_DIR/open.txt"
err="$TMP_ROOT/e5"
out="$(run_watch -- --item issue-9 gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "0" "heartbeat exits 0" "$err"
assert_contains "$out" "EVENT heartbeat" "heartbeat after --max-loops with no event" "$err"
assert_contains "$out" "$(printf 'owner/repo\t9\tissue-9\tfix the thing')" "open PR list follows the heartbeat, each line prefixed with its repo" "$err"
assert_eq "$(grep -c -- '--head issue-9 --state merged' "$STUB_DIR/gh.calls")|$(grep -c -- '--search "issue-9" in:title,body --state merged' "$STUB_DIR/gh.calls")" "2|2" \
  "merged check ran once per loop (2 loops), each its branch list and its key search" "$err"

# every --repo's open PRs follow the heartbeat
new_case heartbeat_multi_repo
printf '9\tissue-9\tfix the thing\n' > "$STUB_DIR/open.owner_repo.txt"
printf '77\tissue-9\tconsumer side\n' > "$STUB_DIR/open.other_repo.txt"
err="$TMP_ROOT/e5b"
out="$(run_watch -- --repo owner/repo --repo other/repo 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT heartbeat loops=2 interval=0s since=none" "a two-repo fleet reaches the heartbeat" "$err"
assert_contains "$out" "$(printf 'other/repo\t77\tissue-9\tconsumer side')" "the second repo's open PRs follow the heartbeat too" "$err"
assert_contains "$out" "$(printf 'owner/repo\t9\tissue-9\tfix the thing')" "beside the first repo's" "$err"

# --- 6. auth and listing failures ------------------------------------------
new_case auth_fail
touch "$STUB_DIR/auth-fail"
err="$TMP_ROOT/e6a"
out="$(run_watch -- 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "2" "gh auth failure exits 2" "$err"
assert_contains "$(cat "$err")" "oversee-watch: auth-failed service=github" "auth failure is named on stderr"
assert_eq "$out" "" "auth failure prints no EVENT" "$err"
assert_eq "prwatch=$([[ -f "$STUB_DIR/prwatch.repos" ]] && echo called || echo none)" "prwatch=none" \
  "a dead credential stops the run before its long pass reads GitHub unauthenticated" "$err"

# A run that dies on its credential check started no long pass, so the run
# after the repair starts one at once rather than --interval later. Its lane
# notice ends that run on the turn it starts, so a long pass not yet due is
# skipped rather than waited for.
auth_recovery_case() { # NAME
  local rc=0
  new_case "$1"
  mkdir -p "$TMP_ROOT/repo/tmp/lane-mail/KEN-96"
  touch "$STUB_DIR/auth-fail"
  run_watch -- --interval 3600 --item KEN-96 >/dev/null 2>"$TMP_ROOT/e-$1" || rc=$?
  rm -f -- "$STUB_DIR/auth-fail"
  printf '{"id":"after-1","kind":"notice","at":"t","text":"Rebased."}\n' \
    > "$TMP_ROOT/repo/tmp/lane-mail/KEN-96/to-overseer.jsonl"
  run_watch -- --interval 3600 --item KEN-96 >/dev/null 2>>"$TMP_ROOT/e-$1" || true
  AUTH_RECOVERY="failed=$rc prwatch=$([[ -f "$STUB_DIR/prwatch.repos" ]] && echo called || echo none)"
  rm -rf -- "${TMP_ROOT:?}/repo/tmp/lane-mail/KEN-96"
}
auth_recovery_case auth_recovery
assert_eq "$AUTH_RECOVERY" "failed=2 prwatch=called" \
  "a run after a failed credential check starts its long pass at once" "$TMP_ROOT/e-auth_recovery"

# The long-pass start kept is the fork's clock: under the stub clock the mail
# pass's lane-mail moves time on before the fork, and the start is that later
# reading, not the turn's.
start_clock_case() { # NAME
  new_case "$1"
  printf '1790000000\n' > "$STUB_DIR/now.epoch"
  printf '#!/usr/bin/env bash\nprintf "1790000500\\n" > "$STUB_DIR/now.epoch"\nexec "%s" "$@"\n' \
    "$REPO_ROOT/skills/orch/scripts/lane-mail" > "$STUB_DIR/lane-mail-slow"
  chmod +x "$STUB_DIR/lane-mail-slow"
  run_watch OVERSEE_WATCH_LANE_MAIL="$STUB_DIR/lane-mail-slow" -- --max-loops 1 \
    >/dev/null 2>"$TMP_ROOT/e-$1" || true
  START_CLOCK="start=$(awk -F'\t' '$1 == "long-pass" && $2 == "fleet" { print $3 }' \
    "$STATE_DIR"/*.mail 2>/dev/null || true)"
}
start_clock_case start_clock
assert_eq "$START_CLOCK" "start=1790000500" "the long-pass start is the clock read at the fork" "$TMP_ROOT/e-start_clock"

# A run that ends on a lane's notice before any long pass is due asks GitHub
# nothing, not even its credential.
mail_only_case() { # NAME
  new_case "$1"
  mkdir -p "$STATE_DIR" "$TMP_ROOT/repo/tmp/lane-mail/KEN-96"
  printf 'long-pass\tfleet\t%s\n' "$(date -u +%s)" > "$STATE_DIR/owner_repo__none.mail"
  printf '{"id":"only-1","kind":"notice","at":"t","text":"Rebased."}\n' \
    > "$TMP_ROOT/repo/tmp/lane-mail/KEN-96/to-overseer.jsonl"
  MAIL_ONLY_OUT="$(run_watch -- --interval 3600 --item KEN-96 2>"$TMP_ROOT/e-$1")" || true
  MAIL_ONLY="notice=$(grep -c '^EVENT lane-notice KEN-96 only-1$' <<<"$MAIL_ONLY_OUT" || :) auth=$(grep -c '^auth status' < <(cat -- "$STUB_DIR/gh.calls" 2>/dev/null) || true)"
  rm -rf -- "${TMP_ROOT:?}/repo/tmp/lane-mail/KEN-96"
}
mail_only_case mail_only_no_github
assert_eq "$MAIL_ONLY" "notice=1 auth=0" "a run ending on mail news before its long pass is due makes no GitHub call" \
  "$TMP_ROOT/e-mail_only_no_github"

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
# The hosted lane's disk: a worktree whose .git names its clone, the status
# file a started lane writes, and one ask in its mailbox. The root exists
# nowhere on this disk, so a pass that read the lane locally would find no
# mailbox and say nothing.
remote_disk() { # DIR
  mkdir -p "$1$REMOTE_ROOT/tmp/lane-mail/KEN-10"
  printf 'gitdir: /srv/clone/.git/worktrees/ken-10\n' > "$1$REMOTE_ROOT/.git"
  printf 'step: dev round 1\n' > "$1$REMOTE_ROOT/tmp/lane-status-KEN-10.md"
  printf '{"id":"remote-1","kind":"ask","at":"t","text":"Hosted question"}\n' > "$1$REMOTE_ROOT/tmp/lane-mail/KEN-10/to-overseer.jsonl"
}
# The handoff read's wrapper: at the pass count NAMED, run one shell line
# against the case's state, then answer as the stub does. The state goes
# through `unlink`, so a second removal is an error rather than a silent
# no-op. Only a handoff read runs the line: the security-alert check reads
# the fleet state through the same helper, and each of its reads would
# otherwise run the line again.
swap_state() { # LINE...  — one `COUNT) COMMAND ;;` case arm per argument
  {
    printf '#!/usr/bin/env bash\n[[ " $* " != *" handoff-standing "* ]] || case "$(grep -c '"'"' handoff-standing '"'"' "$STUB_DIR/workflow-state.args" 2>/dev/null)" in\n'
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
fleet_case() { # NAME
  new_case "$1"
  printf 'gh-1\ngh-2\nKEN-10\n' > "$STUB_DIR/windows.txt"
  printf '⏺ working on it\n' > "$STUB_DIR/pane-KEN-10.txt"
  printf 'ssh\n' > "$STUB_DIR/cmd-KEN-10.txt"
  remote_disk "$STUB_DIR/remote"
  write_state "$STUB_DIR/state.json" "$(lane_record issue-1 gh-1 '' /w/issue-1 running)" \
    "$(lane_record KEN-10 KEN-10 "$FIXTURE_HOST" "$REMOTE_ROOT" running)" "$(lane_record issue-3 gh-3 '' /w/issue-3 done)"
  swap_state '2) unlink "$STUB_DIR/state.json" ;;'
  err="$TMP_ROOT/e-$1"
  out="$(run_watch OVERSEE_WATCH_WORKFLOW_STATE="$STUB_DIR/swap-state.sh" \
    LANE_HOST_STUB_LOG="$STUB_DIR/host.log" LANE_HOST_STUB_DIR="$STUB_DIR/remote" -- --max-loops 1 \
    --repeat 0 --state "$STUB_DIR/state.json" 2>"$err" </dev/null)" && rc=0 || rc=$?
  REPEAT_ITEMS="$(awk '{ for (i = 1; i < NF; i++) if ($i == "handoff-standing") { printf "%s%s", sep, $(i + 1); sep = " " } }' "$STUB_DIR/workflow-state.args")"
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
assert_eq "$(grep '^oversee-watch: fleet-read ' "$err")" "oversee-watch: fleet-read items=2 windows=2 hosted=1 parked=0 dropped=1 path=$STUB_DIR/state.json" \
  "the set the passes carry is named once, with the done record counted as dropped, and not again while it stands" "$err"

STATE_READ_SCRIPTS="$(mutant_scripts state-open-mutant/orch oversee-watch)" || exit 1
ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/state-open-mutant/github"
mutate_file "$STATE_READ_SCRIPTS/oversee-watch" '    die state-unreadable "" "option=--state" "path=$STATE_FILE"' \
  '    : die state-unreadable "" "option=--state" "path=$STATE_FILE"; exit 1'
WATCH_BIN="$STATE_READ_SCRIPTS/oversee-watch" fleet_case repeat_state_read_mutant
assert_eq "$rc" "1" "control: replacing the state refusal changes the removal exit" "$err"
assert_not_contains "$(cat "$err")" "oversee-watch: state-unreadable option=--state" \
  "control: replacing the state refusal loses the named removal refusal" "$err"

# A parked record: lane-close --park stopped its sandbox with the disk kept
# while its pull request waited for the queue. The watch carries it for the
# merged check alone, never reads its stopped disk, and on the merge of the
# pull request its record names, in that repository, prints parked-merged for
# the overseer's relaunch and closes nothing.
parked_record() { # ITEM HOST MAIL_ROOT PR [REPO]
  lane_record "$1" "" "$2" "$3" parked | jq -c --argjson pr "$4" --arg repo "${5:-owner/repo}" '.parked = {pr: $pr, head: "abc123", repo: $repo, at: "2026-09-20T00:00:00Z"}'
}
# The fleet: one running lane with a window and one parked lane whose pull
# request 2 on branch issue-2 is the park's.
parked_fleet() { # NAME
  new_case "$1"
  printf 'gh-1\n' > "$STUB_DIR/windows.txt"
  write_state "$STUB_DIR/state.json" "$(lane_record issue-1 gh-1 '' /w/issue-1 running)" \
    "$(parked_record issue-2 /srv/provider /srv/lane/issue-2 2)"
  err="$TMP_ROOT/e-$1"
}
parked_run() { # [ENV=VAL...] -- [ARGS...]
  out="$(run_watch ORCH_LANE_HOST="$FIXTURE_HOST" LANE_HOST_STUB_LOG="$STUB_DIR/host.log" "$@" \
    --since 2026-09-19T00:00:00Z --state "$STUB_DIR/state.json" 2>"$err" </dev/null)" && rc=0 || rc=$?
  EVENTS="$(awk '/^EVENT / { printf "%s%s", sep, $2 " " $3; sep = "," }' <<<"$out")"
  HOST_VERBS="$(awk '{ printf "%s%s", sep, $1 " " $3; sep = "," }' "$STUB_DIR/host.log" 2>/dev/null || true)"
  CLOSES="$(grep -c . "$STUB_DIR/lane-close.args" 2>/dev/null || true)"
}
parked_case() { # NAME [ENV=VAL...]
  local name="$1"
  shift
  parked_fleet "$name"
  printf '[{"number": 2, "headRefName": "issue-2", "mergedAt": "2026-09-20T00:00:00Z"}]\n' > "$STUB_DIR/merged.json"
  parked_run "$@" --
}
parked_case parked_merged
assert_eq "rc=$rc events=$EVENTS host=$HOST_VERBS closes=${CLOSES:-0} status=$(jq -r '.lanes[] | select(.item == "issue-2") | .status' "$STUB_DIR/state.json")" \
  "rc=0 events=merged 2,parked-merged issue-2 host= closes=0 status=parked" \
  "a parked record's merge is reported and handed on, with no close, no read of the stopped disk and the record left parked" "$err"
assert_eq "$(grep '^EVENT parked-merged ' <<<"$out")" "EVENT parked-merged issue-2 pr=2 repo=owner/repo" \
  "the hand names the item, the pull request and the repository" "$err"
assert_contains "$(cat "$err")" "oversee-watch: fleet-read items=1 windows=1 hosted=0 parked=1 dropped=1" \
  "the parked record is carried as parked, not as a running item" "$err"
# The same pass again: the merged row is committed, so the merge is not news
# again, but the record still reads parked, so the next heartbeat hands it on
# again: a relaunch refused, or an overseer gone after the first hand, is
# named until the relaunch rewrites the record.
parked_run --
assert_eq "events=$EVENTS closes=${CLOSES:-0}" "events=parked-merged issue-2,heartbeat loops=2 closes=0" \
  "a record still parked over its already-handed merge is named again at the heartbeat, and the merge is not reported again" "$err"
assert_eq "$(grep '^EVENT parked-merged ' <<<"$out")" "EVENT parked-merged issue-2 pr=2 repo=owner/repo" \
  "the repeated hand is spelled as the first" "$err"
# The must-fail control for the repeat: the heartbeat's hand removed.
HAND_MUTANT_DIR="$TMP_ROOT/parked-hand-mutant"
HAND_MUTANT="$(mutant_scripts parked-hand-mutant/orch oversee-watch)/oversee-watch" || exit 1
ln -s "$REPO_ROOT/skills/github" "$HAND_MUTANT_DIR/github"
mutate_file "$HAND_MUTANT" "  [[ -z \"\$hands\" ]] || printf '%s\\n' \"\$hands\"" '  :'
WATCH_BIN="$HAND_MUTANT" parked_run --
assert_eq "events=$EVENTS" "events=heartbeat loops=2" \
  "control: with the heartbeat's hand removed the record left parked over its merge is silent" "$err"
# A row read that fails at the heartbeat ends the run naming the merged row,
# never a heartbeat with the hand dropped. The plant fails the read; its
# must-fail control is the same plant with the read's own return removed.
owed_read_mutant() { # NAME NEW, sets OWED_READ_BIN
  OWED_READ_BIN="$(mutant_scripts "$1/orch" oversee-watch)/oversee-watch" || exit 1
  ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/$1/github"
  mutate_file "$OWED_READ_BIN" '    row="$(lane_row_get merged "$1" "${PARKED_ITEMS[$i]}")" || return 1' "$2"
}
owed_read_mutant parked-owed-read-fail '    row="$(exit 1)" || return 1'
WATCH_BIN="$OWED_READ_BIN" parked_run --
assert_eq "rc=$rc events=$EVENTS note=$(grep -c "^oversee-watch: state-read-failed path=.* row=merged\$" "$err" || true)" "rc=2 events= note=1" \
  "a failed merged-row read at the heartbeat exits 2 naming the row, with no parked-merged line" "$err"
owed_read_mutant parked-owed-read-open '    row="$(exit 1)"'
WATCH_BIN="$OWED_READ_BIN" parked_run --
assert_eq "rc=$rc events=$EVENTS" "rc=0 events=heartbeat loops=2" \
  "control: with the read's return removed the failed read drops the hand and the heartbeat exits 0" "$err"
# The relaunch rewrites the record stopped and drops `parked`: the repeat ends.
jq '(.lanes[] | select(.item == "issue-2")) |= (.status = "stopped" | del(.parked))' "$STUB_DIR/state.json" > "$STUB_DIR/state.next" && mv -- "$STUB_DIR/state.next" "$STUB_DIR/state.json"
parked_run --
assert_eq "events=$EVENTS" "events=heartbeat loops=2" \
  "a record the relaunch rewrote stopped is handed on no more" "$err"
# The must-fail control: the close restored where the hand is printed.
PARKED_MUTANT_DIR="$TMP_ROOT/parked-mutant"
PARKED_MUTANT="$(mutant_scripts parked-mutant/orch oversee-watch)/oversee-watch" || exit 1
ln -s "$REPO_ROOT/skills/github" "$PARKED_MUTANT_DIR/github"
mutate_file "$PARKED_MUTANT" '    parked_merged_line "$item" "$PARKED_KEY"' '    close_hosted_lane "$item"'
parked_fleet parked_merged_mutant
printf '[{"number": 2, "headRefName": "issue-2", "mergedAt": "2026-09-20T00:00:00Z"}]\n' > "$STUB_DIR/merged.json"
WATCH_BIN="$PARKED_MUTANT" parked_run --
assert_eq "events=$EVENTS closes=${CLOSES:-0}" "events=merged 2,lane-closed issue-2 closes=1" \
  "control: with the close restored the parked merge runs lane-close and prints no parked-merged" "$err"

# Two parked records whose recorded pull requests both merged: each is handed
# on at the merge and again at the heartbeat, not the first record alone.
parked_pair_case() { # NAME [ENV=VAL...]
  local name="$1" pair
  shift
  parked_fleet "$name"
  pair="$(parked_record issue-4 /srv/provider /srv/lane/issue-4 4)" || exit 1
  jq --argjson rec "$pair" '.lanes += [$rec]' "$STUB_DIR/state.json" > "$STUB_DIR/state.next" && mv -- "$STUB_DIR/state.next" "$STUB_DIR/state.json"
  printf '[{"number": 2, "headRefName": "issue-2", "mergedAt": "2026-09-20T00:00:00Z"}, {"number": 4, "headRefName": "issue-4", "mergedAt": "2026-09-20T00:00:00Z"}]\n' > "$STUB_DIR/merged.json"
  parked_run "$@" --
}
pair_hands() { awk '/^EVENT parked-merged / { printf "%s%s", sep, $0; sep = "," }' <<<"$out"; }
PAIR_BOTH="EVENT parked-merged issue-2 pr=2 repo=owner/repo,EVENT parked-merged issue-4 pr=4 repo=owner/repo"
parked_pair_case parked_merged_pair
assert_eq "rc=$rc events=$EVENTS hands=$(pair_hands)" "rc=0 events=merged 2,parked-merged issue-2,merged 4,parked-merged issue-4 hands=$PAIR_BOTH" \
  "two parked records whose pull requests both merged are each handed on at the merge" "$err"
parked_run --
assert_eq "events=$EVENTS hands=$(pair_hands)" "events=parked-merged issue-2,parked-merged issue-4,heartbeat loops=2 hands=$PAIR_BOTH" \
  "two records still parked over their handed merges are each named again at the heartbeat" "$err"
# The must-fail controls: each loop cut to the first parked record.
FIRST_MUTANT="$(mutant_scripts parked-first-mutant/orch oversee-watch)/oversee-watch" || exit 1
ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/parked-first-mutant/github"
mutate_file "$FIRST_MUTANT" '    [[ "${PARKED_ITEMS[$i]}" != "$1" ]] || { PARKED_KEY="${PARKED_KEYS[$i]}"; return 0; }' \
  '    [[ "${PARKED_ITEMS[0]}" != "$1" ]] || { PARKED_KEY="${PARKED_KEYS[0]}"; return 0; }'
WATCH_BIN="$FIRST_MUTANT" parked_pair_case parked_merged_pair_first
assert_eq "events=$EVENTS" "events=merged 2,parked-merged issue-2,merged 4" \
  "control: with the parked lookup cut to the first record the second record's merge hands nothing on" "$err"
owed_read_mutant parked-owed-first '    row="$(lane_row_get merged "$1" "${PARKED_ITEMS[0]}")" || return 1'
parked_pair_case parked_merged_pair_owed_first
WATCH_BIN="$OWED_READ_BIN" parked_run --
assert_eq "events=$EVENTS" "events=parked-merged issue-2,heartbeat loops=2" \
  "control: with the heartbeat's row read cut to the first record the second record is not named again" "$err"

# --item naming a lane the state records as parked: the record wins, as a
# running record does, so the item is carried once, for the merged check alone.
parked_fleet parked_item_given
printf '[{"number": 2, "headRefName": "issue-2", "mergedAt": "2026-09-20T00:00:00Z"}]\n' > "$STUB_DIR/merged.json"
parked_run -- --item issue-2
assert_eq "rc=$rc events=$EVENTS" "rc=0 events=merged 2,parked-merged issue-2" \
  "a hand-passed item the state records as parked is read once per pass, so its merge and its hand print once" "$err"
assert_contains "$(cat "$err")" "oversee-watch: fleet-read items=1 windows=1 hosted=0 parked=1" \
  "the parked record wins over the --item entry and is carried as parked, not as a running item" "$err"

# The hand is owed to the pull request the park judged and to no other on
# the branch's name: another number, or the same number in another
# repository, is reported as any item's merge is and hands nothing on.
parked_fleet parked_other_pr
printf '[{"number": 3, "headRefName": "issue-2", "mergedAt": "2026-09-20T00:00:00Z"}]\n' > "$STUB_DIR/merged.json"
parked_run --
assert_eq "rc=$rc events=$EVENTS host=$HOST_VERBS note=$(grep -c '^oversee-watch: parked-merge-unmatched item=issue-2 recorded=owner/repo#2 seen=owner/repo#3$' "$err" || true)" "rc=0 events=merged 3 host= note=1" \
  "another pull request merged on the parked branch's name is reported, named as not the record's, and hands nothing on" "$err"
# The heartbeat hands on only a record whose own key is in the merged row:
# another number committed there is owed nothing.
parked_run --
assert_eq "events=$EVENTS" "events=heartbeat loops=2" \
  "a record still parked with another pull request's merge committed on its branch is not handed on at the heartbeat" "$err"
# The must-fail control: the heartbeat's membership test removed.
OWED_MUTANT_DIR="$TMP_ROOT/parked-owed-mutant"
OWED_MUTANT="$(mutant_scripts parked-owed-mutant/orch oversee-watch)/oversee-watch" || exit 1
ln -s "$REPO_ROOT/skills/github" "$OWED_MUTANT_DIR/github"
mutate_file "$OWED_MUTANT" '    [[ " $row " == *" ${PARKED_KEYS[$i]} "* ]] || continue' '    :'
WATCH_BIN="$OWED_MUTANT" parked_run --
assert_eq "events=$EVENTS" "events=parked-merged issue-2,heartbeat loops=2" \
  "control: with the membership test removed another number's merge hands the parked record on at the heartbeat" "$err"
# A parked pull request the key search returns but whose title and body name
# the item in neither its scope nor a Closes line is the item's by its
# recorded number alone, in the repository the record names: owner/other's
# #2 mentions issue-2 the same way and is not the item's.
parked_number_case() { # NAME [WATCH_BIN]
  parked_fleet "$1"
  printf '[{"number": 2, "headRefName": "claude/fix-p", "title": "chore: p", "body": "Follow-up to issue-2.", "mergedAt": "2026-09-20T00:00:00Z"}]\n' > "$STUB_DIR/merged.json"
  printf '[{"number": 2, "headRefName": "claude/fix-q", "title": "chore: q", "body": "Follow-up to issue-2.", "mergedAt": "2026-09-20T00:00:00Z"}]\n' > "$STUB_DIR/merged.owner_other.json"
  WATCH_BIN="${2:-${WATCH_BIN:-}}" parked_run -- --repo owner/repo --repo owner/other
}
parked_number_case parked_number_only
assert_eq "rc=$rc events=$EVENTS merged=$(grep '^EVENT merged ' <<<"$out")" \
  "rc=0 events=merged 2,parked-merged issue-2 merged=EVENT merged 2 issue-2 owner/repo" \
  "a parked pull request only its recorded number claims is the item's merge and is handed on, in its own repository alone" "$err"
# Rows, tab-separated: case, oversee-watch text, its replacement, want.
while IFS=$'\t' read -r name old new want; do
  bin="$(mutant_scripts "parked-number-$name/orch" oversee-watch)/oversee-watch" || exit 1
  ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/parked-number-$name/github"
  mutate_file "$bin" "$old" "$new"
  parked_number_case "parked_number_$name" "$bin"
  assert_eq "rc=$rc events=$EVENTS" "$want" "control: $name" "$err"
done <<'ROWS'
pr_null	|| pr="${PARKED_KEY##*#}"	|| pr=null	rc=0 events=heartbeat loops=2
any_repo	[[ "${PARKED_KEY%#*}" != "$repo" ]] ||	[[ -z "$PARKED_KEY" ]] ||	rc=0 events=merged 2,merged 2,parked-merged issue-2
ROWS
# The record carries the repository as gh repo view spells it; the watch's
# --repo set is lowercased on entry, and GitHub reads both the same.
parked_fleet parked_mixed_case_repo
jq '(.lanes[] | select(.item == "issue-2")).parked.repo = "Owner/Repo"' "$STUB_DIR/state.json" > "$STUB_DIR/state.next" && mv -- "$STUB_DIR/state.next" "$STUB_DIR/state.json"
printf '[{"number": 2, "headRefName": "issue-2", "mergedAt": "2026-09-20T00:00:00Z"}]\n' > "$STUB_DIR/merged.json"
parked_run -- --repo owner/repo
assert_eq "rc=$rc events=$EVENTS" "rc=0 events=merged 2,parked-merged issue-2" \
  "a record spelling the repository Owner/Repo is handed on at the merge the watch lists under owner/repo" "$err"
parked_fleet parked_other_repo
printf '[]\n' > "$STUB_DIR/merged.json"
printf '[{"number": 2, "headRefName": "issue-2", "mergedAt": "2026-09-20T00:00:00Z"}]\n' > "$STUB_DIR/merged.other_repo.json"
parked_run -- --repo owner/repo --repo other/repo
assert_eq "rc=$rc events=$EVENTS host=$HOST_VERBS" "rc=0 events=merged 2 host=" \
  "the same pull request number merged in another repository is reported and hands nothing on" "$err"
parked_run -- --repo owner/repo --repo other/repo
assert_eq "events=$EVENTS" "events=heartbeat loops=2" \
  "a record still parked with its number merged in another repository is not handed on at the heartbeat" "$err"
WATCH_BIN="$OWED_MUTANT" parked_run -- --repo owner/repo --repo other/repo
assert_eq "events=$EVENTS" "events=parked-merged issue-2,heartbeat loops=2" \
  "control: with the membership test removed another repository's merge hands the parked record on at the heartbeat" "$err"
# A pull request still in the queue: nothing merged, nothing handed on.
parked_fleet parked_queued
printf '[]\n' > "$STUB_DIR/merged.json"
parked_run --
parked_run --
assert_eq "events=$EVENTS" "events=heartbeat loops=2" \
  "a record still parked while its pull request is queued is not handed on at the heartbeat" "$err"
WATCH_BIN="$OWED_MUTANT" parked_run --
assert_eq "events=$EVENTS" "events=parked-merged issue-2,heartbeat loops=2" \
  "control: with the membership test removed a queued record is handed on at the heartbeat" "$err"

custom_close_case() { # NAME
  local name="$1" custom
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
    "$(lane_record issue-2 gh-2 "$FIXTURE_HOST" /srv/lane/issue-2 running)"
  printf 'running\n' > "$STUB_DIR/harness-state"
  repeat_sleep_stub \
    'n=0; [[ ! -f "$STUB_DIR/repeat.calls" ]] || n="$(cat "$STUB_DIR/repeat.calls")"' \
    'n=$((n + 1)); printf "%s\n" "$n" > "$STUB_DIR/repeat.calls"' \
    'case "$n" in 1) rm -rf -- "$STUB_DIR/remote/srv/lane/issue-2"; printf "exited\n" > "$STUB_DIR/harness-state" ;; 2) unlink "$STUB_DIR/custom/workflow-state-oversee.json" ;; esac'
  err="$TMP_ROOT/e-$name"
  out="$(run_watch ORCH_LANE_HOST="$FIXTURE_HOST" LANE_HOST_STUB_LOG="$STUB_DIR/host.log" \
    LANE_HOST_STUB_DIR="$STUB_DIR/remote" LANE_HOST_STUB_HARNESS_STATE_FILE="$STUB_DIR/harness-state" \
    PATH="$STUB_DIR/bin:$TMP_ROOT/bin:$PATH" -- --max-loops 1 \
    --since 2026-09-19T00:00:00Z --repeat 0 --state "$custom/workflow-state-oversee.json" 2>"$err" </dev/null)" && rc=0 || rc=$?
}
custom_close_case repeat_state_custom_close
assert_eq "$rc" "2" "the custom-state repeat run ends after its state is removed" "$err"
assert_eq "$(cat "$STUB_DIR/lane-close.args")" "--state-dir $STUB_DIR/custom issue-2" \
  "repeat mode gives automatic close the explicit fleet state directory" "$err"
assert_eq "$(grep -cF -- "--state-dir $STUB_DIR/custom handoff-standing issue-2" "$STUB_DIR/workflow-state.args" || true)" "0" \
  "the fleet directory does not replace the hosted item's workflow-state directory" "$err"

# A fleet closed out to no running record is named, not watched in silence:
# one done record reads as items=0 with the record counted dropped, the pass
# still heartbeats, and the run ends when the sleep stub takes the state away.
new_case repeat_state_all_done
write_state "$STUB_DIR/state.json" "$(lane_record issue-3 gh-3 '' /w/issue-3 done)"
repeat_sleep_stub 'unlink "$STUB_DIR/state.json"'
err="$TMP_ROOT/e-repeat_state_all_done"
out="$(run_watch PATH="$STUB_DIR/bin:$TMP_ROOT/bin:$PATH" -- --max-loops 1 --repeat 0 --state "$STUB_DIR/state.json" 2>"$err" </dev/null)" && rc=0 || rc=$?
assert_eq "rc=$rc note=$(grep '^oversee-watch: fleet-read ' "$err" | sed 's/ path=.*//' | paste -sd '|' -) unreadable=$(grep -c '^oversee-watch: state-unreadable option=--state' "$err") events=$(awk '/^EVENT / { printf "%s%s", sep, $2; sep = " " }' <<<"$out")" \
  "rc=2 note=oversee-watch: fleet-read items=0 windows=0 hosted=0 parked=0 dropped=1 unreadable=1 events=heartbeat" \
  "a state whose every record is done is named as an empty fleet, heartbeats, and ends on the state taken away" "$err"
# A run handed --state with no --repeat has no wrapper to have named its fleet,
# so its own first read names it. One line, not two: the loop below re-reads
# the same set and a read that changes nothing says nothing.
standalone_read_case() { # NAME
  new_case "$1"
  write_state "$STUB_DIR/state.json" "$(lane_record issue-1 '' '' /w/issue-1 running)"
  err="$TMP_ROOT/e-$1"
  out="$(run_watch PATH="$STUB_DIR/bin:$TMP_ROOT/bin:$PATH" -- --max-loops 1 \
    --state "$STUB_DIR/state.json" 2>"$err" </dev/null)" && rc=0 || rc=$?
  # A miss is an answer here, and under pipefail an unguarded grep would abort
  # instead.
  STANDALONE_NOTES="$(grep '^oversee-watch: fleet-read ' "$err" | sed 's/ path=.*//' | paste -sd '|' - || true)"
  STANDALONE_EVENTS="$(awk '/^EVENT / { printf "%s%s", sep, $2; sep = " " }' <<<"$out")"
}
standalone_read_case standalone_state_first_read
assert_eq "rc=$rc note=$STANDALONE_NOTES events=$STANDALONE_EVENTS" \
  "rc=0 note=oversee-watch: fleet-read items=1 windows=0 hosted=0 parked=0 dropped=0 events=heartbeat" \
  "a standalone --state run names the fleet its own first read found" "$err"
# A repeat delay that cannot be slept ends the watch with its cause named,
# never with a bare exit status: the stub fails the delay after the first pass.
new_case repeat_sleep_fails
write_state "$STUB_DIR/state.json" "$(lane_record issue-1 '' '' /w/issue-1 running)"
repeat_sleep_stub 'exit 3'
err="$TMP_ROOT/e-repeat_sleep_fails"
out="$(run_watch PATH="$STUB_DIR/bin:$TMP_ROOT/bin:$PATH" -- --max-loops 1 --repeat 0 --state "$STUB_DIR/state.json" 2>"$err" </dev/null)" && rc=0 || rc=$?
assert_eq "rc=$rc named=$(grep -c '^oversee-watch: sleep-failed secs=0$' "$err") events=$(awk '/^EVENT / { printf "%s%s", sep, $2; sep = " " }' <<<"$out")" \
  "rc=2 named=1 events=heartbeat" "a failed repeat delay ends the watch as sleep-failed after the pass it followed" "$err"
# The delay between two passes is the mail interval where that is shorter,
# so a note sent right after a run ends is read within one interval; a pass
# that failed waits the whole delay. DELAYS is the one delay the stub was
# asked for, after a pass that ended quietly or, with every PR list failing,
# exited 2.
repeat_delay_case() { # NAME ok|failed
  new_case "$1"
  write_state "$STUB_DIR/state.json" "$(lane_record issue-1 '' '' /w/issue-1 running)"
  [[ "$2" == ok ]] || touch "$STUB_DIR/list-fail"
  repeat_sleep_stub 'printf "%s\n" "$1" >> "$STUB_DIR/repeat.delays"' 'exit 3'
  run_watch PATH="$STUB_DIR/bin:$TMP_ROOT/bin:$PATH" ORCH_WATCH_MAIL_INTERVAL=5 -- --max-loops 1 \
    --repeat 60 --state "$STUB_DIR/state.json" >/dev/null 2>"$TMP_ROOT/e-$1" </dev/null || true
  DELAYS="$(paste -sd ' ' - <"$STUB_DIR/repeat.delays" 2>/dev/null || echo none)"
}
repeat_delay_case repeat_delay_mail ok
assert_eq "$DELAYS" "5" "the repeat delay after a pass is the mail interval where that is shorter" "$TMP_ROOT/e-repeat_delay_mail"
repeat_delay_case repeat_delay_failed failed
assert_eq "$DELAYS" "60" "a pass that exited 2 waits the whole repeat delay" "$TMP_ROOT/e-repeat_delay_failed"

# One lane's mailbox fails and stays failed: the run that reports it exits 2
# and waits the whole delay, and the run after it, the failure unchanged and
# quiet, fails nothing, so the delay before the next is the mail interval and
# another lane's note waits no longer.
standing_delay_case() { # NAME
  local root="$TMP_ROOT/standing/$1/ken-12"
  new_case "$1"
  mkdir -p "$root/tmp/lane-mail/KEN-12"
  git -C "$root" init -q
  printf '{"id":"s-1","kind":"notice","at":"t","text":"x"}\n' > "$root/tmp/lane-mail/KEN-12/to-overseer.jsonl"
  chmod 000 "$root/tmp/lane-mail/KEN-12/to-overseer.jsonl"
  write_state "$STUB_DIR/state.json" "$(lane_record KEN-12 '' '' "$root" running)"
  repeat_sleep_stub 'printf "%s\n" "$1" >> "$STUB_DIR/repeat.delays"' \
    '[[ "$(grep -c . "$STUB_DIR/repeat.delays")" -lt 2 ]] || exit 3'
  run_watch PATH="$STUB_DIR/bin:$TMP_ROOT/bin:$PATH" ORCH_WATCH_MAIL_INTERVAL=5 -- --max-loops 1 \
    --repeat 60 --state "$STUB_DIR/state.json" >/dev/null 2>"$TMP_ROOT/e-$1" </dev/null || true
  chmod 644 "$root/tmp/lane-mail/KEN-12/to-overseer.jsonl"
  DELAYS="$(paste -sd ' ' - <"$STUB_DIR/repeat.delays" 2>/dev/null || echo none)"
}
standing_delay_case repeat_delay_standing
assert_eq "$DELAYS" "60 5" "a lane failure still standing fails no later run, so the delay after it is the mail interval" \
  "$TMP_ROOT/e-repeat_delay_standing"

# A local lane whose worktree sits outside the watch's own checkout has its
# mailbox read at the root its record carries, never in this checkout.
new_case repeat_state_local_root
LOCAL_ROOT="$TMP_ROOT/elsewhere/ken-11"
mkdir -p "$LOCAL_ROOT/tmp/lane-mail/KEN-11"
printf 'step: dev round 1\n' > "$LOCAL_ROOT/tmp/lane-status-KEN-11.md"
git -C "$LOCAL_ROOT" init -q
printf '{"id":"local-1","kind":"ask","at":"t","text":"Local question"}\n' > "$LOCAL_ROOT/tmp/lane-mail/KEN-11/to-overseer.jsonl"
write_state "$STUB_DIR/state.json" "$(lane_record KEN-11 '' '' "$LOCAL_ROOT" running)"
repeat_sleep_stub 'unlink "$STUB_DIR/state.json"'
err="$TMP_ROOT/e-repeat_state_local_root"
out="$(run_watch PATH="$STUB_DIR/bin:$TMP_ROOT/bin:$PATH" -- --max-loops 1 --repeat 0 --state "$STUB_DIR/state.json" 2>"$err" </dev/null)" && rc=0 || rc=$?
assert_eq "rc=$rc events=$(awk '/^EVENT / { printf "%s%s", sep, $2; sep = " " }' <<<"$out") asked=$(grep -c '^EVENT lane-question KEN-11 local-1' <<<"$out" || true)" \
  "rc=2 events=lane-question asked=1" "a local record's mail_root outside this checkout is where its mailbox is read" "$err"
# A --hosted entry passed by hand for an item the state also records hosted
# is merged by item, the state's root winning: the pass is not refused as
# hosted-duplicate, and the ask is read at the recorded root.
new_case repeat_state_hosted_merge
printf 'gh-1\ngh-2\nKEN-10\n' > "$STUB_DIR/windows.txt"
printf '⏺ working on it\n' > "$STUB_DIR/pane-KEN-10.txt"
printf 'ssh\n' > "$STUB_DIR/cmd-KEN-10.txt"
remote_disk "$STUB_DIR/remote"
write_state "$STUB_DIR/state.json" "$(lane_record KEN-10 KEN-10 "$FIXTURE_HOST" "$REMOTE_ROOT" running)"
repeat_sleep_stub 'unlink "$STUB_DIR/state.json"'
err="$TMP_ROOT/e-repeat_state_hosted_merge"
out="$(run_watch LANE_HOST_STUB_LOG="$STUB_DIR/host.log" LANE_HOST_STUB_DIR="$STUB_DIR/remote" \
  PATH="$STUB_DIR/bin:$TMP_ROOT/bin:$PATH" -- --max-loops 1 --repeat 0 --state "$STUB_DIR/state.json" --hosted KEN-10=/srv/other 2>"$err" </dev/null)" && rc=0 || rc=$?
assert_eq "rc=$rc dup=$(grep -c 'hosted-duplicate' "$err") carried=$(grep -o '^oversee-watch: fleet-read items=[0-9]* windows=[0-9]* hosted=[0-9]*' "$err" | head -1) events=$(awk '/^EVENT / { printf "%s%s", sep, $2; sep = " " }' <<<"$out")" \
  "rc=2 dup=0 carried=oversee-watch: fleet-read items=1 windows=1 hosted=1 events=lane-question" \
  "a hand-passed hosted entry and the state's record for one item merge as one, the state's root read" "$err"
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
# A hosted lane joining between passes is carried by the next pass with no
# restart: pass 1 sees the local lane alone and its handoff read records the
# hosted lane, pass 2 reads that lane's ask, pass 3 finds it drained, and the
# read of pass 4 ends the run. A sleep stub ends a watch that never re-reads
# the state, which would otherwise run for ever.
joins_case() { # NAME
  new_case "$1"
  repeat_sleep_stub 'n=0; [[ ! -f "$STUB_DIR/sleep.calls" ]] || n="$(cat "$STUB_DIR/sleep.calls")"' \
    'n=$((n + 1)); printf "%s" "$n" > "$STUB_DIR/sleep.calls"' \
    '[[ "$n" -lt 4 ]] || kill -TERM "$PPID"'
  printf 'gh-1\ngh-2\nKEN-10\n' > "$STUB_DIR/windows.txt"
  printf '⏺ working on it\n' > "$STUB_DIR/pane-KEN-10.txt"
  printf 'ssh\n' > "$STUB_DIR/cmd-KEN-10.txt"
  remote_disk "$STUB_DIR/remote"
  write_state "$STUB_DIR/state.json" "$(lane_record issue-1 gh-1 '' /w/issue-1 running)"
  lane_record KEN-10 KEN-10 "$FIXTURE_HOST" "$REMOTE_ROOT" running > "$STUB_DIR/hosted.json"
  swap_state "'' | 0) jq --slurpfile h \"\$STUB_DIR/hosted.json\" '.lanes += \$h' \"\$STUB_DIR/state.json\" > \"\$STUB_DIR/state.next\" && mv \"\$STUB_DIR/state.next\" \"\$STUB_DIR/state.json\" ;;" \
    '3) unlink "$STUB_DIR/state.json" ;;'
  err="$TMP_ROOT/e-$1"
  out="$(run_watch OVERSEE_WATCH_WORKFLOW_STATE="$STUB_DIR/swap-state.sh" \
    LANE_HOST_STUB_LOG="$STUB_DIR/host.log" LANE_HOST_STUB_DIR="$STUB_DIR/remote" PATH="$STUB_DIR/bin:$TMP_ROOT/bin:$PATH" -- --max-loops 1 \
    --repeat 0 --state "$STUB_DIR/state.json" 2>"$err" </dev/null)" && rc=0 || rc=$?
  REPEAT_EVENTS="$(awk '/^EVENT / { printf "%s%s", sep, $2; sep = " " }' <<<"$out")"
}
joins_case repeat_state_hosted_joins
assert_eq "$rc" "2" "the joining run ends on the state it cannot read" "$err"
assert_eq "$REPEAT_EVENTS" "heartbeat lane-question heartbeat" "a hosted lane recorded between passes is read by the next pass, with no restart" "$err"
assert_eq "$(grep '^oversee-watch: fleet-read ' "$err" | sed 's/ path=.*//' | paste -sd '|' -)" \
  "oversee-watch: fleet-read items=1 windows=1 hosted=0 parked=0 dropped=0|oversee-watch: fleet-read items=2 windows=2 hosted=1 parked=0 dropped=0" \
  "the set is named again on the re-read that changes it, and not on the one that does not" "$err"
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
    lane_record KEN-10 KEN-10 "$FIXTURE_HOST" "$REMOTE_ROOT" running > "$STUB_DIR/hosted.json"
    swap_state "'' | 0) jq --slurpfile h \"\$STUB_DIR/hosted.json\" '.lanes += \$h' \"\$STUB_DIR/state.json\" > \"\$STUB_DIR/state.next\" && mv \"\$STUB_DIR/state.next\" \"\$STUB_DIR/state.json\" ;;"
  else
    write_state "$STUB_DIR/state.json" "$(lane_record issue-1 gh-1 '' /w/issue-1 running)" \
      "$(lane_record KEN-10 KEN-10 "$FIXTURE_HOST" "$REMOTE_ROOT" running)"
    unlink "$STUB_DIR/remote$REMOTE_ROOT/tmp/lane-mail/KEN-10/to-overseer.jsonl"
    swap_state "'' | 0) jq '(.lanes[] | select(.item == \"KEN-10\") | .status) = \"done\"' \"\$STUB_DIR/state.json\" > \"\$STUB_DIR/state.next\" && mv \"\$STUB_DIR/state.next\" \"\$STUB_DIR/state.json\" ;;"
  fi
  repeat_sleep_stub 'unlink "$STUB_DIR/state.json"'
  err="$TMP_ROOT/e-$1"
  out="$(WATCH_BIN="${3:-}" run_watch OVERSEE_WATCH_WORKFLOW_STATE="$STUB_DIR/swap-state.sh" \
    LANE_HOST_STUB_LOG="$STUB_DIR/host.log" LANE_HOST_STUB_DIR="$STUB_DIR/remote" PATH="$STUB_DIR/bin:$TMP_ROOT/bin:$PATH" \
    -- --max-loops 3 --repeat 0 --state "$STUB_DIR/state.json" 2>"$err" </dev/null)" && rc=0 || rc=$?
  MID_EVENTS="$(awk '/^EVENT / { printf "%s%s", sep, $2; sep = " " }' <<<"$out")"
  MID_ITEMS="$(awk '{ for (i = 1; i < NF; i++) if ($i == "handoff-standing") { printf "%s%s", sep, $(i + 1); sep = " " } }' "$STUB_DIR/workflow-state.args")"
  MID_MAIL_READS="$(grep -c -- '/tmp/lane-mail/KEN-10/to-overseer\.jsonl$' "$STUB_DIR/host.log" || true)"
}
mid_pass_case repeat_state_joins_mid_pass joins
assert_eq "$rc" "2" "the mid-pass run ends on the state it cannot read" "$err"
assert_eq "$MID_ITEMS" "issue-1 issue-1 KEN-10" "the loop after the record lands carries it, without the pass returning first" "$err"
assert_eq "$MID_EVENTS" "lane-question" "that loop reads the joined lane's ask, in the pass the first loop started" "$err"
assert_contains "$out" "EVENT lane-question KEN-10 remote-1" "the ask is read at the record's own root, on the record's host" "$err"
assert_eq "$(grep '^oversee-watch: fleet-read ' "$err" | sed 's/ path=.*//' | paste -sd '|' -)" \
  "oversee-watch: fleet-read items=1 windows=1 hosted=0 parked=0 dropped=0|oversee-watch: fleet-read items=2 windows=2 hosted=1 parked=0 dropped=0" \
  "the wrapper names the set it launched the pass with, and the pass names the set its own re-read changed" "$err"
# The other half: a record closed between two loops leaves that pass's fleet.
# The wrapper hands the pass only what argv gave it, so nothing outside the
# state puts the closed item back.
mid_pass_case repeat_state_departs_mid_pass departs
assert_eq "$rc" "2" "the departure run ends on the state it cannot read" "$err"
assert_eq "$MID_ITEMS" "issue-1 KEN-10 issue-1 issue-1" "the loops after the record closes no longer carry it, without the pass returning first" "$err"
assert_eq "$MID_MAIL_READS" "1" "the closed lane's mailbox is read in the loop that carried it and never again" "$err"
assert_eq "$MID_EVENTS" "heartbeat" "the closed lane produces no event after it leaves the fleet" "$err"
# Keep a closed record in the production reader to prove the mailbox counter
# detects reads after closure, while ignoring the numbering file beside it.
DEPARTS_MUTANT="$(mutant_scripts departs-mutant/orch oversee-watch)/oversee-watch" || exit 1
ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/departs-mutant/github"
mutate_file "$DEPARTS_MUTANT" '(.[] | select(running)' '(.[] | select(running or .status == "done")'
mid_pass_case repeat_state_departs_control departs "$DEPARTS_MUTANT"
assert_le 2 "$MID_MAIL_READS" "control: retaining the closed lane repeats reads of its actual mailbox" "$err"
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
# Repeat mode's one must-fail control: the parent's check of the pass set
# removed. The copy keeps orch's place in a skills tree, as the reducer
# mutant's does.
REPEAT_MUTANT_DIR="$TMP_ROOT/repeat-mutant"
REPEAT_MUTANT="$(mutant_scripts repeat-mutant/orch oversee-watch)/oversee-watch" || exit 1
ln -s "$REPO_ROOT/skills/github" "$REPEAT_MUTANT_DIR/github"
mutate_file "$REPEAT_MUTANT" '  check_item_set' '  :'
refused_case repeat_hosted_item_gone_mutant "$REPEAT_MUTANT" --hosted issue-2=host:/x
assert_contains "$REFUSED_KEYS" "oversee-watch: state-unreadable option=--state" "control: unchecked, the failing pass is followed by a sleep and another read" "$err"
refused_case repeat_repo_duplicate "" --repo owner/repo --repo Owner/Repo
assert_eq "$rc" "2" "a repeated --repo ends repeat mode" "$err"
assert_eq "$REFUSED_KEYS" "oversee-watch: repo-duplicate repo=Owner/Repo" "it ends on that refusal before any pass runs" "$err"
# A record's window across five passes: listed, gone, still gone, listed
# again, gone again. The handoff read counts passes as above and moves the
# window in and out of the tmux stub's list; after the fifth pass the state
# goes, and the run ends on it.
windows_case() { # NAME
  new_case "$1"
  write_state "$STUB_DIR/state.json" "$(lane_record issue-1 lane-x '' /w/issue-1 running)"
  printf 'gh-1\nlane-x\n' > "$STUB_DIR/windows.txt"
  printf '⏺ working on it\n' > "$STUB_DIR/pane-lane-x.txt"
  printf 'claude\n' > "$STUB_DIR/cmd-lane-x.txt"
  swap_state "'' | 0 | 3) printf 'gh-1\\n' > \"\$STUB_DIR/windows.txt\" ;;" \
    "2) printf 'gh-1\\nlane-x\\n' > \"\$STUB_DIR/windows.txt\" ;;" \
    '4) unlink "$STUB_DIR/state.json" ;;'
  err="$TMP_ROOT/e-$1"
  out="$(run_watch OVERSEE_WATCH_WORKFLOW_STATE="$STUB_DIR/swap-state.sh" -- --max-loops 1 \
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
# A pass that carries an absent window and fails before check_lanes reports
# nothing, so the absence rides on: pass 1's pr-watch fails, pass 2 reports
# window-gone, pass 3 leaves the window out, and the handoff read of pass 3
# takes the state away.
recovery_case() { # NAME
  new_case "$1"
  write_state "$STUB_DIR/state.json" "$(lane_record issue-1 lane-x '' /w/issue-1 running)"
  printf '1' > "$STUB_DIR/prwatch.rc.1"
  swap_state '1) unlink "$STUB_DIR/state.json" ;;'
  err="$TMP_ROOT/e-$1"
  out="$(run_watch OVERSEE_WATCH_WORKFLOW_STATE="$STUB_DIR/swap-state.sh" -- --max-loops 1 \
    --repeat 0 --state "$STUB_DIR/state.json" 2>"$err" </dev/null)" && rc=0 || rc=$?
  WINDOW_EVENTS="$(awk '/^EVENT / { printf "%s%s", sep, $2; sep = " " }' <<<"$out")"
  WINDOW_NOTES="$(grep -c '^oversee-watch: window-absent lane=lane-x$' "$err" || true)"
}
recovery_case repeat_window_after_failed_pass
assert_eq "$rc" "2" "the recovery run ends on the state" "$err"
assert_contains "$(cat "$err")" "oversee-watch: reducer-failed" "the pass carrying the first absence fails before check_lanes"
assert_eq "$WINDOW_EVENTS" "window-gone heartbeat" "the next pass still reports window-gone, and the one after leaves it out" "$err"
assert_eq "$WINDOW_NOTES" "1" "the absence is noted once across the failed pass and the one that reports it" "$err"
# A --skip-lane the caller passes beside --repeat reaches the pass, which
# re-reads the record naming that window: the window tmux does not list is
# left alone rather than reported gone every pass. The handoff read of pass 1
# takes the state away, so the next read ends the run.
caller_skip_case() { # NAME
  new_case "$1"
  write_state "$STUB_DIR/state.json" "$(lane_record issue-1 lane-x '' /w/issue-1 running)"
  swap_state '1) unlink "$STUB_DIR/state.json" ;;'
  err="$TMP_ROOT/e-$1"
  out="$(run_watch OVERSEE_WATCH_WORKFLOW_STATE="$STUB_DIR/swap-state.sh" -- --max-loops 1 \
    --repeat 0 --state "$STUB_DIR/state.json" --skip-lane lane-x 2>"$err" </dev/null)" && rc=0 || rc=$?
  WINDOW_EVENTS="$(awk '/^EVENT / { printf "%s%s", sep, $2; sep = " " }' <<<"$out")"
  WINDOW_NOTES="$(grep -c '^oversee-watch: window-absent lane=lane-x$' "$err" || true)"
}
caller_skip_case repeat_caller_skip_lane
assert_eq "$rc" "2" "the caller-skip run ends on the state it cannot read" "$err"
assert_eq "$WINDOW_EVENTS" "heartbeat heartbeat" "a caller's --skip-lane leaves the window unwatched in every pass, not reported gone" "$err"
assert_eq "$WINDOW_NOTES" "0" "the window the caller skipped is never noted absent" "$err"
# Repeat-mode refusals, `label|env|args|first stderr line|detail line
# holds`: each exits 2 with nothing on stdout, and a state-invalid refusal's
# third line, the tool detail under the explanation, carries the filter rule
# that refused it. %S is the case's stub
# directory, whose state.json holds one running lane at window lane-x,
# bad.json the JSON null, the one non-object jq indexes without complaint,
# nolanes.json a lanes object, and noitem.json a running record with no item.
# The sleep stub takes every state away, so a watch that carried a refused
# state past the read would end on the next read instead of looping.
refusal_case() { # LABEL ENV ARGS
  local label="$1" env="$2" args="$3"
  new_case repeat_refusal
  write_state "$STUB_DIR/state.json" "$(lane_record issue-1 lane-x '' /w/issue-1 running)"
  printf 'null\n' > "$STUB_DIR/bad.json"
  printf '{"lanes":{}}\n' > "$STUB_DIR/nolanes.json"
  printf '{"lanes":[{"window":"gh-9","status":"running"}]}\n' > "$STUB_DIR/noitem.json"
  repeat_sleep_stub 'rm -f "$STUB_DIR/state.json" "$STUB_DIR/bad.json" "$STUB_DIR/nolanes.json" "$STUB_DIR/noitem.json"'
  err="$TMP_ROOT/e-repeat-refusal"
  # shellcheck disable=SC2086
  out="$(run_watch PATH="$STUB_DIR/bin:$TMP_ROOT/bin:$PATH" $env -- ${args//%S/$STUB_DIR} 2>"$err" </dev/null)" && rc=0 || rc=$?
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

# --- 8d. ORCH_CONNECTED_REPOS adds watched repositories --------------------
# Each entry the setting lists is read after the --repo values, the items
# repository first, and an entry a --repo already names is read once. The
# reads proven are the merged lookup for the item and the heartbeat's open
# pull request list. The repeat row hands its pass a --repo for every
# repository the wrapper settled, and that pass reads the setting again and
# skips what those already name.
# connected_case NAME SETTING MODE [WATCH] — MODE is `repo` (--repo owner/repo),
# `default` (no --repo, `gh repo view` answering owner/repo), `repeat`
# (--repo owner/repo under --repeat over one running record for issue-5, the
# state taken away after the first pass) or `repeat-default` (`repeat` with no
# --repo, `gh repo view` answering owner/repo), each one long pass. SETTING
# `absent` sets nothing.
# Sets CONNECTED_MERGED and CONNECTED_OPEN to the repository of each merged
# lookup and each heartbeat open pull request line, in the order asked.
connected_case() {
  local name="$1" setting="$2" mode="$3" env_args=() args=()
  new_case "$name"
  printf '9\tissue-9\titems side\n' > "$STUB_DIR/open.owner_repo.txt"
  printf '77\tissue-9\tconsumer side\n' > "$STUB_DIR/open.other_repo.txt"
  [[ "$setting" == absent ]] || env_args+=("ORCH_CONNECTED_REPOS=$setting")
  case "$mode" in
    repo) args=(--repo owner/repo --max-loops 1 --since 2026-08-15T09:00:00Z --item issue-5) ;;
    default)
      printf 'owner/repo\n' > "$STUB_DIR/repoview.txt"
      args=(--no-repo --max-loops 1 --since 2026-08-15T09:00:00Z --item issue-5) ;;
    repeat)
      write_state "$STUB_DIR/state.json" "$(lane_record issue-5 '' '' /w/issue-5 running)"
      repeat_sleep_stub 'unlink "$STUB_DIR/state.json"'
      env_args+=(PATH="$STUB_DIR/bin:$TMP_ROOT/bin:$PATH")
      args=(--repo owner/repo --max-loops 1 --repeat 0 --state "$STUB_DIR/state.json") ;;
    repeat-default)
      printf 'owner/repo\n' > "$STUB_DIR/repoview.txt"
      write_state "$STUB_DIR/state.json" "$(lane_record issue-5 '' '' /w/issue-5 running)"
      repeat_sleep_stub 'unlink "$STUB_DIR/state.json"'
      env_args+=(PATH="$STUB_DIR/bin:$TMP_ROOT/bin:$PATH")
      args=(--no-repo --max-loops 1 --repeat 0 --state "$STUB_DIR/state.json") ;;
  esac
  err="$TMP_ROOT/e-$name"
  out="$(WATCH_BIN="${4:-}" run_watch ${env_args[@]+"${env_args[@]}"} -- "${args[@]}" 2>"$err" </dev/null)" && rc=0 || rc=$?
  CONNECTED_MERGED="$(awk '/--head issue-5 --state merged/ { for (i = 1; i < NF; i++) if ($i == "--repo") { printf "%s%s", sep, $(i + 1); sep = " " } }' "$STUB_DIR/gh.calls")"
  CONNECTED_OPEN="$(awk -F'\t' '$2 ~ /^[0-9]+$/ && $3 == "issue-9" { printf "%s%s", sep, $1; sep = " " }' <<<"$out")"
}
for row in \
  "connected_listed|Other/Repo owner/repo|repo|0|owner/repo other/repo|a listed repository is read after --repo, once, in one spelling" \
  "connected_default|other/repo|default|0|owner/repo other/repo|a listed repository is read after the resolved default" \
  "connected_repeat|other/repo owner/repo|repeat|2|owner/repo other/repo|repeat mode's pass reads a listed repository the wrapper handed it" \
  "connected_repeat_default|other/repo|repeat-default|2|owner/repo other/repo|repeat mode with no --repo reads the resolved default, then a listed repository" \
  "connected_absent|absent|repo|0|owner/repo|with no setting only --repo is read"; do
  IFS='|' read -r name setting mode want_rc want label <<<"$row"
  connected_case "$name" "$setting" "$mode"
  assert_eq "rc=$rc merged=$CONNECTED_MERGED open=$CONNECTED_OPEN" "rc=$want_rc merged=$want open=$want" "$label" "$err"
done
# The control for the append: the entries are still read and printed, and
# none joins the watched set, so the run reads the --repo alone. Each listed
# entry's spelling and the skip are lib/gh-repo.sh's orch_connected_repos
# rules, whose controls are in connected-repos.test.sh.
CONNECTED_MUTANT_DIR="$TMP_ROOT/connected-add"
CONNECTED_MUTANT="$(mutant_scripts connected-add/orch oversee-watch)/oversee-watch" || exit 1
ln -s "$REPO_ROOT/skills/github" "$CONNECTED_MUTANT_DIR/github"
mutate_file "$CONNECTED_MUTANT" '  REPOS+=(${connected_list[@]+"${connected_list[@]}"})' '  true || REPOS+=(${connected_list[@]+"${connected_list[@]}"})'
connected_case connected-add "Other/Repo owner/repo" repo "$CONNECTED_MUTANT"
assert_eq "rc=$rc merged=$CONNECTED_MERGED open=$CONNECTED_OPEN" "rc=0 merged=owner/repo open=owner/repo" \
  "control: without the append only the --repo is read" "$err"
# The control for the empty-set return: with it gone the wrapper, which has
# resolved no default, settles a set of the listed entry alone, and each pass
# reads that set and never the overseer's own repository.
NODEFAULT_MUTANT_DIR="$TMP_ROOT/connected-nodefault"
NODEFAULT_MUTANT="$(mutant_scripts connected-nodefault/orch oversee-watch)/oversee-watch" || exit 1
ln -s "$REPO_ROOT/skills/github" "$NODEFAULT_MUTANT_DIR/github"
mutate_file "$NODEFAULT_MUTANT" '  [[ ${#REPOS[@]} -gt 0 ]] || return 0' '  true || [[ ${#REPOS[@]} -gt 0 ]] || return 0'
connected_case connected-nodefault other/repo repeat-default "$NODEFAULT_MUTANT"
assert_eq "rc=$rc merged=$CONNECTED_MERGED open=$CONNECTED_OPEN" "rc=2 merged=other/repo open=other/repo" \
  "control: without the empty-set return a repeat pass reads the listed repository alone" "$err"
# A setting orch-env refuses to read ends the watch before any pass rather than
# watching fewer repositories: ORCH_CONSUMER_REPOS is the retired setting
# orch-env refuses on every read. MODE is `single` (--repo owner/repo, one run)
# or `repeat` (no --repo, --repeat 0 over one running record, the sleep stub
# counting each repeat delay in slept and taking the state away, so a wrapper
# that reached a pass ends on the next read).
connected_unread_case() { # NAME MODE [WATCH]
  local args=(--repo owner/repo) env_args=()
  new_case "$1"
  if [[ "$2" == repeat ]]; then
    printf 'owner/repo\n' > "$STUB_DIR/repoview.txt"
    write_state "$STUB_DIR/state.json" "$(lane_record issue-5 '' '' /w/issue-5 running)"
    repeat_sleep_stub 'echo x >> "$STUB_DIR/slept"' 'unlink "$STUB_DIR/state.json"'
    env_args=(PATH="$STUB_DIR/bin:$TMP_ROOT/bin:$PATH")
    args=(--no-repo --max-loops 1 --repeat 0 --state "$STUB_DIR/state.json")
  fi
  err="$TMP_ROOT/e-$1"
  out="$(WATCH_BIN="${3:-}" run_watch ${env_args[@]+"${env_args[@]}"} ORCH_CONSUMER_REPOS=x/y -- "${args[@]}" 2>"$err" </dev/null)" && rc=0 || rc=$?
  CONNECTED_UNREAD="$(grep -c '^oversee-watch: connected-repos-unread setting=ORCH_CONNECTED_REPOS$' "$err" || true)"
  CONNECTED_SLEPT="$(grep -c . "$STUB_DIR/slept" 2>/dev/null || true)"
  CONNECTED_SLEPT="${CONNECTED_SLEPT:-0}"
}
for row in \
  "connected_unread|single|a setting orch-env cannot read exits 2 naming it, with no pass run" \
  "connected_unread_repeat|repeat|in repeat mode with no --repo the wrapper exits 2 naming it, before any pass"; do
  IFS='|' read -r name mode label <<<"$row"
  connected_unread_case "$name" "$mode"
  assert_eq "rc=$rc unread=$CONNECTED_UNREAD slept=$CONNECTED_SLEPT out=$out" "rc=2 unread=1 slept=0 out=" "$label" "$err"
done
UNREAD_MUTANT_DIR="$TMP_ROOT/connected-unread-mutant"
UNREAD_MUTANT="$(mutant_scripts connected-unread-mutant/orch oversee-watch)/oversee-watch" || exit 1
ln -s "$REPO_ROOT/skills/github" "$UNREAD_MUTANT_DIR/github"
mutate_file "$UNREAD_MUTANT" '    || die connected-repos-unread' '    || true || die connected-repos-unread'
connected_unread_case connected_unread_control single "$UNREAD_MUTANT"
assert_eq "rc=$rc unread=$CONNECTED_UNREAD" "rc=0 unread=0" \
  "control: with the refusal removed the watch runs on without the setting" "$err"
# The repeat row's control: with the read after the empty-set return, the
# wrapper reads nothing, and the pass refuses the setting and sleeps before
# the read that ends the run.
EARLY_MUTANT_DIR="$TMP_ROOT/connected-early-mutant"
EARLY_MUTANT="$(mutant_scripts connected-early-mutant/orch oversee-watch)/oversee-watch" || exit 1
ln -s "$REPO_ROOT/skills/github" "$EARLY_MUTANT_DIR/github"
mutate_file "$EARLY_MUTANT" '  connected="$(orch_connected_repos' '  [[ ${#REPOS[@]} -gt 0 ]] || return 0
  connected="$(orch_connected_repos'
connected_unread_case connected_unread_repeat_control repeat "$EARLY_MUTANT"
assert_eq "rc=$rc unread=$CONNECTED_UNREAD slept=$CONNECTED_SLEPT" "rc=2 unread=1 slept=1" \
  "control: with the read after the empty-set return the wrapper sleeps after a refused pass" "$err"

# --- 9. --help -------------------------------------------------------------
err="$TMP_ROOT/e9"
out="$(run_watch -- --help 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "0" "--help exits 0" "$err"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
