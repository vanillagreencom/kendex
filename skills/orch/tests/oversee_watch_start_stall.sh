#!/usr/bin/env bash
# oversee-watch's start-stalled report: a running lane record whose status
# file, tmp/lane-status-<item>.md under its mail_root, is still missing
# ORCH_WATCH_START_STALL_SECS after the record went running, its running_at, on
# every harness, a hosted one read through `lane-host cat`. A lane whose host
# kind declares files=none, a Claude cloud session, writes no file: its own
# open pull request on the item branch is its start. Reported once, then every
# ORCH_OVERSEER_MARK_REPEAT passes while it stands.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
# shellcheck source=lib/oversee-watch-harness.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/oversee-watch-harness.sh"
# mutant_scripts and mutate_file, the two halves of the control below.
# shellcheck source=lib/growth-state.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/growth-state.sh"

FIXTURE_HOST="$REPO_ROOT/skills/orch/tests/fixtures/lane-host"
LAUNCHED=2026-08-15T10:00:00Z
LAUNCHED_EPOCH="$(date -u -d "$LAUNCHED" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$LAUNCHED" +%s)"

# launched ITEM ROOT [HARNESS] [HOST] [RUNNING_AFTER] — one running lane record
# with no window, so the pass reads no pane for it, launched at LAUNCHED on
# ROOT. RUNNING_AFTER, in seconds past LAUNCHED, stamps its running_at, the
# time a prepared launch or a relaunch recorded it running; with none the
# record carries no running_at, as one written before the stamp.
launched() {
  local running=""
  [[ -z "${5:-}" ]] || running="$(date -u -d "@$((LAUNCHED_EPOCH + $5))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -r "$((LAUNCHED_EPOCH + $5))" +%Y-%m-%dT%H:%M:%SZ)"
  jq -cn --arg item "$1" --arg root "$2" --arg harness "${3:-claude}" --arg host "${4:-}" --arg at "$LAUNCHED" --arg running "$running" \
    '{item: $item, window: null, host: (if $host == "" then null else $host end), mail_root: $root,
      harness: $harness, launched_at: $at, status: "running"} + (if $running == "" then {} else {running_at: $running} end)'
}
write_state() { # RECORD...
  printf '%s\n' "$@" | jq -s '{issue_id: "oversee", triaged: [], lanes: .}' > "$STUB_DIR/state.json"
}
# A lane worktree on this disk, with its mailbox directory and, where STATUS
# is `status`, the status file its workflow writes.
worktree() { # ITEM [status]
  local root="$STUB_DIR/wt/$1"
  mkdir -p "$root/tmp/lane-mail/$1"
  [[ "${2:-}" != status ]] || printf 'step: dev round 1\n' > "$root/tmp/lane-status-$1.md"
  printf '%s\n' "$root"
}
# watch AGE [ENV=VAL...] — one pass at LAUNCHED + AGE seconds; EVENTS holds its
# EVENT lines joined by `|`, the heartbeat left out.
watch() {
  local age="$1"
  shift
  printf '%s\n' "$((LAUNCHED_EPOCH + age))" > "$STUB_DIR/now.epoch"
  EVENTS="$(run_watch "$@" -- --max-loops 1 --state "$STUB_DIR/state.json" 2>"$STUB_DIR/err" </dev/null \
    | grep '^EVENT ' | grep -v '^EVENT heartbeat' | paste -sd '|' - || true)"
}

echo "=== a lane with no status file past the window is reported, on every harness ==="
new_case start_stalled
ROOT_1="$(worktree issue-1)"
ROOT_2="$(worktree issue-2 status)"
ROOT_3="$(worktree issue-3)"
write_state "$(launched issue-1 "$ROOT_1" pi)" "$(launched issue-2 "$ROOT_2" claude)" "$(launched issue-3 "$ROOT_3" codex)"
# AGE|WANT: under the window nothing, past it each file-less lane once, the
# lane with its file never.
for row in "599|" "600|EVENT start-stalled issue-1 age=600|EVENT start-stalled issue-3 age=600" "660|"; do
  IFS='|' read -r age want <<<"$row"
  want="${row#*|}"
  watch "$age"
  assert_eq "events=$EVENTS" "events=$want" "a pass ${age}s after launch at the default window of 600 reports '${want:-nothing}'" "$STUB_DIR/err"
done

echo "=== a standing stall comes back every ORCH_OVERSEER_MARK_REPEAT passes ==="
new_case start_stall_repeat
ROOT_1="$(worktree issue-1)"
write_state "$(launched issue-1 "$ROOT_1" pi)"
for row in "700|EVENT start-stalled issue-1 age=700" "760|" "820|EVENT start-stalled issue-1 age=820"; do
  IFS='|' read -r age want <<<"$row"
  watch "$age" ORCH_OVERSEER_MARK_REPEAT=2
  assert_eq "events=$EVENTS" "events=$want" "at ORCH_OVERSEER_MARK_REPEAT=2 the pass ${age}s after launch reports '${want:-nothing}'" "$STUB_DIR/err"
done

echo "=== the window runs from when the record went running ==="
# A prepared launch went running 1000 seconds after its launch: the host's
# preparation is not the lane's start, so nothing is due until 600 seconds
# after that.
new_case start_stall_prepared
ROOT_1="$(worktree issue-1)"
write_state "$(launched issue-1 "$ROOT_1" pi "" 1000)"
for row in "1599|" "1600|EVENT start-stalled issue-1 age=600"; do
  IFS='|' read -r age want <<<"$row"
  want="${row#*|}"
  watch "$age"
  assert_eq "events=$EVENTS" "events=$want" "a record that went running 1000s after launch reports '${want:-nothing}' ${age}s after launch" "$STUB_DIR/err"
done
# A relaunch renews running_at: the stall reported above does not carry over,
# and a fresh window runs from the relaunch, so the next line is a second
# stall.
write_state "$(launched issue-1 "$ROOT_1" pi "" 2000)"
for row in "2599|" "2600|EVENT start-stalled issue-1 age=600"; do
  IFS='|' read -r age want <<<"$row"
  want="${row#*|}"
  watch "$age"
  assert_eq "events=$EVENTS" "events=$want" "after a relaunch at 2000s the pass ${age}s after launch reports '${want:-nothing}'" "$STUB_DIR/err"
done

echo "=== a status file that once stood is never a late start ==="
new_case start_stall_seen
ROOT_1="$(worktree issue-1 status)"
write_state "$(launched issue-1 "$ROOT_1" pi)"
watch 60
rm -f -- "${ROOT_1:?}/tmp/lane-status-issue-1.md"
watch 700
assert_eq "events=$EVENTS" "events=" "a lane whose close-out removed its status file after it stood reports nothing" "$STUB_DIR/err"
rm -rf -- "${ROOT_1:?}"
write_state "$(launched issue-1 "$ROOT_1" pi)" "$(launched issue-4 "$STUB_DIR/wt/issue-4" pi)"
watch 760
assert_eq "events=$EVENTS" "events=" "a local root that is no directory is a removed worktree, never a late start" "$STUB_DIR/err"

echo "=== a hosted lane's status file is read through lane-host ==="
new_case start_stall_hosted
REMOTE_DISK="$STUB_DIR/remote"
mkdir -p "$REMOTE_DISK/srv/lane/issue-5/tmp/lane-mail/issue-5" "$REMOTE_DISK/srv/lane/issue-6/tmp/lane-mail/issue-6"
printf 'gitdir: /srv/clone/.git/worktrees/issue-5\n' > "$REMOTE_DISK/srv/lane/issue-5/.git"
printf 'gitdir: /srv/clone/.git/worktrees/issue-6\n' > "$REMOTE_DISK/srv/lane/issue-6/.git"
printf 'step: dev round 1\n' > "$REMOTE_DISK/srv/lane/issue-6/tmp/lane-status-issue-6.md"
write_state "$(launched issue-5 /srv/lane/issue-5 pi "$FIXTURE_HOST")" "$(launched issue-6 /srv/lane/issue-6 claude "$FIXTURE_HOST")"
HOSTED_ENV=(ORCH_LANE_HOST="$FIXTURE_HOST" LANE_HOST_STUB_LOG="$STUB_DIR/host.log" LANE_HOST_STUB_DIR="$REMOTE_DISK")
watch 700 "${HOSTED_ENV[@]}"
assert_eq "events=$EVENTS" "events=EVENT start-stalled issue-5 age=700" \
  "a hosted lane with no status file on its host is reported, one with the file is not" "$STUB_DIR/err"
# A read the host failed settles nothing: noted, and no event on a guess.
watch 1300 "${HOSTED_ENV[@]}" LANE_HOST_STUB_CAT_STATUS=5 LANE_HOST_STUB_CAT_ITEM=issue-5 \
  LANE_HOST_STUB_CAT_PATH=/srv/lane/issue-5/tmp/lane-status-issue-5.md
assert_eq "events=$EVENTS unread=$(grep -c '^oversee-watch: start-stall-unread item=issue-5 exit=2$' "$STUB_DIR/err" || true)" \
  "events= unread=1" "a failed hosted read is noted and reports no stall" "$STUB_DIR/err"

echo "=== a lane whose kind writes no file starts with its own pull request ==="
# One claude-cloud record per case, its mail_root a local worktree holding no
# status file. OPEN is the item branch's open pull request line, the head
# owner last: none, the lane's own, or a fork's on the same branch name.
OWN_PR=$'7\tissue-7\tcloud lane\toctocat\tabc111\t## Lane status'
FORK_PR=$'8\tissue-7\tfork lane\tforker\tdef222\t## Lane status\tforker'
cloud_start() { # NAME OPEN [WATCH_BIN]
  new_case "$1"
  write_state "$(launched issue-7 "$(worktree issue-7)" claude claude-cloud)"
  printf '%s\n' "$2" > "$STUB_DIR/open.txt"
  WATCH_BIN="${3:-}" watch 700
}
# NAME|OPEN|WANT
for row in "start_stall_cloud_none||EVENT start-stalled issue-7 age=700" "start_stall_cloud_own|$OWN_PR|" \
  "start_stall_cloud_fork|$FORK_PR|EVENT start-stalled issue-7 age=700"; do
  IFS='|' read -r name open want <<<"$row"
  cloud_start "$name" "$open"
  assert_eq "events=$EVENTS" "events=$want" "$name: a files=none lane's start is its own open pull request" "$STUB_DIR/err"
done

echo "=== the window is a setting ==="
new_case start_stall_bound
ROOT_1="$(worktree issue-1)"
write_state "$(launched issue-1 "$ROOT_1" pi)"
watch 61 ORCH_WATCH_START_STALL_SECS=60
assert_eq "events=$EVENTS" "events=EVENT start-stalled issue-1 age=61" "ORCH_WATCH_START_STALL_SECS sets the window" "$STUB_DIR/err"
watch 120 ORCH_WATCH_START_STALL_SECS=060
assert_eq "refused=$(grep -c '^oversee-watch: start-stall-secs-invalid value=060$' "$STUB_DIR/err" || true)" "refused=1" \
  "a window that is not a positive whole number refuses the watch" "$STUB_DIR/err"
watch 120 ORCH_WATCH_LANE_STALL_SECS=060
LANE_STALL_REFUSED="$(grep -c '^oversee-watch: lane-stall-secs-invalid value=060$' "$STUB_DIR/err" || true)"
assert_eq "refused=$LANE_STALL_REFUSED" "refused=1" \
  "a lane-stalled window that is not a positive whole number refuses the watch" "$STUB_DIR/err"

echo "=== must-fail control ==="
# The status file never looked for: a lane that wrote its file is reported
# stalled all the same.
MUTANT_DIR="$TMP_ROOT/start-stall-mutant"
MUTANT_WATCH="$(mutant_scripts start-stall-mutant/orch oversee-watch)/oversee-watch" || exit 1
ln -s "$REPO_ROOT/skills/github" "$MUTANT_DIR/github"
mutate_file "$MUTANT_WATCH" '      [[ -e "$path" ]] || rc=1' '      rc=1'
new_case start_stall_mutant
ROOT_2="$(worktree issue-2 status)"
write_state "$(launched issue-2 "$ROOT_2" claude)"
WATCH_BIN="$MUTANT_WATCH" watch 700
assert_eq "events=$EVENTS" "events=EVENT start-stalled issue-2 age=700" \
  "control: without the status-file test a lane that wrote its file is reported stalled" "$STUB_DIR/err"

# The window anchored on launched_at again: a prepared lane's preparation is
# counted as its own stall.
ANCHOR_DIR="$TMP_ROOT/start-stall-anchor"
ANCHOR_WATCH="$(mutant_scripts start-stall-anchor/orch oversee-watch)/oversee-watch" || exit 1
ln -s "$REPO_ROOT/skills/github" "$ANCHOR_DIR/github"
mutate_file "$ANCHOR_WATCH" '((.running_at // .launched_at) | if' '(.launched_at | if'
new_case start_stall_anchor_mutant
ROOT_1="$(worktree issue-1)"
write_state "$(launched issue-1 "$ROOT_1" pi "" 1000)"
WATCH_BIN="$ANCHOR_WATCH" watch 1599
assert_eq "events=$EVENTS" "events=EVENT start-stalled issue-1 age=1599" \
  "control: anchored on launched_at a lane that went running 599s ago is reported stalled" "$STUB_DIR/err"

# A files=none lane read as one with a status file, which has no root to read
# it under: a lane with no pull request is never reported.
FILELESS_DIR="$TMP_ROOT/start-stall-fileless"
FILELESS_WATCH="$(mutant_scripts start-stall-fileless/orch oversee-watch)/oversee-watch" || exit 1
ln -s "$REPO_ROOT/skills/github" "$FILELESS_DIR/github"
# shellcheck disable=SC2016  # the script's own text, never expanded here.
mutate_file "$FILELESS_WATCH" '    if item_in "$item" ${FILELESS[@]+"${FILELESS[@]}"}; then' '    if false; then'
cloud_start start_stall_fileless_mutant "" "$FILELESS_WATCH"
assert_eq "events=$EVENTS" "events=" \
  "control: read for a status file, a files=none lane with no pull request is never reported" "$STUB_DIR/err"
# The head owner never compared: a fork's pull request on the branch name
# stands in for the lane's start.
FORK_DIR="$TMP_ROOT/start-stall-fork"
FORK_WATCH="$(mutant_scripts start-stall-fork/orch lib/watch-host-kinds.sh)/oversee-watch" || exit 1
ln -s "$REPO_ROOT/skills/github" "$FORK_DIR/github"
mutate_file "${FORK_WATCH%/*}/lib/watch-host-kinds.sh" '[.[] | lane_own($branch; $owner)] | first' '[.[]] | first'
cloud_start start_stall_fork_mutant "$FORK_PR" "$FORK_WATCH"
assert_eq "events=$EVENTS" "events=" "control: without the owner rule a fork's pull request starts the lane" "$STUB_DIR/err"
# The lane-stalled window never validated: 060 runs the watch.
SECS_DIR="$TMP_ROOT/lane-stall-secs"
SECS_WATCH="$(mutant_scripts lane-stall-secs/orch oversee-watch)/oversee-watch" || exit 1
ln -s "$REPO_ROOT/skills/github" "$SECS_DIR/github"
# shellcheck disable=SC2016
mutate_file "$SECS_WATCH" '[[ "$LANE_STALL_SECS" =~ ^[1-9][0-9]*$ ]] || die' 'true || die'
new_case lane_stall_secs_mutant
write_state "$(launched issue-1 "$(worktree issue-1 status)" pi)"
WATCH_BIN="$SECS_WATCH" watch 120 ORCH_WATCH_LANE_STALL_SECS=060
assert_eq "refused=$(grep -c '^oversee-watch: lane-stall-secs-invalid' "$STUB_DIR/err" || true)" "refused=0" \
  "control: without its check a lane-stalled window of 060 is taken" "$STUB_DIR/err"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
