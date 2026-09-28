#!/usr/bin/env bash
# oversee-watch's owed items: under a heartbeat, one `owed` line per item the
# tracker holds as work the fleet owes and the fleet state's launch_queue
# lacks, with the verdict the account roster gives it. Every run is one pass
# (--max-loops 1) over a fleet state passed with --state.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
# shellcheck source=lib/oversee-watch-harness.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/oversee-watch-harness.sh"
# mutant_scripts and mutate_file, the two halves of the control below.
# shellcheck source=lib/growth-state.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/growth-state.sh"

HEARTBEAT='EVENT heartbeat loops=1 interval=0s since=none'

# record ITEM STATUS HARNESS [EXTRA_JSON] — one lanes[] record with no window,
# so the pass reads no pane for it; EXTRA_JSON is merged over it.
record() {
  jq -nc --arg item "$1" --arg status "$2" --arg harness "$3" --argjson extra "${4:-{\}}" \
    '{item: $item, window: null, host: null, mail_root: ("/w/" + $item), account: null,
      harness: $harness, surface: "tmux", model: null, session_id: null,
      launched_at: "2026-09-20T00:00:00Z", status: $status} + $extra'
}
# fleet QUEUE_JSON RECORD... — the fleet state file --state names.
fleet() {
  local queue="$1"
  shift
  jq -n --argjson queue "$queue" --argjson lanes "$(printf '%s\n' "$@" | jq -sc .)" \
    '{issue_id: "oversee", triaged: [], launch_queue: $queue, lanes: $lanes}' > "$STUB_DIR/state.json"
}
# account ALIAS HARNESS VERDICT RESETS — one `lanes list --json` record.
account() {
  jq -nc --arg a "$1" --arg h "$2" --arg v "$3" --arg r "$4" '{
    alias: $a, harness: $h, config_dir: ("/home/u/." + $a), measured_through: "local",
    status: "ok", verdict: $v, headroom_pct: 0, binding_bucket: "weekly", binding_resets_at: $r}'
}
# issue ID STATE PRIORITY — one safe-format tracker item.
issue() { jq -nc --arg id "$1" --arg s "$2" --argjson p "$3" '{id: $id, state: $s, priority: $p}'; }

# watch_pass [ENV=VAL...] [-- ARGS...] — one run over the case's state; OUT,
# RC and ERR (a file) are what the assertions read.
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
# rule. KEN-1 runs, KEN-2 is stopped on a harness with room, KEN-3 stopped on
# a harness whose every account is walled, KEN-4 parked, KEN-5 closed out with
# its merge's cycle, KEN-6 in review with no record and an open PR, KEN-7
# already queued, KEN-8 done.
world() {
  new_case "$1"
  fleet '["KEN-7"]' \
    "$(record KEN-1 running claude)" \
    "$(record KEN-2 stopped claude)" \
    "$(record KEN-3 stopped codex)" \
    "$(record KEN-4 parked claude '{"parked":{"pr":14,"head":"abc","repo":"owner/repo","at":"2026-09-27T00:00:00Z"}}')" \
    "$(record KEN-5 done claude '{"cycle":{"pr":15}}')"
  printf '%s\n' "$(issue KEN-1 'In Progress' 1)" "$(issue KEN-2 'In Progress' 2)" \
    "$(issue KEN-3 'In Progress' 1)" "$(issue KEN-4 'In Review' 2)" "$(issue KEN-5 'In Review' 2)" \
    "$(issue KEN-6 'In Review' 3)" "$(issue KEN-7 'In Progress' 2)" "$(issue KEN-8 Done 2)" \
    | jq -sc . > "$STUB_DIR/tracker.out"
  printf '16\tken-6\tthe review item\n' > "$STUB_DIR/open.txt"
  printf '%s\n' "$(account claude claude room 2026-10-01T00:00:00Z)" \
    "$(account codex codex walled 2026-10-05T00:00:00Z)" "$(account codex2 codex walled 2026-10-03T00:00:00Z)" \
    | jq -sc . > "$STUB_DIR/lanes.json"
}

echo "=== oversee-watch owed items ==="

world owed
watch_pass -- --state "$STUB_DIR/state.json"
assert_eq "rc=$RC first=$(head -1 <<<"$OUT")" "rc=0 first=$HEARTBEAT" "the fleet reaches the heartbeat" "$ERR"
assert_eq "$(cat "$STUB_DIR/tracker.args")" "issues list --team kendex --state In Progress,In Review --max --format=safe" \
  "the owed items are one live read of the team's In Progress and In Review items" "$ERR"
# Rows: item | its owed line, `-` for none.
while IFS='|' read -r item want; do
  assert_eq "$(owed "$item")" "$want" "owed $item" "$ERR"
done <<'ROWS'
KEN-1|-
KEN-2|owed KEN-2 state=in-progress priority=2 lane=stopped verdict=queue
KEN-3|owed KEN-3 state=in-progress priority=1 lane=stopped verdict=dated harness=codex until=2026-10-03T00:00:00Z
KEN-4|-
KEN-5|-
KEN-6|owed KEN-6 state=in-review priority=3 lane=none verdict=queue
KEN-7|-
KEN-8|-
ROWS
assert_eq "$(grep -n '^owed ' <<<"$OUT" | head -1 | cut -d: -f1)" "$(($(grep -n '^account ' <<<"$OUT" | tail -1 | cut -d: -f1) + 1))" \
  "the owed lines follow the account roster" "$ERR"

# A roster that was not read judges no wall: every item with a harness is
# unjudged, and one with no record is still queued.
world owed_unjudged
printf '1\n' > "$STUB_DIR/lanes.rc"
watch_pass -- --state "$STUB_DIR/state.json"
assert_eq "$(owed KEN-3)|$(owed KEN-2)|$(owed KEN-6)" \
  "owed KEN-3 state=in-progress priority=1 lane=stopped verdict=unjudged harness=codex|owed KEN-2 state=in-progress priority=2 lane=stopped verdict=unjudged harness=claude|owed KEN-6 state=in-review priority=3 lane=none verdict=queue" \
  "an unread roster leaves every harness unjudged" "$ERR"

# A fleet with no tracker team owes the item repository's open PRs on a GitHub
# item's branch, and reads no tracker.
new_case owed_github
fleet '[]'
printf '12\tissue-12\tan issue\n13\tken-9\tnot an issue branch\n' > "$STUB_DIR/open.txt"
watch_pass LINEAR_TEAM -- --state "$STUB_DIR/state.json"
assert_eq "rc=$RC tracker=$([[ -e "$STUB_DIR/tracker.args" ]] && echo read || echo unread) lines=$(grep -c '^owed ' <<<"$OUT" || true) $(owed issue-12)" \
  "rc=0 tracker=unread lines=1 owed issue-12 state=open-pr priority=- lane=none verdict=queue" \
  "an open PR on issue-N is owed on a fleet with no team" "$ERR"

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

echo "=== must-fail control ==="
# The watch without the held exclusion: the running lane's item is owed.
MUTANT_DIR="$TMP_ROOT/owed-mutant"
MUTANT_WATCH="$(mutant_scripts owed-mutant/orch oversee-watch)/oversee-watch" || exit 1
ln -s "$REPO_ROOT/skills/github" "$MUTANT_DIR/github"
mutate_file "$MUTANT_WATCH" '($rec | held)' 'false'
world owed_mutant
WATCH_BIN="$MUTANT_WATCH" watch_pass -- --state "$STUB_DIR/state.json"
assert_eq "$(owed KEN-1)" "owed KEN-1 state=in-progress priority=1 lane=running verdict=queue" \
  "control: without the held exclusion an item with a running lane is owed" "$ERR"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
