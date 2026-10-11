#!/usr/bin/env bash
# oversee-watch's owed items: under a heartbeat, one `owed` line per item the
# tracker holds as work the fleet owes and the fleet state's launch_queue
# lacks, with its verdict. Every run is one pass (--max-loops 1) over a fleet
# state passed with --state. The wall itself is `lanes pick`'s judgement,
# tested in lanes.sh; these rows hold the watch to asking it for the record's
# harness and model and to reading its answer.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
# shellcheck source=lib/oversee-watch-harness.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/oversee-watch-harness.sh"
# mutant_scripts and mutate_file, the two halves of the controls below.
# shellcheck source=lib/growth-state.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/growth-state.sh"

HEARTBEAT='EVENT heartbeat loops=1 interval=0s since=none'

# record ITEM STATUS HARNESS [EXTRA_JSON] — one lanes[] record with no window,
# so the pass reads no pane for it; EXTRA_JSON is merged over it. EXTRA_JSON
# defaults by count, not as `${4:-{\}}`: Bash 3.2 keeps the backslash in that
# default and hands jq `{\}`.
record() {
  local extra='{}'
  [[ $# -lt 4 ]] || extra="$4"
  jq -nc --arg item "$1" --arg status "$2" --arg harness "$3" --argjson extra "$extra" \
    '{item: $item, window: null, host: null, mail_root: ("/w/" + $item), account: null,
      harness: $harness, surface: "tmux", model: null, session_id: null,
      launched_at: "2026-09-20T00:00:00Z", status: $status} + $extra'
}
# fleet QUEUE_JSON RECORD... — the fleet state file --state names. A RECORD
# whose `record` call failed arrives empty, which jq -s would skip, so the
# lane count is checked against the arguments.
fleet() {
  local queue="$1" lanes
  shift
  lanes="$(printf '%s\n' "$@" | jq -sc .)" || { echo "fleet: records are not JSON" >&2; exit 1; }
  [[ "$(jq length <<<"$lanes")" -eq $# ]] || { echo "fleet: lanes=$(jq length <<<"$lanes") args=$#" >&2; exit 1; }
  jq -n --argjson queue "$queue" --argjson lanes "$lanes" \
    '{issue_id: "oversee", triaged: [], launch_queue: $queue, lanes: $lanes}' > "$STUB_DIR/state.json"
}
# account ALIAS HARNESS VERDICT RESETS — one `lanes list --json` record, its
# binding bucket the weekly window resetting at RESETS. The listing says which
# harnesses have accounts; a wall's date is the pick's own walled_resets_at.
account() {
  jq -nc --arg a "$1" --arg h "$2" --arg v "$3" --arg r "$4" '{
    alias: $a, harness: $h, config_dir: ("/home/u/." + $a), measured_through: "local",
    status: "ok", verdict: $v, headroom_pct: 0, binding_bucket: "weekly", binding_resets_at: $r,
    session_5h_pct: 10, weekly_pct: 20, resets: {session: "2026-09-28T05:00:00Z", weekly: $r},
    model_buckets: [{label: "Opus", pct: 100, resets_at: "2026-10-04T00:00:00Z"}]}'
}
# issue ID STATE PRIORITY — one safe-format tracker item.
issue() { jq -nc --arg id "$1" --arg s "$2" --argjson p "$3" '{id: $id, state: $s, priority: $p}'; }
# pick HARNESS MODEL RC [JSON] — what `lanes pick` answers for that pair.
pick() {
  printf '%s\n' "$3" > "$STUB_DIR/pick-$1-$2.rc"
  [[ -z "${4:-}" ]] || printf '%s\n' "$4" > "$STUB_DIR/pick-$1-$2.json"
}

# watch_pass [ENV=VAL...] [-- ARGS...] — one run; OUT, RC and ERR (a file) are
# what the assertions read.
RUN_SEQ=0
watch_pass() {
  local env_args=()
  while [[ $# -gt 0 && "$1" != -- ]]; do env_args+=("$1"); shift; done
  shift || true
  ERR="$TMP_ROOT/run-$((++RUN_SEQ)).err"
  OUT="$(run_watch ${env_args[@]+"${env_args[@]}"} -- --max-loops 1 "$@" 2>"$ERR")" && RC=0 || RC=$?
}
# owed ITEM — the item's owed line, or `-` with none.
owed() {
  local line
  line="$(awk -v id="$1" '$1 == "owed" && $2 == id' <<<"$OUT")"
  printf '%s' "${line:--}"
}

# The shared world: one fleet whose records and tracker items each reach one
# rule. KEN-1 runs; KEN-2 is stopped on a Sonnet model its harness has room
# for; KEN-3 stopped on a harness walled for every model; KEN-4 parked; KEN-5
# closed out with its merge's cycle; KEN-6 in review with no record and an
# open PR; KEN-7 already queued; KEN-8 done; KEN-9 stopped on a harness no
# roster account belongs to, with no priority; KEN-10 stopped after a relaunch
# that kept an earlier merge's cycle; KEN-11 stopped on the Opus model its
# harness is walled for; KEN-12 stopped on another host, whose codex accounts
# have room while this host's are walled; KEN-13 closed after a direct push
# whose cycle oversee-cycle record writes without a PR. The claude roster mixes a walled
# account with one that has room, which is pick's to weigh.
world() {
  new_case "$1"
  fleet '["KEN-7"]' \
    "$(record KEN-1 running claude)" \
    "$(record KEN-2 stopped claude '{"model":"claude-sonnet-5"}')" \
    "$(record KEN-3 stopped codex)" \
    "$(record KEN-4 parked claude '{"parked":{"pr":14,"head":"abc","repo":"owner/repo","at":"2026-09-27T00:00:00Z"}}')" \
    "$(record KEN-5 done claude '{"cycle":{"pr":15}}')" \
    "$(record KEN-9 stopped pi)" \
    "$(record KEN-10 stopped claude '{"cycle":{"pr":21}}')" \
    "$(record KEN-11 stopped claude '{"model":"claude-opus-5"}')" \
    "$(record KEN-12 stopped codex '{"host":"provider-x"}')" \
    "$(record KEN-13 done claude '{"cycle":{"commit":"0123456789abcdef0123456789abcdef01234567","class":"small","class_cause":null,"class_reason":"within-small-ceiling","tier":"small","tier_inputs":null,"stamps":{"launched":"2026-09-20T00:00:00Z","first_commit":"2026-09-20T00:01:00Z","pr_opened":null,"gate_green":null,"ci_green":null,"armed":null,"merged":"2026-09-20T00:02:00Z"},"target":1800,"merge_group":null,"actual":120,"open":null,"verdict":"unmeasured","phase":null,"phase_secs":null,"gate_waits":null,"cause":null,"missing":["pr_opened","gate_green","ci_green","armed"],"rounds":null,"pr_rounds":null,"escaped":false,"escape_cause":null,"refixed":null}}')"
  printf '%s\n' "$(issue KEN-1 'In Progress' 1)" "$(issue KEN-2 'In Progress' 2)" \
    "$(issue KEN-3 'In Progress' 1)" "$(issue KEN-4 'In Review' 2)" "$(issue KEN-5 'In Review' 2)" \
    "$(issue KEN-6 'In Review' 3)" "$(issue KEN-7 'In Progress' 2)" "$(issue KEN-8 Done 2)" \
    "$(issue KEN-9 'In Progress' 0)" "$(issue KEN-10 'In Progress' 2)" "$(issue KEN-11 'In Progress' 1)" \
    "$(issue KEN-12 'In Progress' 2)" "$(issue KEN-13 'In Review' 2)" \
    | jq -sc . > "$STUB_DIR/tracker.out"
  printf '16\tken-6\tthe review item\n' > "$STUB_DIR/open.txt"
  printf '%s\n' "$(account claude claude room 2026-10-01T00:00:00Z)" \
    "$(account claude2 claude walled 2026-10-02T00:00:00Z)" \
    "$(account codex codex walled 2026-10-05T00:00:00Z)" "$(account codex2 codex walled 2026-10-03T00:00:00Z)" \
    | jq -sc . > "$STUB_DIR/lanes.json"
  pick claude claude-sonnet-5 0 '{"config_dir":"/home/u/.claude"}'
  pick codex - 3 '{"walled":2,"unmeasured":0,"walled_resets_at":"2026-10-03T00:00:00Z"}'
  pick claude claude-opus-5 3 '{"walled":2,"unmeasured":0,"walled_resets_at":"2026-10-04T00:00:00Z"}'
  pick provider-x-codex - 0 '{"config_dir":"/home/u/.codex"}'
}

# hosted NAME REPLY — the shared world with KEN-12's host walled for codex,
# its pick there answering REPLY.
hosted() {
  world "$1"
  pick provider-x-codex - 3 "$2"
}
# noisy NAME — the shared world whose listings each write a keyed notice.
noisy() {
  world "$1"
  : > "$STUB_DIR/lanes.notice"
}
# notices — the stub notices the pass forwarded, counted per host an owed
# listing was read under.
notices() {
  printf 'local=%s provider-x=%s' "$(grep -Ec '^lanes: stub-notice host=(local|unset)$' "$ERR" || true)" \
    "$(grep -c '^lanes: stub-notice host=provider-x$' "$ERR" || true)"
}

# Rows: item | its owed line in the shared world, `-` for none.
WORLD_ROWS='KEN-1|-
KEN-2|owed KEN-2 state=in-progress priority=2 lane=stopped verdict=queue
KEN-3|owed KEN-3 state=in-progress priority=1 lane=stopped verdict=dated harness=codex until=2026-10-03T00:00:00Z
KEN-4|-
KEN-5|owed KEN-5 state=in-review priority=2 lane=done verdict=merged pr=15
KEN-6|owed KEN-6 state=in-review priority=3 lane=none verdict=queue
KEN-7|-
KEN-8|-
KEN-9|owed KEN-9 state=in-progress priority=- lane=stopped verdict=queue
KEN-10|owed KEN-10 state=in-progress priority=2 lane=stopped verdict=merged pr=21
KEN-11|owed KEN-11 state=in-progress priority=1 lane=stopped verdict=dated harness=claude until=2026-10-04T00:00:00Z
KEN-12|owed KEN-12 state=in-progress priority=2 lane=stopped verdict=queue
KEN-13|owed KEN-13 state=in-review priority=2 lane=done verdict=merged commit=0123456789abcdef0123456789abcdef01234567'

echo "=== oversee-watch owed items ==="

world owed
watch_pass -- --state "$STUB_DIR/state.json"
assert_eq "rc=$RC first=$(head -1 <<<"$OUT")" "rc=0 first=$HEARTBEAT" "the fleet reaches the heartbeat" "$ERR"
assert_eq "$(cat "$STUB_DIR/tracker.args")" "issues list --team kendex --state In Progress,In Review,Verifying --max --format=safe" \
  "the owed items are one live read of the team's In Progress and In Review items" "$ERR"
while IFS='|' read -r item want; do
  assert_eq "$(owed "$item")" "$want" "owed $item" "$ERR"
done <<<"$WORLD_ROWS"
assert_eq "$(grep -E '^[^ ]+ (pick|list --json$)' "$STUB_DIR/lanes.hosts" | grep -v '^unset ' | sort)" \
  "$(printf '%s\n' 'local pick --harness claude --json --model claude-opus-5' \
      'local pick --harness claude --json --model claude-sonnet-5' 'local pick --harness codex --json' \
      'provider-x list --json' 'provider-x pick --harness codex --json' | sort)" \
  "each host's accounts are listed once and its wall asked of lanes pick once per harness and model, under that host" "$ERR"
assert_eq "$(grep -n '^owed ' <<<"$OUT" | head -1 | cut -d: -f1)" "$(($(grep -n '^account ' <<<"$OUT" | tail -1 | cut -d: -f1) + 1))" \
  "the owed lines follow the account roster" "$ERR"
assert_eq "$(grep -cx 'unset list --json' "$STUB_DIR/lanes.hosts" || true)" 1 \
  "the own-host roster and owed items share one listing" "$ERR"

# The settings-loaded host, not the spelling local, owns the pass roster.
world owed_own_provider
watch_pass ORCH_LANE_HOST=provider-x -- --state "$STUB_DIR/state.json"
assert_eq "$(grep -cx 'provider-x list --json' "$STUB_DIR/lanes.hosts" || true)|$(grep -cx 'local list --json' "$STUB_DIR/lanes.hosts" || true)|$(owed KEN-12)" \
  "1|1|owed KEN-12 state=in-progress priority=2 lane=stopped verdict=queue" \
  "the configured own host reuses its roster and the other host is listed" "$ERR"

# A malformed first listing fails the roster read. The owed read can still
# obtain the valid listing the stub gives its later calls.
world owed_roster_retry
printf 'not-json\n' > "$STUB_DIR/lanes.1.json"
watch_pass -- --state "$STUB_DIR/state.json"
assert_eq "$(grep -cx 'local list --json' "$STUB_DIR/lanes.hosts" || true)|$(owed KEN-3)" \
  "1|owed KEN-3 state=in-progress priority=1 lane=stopped verdict=dated harness=codex until=2026-10-03T00:00:00Z" \
  "a failed own-host roster leaves owed work its separate listing" "$ERR"

reuse_scripts="$(mutant_scripts owed-roster-repeat/orch oversee-watch)" || exit 1
ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/owed-roster-repeat/github"
ln -s "$REPO_ROOT/skills/linear" "$TMP_ROOT/owed-roster-repeat/linear"
mutate_file "$reuse_scripts/oversee-watch" \
  'if [[ "$ACCOUNT_ROSTER_RC" -eq 0 && "$host" == "${ORCH_LANE_HOST:-local}" ]]; then' \
  'if false; then'
world owed_roster_control
WATCH_BIN="$reuse_scripts/oversee-watch" watch_pass -- --state "$STUB_DIR/state.json"
control_rc=0
( FAIL=0; assert_eq "$(grep -c ' list --json$' "$STUB_DIR/lanes.hosts")" 2 'shared roster'; [[ "$FAIL" == 0 ]] ) \
  > "$TMP_ROOT/owed-roster-control.log" || control_rc=$?
assert_eq "$control_rc:$(grep -cx 'local list --json' "$STUB_DIR/lanes.hosts" || true)" '1:1' \
  "the roster assertion rejects the base behavior's duplicate own-host listing" "$ERR"

# Each reuse condition has its own counterexample from the pass producer.
while IFS='|' read -r name old new host; do
  guard_scripts="$(mutant_scripts "owed-reuse-$name/orch" oversee-watch)" || exit 1
  ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/owed-reuse-$name/github"
  ln -s "$REPO_ROOT/skills/linear" "$TMP_ROOT/owed-reuse-$name/linear"
  mutate_file "$guard_scripts/oversee-watch" "$old" "$new"
  world "owed_reuse_$name"
  [[ "$name" != failed ]] || printf 'not-json\n' > "$STUB_DIR/lanes.1.json"
  WATCH_BIN="$guard_scripts/oversee-watch" watch_pass "ORCH_LANE_HOST=$host" -- --state "$STUB_DIR/state.json"
  control_rc=0
  expected_lists=1
  [[ "$name" != failed ]] || expected_lists=2
  ( FAIL=0; assert_eq "$(grep -cx 'local list --json' "$STUB_DIR/lanes.hosts" || true)" "$expected_lists" 'separate owed listing'; [[ "$FAIL" == 0 ]] ) \
    > "$TMP_ROOT/owed-reuse-$name.log" || control_rc=$?
  assert_eq "$control_rc" 1 "control: $name roster cannot replace the owed host's listing" "$ERR"
done <<'ROWS'
failed|"$ACCOUNT_ROSTER_RC" -eq 0 &&|true &&|local
other|"$host" == "${ORCH_LANE_HOST:-local}"|true|provider-x
ROWS

# A host whose accounts could not be listed judges no wall: every item with a
# harness is unjudged, each host named once, a merged one is still merged,
# and one with no record is queued.
world owed_unjudged
printf '1\n' > "$STUB_DIR/lanes.rc"
watch_pass -- --state "$STUB_DIR/state.json"
assert_eq "$(owed KEN-3)|$(owed KEN-9)|$(owed KEN-12)|$(owed KEN-5)|$(owed KEN-6) notes=$(grep -c '^oversee-watch: owed-accounts-unread host=' "$ERR" || true)" \
  "owed KEN-3 state=in-progress priority=1 lane=stopped verdict=unjudged harness=codex|owed KEN-9 state=in-progress priority=- lane=stopped verdict=unjudged harness=pi|owed KEN-12 state=in-progress priority=2 lane=stopped verdict=unjudged harness=codex|owed KEN-5 state=in-review priority=2 lane=done verdict=merged pr=15|owed KEN-6 state=in-review priority=3 lane=none verdict=queue notes=2" \
  "an unread listing leaves every harness on its host unjudged" "$ERR"

# A notice a host's listing writes while it still answers passes through with
# the verdicts judged on it.
noisy owed_notice
watch_pass -- --state "$STUB_DIR/state.json"
assert_eq "rc=$RC $(notices) $(owed KEN-12)" \
  "rc=0 local=1 provider-x=1 owed KEN-12 state=in-progress priority=2 lane=stopped verdict=queue" \
  "each owed listing's notices reach stderr" "$ERR"

# Rows: case | the pick reply on KEN-12's host | KEN-12's owed line. A walled
# hosted lane dates to the reset its own host's pick names, never the local
# host's, and to none where that pick names none.
while IFS='|' read -r name reply want; do
  hosted "owed_hosted_$name" "$reply"
  watch_pass -- --state "$STUB_DIR/state.json"
  assert_eq "rc=$RC $(owed KEN-12)|$(owed KEN-3)" \
    "rc=0 $want|owed KEN-3 state=in-progress priority=1 lane=stopped verdict=dated harness=codex until=2026-10-03T00:00:00Z" \
    "a walled hosted lane whose pick names $name reset" "$ERR"
done <<'ROWS'
a|{"walled":1,"unmeasured":0,"walled_resets_at":"2026-10-06T00:00:00Z"}|owed KEN-12 state=in-progress priority=2 lane=stopped verdict=dated harness=codex until=2026-10-06T00:00:00Z
no|{"walled":1,"unmeasured":0,"walled_resets_at":null}|owed KEN-12 state=in-progress priority=2 lane=stopped verdict=dated harness=codex until=-
ROWS

# Rows: case | pick's exit and reply for codex. Every account unmeasured and a
# pick that fails are both unjudged; the failure is named.
while IFS='|' read -r name rc reply notes; do
  world "owed_pick_$name"
  pick codex - "$rc" "$reply"
  watch_pass -- --state "$STUB_DIR/state.json"
  assert_eq "rc=$RC $(owed KEN-3) notes=$(grep -c '^oversee-watch: owed-wall-unjudged host=local harness=codex model=- exit=' "$ERR" || true)" \
    "rc=0 owed KEN-3 state=in-progress priority=1 lane=stopped verdict=unjudged harness=codex notes=$notes" \
    "a pick answering $name leaves the item unjudged" "$ERR"
done <<'ROWS'
unmeasured|3|{"walled":0,"unmeasured":2}|0
failure|1||1
ROWS

# A fleet with no tracker team owes the item repository's open PRs on a GitHub
# item's branch, and no other repository's, and reads no tracker.
new_case owed_github
fleet '[]'
printf '12\tissue-12\tan issue\n13\tken-9\tnot an issue branch\n' > "$STUB_DIR/open.owner_repo.txt"
printf '77\tissue-77\ta consumer-side PR\n' > "$STUB_DIR/open.other_repo.txt"
watch_pass LINEAR_TEAM -- --state "$STUB_DIR/state.json" --repo owner/repo --repo other/repo
assert_eq "rc=$RC tracker=$([[ -e "$STUB_DIR/tracker.args" ]] && echo read || echo unread) lines=$(grep -c '^owed ' <<<"$OUT" || true) $(owed issue-12)" \
  "rc=0 tracker=unread lines=1 owed issue-12 state=open-pr priority=- lane=none verdict=queue" \
  "an open PR on issue-N in the item repository is owed on a fleet with no team" "$ERR"

# The owed read lists the item repository past the heartbeat's 50-line
# display: the oldest of 51 open PRs is owed, and a listing that reaches the
# owed read's own limit refuses rather than pass as whole.
new_case owed_github_deep
fleet '[]'
# Newest first, as gh lists: the issue-N PR is the oldest, the 51st line.
{ for n in $(seq 50 -1 1); do printf '%s\tken-%s\tpr %s\n' "$n" "$n" "$n"; done; printf '9\tissue-999\tthe oldest\n'; } \
  > "$STUB_DIR/open.txt"
watch_pass LINEAR_TEAM -- --state "$STUB_DIR/state.json"
assert_eq "rc=$RC display=$(grep -c "^owner/repo$(printf '\t')" <<<"$OUT" || true) $(owed issue-999)" \
  "rc=0 display=50 owed issue-999 state=open-pr priority=- lane=none verdict=queue" \
  "the 51st open PR is owed though the heartbeat displays 50" "$ERR"
new_case owed_github_truncated
fleet '[]'
for n in $(seq 1 1000); do printf '%s\tissue-%s\tpr %s\n' "$n" "$n" "$n"; done > "$STUB_DIR/open.txt"
watch_pass LINEAR_TEAM -- --state "$STUB_DIR/state.json"
assert_eq "rc=$RC heartbeat=$(grep -c '^EVENT heartbeat' <<<"$OUT" || true) key=$(grep -c '^oversee-watch: owed-list-truncated repo=owner/repo limit=1000$' "$ERR" || true)" \
  "rc=2 heartbeat=0 key=1" "a listing at its limit exits 2 with no heartbeat" "$ERR"

# No fleet state, no queue to compare: no owed line and no tracker read.
world owed_stateless
watch_pass
assert_eq "rc=$RC tracker=$([[ -e "$STUB_DIR/tracker.args" ]] && echo read || echo unread) lines=$(grep -c '^owed ' <<<"$OUT" || true)" \
  "rc=0 tracker=unread lines=0" "a watch with no --state owes nothing" "$ERR"

# A tracker read that fails fails the pass before any heartbeat line.
world owed_tracker_failed
printf '1\n' > "$STUB_DIR/tracker.rc"
watch_pass -- --state "$STUB_DIR/state.json"
assert_eq "rc=$RC heartbeat=$(grep -c '^EVENT heartbeat' <<<"$OUT" || true) key=$(grep -c '^oversee-watch: tracker-list-failed team=kendex exit=1$' "$ERR" || true)" \
  "rc=2 heartbeat=0 key=1" "a failed tracker read exits 2 with no heartbeat" "$ERR"

# Rows: case | tracker.out. A reply the watch cannot read is refused, never
# read as no owed item.
while IFS='|' read -r name reply; do
  world "owed_invalid_$name"
  printf '%s\n' "$reply" > "$STUB_DIR/tracker.out"
  watch_pass -- --state "$STUB_DIR/state.json"
  assert_eq "rc=$RC key=$(grep -c '^oversee-watch: tracker-list-invalid team=kendex$' "$ERR" || true)" "rc=2 key=1" \
    "a tracker reply of $name is refused" "$ERR"
done <<'ROWS'
object|{"id":"KEN-2","state":"In Progress"}
bad_id|[{"id":"KEN 2","state":"In Progress","priority":2}]
ROWS


# Verifying membership comes from the same read as owed development. KEN-1
# has an active record and KEN-4 is queued; both still print every box.
# Controls follow the judgement moved into its shared library. The watch
# still owns inventory membership, event edges and committed state.
mutate_verifying() { # SCRIPT OLD NEW
  local target="$1" old="$2" new="$3" lib="${1%/*}/lib/verifying.sh"
  if [[ "$(cat -- "$target")" != *"$old"* ]]; then
    target="$lib"
    if [[ -L "$target" ]]; then
      rm -- "${target:?}"
      cp "$REPO_ROOT/skills/orch/scripts/lib/verifying.sh" "$target"
    fi
  fi
  mutate_file "$target" "$old" "$new"
}

verifying_world() {
  world "$1"
  local description
  jq '.launch_queue += ["KEN-4"]' "$STUB_DIR/state.json" >"$STUB_DIR/verifying-state.json"
  mv -- "$STUB_DIR/verifying-state.json" "$STUB_DIR/state.json"
  description='## Done when
- [x] branch proof
- [ ] Post-merge: Read deployed health; Where: live service; Why after merge: needs deployment; Deadline: 2026-10-02T00:00:00Z
- [ ] Post-merge: Read consumer refresh; Where: consumer PR; Why after merge: needs rollout; Deadline: 2026-10-03T00:00:00Z'
  jq --arg d "$description" 'map(if .id == "KEN-1" or .id == "KEN-4" then .state = "Verifying" | .description = $d else . end)' \
    "$STUB_DIR/tracker.out" >"$STUB_DIR/verifying.json"
  mv -- "$STUB_DIR/verifying.json" "$STUB_DIR/tracker.out"
  jq -nr '"2026-10-02T00:00:01Z" | fromdateiso8601' >"$STUB_DIR/now.epoch"
}
verification_lines() { awk '/^verifying /' <<<"$OUT"; }
verification_events() { awk '/^EVENT verifying-deadline /' <<<"$OUT"; }
want_lines='verifying KEN-1 box=2 trigger="merge" status=overdue deadline=2026-10-02T00:00:00Z blocked_by=- reading="Read deployed health" where="live service" why="needs deployment"
verifying KEN-1 box=3 trigger="merge" status=due deadline=2026-10-03T00:00:00Z blocked_by=- reading="Read consumer refresh" where="consumer PR" why="needs rollout"
verifying KEN-4 box=2 trigger="merge" status=overdue deadline=2026-10-02T00:00:00Z blocked_by=- reading="Read deployed health" where="live service" why="needs deployment"
verifying KEN-4 box=3 trigger="merge" status=due deadline=2026-10-03T00:00:00Z blocked_by=- reading="Read consumer refresh" where="consumer PR" why="needs rollout"'
want_events='EVENT verifying-deadline KEN-1 box=2 trigger="merge" status=overdue deadline=2026-10-02T00:00:00Z
EVENT verifying-deadline KEN-1 box=3 trigger="merge" status=due deadline=2026-10-03T00:00:00Z
EVENT verifying-deadline KEN-4 box=2 trigger="merge" status=overdue deadline=2026-10-02T00:00:00Z
EVENT verifying-deadline KEN-4 box=3 trigger="merge" status=due deadline=2026-10-03T00:00:00Z'
verifying_world verifying_deadline
watch_pass -- --state "$STUB_DIR/state.json"
assert_eq "rc=$RC $(verification_events)" "rc=0 $want_events" "the deadline raises attention for active and queued verification" "$ERR"
assert_eq "$(verification_lines)" "$want_lines" "every Verifying box and deadline remains visible" "$ERR"
assert_eq "$(owed KEN-1)$(owed KEN-4)" "--" "Verifying never becomes owed development" "$ERR"
# The next pass has the same deadline keys: it prints the boxes at heartbeat
# without a second deadline event or another tracker inventory read.
watch_pass -- --state "$STUB_DIR/state.json"
assert_eq "rc=$RC $(verification_events)" "rc=0 " "a standing deadline emits once" "$ERR"
assert_eq "$(verification_lines)" "$want_lines" "the heartbeat carries the same Verifying inventory" "$ERR"
assert_eq "$(cat "$STUB_DIR/tracker.args")" "issues list --team kendex --state In Progress,In Review,Verifying --max --format=safe" "verification shares the owed inventory" "$ERR"
assert_eq "$(wc -l <"$STUB_DIR/tracker.args.all" | tr -d ' ')" 2 "two passes use two inventory reads" "$ERR"
verifying_world verifying_future
jq 'map(if .state == "Verifying" then .description |= gsub("; Deadline:"; "; Trigger: 2026-10-01T12:00:00Z; Deadline:") else . end)' "$STUB_DIR/tracker.out" >"$STUB_DIR/future.json"
mv -- "$STUB_DIR/future.json" "$STUB_DIR/tracker.out"
jq -nr '"2026-10-01T11:59:59Z" | fromdateiso8601' >"$STUB_DIR/now.epoch"
watch_pass -- --state "$STUB_DIR/state.json"
assert_eq "rc=$RC $(verification_events)" "rc=0 " "an unfired time trigger raises no event" "$ERR"
assert_eq "$(verification_lines | grep -c 'status=waiting' || true)" 4 "unfired checks stay visible as waiting" "$ERR"
# A malformed box fails the read instead of losing verification silently.
verifying_world verifying_invalid
jq 'map(if .id == "KEN-1" then .description = "## Done when\n- [ ] Post-merge: Read health" else . end)' \
  "$STUB_DIR/tracker.out" >"$STUB_DIR/invalid.json"
mv -- "$STUB_DIR/invalid.json" "$STUB_DIR/tracker.out"
watch_pass -- --state "$STUB_DIR/state.json"
assert_eq "rc=$RC key=$(grep -c '^oversee-watch: verifying-invalid issue=KEN-1$' "$ERR" || true)" "rc=0 key=1" "invalid verification reports the item and continues" "$ERR"

# The watcher refuses a Verifying item that still has branch work. This is
# distinct from a post-merge box whose required deadline fields are absent.
verifying_world verifying_branch_open
jq 'map(if .id == "KEN-1" then .description |= sub("\\[x\\] branch proof"; "[ ] branch proof") else . end)' \
  "$STUB_DIR/tracker.out" >"$STUB_DIR/branch-open.json"
mv -- "$STUB_DIR/branch-open.json" "$STUB_DIR/tracker.out"
watch_pass -- --state "$STUB_DIR/state.json"
assert_eq "rc=$RC key=$(grep -c '^oversee-watch: verifying-invalid issue=KEN-1$' "$ERR" || true)" "rc=0 key=1" "open branch work reports the item and continues" "$ERR"
for validation in fields branch; do
  MUTANT_DIR="$TMP_ROOT/verifying-validation-$validation"
  MUTANT_WATCH="$(mutant_scripts "verifying-validation-$validation/orch" oversee-watch)/oversee-watch" || exit 1
  ln -s "$REPO_ROOT/skills/github" "$MUTANT_DIR/github"
  ln -s "$REPO_ROOT/skills/linear" "$MUTANT_DIR/linear"
  old="jq -e '(.errors | length) == 0 and all(.boxes[]; .checked or .post_merge)' <<<\"\$parsed\" >/dev/null"
  if [[ "$validation" == fields ]]; then
    new="jq -e 'all(.boxes[]; .checked or .post_merge)' <<<\"\$parsed\" >/dev/null"
    description='## Done when
- [ ] Post-merge: Read health'
  else
    new="jq -e '(.errors | length) == 0' <<<\"\$parsed\" >/dev/null"
    description='## Done when
- [ ] branch proof
- [ ] Post-merge: Read health; Where: service; Why after merge: needs deployment; Deadline: 2026-10-02T00:00:00Z'
  fi
  mutate_verifying "$MUTANT_WATCH" "$old" "$new"
  verifying_world "verifying_validation_$validation"
  jq --arg d "$description" 'map(if .id == "KEN-1" then .description = $d else . end)' \
    "$STUB_DIR/tracker.out" >"$STUB_DIR/validation.json"
  mv -- "$STUB_DIR/validation.json" "$STUB_DIR/tracker.out"
  WATCH_BIN="$MUTANT_WATCH" watch_pass -- --state "$STUB_DIR/state.json"
  assert_eq "$(grep -c '^oversee-watch: verifying-invalid issue=KEN-1$' "$ERR" || true)" 0 "control: missing $validation check loses the item error" "$ERR"
done

# Must-fail controls retain the executable watch and change one rule each.
for control in membership event filter queue; do
  MUTANT_DIR="$TMP_ROOT/verifying-mutant-$control"
  MUTANT_WATCH="$(mutant_scripts "verifying-mutant-$control/orch" oversee-watch)/oversee-watch" || exit 1
  ln -s "$REPO_ROOT/skills/github" "$MUTANT_DIR/github"
  ln -s "$REPO_ROOT/skills/linear" "$MUTANT_DIR/linear"
  case "$control" in
    membership) mutate_verifying "$MUTANT_WATCH" 'In Progress,In Review,Verifying' 'In Progress,In Review' ;;
    event) mutate_verifying "$MUTANT_WATCH" 'select(.status == "due" or .status == "overdue")' 'select(false)' ;;
    filter) mutate_verifying "$MUTANT_WATCH" 'items="$(jq -c '\''map(select(.state != "verifying"))'\'' <<<"$items")"' 'items="$(jq -c '\''map(select(.state != "verifying"))'\'' <<<"$items")"; VERIFYING_LINES=""' ;;
    queue)
      old='    verifying_read "$items"'
      new='    items="$(jq -c --argjson fleet "$FLEET_STATE" '\''map(. as $item | select(($fleet.launch_queue // []) | index($item.id) | not))'\'' <<<"$items")"
    verifying_read "$items"'
      mutate_verifying "$MUTANT_WATCH" "$old" "$new"
      ;;
  esac
  verifying_world "verifying_control_$control"
  WATCH_BIN="$MUTANT_WATCH" watch_pass -- --state "$STUB_DIR/state.json"
  if [[ "$control" == filter || "$control" == queue ]]; then
    if [[ "$(verification_lines)" != "$want_lines" ]]; then
      pass "control: the missing boxes violate the listing contract"
    else
      fail "control: the missing boxes violate the listing contract" "$OUT"
    fi
  fi
  if [[ "$control" != filter ]]; then
    if [[ "$(verification_events)" != "$want_events" ]]; then
      pass "control: $control violates the deadline event contract"
    else
      fail "control: $control violates the deadline event contract" "$OUT"
    fi
  fi
  assert_eq "rc=$RC" "rc=0" "control: $control reaches the watch result" "$ERR"
done

# The overseer consumes these machine fields. Each row changes one rule and
# observes the same script result, including a must-fail production mutation.
verifying_one() {
  world "$1"
  local trigger="$2" blockers="${3:-[]}"
  jq --arg trigger "$trigger" --argjson blockers "$blockers" '
    map(if .id == "KEN-1" then .state = "Verifying" | .blocked_by_open = $blockers
      | .description = ("## Done when\n- [ ] Post-merge: Read health; Where: service; Why after merge: live release; Trigger: " + $trigger + "; Deadline: 2026-10-03T00:00:00Z") else . end)' \
    "$STUB_DIR/tracker.out" >"$STUB_DIR/one.json"
  mv -- "$STUB_DIR/one.json" "$STUB_DIR/tracker.out"
  jq -nr '"2026-10-02T00:00:01Z" | fromdateiso8601' >"$STUB_DIR/now.epoch"
}
box_status() { awk '$1 == "verifying" && $2 == "KEN-1" {for(i=1;i<=NF;i++) if($i ~ /^status=/) print $i}' <<<"$OUT"; }
while IFS='|' read -r name trigger blockers stamp want old new; do
  verifying_one "trigger_$name" "$trigger" "$blockers"
  [[ "$stamp" == - ]] || jq -nr --arg stamp "$stamp" '$stamp | fromdateiso8601' >"$STUB_DIR/now.epoch"
  watch_pass -- --state "$STUB_DIR/state.json"
  assert_eq "rc=$RC $(box_status)" "rc=0 status=$want" "$name status" "$ERR"
  watch_pass -- --state "$STUB_DIR/state.json"
  assert_eq "rc=$RC $(box_status) events=$(verification_events)" "rc=0 status=$want events=" "$name persists on every pass" "$ERR"
  MUTANT_DIR="$TMP_ROOT/trigger-mutant-$name"
  MUTANT_WATCH="$(mutant_scripts "trigger-mutant-$name/orch" oversee-watch)/oversee-watch" || exit 1
  ln -s "$REPO_ROOT/skills/github" "$MUTANT_DIR/github"
  ln -s "$REPO_ROOT/skills/linear" "$MUTANT_DIR/linear"
  mutate_verifying "$MUTANT_WATCH" "$old" "$new"
  WATCH_BIN="$MUTANT_WATCH" watch_pass -- --state "$STUB_DIR/state.json"
  assert_eq "$RC" 0 "control: $name reaches the status result" "$ERR"
  if [[ "$(box_status)" != "status=$want" ]]; then pass "control: $name violates its status contract"; else fail "control: $name violates its status contract" "$OUT"; fi
done <<'ROWS'
due|merge|[]|-|due|else "due" end|else "waiting" end
waiting|2026-10-02T12:00:00Z|[]|-|waiting|.trigger_epoch > $now|false
overdue|merge|[]|2026-10-03T00:00:01Z|overdue|.deadline_epoch <= $now|false
blocked|merge|["KEN-99"]|-|blocked|elif $blocked then|elif false then
ROWS
verifying_one blocker_closed merge '["KEN-99"]'
watch_pass -- --state "$STUB_DIR/state.json"
assert_eq "$(verification_events)" "" "a blocker holds due attention" "$ERR"
jq 'map(.blocked_by_open = [])' "$STUB_DIR/tracker.out" >"$STUB_DIR/unblocked.json"
mv -- "$STUB_DIR/unblocked.json" "$STUB_DIR/tracker.out"
watch_pass -- --state "$STUB_DIR/state.json"
assert_eq "$(box_status)" 'status=due' "closing a blocker repeats the original check" "$ERR"
assert_contains "$(verification_events)" 'status=due' "closing a blocker raises due attention" "$ERR"
jq 'map(if .id == "KEN-1" then .description |= sub("\\[ \\]"; "[x]") else . end)' "$STUB_DIR/tracker.out" >"$STUB_DIR/ticked.json"
mv -- "$STUB_DIR/ticked.json" "$STUB_DIR/tracker.out"
watch_pass -- --state "$STUB_DIR/state.json"
assert_eq "$(box_status)" '' "a tick removes the due box" "$ERR"
assert_contains "$(verification_lines)" 'verifying KEN-1 boxes=0' "all ticked boxes request completion" "$ERR"

release_world() {
  verifying_one "$1" "${2:-release owner/releases v*}"
  jq 'map(if .id == "KEN-1" then .description |= sub("Deadline: [^;]+$"; "Deadline: +24h") else . end)' "$STUB_DIR/tracker.out" >"$STUB_DIR/release-items.json"
  mv -- "$STUB_DIR/release-items.json" "$STUB_DIR/tracker.out"
  printf '%s\n' '[{"number":1,"headRefName":"ken-1","mergedAt":"2026-10-01T00:00:00Z"}]' >"$STUB_DIR/merged.json"
  printf '%s\n' '[{"tagName":"v3","publishedAt":"2026-10-02T00:00:00Z","isDraft":false},{"tagName":"other","publishedAt":"2026-10-01T00:00:01Z","isDraft":false},{"tagName":"vdraft","publishedAt":"2026-10-01T00:00:02Z","isDraft":true},{"tagName":"v2","publishedAt":"2026-10-01T12:00:00Z","isDraft":false},{"tagName":"v1","publishedAt":"2026-09-30T00:00:00Z","isDraft":false}]' >"$STUB_DIR/releases.owner_releases.json"
}
# Both scripts read the same Linear boxes and GitHub evidence. The adapters
# only translate each external API's row format; they do not judge boxes.
RECONCILE_SCRIPTS="$(mutant_scripts shared-reconcile/orch)" || exit 1
mkdir -p "$TMP_ROOT/shared-reconcile/linear/scripts"
ln -s "$REPO_ROOT/skills/linear/scripts/lib" "$TMP_ROOT/shared-reconcile/linear/scripts/lib"
cat >"$TMP_ROOT/shared-reconcile/linear/scripts/linear.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
jq -c '{issues:{nodes:[.[] | select(.state == "Verifying")
  | {identifier:.id, id:("uuid-" + .id), description, title:"verification",
     state:{name:"Verifying",type:"started"}, updatedAt:"2026-10-01T00:00:00Z",
     archivedAt:null, trashed:false,
     inverseRelations:{nodes:[(.blocked_by_open // [])[]
       | {type:"blocks",issue:{identifier:.,state:{name:"In Progress",type:"started"}}}]}}]}}' "$STUB_DIR/tracker.out"
SH
cat >"$TMP_ROOT/bin/reconcile-gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${X:-}" == 1 ]]; then
  printf '%s X=%s\n' "$1 $2" "$X" >>"$STUB_DIR/command.calls"
fi
if [[ "$1 $2" == 'pr list' ]]; then
  [[ ! -f "$STUB_DIR/reconcile-pr-fail" ]] || { echo 'HTTP 502' >&2; exit 1; }
  head=''
  while [[ $# -gt 0 ]]; do
    case "$1" in --head) head="$2"; shift ;; esac
    shift
  done
  jq -c --arg head "$head" 'map(select(.headRefName == $head)
    | . + {state:"MERGED",isCrossRepository:false,url:("https://github.com/owner/repo/pull/" + (.number | tostring))})' "$STUB_DIR/merged.json"
else
  exec "${BASH_SOURCE[0]%/*}/gh" "$@"
fi
SH
chmod +x "$TMP_ROOT/shared-reconcile/linear/scripts/linear.sh" "$TMP_ROOT/bin/reconcile-gh"
reconcile_same_world() {
  local scripts="${1:-$RECONCILE_SCRIPTS}" gh_command="${2:-$TMP_ROOT/bin/reconcile-gh}"
  RECONCILE_RC=0
  RECONCILE_OUT="$(cd "$TMP_ROOT/repo" && env -i PATH="$TMP_ROOT/bin:$PATH" HOME="$TMP_ROOT" STUB_DIR="$STUB_DIR" \
    OVERSEE_TEST_REAL_DATE="$OVERSEE_TEST_REAL_DATE" RECONCILE_GH_CLI="$gh_command" \
    "$scripts/reconcile-work-items" 2>"$STUB_DIR/reconcile.err")" || RECONCILE_RC=$?
}
while IFS='|' read -r name trigger blockers now deadline status control merge_at; do
  verifying_one "shared_$name" "$trigger" "$blockers"
  gh_command="$TMP_ROOT/bin/reconcile-gh"
  [[ "$control" != arguments ]] || gh_command="env X=1 $gh_command"
  jq --arg d "$deadline" 'map(if .id == "KEN-1" then .description |= sub("Deadline: [^;]+$"; "Deadline: " + $d) else . end)' \
    "$STUB_DIR/tracker.out" >"$STUB_DIR/shared.json"
  mv -- "$STUB_DIR/shared.json" "$STUB_DIR/tracker.out"
  jq -nr --arg now "$now" '$now | fromdateiso8601' >"$STUB_DIR/now.epoch"
  printf '%s\n' '[{"number":1,"headRefName":"ken-1","mergedAt":"2026-10-01T00:00:00Z","mergeCommit":{"oid":"1111111111111111111111111111111111111111"}}]' >"$STUB_DIR/merged.json"
  if [[ -n "$merge_at" ]]; then
    jq --arg at "$merge_at" 'map(.mergedAt = $at)' "$STUB_DIR/merged.json" >"$STUB_DIR/fractional.json"
    mv -- "$STUB_DIR/fractional.json" "$STUB_DIR/merged.json"
  fi
  printf '%s\n' '[{"tagName":"v1","publishedAt":"2026-10-02T00:00:00Z","isDraft":false}]' >"$STUB_DIR/releases.owner_releases.json"
  case "$control" in
    cutoff|waiting|fractional) echo '[]' >"$STUB_DIR/releases.owner_releases.json" ;;
    containment|arguments)
      printf '%s\n' '[{"tagName":"v3","publishedAt":"2026-10-02T00:00:00Z","isDraft":false},{"tagName":"v2","publishedAt":"2026-10-01T12:00:00Z","isDraft":false}]' >"$STUB_DIR/releases.owner_repo.json"
      printf '%s\n' '{"status":"behind"}' >"$STUB_DIR/compare.owner_repo_compare_1111111111111111111111111111111111111111...v2.json"
      printf '%s\n' '{"status":"ahead"}' >"$STUB_DIR/compare.owner_repo_compare_1111111111111111111111111111111111111111...v3.json"
      ;;
    missing)
      jq '[{id:"KEN-0",state:"Verifying",priority:2,
          description:"## Done when\n- [ ] Post-merge: Read health; Where: service; Why after merge: live release; Trigger: release owner/releases v*; Deadline: +24h"}] + .' \
        "$STUB_DIR/tracker.out" >"$STUB_DIR/missing-first.json"
      mv -- "$STUB_DIR/missing-first.json" "$STUB_DIR/tracker.out"
      jq '. + [{number:2,headRefName:"claude/cloud-session",body:"Closes KEN-0",mergedAt:"2026-10-01T00:00:00Z",
          mergeCommit:{oid:"2222222222222222222222222222222222222222"}}]' "$STUB_DIR/merged.json" >"$STUB_DIR/cloud-merge.json"
      mv -- "$STUB_DIR/cloud-merge.json" "$STUB_DIR/merged.json"
      ;;
    invalid)
      jq '[{id:"KEN-0",state:"Verifying",priority:2,description:"## Done when\n- [ ] Post-merge: malformed"}] + .' \
        "$STUB_DIR/tracker.out" >"$STUB_DIR/invalid-first.json"
      mv -- "$STUB_DIR/invalid-first.json" "$STUB_DIR/tracker.out"
      ;;
  esac
  watch_pass -- --state "$STUB_DIR/state.json"
  assert_eq "$RC" 0 "$name watch completes the inventory" "$ERR"
  watch_lines="$(verification_lines)"
  expected="verifying KEN-1 box=1 trigger=\"$trigger\" status=$status deadline=$deadline blocked_by="
  case "$control" in
    release) expected="${expected%deadline=*}deadline=2026-10-03T00:00:00Z blocked_by=KEN-99" ;;
    containment|arguments) expected="${expected%deadline=*}deadline=2026-10-03T00:00:00Z blocked_by=-" ;;
    cutoff|waiting|fractional) expected="${expected%deadline=*}deadline=2026-10-04T00:00:00Z blocked_by=-" ;;
    *) [[ "$blockers" != '[]' ]] && expected+=KEN-99 || expected+=- ;;
  esac
  expected+=' reading="Read health" where="service" why="live release"'
  expected_watch="$expected"
  if [[ "$control" == missing ]]; then
    expected_watch='verifying KEN-0 box=1 trigger="release owner/releases v*" status=due deadline=2026-10-03T00:00:00Z blocked_by=- reading="Read health" where="service" why="live release"'$'\n'"$expected"
  fi
  assert_eq "$watch_lines" "$expected_watch" "$name status, date and blockers" "$ERR"
  reconcile_same_world "$RECONCILE_SCRIPTS" "$gh_command"
  assert_eq "$(awk '/^verifying /' <<<"$RECONCILE_OUT")" "$expected" "$name callers print identical lines for readable local merge evidence" "$STUB_DIR/reconcile.err"
  if [[ "$control" == arguments ]]; then
    assert_eq "$RECONCILE_RC" 0 "command arguments reach a complete release judgement" "$STUB_DIR/reconcile.err"
    assert_eq "$(cat "$STUB_DIR/command.calls")" $'pr list X=1\nrelease list X=1\napi repos/owner/repo/compare/1111111111111111111111111111111111111111...v2 X=1\napi repos/owner/repo/compare/1111111111111111111111111111111111111111...v3 X=1' \
      "command arguments reach the probe, release list and containment calls" "$STUB_DIR/reconcile.err"
  fi
  if [[ "$control" == missing ]]; then
    assert_eq "$RECONCILE_RC" 1 "a missing local merge is an item finding" "$STUB_DIR/reconcile.err"
    assert_contains "$RECONCILE_OUT" 'verifying-merge-unread issue=KEN-0' "the missing merge item is named"
    assert_contains "$RECONCILE_OUT" 'verifying-counts due=1 overdue=0 blocked=0 waiting=0 items=2' "the later valid item is read and counted"
    touch "$STUB_DIR/reconcile-pr-fail"
    reconcile_same_world
    assert_eq "$RECONCILE_RC" 2 "a failed GitHub read remains fatal" "$STUB_DIR/reconcile.err"
    assert_contains "$(cat "$STUB_DIR/reconcile.err")" 'verifying-merge-unread issue=KEN-0' "the failed read names its item"
    assert_not_contains "$RECONCILE_OUT" 'verifying-counts' "a failed read supplies no complete counts"
    rm -- "$STUB_DIR/reconcile-pr-fail"
  fi
  if [[ "$control" == invalid ]]; then
    assert_eq "$(grep -c '^oversee-watch: verifying-invalid issue=KEN-0$' "$ERR" || true)" 1 "invalid item reports its key" "$ERR"
    assert_contains "$(cat "$ERR")" '"box":1' "invalid item includes parser box evidence" "$ERR"
    assert_contains "$(verification_events)" 'EVENT verifying-deadline KEN-1 box=1' "valid due item emits its event after invalid item" "$ERR"
    committed="$(find "$STATE_DIR" -type f -exec cat {} +)"
    assert_contains "$committed" $'verifying-deadline\tKEN-1\tbox=1' "due set commits after invalid item" "$ERR"
    assert_contains "$RECONCILE_OUT" 'verifying-invalid issue=KEN-0' "reconciliation reports invalid item and continues"
  fi
  # Restore each old failure in a disposable production copy. Each row
  # observes the contract above fail while the fixture still reaches it.
  MUTANT_DIR="$TMP_ROOT/shared-old-$name"
  if [[ "$control" == fractional || "$control" == missing || "$control" == containment || "$control" == arguments ]]; then
    MUTANT_RW="$(mutant_scripts "shared-old-$name/orch" reconcile-work-items)/reconcile-work-items" || exit 1
    ln -s "$TMP_ROOT/shared-reconcile/linear" "$MUTANT_DIR/linear"
    case "$control" in
      fractional) mutate_file "$MUTANT_RW" 'sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601' 'fromdateiso8601' ;;
      missing) mutate_file "$MUTANT_RW" 'if [ "$merge_epoch" = none ]; then' 'if [ "$merge_epoch" = none ]; then config_error verifying-merge-unread "issue=$iid"' ;;
      containment) mutate_file "$MUTANT_RW" 'read -r open merged unmerged merged_at merged_repos merge_epoch <<<"$prs"' 'read -r open merged unmerged merged_at merged_repos merge_epoch <<<"$prs"; merged_repos="{}"' ;;
      arguments)
        mutate_verifying "$MUTANT_RW" '$gh_cli release list' '"$gh_cli" release list'
        mutate_verifying "$MUTANT_RW" '$gh_cli api' '"$gh_cli" api'
        : >"$STUB_DIR/command.calls"
        ;;
    esac
    reconcile_same_world "${MUTANT_RW%/*}" "$gh_command"
    if [[ "$control" == containment ]]; then
      assert_eq "$RECONCILE_RC" 0 "control: dropped merge evidence still reaches a release judgement" "$STUB_DIR/reconcile.err"
      assert_contains "$RECONCILE_OUT" 'deadline=2026-10-02T12:00:00Z' "control: dropped merge evidence chooses the tag without the merge"
    else
      assert_eq "$RECONCILE_RC" 2 "control: $name stops before the required result" "$STUB_DIR/reconcile.err"
    fi
    if [[ "$control" == arguments ]]; then
      assert_eq "$(cat "$STUB_DIR/command.calls")" 'pr list X=1' "control: quoting the command keeps the probe but loses the release calls" "$STUB_DIR/reconcile.err"
    fi
    assert_not_contains "$RECONCILE_OUT" "$expected" "control: $name loses the independently expected box line"
    continue
  fi
  MUTANT_WATCH="$(mutant_scripts "shared-old-$name/orch" oversee-watch)/oversee-watch" || exit 1
  ln -s "$REPO_ROOT/skills/github" "$MUTANT_DIR/github"
  ln -s "$REPO_ROOT/skills/linear" "$MUTANT_DIR/linear"
  case "$control" in
    overdue) mutate_verifying "$MUTANT_WATCH" 'if .deadline_epoch <= $now then "overdue"' 'if .deadline_epoch <= $now and ($blocked | not) then "overdue"' ;;
    blockers) mutate_verifying "$MUTANT_WATCH" ' blocked_by=\($blocked)' '' ;;
    cutoff|waiting) mutate_verifying "$MUTANT_WATCH" '$merged + 259200' 'null' ;;
    release) mutate_verifying "$MUTANT_WATCH" 'if jq -e '\''any(.[]; .trigger_kind == "release")'\'' <<<"$boxes" >/dev/null; then' 'if [[ "$blocked" == false ]] && jq -e '\''any(.[]; .trigger_kind == "release")'\'' <<<"$boxes" >/dev/null; then' ;;
    invalid) mutate_verifying "$MUTANT_WATCH" 'if ! boxes="$(verifying_parse "$row" 2>"$errf")"; then' 'if ! boxes="$(verifying_parse "$row" 2>"$errf")"; then die verifying-invalid "" "issue=$id"' ;;
  esac
  # A fresh event store is necessary to observe the invalid row's commit.
  WATCH_BIN="$MUTANT_WATCH" watch_pass OVERSEE_WATCH_STATE_DIR="$STUB_DIR/old-state" -- --state "$STUB_DIR/state.json"
  if [[ "$RC" != 0 || "$(verification_lines)" != "$expected" ]]; then
    pass "control: $name rejects the previous reader's result"
  else
    fail "control: $name rejects the previous reader's result" "$OUT"
  fi
done <<'ROWS'
blocked_overdue|merge|["KEN-99"]|2026-10-03T00:00:01Z|2026-10-03T00:00:00Z|overdue|overdue
blocked_future|merge|["KEN-99"]|2026-10-02T00:00:01Z|2026-10-03T00:00:00Z|blocked|blockers
release_unfired_late|release owner/releases v*|[]|2026-10-04T01:00:00Z|+24h|overdue|cutoff
release_blocked|release owner/releases v*|["KEN-99"]|2026-10-02T00:00:01Z|+24h|blocked|release
release_waiting|release owner/releases v*|[]|2026-10-02T00:00:01Z|+24h|waiting|waiting
invalid_then_due|merge|[]|2026-10-02T00:00:01Z|2026-10-03T00:00:00Z|due|invalid
fractional_merge|release owner/releases v*|[]|2026-10-02T00:00:01Z|+24h|waiting|fractional|2026-10-01T00:00:00.123Z
missing_merge_then_due|merge|[]|2026-10-02T00:00:01Z|2026-10-03T00:00:00Z|due|missing
release_contains_merge|release owner/repo v*|[]|2026-10-02T00:00:01Z|+24h|due|containment
command_arguments|release owner/repo v*|[]|2026-10-02T00:00:01Z|+24h|due|arguments
ROWS

release_world release_first
watch_pass -- --state "$STUB_DIR/state.json"
assert_eq "rc=$RC $(box_status)" 'rc=0 status=due' "the first matching publication after merge fires" "$ERR"
assert_contains "$(verification_lines)" 'deadline=2026-10-02T12:00:00Z' "the deadline uses the first matching publication" "$ERR"
assert_eq "$(awk '/^api repos\/.*\/compare\// {n++} END {print n+0}' "$STUB_DIR/gh.calls")" 0 "a release in another repository makes no compare call" "$ERR"
watch_pass -- --state "$STUB_DIR/state.json"
assert_eq "rc=$RC $(box_status) events=$(verification_events)" 'rc=0 status=due events=' "release evidence stays due on every pass" "$ERR"

# GitHub's compare response is the containment evidence. The older merged row
# comes last to prove selection uses merge time, not the API's row order.
own_release_world() {
  release_world "$1" 'release owner/repo v*'
  cp "$STUB_DIR/releases.owner_releases.json" "$STUB_DIR/releases.owner_repo.json"
  printf '%s\n' '[{"number":1,"headRefName":"ken-1","mergedAt":"2026-10-01T00:00:00Z","mergeCommit":{"oid":"1111111111111111111111111111111111111111"}},{"number":2,"headRefName":"ken-1","mergedAt":"2026-09-30T00:00:00Z","mergeCommit":{"oid":"2222222222222222222222222222222222222222"}}]' >"$STUB_DIR/merged.json"
  jq -nc --arg status "$2" '{status:$status}' >"$STUB_DIR/compare.owner_repo_compare_1111111111111111111111111111111111111111...v2.json"
  jq -nc --arg status "$3" '{status:$status}' >"$STUB_DIR/compare.owner_repo_compare_1111111111111111111111111111111111111111...v3.json"
}
while IFS='|' read -r name first second status deadline calls; do
  own_release_world "release_contains_$name" "$first" "$second"
  watch_pass -- --state "$STUB_DIR/state.json"
  assert_eq "rc=$RC $(box_status)" "rc=0 status=$status" "$name containment status" "$ERR"
  assert_contains "$(verification_lines)" "deadline=$deadline" "$name containment deadline" "$ERR"
  assert_eq "$(awk '/^api repos\/.*\/compare\// {n++} END {print n+0}' "$STUB_DIR/gh.calls")" "$calls" "$name compares only matching candidates through the first contained tag" "$ERR"
  if [[ "$status" == waiting ]]; then
    assert_eq "$(verification_events)" '' "$name raises no verification event" "$ERR"
  fi
done <<'ROWS'
behind_then_ahead|behind|ahead|due|2026-10-03T00:00:00Z|2
behind_then_identical|behind|identical|due|2026-10-03T00:00:00Z|2
first_ahead|ahead|behind|due|2026-10-02T12:00:00Z|1
first_identical|identical|behind|due|2026-10-02T12:00:00Z|1
behind_and_diverged|behind|diverged|waiting|2026-10-04T00:00:00Z|2
ROWS
while IFS='|' read -r name setup; do
  own_release_world "release_compare_unread_$name" behind ahead
  case "$setup" in
    fail) echo 'HTTP 502' >"$STUB_DIR/compare.owner_repo_compare_1111111111111111111111111111111111111111...v2.err" ;;
    missing) echo '{}' >"$STUB_DIR/compare.owner_repo_compare_1111111111111111111111111111111111111111...v2.json" ;;
    number) echo '{"status":42}' >"$STUB_DIR/compare.owner_repo_compare_1111111111111111111111111111111111111111...v2.json" ;;
    unknown) echo '{"status":"unknown"}' >"$STUB_DIR/compare.owner_repo_compare_1111111111111111111111111111111111111111...v2.json" ;;
    oid) jq 'map(.mergeCommit.oid = null)' "$STUB_DIR/merged.json" >"$STUB_DIR/invalid-oid.json"; mv -- "$STUB_DIR/invalid-oid.json" "$STUB_DIR/merged.json" ;;
  esac
  watch_pass -- --state "$STUB_DIR/state.json"
  assert_eq "rc=$RC status=$(box_status) key=$(grep -c '^oversee-watch: verifying-release-unread ' "$ERR" || true)" 'rc=2 status= key=1' "$name compare evidence refuses instead of waiting" "$ERR"
done <<'ROWS'
read|fail
missing_status|missing
numeric_status|number
unknown_status|unknown
missing_oid|oid
ROWS
# Each control changes a disposable production copy and reaches the same
# containment assertion. The first restores the old publication-only choice.
while IFS='@' read -r name first old new; do
  own_release_world "release_contains_control_$name" "$first" ahead
  MUTANT_DIR="$TMP_ROOT/release-contains-$name"
  MUTANT_WATCH="$(mutant_scripts "release-contains-$name/orch" oversee-watch)/oversee-watch" || exit 1
  ln -s "$REPO_ROOT/skills/github" "$MUTANT_DIR/github"
  ln -s "$REPO_ROOT/skills/linear" "$MUTANT_DIR/linear"
  mutate_verifying "$MUTANT_WATCH" "$old" "$new"
  WATCH_BIN="$MUTANT_WATCH" watch_pass -- --state "$STUB_DIR/state.json"
  got="rc=$RC $(box_status) deadline=$(awk '$1 == "verifying" && $2 == "KEN-1" {for(i=1;i<=NF;i++) if($i ~ /^deadline=/) print substr($i,10)}' <<<"$OUT")"
  if [[ "$got" != 'rc=0 status=due deadline=2026-10-03T00:00:00Z' ]]; then
    pass "control: $name violates the contained release contract"
  else
    fail "control: $name violates the contained release contract" "$OUT"
  fi
done <<'ROWS'
old_code@behind@if [[ -n "$oid" ]]; then@if false; then
behind_contained@behind@ahead|identical)@ahead|identical|behind)
diverged_contained@diverged@ahead|identical)@ahead|identical|diverged)
latest_merge@behind@max_by(.at) // null@min_by(.at) // null
ROWS
while IFS='@' read -r name setup old new; do
  own_release_world "release_compare_guard_$name" behind ahead
  case "$setup" in
    failed) echo 'HTTP 502' >"$STUB_DIR/compare.owner_repo_compare_1111111111111111111111111111111111111111...v2.err" ;;
    malformed) echo '{"status":"unknown"}' >"$STUB_DIR/compare.owner_repo_compare_1111111111111111111111111111111111111111...v2.json" ;;
    oid) jq 'map(.mergeCommit.oid = "invalid")' "$STUB_DIR/merged.json" >"$STUB_DIR/invalid-oid.json"; mv -- "$STUB_DIR/invalid-oid.json" "$STUB_DIR/merged.json" ;;
  esac
  MUTANT_DIR="$TMP_ROOT/release-compare-guard-$name"
  MUTANT_WATCH="$(mutant_scripts "release-compare-guard-$name/orch" oversee-watch)/oversee-watch" || exit 1
  ln -s "$REPO_ROOT/skills/github" "$MUTANT_DIR/github"
  ln -s "$REPO_ROOT/skills/linear" "$MUTANT_DIR/linear"
  mutate_verifying "$MUTANT_WATCH" "$old" "$new"
  watch_pass -- --state "$STUB_DIR/state.json"
  assert_eq "$RC" 2 "$name refuses unreadable containment evidence" "$ERR"
  WATCH_BIN="$MUTANT_WATCH" watch_pass -- --state "$STUB_DIR/state.json"
  assert_eq "rc=$RC $(box_status)" 'rc=0 status=due' "control: $name bypasses its evidence guard" "$ERR"
done <<'ROWS'
failed_read@failed@|| { verifying_error verifying-release-unread "$(cat "$errf")" "issue=$id" "repo=$repo" "tag=$tag"; return 2; }@|| comparison=behind
malformed_status@malformed@*) verifying_error verifying-release-unread "issue=$id" "repo=$repo" "tag=$tag" "status=$comparison"; return 2 ;;@*) continue ;;
missing_commit@oid@select(test("^[0-9a-fA-F]{40}$"))@""
ROWS

release_world release_escaped 'release owner/releases v\*'
watch_pass -- --state "$STUB_DIR/state.json"
assert_eq "rc=$RC $(box_status)" 'rc=0 status=due' "a Markdown-escaped release glob fires in the first pass" "$ERR"
assert_contains "$(verification_lines)" 'deadline=2026-10-02T12:00:00Z' "the escaped glob uses the first matching publication" "$ERR"
MUTANT_DIR="$TMP_ROOT/release-escape-mutant"
MUTANT_WATCH="$(mutant_scripts release-escape-mutant/orch)/oversee-watch" || exit 1
ln -s "$REPO_ROOT/skills/github" "$MUTANT_DIR/github"
mkdir -p "$MUTANT_DIR/linear/scripts/lib"
cp "$REPO_ROOT/skills/linear/scripts/lib/issue-validation.sh" "$MUTANT_DIR/linear/scripts/lib/issue-validation.sh"
mutate_file "$MUTANT_DIR/linear/scripts/lib/issue-validation.sh" \
  'gsub("\\\\(?<punct>[\\x21-\\x2f\\x3a-\\x40\\x5b-\\x60\\x7b-\\x7e])"; .punct)' '.'
rm -- "$TMP_ROOT/repo/.agents/skills/linear"
ln -s "$MUTANT_DIR/linear" "$TMP_ROOT/repo/.agents/skills/linear"
WATCH_BIN="$MUTANT_WATCH" watch_pass -- --state "$STUB_DIR/state.json"
rm -- "$TMP_ROOT/repo/.agents/skills/linear"
ln -s "$REPO_ROOT/skills/linear" "$TMP_ROOT/repo/.agents/skills/linear"
assert_eq "rc=$RC $(box_status)" 'rc=0 status=waiting' "control: skipping parser unescape violates the escaped glob's due status" "$ERR"
release_world release_waiting
printf '%s\n' '[]' >"$STUB_DIR/releases.owner_releases.json"
watch_pass -- --state "$STUB_DIR/state.json"
assert_eq "rc=$RC $(box_status) events=$(verification_events)" 'rc=0 status=waiting events=' "no matching publication waits without an event" "$ERR"
while IFS='|' read -r name setup key; do
  release_world "release_unread_$name"
  case "$setup" in
    fail) touch "$STUB_DIR/release-fail" ;;
    invalid) echo '{}' >"$STUB_DIR/releases.owner_releases.json" ;;
    timestamp) echo '[{"tagName":"v1","publishedAt":"invalid","isDraft":false}]' >"$STUB_DIR/releases.owner_releases.json" ;;
    truncated) jq -n '[range(1000) | {tagName:"v1",publishedAt:"2026-10-01T12:00:00Z",isDraft:false}]' >"$STUB_DIR/releases.owner_releases.json" ;;
    merge) echo '[]' >"$STUB_DIR/merged.json" ;;
  esac
  watch_pass -- --state "$STUB_DIR/state.json"
  assert_eq "rc=$RC status=$(box_status) key=$(grep -c "^oversee-watch: $key " "$ERR" || true)" 'rc=2 status= key=1' "unread $name refuses instead of waiting" "$ERR"
done <<'ROWS'
read|fail|verifying-release-unread
shape|invalid|verifying-release-unread
time|timestamp|verifying-release-unread
page|truncated|verifying-release-unread
merge|merge|verifying-merge-unread
ROWS
# The controls keep the release read and violate its selection decisions.
while IFS='|' read -r name old new; do
  release_world "release_control_$name"
  MUTANT_DIR="$TMP_ROOT/release-mutant-$name"
  MUTANT_WATCH="$(mutant_scripts "release-mutant-$name/orch" oversee-watch)/oversee-watch" || exit 1
  ln -s "$REPO_ROOT/skills/github" "$MUTANT_DIR/github"
  ln -s "$REPO_ROOT/skills/linear" "$MUTANT_DIR/linear"
  mutate_verifying "$MUTANT_WATCH" "$old" "$new"
  WATCH_BIN="$MUTANT_WATCH" watch_pass -- --state "$STUB_DIR/state.json"
  assert_eq "$RC" 0 "control: $name reaches the publication result" "$ERR"
  if [[ "$(verification_lines)" != *'deadline=2026-10-02T12:00:00Z'* ]]; then pass "control: $name violates publication selection"; else fail "control: $name violates publication selection" "$OUT"; fi
done <<'ROWS'
floor|select(.at > $merged)|select(true)
first|sort_by(.at)[]|sort_by(.at) | reverse | .[]
glob|[[ "$tag" == $glob ]]|[[ "$tag" == * ]]
draft|select(.isDraft == false)|select(true)
ROWS

# Each release-read guard has a control at its own failing input.
while IFS='@' read -r name fixture old new; do
  release_world "release_guard_$name"
  case "$fixture" in
    shape) echo '{}' >"$STUB_DIR/releases.owner_releases.json" ;;
    page) jq -n '[range(1000) | {tagName:"v1",publishedAt:"2026-10-01T12:00:00Z",isDraft:false}]' >"$STUB_DIR/releases.owner_releases.json" ;;
    time) echo '[{"tagName":"v1","publishedAt":"2026-09-31T12:00:00Z","isDraft":false}]' >"$STUB_DIR/releases.owner_releases.json" ;;
    tag) echo '[{"tagName":42,"publishedAt":"2026-10-01T12:00:00Z","isDraft":false}]' >"$STUB_DIR/releases.owner_releases.json" ;;
    draft) echo '[{"tagName":"v1","publishedAt":"2026-10-01T12:00:00Z"}]' >"$STUB_DIR/releases.owner_releases.json" ;;
    merge) echo '[]' >"$STUB_DIR/merged.json" ;;
  esac
  MUTANT_DIR="$TMP_ROOT/release-guard-$name"
  MUTANT_WATCH="$(mutant_scripts "release-guard-$name/orch" oversee-watch)/oversee-watch" || exit 1
  ln -s "$REPO_ROOT/skills/github" "$MUTANT_DIR/github"
  ln -s "$REPO_ROOT/skills/linear" "$MUTANT_DIR/linear"
  mutate_verifying "$MUTANT_WATCH" "$old" "$new"
  watch_pass -- --state "$STUB_DIR/state.json"
  assert_eq "$RC" 2 "$name guard refuses incomplete evidence" "$ERR"
  WATCH_BIN="$MUTANT_WATCH" watch_pass -- --state "$STUB_DIR/state.json"
  assert_eq "$RC" 0 "control: $name bypasses its evidence guard" "$ERR"
done <<'ROWS'
shape@shape@if type != "array" or length >= $limit then@if false or length >= $limit then
page@page@or length >= $limit@or false
time@time@todateiso8601 == $stamp@true
draft@draft@(.isDraft | type) != "boolean"@false
tag@tag@(.tagName | type) != "string"@false
merge@merge@[[ "$merged" != null ]]@[[ true ]]
ROWS
release_world release_read_control
touch "$STUB_DIR/release-fail"
MUTANT_DIR="$TMP_ROOT/release-read-mutant"
MUTANT_WATCH="$(mutant_scripts "release-read-mutant/orch" oversee-watch)/oversee-watch" || exit 1
ln -s "$REPO_ROOT/skills/github" "$MUTANT_DIR/github"
ln -s "$REPO_ROOT/skills/linear" "$MUTANT_DIR/linear"
old='releases="$($gh_cli release list --repo "$repo" --limit "$release_limit" --json tagName,publishedAt,isDraft 2>"$errf")" \
        || { verifying_error verifying-release-unread "$(cat "$errf")" "issue=$id" "repo=$repo"; return 2; }'
new='releases="$($gh_cli release list --repo "$repo" --limit "$release_limit" --json tagName,publishedAt,isDraft 2>"$errf")" || :'
mutate_verifying "$MUTANT_WATCH" "$old" "$new"
WATCH_BIN="$MUTANT_WATCH" watch_pass -- --state "$STUB_DIR/state.json"
assert_eq "rc=$RC $(box_status)" 'rc=0 status=waiting' "control: ignoring the release read failure fabricates waiting" "$ERR"

# A due set's status change must raise attention even when its membership
# stays the same. Standing due lines still print without a second event.
verifying_one due_to_overdue merge
watch_pass -- --state "$STUB_DIR/state.json"
jq -nr '"2026-10-03T00:00:01Z" | fromdateiso8601' >"$STUB_DIR/now.epoch"
watch_pass -- --state "$STUB_DIR/state.json"
assert_contains "$(verification_events)" 'status=overdue' "due becoming overdue raises attention" "$ERR"
# Fresh state keeps the repeated-listing clock monotonic.
verifying_one repeated_due merge
watch_pass -- --state "$STUB_DIR/state.json"
MUTANT_DIR="$TMP_ROOT/repeat-mutant"
MUTANT_WATCH="$(mutant_scripts "repeat-mutant/orch" oversee-watch)/oversee-watch" || exit 1
ln -s "$REPO_ROOT/skills/github" "$MUTANT_DIR/github"
ln -s "$REPO_ROOT/skills/linear" "$MUTANT_DIR/linear"
mutate_verifying "$MUTANT_WATCH" '[[ "$prior" != "${due//$'"'"'\n'"'"'/|}" ]] || continue' '[[ "$prior" != "${due//$'"'"'\n'"'"'/|}" ]] || { VERIFYING_LINES=""; continue; }'
WATCH_BIN="$MUTANT_WATCH" watch_pass -- --state "$STUB_DIR/state.json"
assert_eq "$RC" 0 "control: repeat reaches the watch result" "$ERR"
assert_eq "$(box_status)" '' "control: dropping a standing due line violates repeated listing"
# Ticking stops listing even if the item's tracker transition is still open.
jq 'map(if .id == "KEN-1" then .description |= sub("\\[ \\]"; "[x]") else . end)' "$STUB_DIR/tracker.out" >"$STUB_DIR/checked.json"
mv -- "$STUB_DIR/checked.json" "$STUB_DIR/tracker.out"
MUTANT_DIR="$TMP_ROOT/tick-mutant"
MUTANT_WATCH="$(mutant_scripts "tick-mutant/orch" oversee-watch)/oversee-watch" || exit 1
ln -s "$REPO_ROOT/skills/github" "$MUTANT_DIR/github"
ln -s "$REPO_ROOT/skills/linear" "$MUTANT_DIR/linear"
mutate_verifying "$MUTANT_WATCH" 'select(.post_merge and (.checked | not))' 'select(.post_merge)'
WATCH_BIN="$MUTANT_WATCH" watch_pass -- --state "$STUB_DIR/state.json"
assert_eq "$RC" 0 "control: tick reaches the watch result" "$ERR"
assert_eq "$(box_status)" 'status=due' "control: ignoring a tick violates removal of the due box" "$ERR"

echo "=== must-fail controls ==="
# Rows, on `@` since the replaced text carries `|`: the world it runs in @
# name @ text the mutant replaces @ its replacement @ item, notices, pi-pick
# or state-invalid @ result. Each removes one rule of owed_read and leaves
# the rest standing.
MUTANT_N=0
while IFS='@' read -r setup name old new item want; do
  MUTANT_N=$((MUTANT_N + 1))
  MUTANT_DIR="$TMP_ROOT/owed-mutant-$MUTANT_N"
  MUTANT_WATCH="$(mutant_scripts "owed-mutant-$MUTANT_N/orch" oversee-watch)/oversee-watch" || exit 1
  ln -s "$REPO_ROOT/skills/github" "$MUTANT_DIR/github"
  ln -s "$REPO_ROOT/skills/linear" "$MUTANT_DIR/linear"
  mutate_verifying "$MUTANT_WATCH" "$old" "$new"
  "$setup" "owed_mutant_$name"
  WATCH_BIN="$MUTANT_WATCH" watch_pass -- --state "$STUB_DIR/state.json"
  if [[ "$item" == notices ]]; then
    got="$(notices)"
  elif [[ "$item" == pi-pick ]]; then
    got="requests=$(grep -cx 'local pick --harness pi --json' "$STUB_DIR/lanes.hosts" || true)"
  elif [[ "$item" == state-invalid ]]; then
    got="rc=$RC heartbeat=$(grep -c '^EVENT heartbeat' <<<"$OUT" || true) key=$(grep -c '^oversee-watch: state-invalid option=--state path=' "$ERR" || true)"
  else
    got="$(owed "$item")"
  fi
  assert_eq "$got" "$want" "control: $name" "$ERR"
done <<'ROWS'
world@without the in-flight exclusion an item with a running lane is owed@($rec | in_flight | not)@true@KEN-1@owed KEN-1 state=in-progress priority=1 lane=running verdict=queue
world@without the merged verdict a cycle record is judged for a wall@if [[ "$delivery" != - ]]; then@if false; then@KEN-5@owed KEN-5 state=in-review priority=2 lane=done verdict=queue
world@the PR-only cycle filter aborts on a direct record@elif has("commit") and (has("pr") | not)@elif false and (has("pr") | not)@state-invalid@rc=2 heartbeat=0 key=1
world@without the roster membership test a harness with no account is asked of pick@any(.[]; .harness == $h)@true@pi-pick@requests=1
world@without the record's model the pick judges the binding bucket@[[ "$model" == - ]] || args+=(--model "$model")@:@KEN-11@owed KEN-11 state=in-progress priority=1 lane=stopped verdict=queue
world@without the record's host the pick judges the default host's accounts@env ORCH_LANE_HOST="$host" "$LANES_CLI" "${args@"$LANES_CLI" "${args@KEN-12@owed KEN-12 state=in-progress priority=2 lane=stopped verdict=dated harness=codex until=2026-10-03T00:00:00Z
world@without the pick's own reset the wall goes undated@.walled_resets_at | if . == null then "-"@null | if . == null then "-"@KEN-3@owed KEN-3 state=in-progress priority=1 lane=stopped verdict=dated harness=codex until=-
noisy@without forwarding a listing's notices are dropped@jq -e 'type == "array"' <<<"$BOUNDED_OUT" >/dev/null 2>&1; then@jq -e 'type == "array"' <<<"$BOUNDED_OUT" >/dev/null 2>&1 && : >"$errf"; then@notices@local=1 provider-x=0
ROWS

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
