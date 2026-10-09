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
  printf 'local=%s provider-x=%s' "$(grep -c '^lanes: stub-notice host=local$' "$ERR" || true)" \
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
  "$(printf '%s\n' 'local list --json' 'local pick --harness claude --json --model claude-opus-5' \
      'local pick --harness claude --json --model claude-sonnet-5' 'local pick --harness codex --json' \
      'provider-x list --json' 'provider-x pick --harness codex --json' | sort)" \
  "each host's accounts are listed once and its wall asked of lanes pick once per harness and model, under that host" "$ERR"
assert_eq "$(grep -n '^owed ' <<<"$OUT" | head -1 | cut -d: -f1)" "$(($(grep -n '^account ' <<<"$OUT" | tail -1 | cut -d: -f1) + 1))" \
  "the owed lines follow the account roster" "$ERR"

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
want_lines='verifying KEN-1 box=2 deadline=2026-10-02T00:00:00Z reading="Read deployed health" where="live service" why="needs deployment"
verifying KEN-1 box=3 deadline=2026-10-03T00:00:00Z reading="Read consumer refresh" where="consumer PR" why="needs rollout"
verifying KEN-4 box=2 deadline=2026-10-02T00:00:00Z reading="Read deployed health" where="live service" why="needs deployment"
verifying KEN-4 box=3 deadline=2026-10-03T00:00:00Z reading="Read consumer refresh" where="consumer PR" why="needs rollout"'
want_events='EVENT verifying-deadline KEN-1 box=2 deadline=2026-10-02T00:00:00Z
EVENT verifying-deadline KEN-4 box=2 deadline=2026-10-02T00:00:00Z'
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
jq -nr '"2026-10-01T23:59:59Z" | fromdateiso8601' >"$STUB_DIR/now.epoch"
watch_pass -- --state "$STUB_DIR/state.json"
assert_eq "rc=$RC $(verification_events)" "rc=0 " "a future deadline raises no event" "$ERR"
assert_eq "$(verification_lines)" "$want_lines" "future checks stay visible" "$ERR"
# A malformed box fails the read instead of losing verification silently.
verifying_world verifying_invalid
jq 'map(if .id == "KEN-1" then .description = "## Done when\n- [ ] Post-merge: Read health" else . end)' \
  "$STUB_DIR/tracker.out" >"$STUB_DIR/invalid.json"
mv -- "$STUB_DIR/invalid.json" "$STUB_DIR/tracker.out"
watch_pass -- --state "$STUB_DIR/state.json"
assert_eq "rc=$RC key=$(grep -c '^oversee-watch: verifying-invalid issue=KEN-1$' "$ERR" || true)" "rc=2 key=1" "invalid verification refuses the pass" "$ERR"

# The watcher refuses a Verifying item that still has branch work. This is
# distinct from a post-merge box whose required deadline fields are absent.
verifying_world verifying_branch_open
jq 'map(if .id == "KEN-1" then .description |= sub("\\[x\\] branch proof"; "[ ] branch proof") else . end)' \
  "$STUB_DIR/tracker.out" >"$STUB_DIR/branch-open.json"
mv -- "$STUB_DIR/branch-open.json" "$STUB_DIR/tracker.out"
watch_pass -- --state "$STUB_DIR/state.json"
assert_eq "rc=$RC key=$(grep -c '^oversee-watch: verifying-invalid issue=KEN-1$' "$ERR" || true)" "rc=2 key=1" "open branch work refuses verification" "$ERR"
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
  mutate_file "$MUTANT_WATCH" "$old" "$new"
  verifying_world "verifying_validation_$validation"
  jq --arg d "$description" 'map(if .id == "KEN-1" then .description = $d else . end)' \
    "$STUB_DIR/tracker.out" >"$STUB_DIR/validation.json"
  mv -- "$STUB_DIR/validation.json" "$STUB_DIR/tracker.out"
  WATCH_BIN="$MUTANT_WATCH" watch_pass -- --state "$STUB_DIR/state.json"
  assert_eq "rc=$RC" "rc=0" "control: missing $validation check violates verification refusal" "$ERR"
done

# Must-fail controls retain the executable watch and change one rule each.
for control in membership event filter queue; do
  MUTANT_DIR="$TMP_ROOT/verifying-mutant-$control"
  MUTANT_WATCH="$(mutant_scripts "verifying-mutant-$control/orch" oversee-watch)/oversee-watch" || exit 1
  ln -s "$REPO_ROOT/skills/github" "$MUTANT_DIR/github"
  ln -s "$REPO_ROOT/skills/linear" "$MUTANT_DIR/linear"
  case "$control" in
    membership) mutate_file "$MUTANT_WATCH" 'In Progress,In Review,Verifying' 'In Progress,In Review' ;;
    event) mutate_file "$MUTANT_WATCH" 'and .deadline_epoch <= $now' 'and false' ;;
    filter) mutate_file "$MUTANT_WATCH" 'items="$(jq -c '\''map(select(.state != "verifying"))'\'' <<<"$items")"' 'items="$(jq -c '\''map(select(.state != "verifying"))'\'' <<<"$items")"; VERIFYING_LINES=""' ;;
    queue)
      old='    verifying_read "$items"'
      new='    items="$(jq -c --argjson fleet "$FLEET_STATE" '\''map(. as $item | select(($fleet.launch_queue // []) | index($item.id) | not))'\'' <<<"$items")"
    verifying_read "$items"'
      mutate_file "$MUTANT_WATCH" "$old" "$new"
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
  mutate_file "$MUTANT_WATCH" "$old" "$new"
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
noisy@without forwarding a listing's notices are dropped@jq -e 'type == "array"' <<<"$BOUNDED_OUT" >/dev/null 2>&1; then@jq -e 'type == "array"' <<<"$BOUNDED_OUT" >/dev/null 2>&1 && : >"$errf"; then@notices@local=0 provider-x=0
ROWS

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
