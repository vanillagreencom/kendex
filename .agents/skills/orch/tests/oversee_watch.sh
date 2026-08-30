#!/usr/bin/env bash
# Regression tests for the GitHub side of orch/scripts/oversee-watch, and for
# the failures that take the whole process down. The pane side — window-gone,
# lane-exited, usage-limit, question, idle-after-return — is
# oversee_watch_lanes.sh; both build their sandbox from
# lib/oversee-watch-harness.sh.
#
# oversee-watch is the overseer's single blocking watch: it loops until the
# fleet needs a hand and prints ONE `EVENT <kind> ...` line. Covered here:
#   1.  pr-watch: on the fleet's first run attention present at start is a
#       baseline (no event, one stderr note, context on the next event); that
#       baseline persists, so a line appearing between two runs is the next
#       run's first-pass event and a standing line is not; a NEW `<pr> <kind>`
#       line mid-run is the event; a head-only change is not; GH_REPO reaches
#       pr-watch; rc≠0 with no lines is a global failure (exit 2); attention
#       at start does not starve a lane's question; the state file is
#       rewritten after every pass, and an uncreatable state dir or an
#       unreadable state file exits 2 naming the path
#   2.  merged: an --item's PR merged at/after --since fires; a PR merged
#       BEFORE --since, a non-item branch, and a non-item conventional branch
#       do not; a fork's PR on the same head branch name does not; item ids
#       match branches case-insensitively; no --since means no floor; no
#       --item skips the check with a note; gh stderr noise on success does
#       not break the JSON parse
#   5.  heartbeat after --max-loops with the open PR list
#   6.  gh auth failure exits 2; a stale env token falls through to the
#       project GH_BOT_TOKEN; a failing pr list exits 2 (never a quiet 0)
#   7.  lanes given outside tmux exit 2
#   8.  a missing pr-watch.sh is a stderr note, not a failure
#   9.  --help exits 0 and states both liveness rules
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
assert_contains "$(cat "$err")" "pr-watch failed (rc=2) with no per-PR lines" "global failure is named on stderr"
assert_contains "$(cat "$err")" "GH_REPO is not set" "pr-watch stderr is surfaced"

# 1f. attention at start does not starve a lane's question
new_case prwatch_no_starve
printf '12\tabcdef01\tthreads-open\t2 unresolved\n' > "$STUB_DIR/prwatch.out"
printf '1' > "$STUB_DIR/prwatch.rc"
printf 'Do you want to proceed?\n❯ 1. Yes\n  2. No\n' > "$STUB_DIR/pane-gh-2.txt"
err="$TMP_ROOT/e1f"
out="$(run_watch -- gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT question gh-2" "a lane question is seen despite standing pr-watch attention" "$err"
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
assert_eq "$(ls -1 "$STATE_DIR" 2>/dev/null | wc -l | tr -d '[:space:]')" "1" "one state file per fleet, no temp left behind" "$err"
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

# --- 2. merged, with item, since, and case controls -------------------------
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
assert_contains "$out" "EVENT question" "--help documents the event kinds" "$err"
assert_contains "$out" "child process" \
  "--help states the rule that keeps a wrapped lane out of lane-exited" "$err"
assert_contains "$out" "last user turn on its screen" \
  "--help states where a limit banner has to sit to count" "$err"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
