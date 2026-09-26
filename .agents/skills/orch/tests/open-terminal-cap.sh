#!/usr/bin/env bash
# open-terminal's fleet caps: a fresh launch under --state-dir is refused as
# cap-reached where the fleet's running and preparing records plus its
# unrecorded live claims reach ORCH_OVERSEER_LANES, and as account-cap-reached
# where the fleet's records on its lane plus the live claims there no such
# record accounts for reach ORCH_LANE_ACCOUNT_CLAIMS, both judged
# under the fleet's lock and the claim store's, held from the count through the
# reservation write, which refuses the launch where it fails. A relaunch meets the fleet cap where the item has no running or preparing
# record, and the account cap where it has none or moves to another account.
# --over-cap admits one launch and records the caps it passed, and --wait-slot
# waits for room instead of refusing.
#
# The suite runs a copy of open-terminal beside copies of workflow-state and
# orch-env in a temp git repo, with the worktree CLI, lanes and tmux stubbed.
# The tmux stub answers a new window with the test shell's own pid as its
# server, so every claim a launch writes stays live for the claims reader. Each
# row gets a fresh fleet state and claim store.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
export ORCH_LANE_HOST=local
# shellcheck source=lib/shared-skill-libs.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/shared-skill-libs.sh"
# shellcheck source=lib/question-off.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/question-off.sh"

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TEST_DIR/.." && pwd)/scripts"
TMP_ROOT="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP_ROOT"' EXIT

# shellcheck source=lib/assertions.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/assertions.sh"

BIN="$TMP_ROOT/bin"
mkdir -p "$BIN"
# lanes: a named lane's judge answers walled once the row's wall file exists,
# and `--lane auto` picks whatever the row's pick file names.
cat > "$BIN/lanes" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  list) echo "[]" ;;
  pick)
    if [[ " $* " == *" --lane "* ]]; then
      [[ ! -e "$STUB_WALL" ]] || { echo '{"wall":97,"binding_bucket":"five_hour"}'; exit 3; }
    else
      cat -- "$STUB_PICK"
    fi ;;
esac
exit 0
EOF
# stub_step STEP HOLD — marks that the launch reached STEP, then, where HOLD
# names a file, holds it there until that file exists, 10 seconds at most:
# a launch held for as long as the row needs it rather than for a guessed
# time. The steps are count (the read of a claim store that exists, under the
# launch locks), recheck (the second pane listing of one launch, which the
# claims reader takes when a claim names the listed server and a pane it did
# not list), create (the worktree create), window (the new window, ahead of
# its claim) and paste (the first line typed into the pane, after its claim
# and before its record). The pane listing prints STUB_PANES where set.
STUB_STEP="$TMP_ROOT/stub-step.sh"
cat > "$STUB_STEP" <<'EOF'
stub_step() {
  local n=0
  [[ -z "${STUB_MARK:-}" ]] || : > "$STUB_MARK.$1.$STUB_TAG"
  while [[ -n "${2:-}" && ! -e "$2" ]] && (( n < 100 )); do sleep 0.1; n=$((n + 1)); done
}
EOF
cat > "$BIN/tmux" <<EOF
#!/usr/bin/env bash
source "$STUB_STEP"
EOF
cat >> "$BIN/tmux" <<'EOF'
case "${1:-}" in
  list-windows) echo 1 ;;
  # The pane writer's identity read, which is none of the counts below: the
  # launch line goes into the window's own shell.
  list-panes) if [[ "$*" == *pane_current_command* ]]; then printf '%%1\t4242\tbash\n'; exit 0; fi
    n=1
    if [[ -n "${STUB_MARK:-}" ]]; then
      calls="$STUB_MARK.list-panes.$STUB_TAG"
      n=$(( $(cat -- "$calls" 2>/dev/null || echo 0) + 1 ))
      echo "$n" > "$calls"
    fi
    if [[ "$n" -eq 2 ]]; then stub_step recheck "${STUB_HOLD_RECHECK:-}"; else stub_step count "${STUB_HOLD_COUNT:-}"; fi
    [[ -z "${STUB_PANES:-}" ]] || printf '%s\n' "$STUB_PANES" ;;
  new-window)
    : > "$STUB_OPEN_MARK.$STUB_TAG"
    stub_step window "${STUB_HOLD_WINDOW:-}"
    echo "$STUB_SERVER %1" ;;
  load-buffer) stub_step paste "${STUB_HOLD_PASTE:-}" ;;
  display-message) echo 0 ;;
esac
exit 0
EOF
cat > "$BIN/ghostty" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$BIN/lanes" "$BIN/tmux" "$BIN/ghostty"

STUB="$TMP_ROOT/worktree-stub"
cat > "$STUB" <<EOF
#!/usr/bin/env bash
set -euo pipefail
source "$STUB_STEP"
d="$TMP_ROOT/wt/\${2:-unknown}"
case "\${1:-}" in
  exists) [[ -d "\$d" ]] && echo true || echo false ;;
  merged) exit 1 ;;
  create) stub_step create "\${STUB_HOLD_CREATE:-}"
    mkdir -p "\$d"; [[ -d "\$d/.git" ]] || { git init -q "\$d"; git -C "\$d" config gc.auto 0; git -C "\$d" config maintenance.auto false; }; printf '%s\n' "\$d" ;;
  *) echo "unexpected worktree stub call: \$*" >&2; exit 1 ;;
esac
EOF
chmod +x "$STUB"

REPO="$TMP_ROOT/repo"
mkdir -p "$REPO/scripts/lib"
cp "$SCRIPTS_DIR/open-terminal" "$SCRIPTS_DIR/lane-host" "$SCRIPTS_DIR/workflow-state" "$SCRIPTS_DIR/git-context" \
  "$SCRIPTS_DIR/lane-marker" "$SCRIPTS_DIR/orch-env" "$REPO/scripts/"
cp -R "$SCRIPTS_DIR/lib/." "$REPO/scripts/lib/"
orch_fixture_shared_libs "$REPO"
git -C "$REPO" init -q
git -C "$REPO" config gc.auto 0
git -C "$REPO" config maintenance.auto false
OT="$REPO/scripts/open-terminal"
WS="$REPO/scripts/workflow-state"
LANE_A="$TMP_ROOT/.lane-a"
LANE_B="$TMP_ROOT/.lane-b"
mkdir -p "$LANE_A" "$LANE_B"

# row NAME — a fresh fleet state and claim store for one row.
row() {
  ROW="$TMP_ROOT/rows/$1"
  mkdir -p "$ROW"
  STATE="$ROW/state"
  CLAIMS="$ROW/watch"
}

# launch TAG FLEET_CAP ACCOUNT_CAP ARGS... — one launch of the row's fleet, or
# of no fleet where STATE is empty, on tmux unless MODE names another surface
# flag; its stdout, stderr and status land in $ROW/TAG.{out,err,rc}.
launch() {
  local tag="$1" fleet_cap="$2" account_cap="$3" rc=0 fleet=()
  shift 3
  [[ -z "$STATE" ]] || fleet=(--state-dir "$STATE")
  (cd "$REPO" && PATH="$BIN:$PATH" OVERSEE_WATCH_STATE_DIR="$CLAIMS" WORKTREE_CLI="$STUB" LANES_CLI="$BIN/lanes" \
    GH_ISSUE_PATTERN='[A-Z]+-[0-9]+' TMUX=stub,1,0 GH_REPO="" STUB_SERVER=$$ STUB_OPEN_MARK="$ROW/opened" STUB_TAG="$tag" \
    STUB_MARK="$ROW/reached" \
    STUB_WALL="$ROW/wall" STUB_PICK="$ROW/pick" TERMINAL=ghostty ORCH_TMUX_SESSION=fleet \
    ORCH_OVERSEER_LANES="$fleet_cap" ORCH_LANE_ACCOUNT_CLAIMS="$account_cap" \
    "$OT" ${fleet[@]+"${fleet[@]}"} "${MODE:---tmux}" --harness claude --cmd "true --model opus --effort high $QUESTION_OFF_ALL" "$@" \
    >"$ROW/$tag.out" 2>"$ROW/$tag.err") || rc=$?
  printf '%s\n' "$rc" > "$ROW/$tag.rc"
}

# await_step TAG STEP — block until launch TAG has reached STEP.
await_step() {
  local n=0
  while [[ ! -e "$ROW/reached.$2.$1" ]] && (( n < 100 )); do sleep 0.1; n=$((n + 1)); done
  [[ -e "$ROW/reached.$2.$1" ]] || { echo "launch $1 never reached $2" >&2; exit 1; }
}

# await_line TAG PATTERN [COUNT] — block until TAG's stdout holds COUNT lines
# matching PATTERN.
await_line() {
  local n=0 want="${3:-1}" got=0
  while (( n < 100 )); do
    got="$(grep -cE -- "$2" "$ROW/$1.out" 2>/dev/null || true)"
    (( got < want )) || return 0
    sleep 0.1; n=$((n + 1))
  done
  echo "launch $1 printed $got of $want lines matching $2" >&2; exit 1
}

# await_exit PID — block until a backgrounded launch exits, bounded: a waiter
# that never sees room is killed and fails the suite rather than hanging it.
await_exit() {
  local n=0
  while kill -0 "$1" 2>/dev/null && (( n < 200 )); do sleep 0.1; n=$((n + 1)); done
  if kill -0 "$1" 2>/dev/null; then kill "$1" 2>/dev/null || true; echo "launch $1 never finished waiting" >&2; exit 1; fi
  wait "$1" || true
}

# race AT FLEET_CAP ACCOUNT_CAP LANE_1 LANE_2 — two launches of CC-1 and CC-2,
# the second, into the fleet STATE_TWO names where set, started while the
# first is held in its worktree create until the second returns. At `count` the
# first is held inside its count first, under the launch locks, until the
# second prints lock-waiting; at `create` it is not.
race() {
  local at="$1" first second
  shift
  if [[ "$at" == count ]]; then
    mkdir -p "$CLAIMS/claims"
    STUB_HOLD_COUNT="$ROW/counted" STUB_HOLD_CREATE="$ROW/release" launch one "$1" "$2" --lane "$3" CC-1 &
  else
    STUB_HOLD_CREATE="$ROW/release" launch one "$1" "$2" --lane "$3" CC-1 &
  fi
  first=$!
  await_step one "$at"
  STATE="${STATE_TWO:-$STATE}" launch two "$1" "$2" --lane "$4" CC-2 &
  second=$!
  if [[ "$at" == count ]]; then
    await_line two '^open-terminal: lock-waiting'
    : > "$ROW/counted"
  fi
  await_exit "$second"
  : > "$ROW/release"
  await_exit "$first"
}

# key TAG — the first line of every open-terminal cap line on TAG's output.
key() { grep -hE '^open-terminal: (cap-reached|account-cap-reached|over-cap-admitted|slot-waiting|cap-unreadable|cap-lock-failed|cap-option-unanchored|over-cap-items|claim-unrecorded|lane-model-walled|cap-reserve-failed) ' "$ROW/$1.out" "$ROW/$1.err" || true; }
# lock_waits TAG — how many lock-waiting lines TAG printed.
lock_waits() { grep -c '^open-terminal: lock-waiting' "$ROW/$1.out" || true; }
# reservations — the reservation files the row's claim store holds.
reservations() { find "$CLAIMS/claims" -name '*.reserve' | wc -l | tr -d ' '; }
rc() { cat "$ROW/$1.rc"; }
running() { "$WS" --state-dir "$STATE" get oversee '[(.lanes // [])[] | select(.status == "running") | .item] | join(",")'; }
account_of() { "$WS" --state-dir "$STATE" get oversee '.lanes[] | select(.item == "'"$1"'") | .account // "null"'; }
over_cap() { "$WS" --state-dir "$STATE" get oversee '.lanes[] | select(.item == "'"$1"'") | .over_cap // "null"'; }
# seed_claim WINDOW LANE [FLEET] — a live claim written by the fleet whose
# oversee state file FLEET names, this row's own by default.
seed_claim() {
  mkdir -p "$CLAIMS/claims"
  printf '%s\t%%9\t%s\t%s\t2026-01-01T00:00:00Z\t%s\n' "$$" "$2" "$1" "${3-$STATE/workflow-state-oversee.json}" \
    > "$CLAIMS/claims/$1.claim"
}
# seed_claim_unfleeted WINDOW LANE — a live claim of five fields, as a launcher
# wrote them before claims carried a fleet.
seed_claim_unfleeted() {
  mkdir -p "$CLAIMS/claims"
  printf '%s\t%%9\t%s\t%s\t2026-01-01T00:00:00Z\n' "$$" "$2" "$1" > "$CLAIMS/claims/$1.claim"
}
# seed_running ITEM [STATUS] [ACCOUNT] — a record, running by default, for a
# lane this suite never launched, its window bare, or `fleet:ITEM` where it
# names an account, as a launch records it.
seed_running() {
  local window="$1" account=""
  [[ -z "${3:-}" ]] || { window="fleet:$1"; account=',"account":"'"$3"'"'; }
  "$WS" --state-dir "$STATE" exists oversee >/dev/null 2>&1 || "$WS" --state-dir "$STATE" init oversee >/dev/null
  "$WS" --state-dir "$STATE" append oversee lanes \
    '{"item":"'"$1"'","window":"'"$window"'","status":"'"${2:-running}"'"'"$account"'}' >/dev/null
}
# status_of ITEM — the status of ITEM's record.
status_of() { "$WS" --state-dir "$STATE" get oversee '.lanes[] | select(.item == "'"$1"'") | .status'; }

echo "=== two concurrent launches against a fleet cap of 1 admit one ==="
row fleet-race
race count 1 0 "$LANE_A" "$LANE_B"
assert_eq "one=$(rc one) two=$(rc two) running=$(running) reservations=$(reservations)" \
  "one=0 two=1 running=CC-1 reservations=0" \
  "the launch holding the lock launches, the one counting after it does not, and no reservation outlives the launch"
assert_eq "$(key two)" "open-terminal: cap-reached item=CC-2 cap=1 running=0 claims=1" \
  "the refusal counts the first launch's reservation, its record not yet written"
assert_eq "$(grep -c "^open-terminal: lock-waiting item=CC-2 lock=$STATE/workflow-state-oversee.json.launch.lock wait-s=900$" "$ROW/two.out" || true)" "1" \
  "the launch that finds the lock held during a count says it waits for it"

echo "=== the launch locks are free while an admitted launch creates its worktree ==="
row create-race
race create 1 0 "$LANE_A" "$LANE_B"
assert_eq "one=$(rc one) two=$(rc two) lock-waits=$(lock_waits two) $(key two)" \
  "one=0 two=1 lock-waits=0 open-terminal: cap-reached item=CC-2 cap=1 running=0 claims=1" \
  "the second launch counts at once, and the first launch's reservation fills the fleet's only slot"

echo "=== a launch naming no lane holds its place in the fleet count ==="
# Its reservation carries an empty config dir.
row laneless
STUB_HOLD_CREATE="$ROW/release" launch one 1 0 CC-1 &
FIRST=$!
await_step one create
launch two 1 0 CC-2
: > "$ROW/release"
await_exit "$FIRST"
assert_eq "one=$(rc one) two=$(rc two) $(key two) reservations=$(reservations)" \
  "one=0 two=1 open-terminal: cap-reached item=CC-2 cap=1 running=0 claims=1 reservations=0" \
  "the reservation of a launch naming no lane fills the fleet's only slot, and goes when the launch ends"

echo "=== an --over-cap launch holds no launch lock through its worktree create ==="
row over-race
seed_running CC-9
STUB_HOLD_CREATE="$ROW/release" launch one 1 0 --lane "$LANE_A" --over-cap CC-1 &
FIRST=$!
await_step one create
launch two 1 0 --lane "$LANE_B" CC-2
: > "$ROW/release"
await_exit "$FIRST"
assert_eq "one=$(rc one) two=$(rc two) lock-waits=$(lock_waits two) $(key two)" \
  "one=0 two=1 lock-waits=0 open-terminal: cap-reached item=CC-2 cap=1 running=1 claims=1" \
  "the next launch counts at once, the exception's reservation among the lanes it counts"

echo "=== a count that reads the claim store before a launch records sees the lane in its records ==="
# A launch naming no lane writes no claim: its record replaces its reservation.
# The second count is held after it lists the claim store's panes, before any
# of its reads, while the first launch records its lane and drops its
# reservation.
row reserve-to-record
STUB_HOLD_CREATE="$ROW/release" launch one 1 0 CC-1 &
FIRST=$!
await_step one create
STUB_HOLD_COUNT="$ROW/counted" launch two 1 0 CC-2 &
SECOND=$!
await_step two count
: > "$ROW/release"
await_exit "$FIRST"
: > "$ROW/counted"
await_exit "$SECOND"
assert_eq "one=$(rc one) two=$(rc two) running=$(running) $(key two)" \
  "one=0 two=1 running=CC-1 open-terminal: cap-reached item=CC-2 cap=1 running=1 claims=0" \
  "the second count finds the first lane by its record once its reservation is gone"

echo "=== a count that lists the claims before a launch claims sees the lane in its reservations ==="
# The first launch writes its claim and drops its reservation while the second
# count is held inside its claim pass: a stale claim on the listed server sends
# it to list the panes again, where it waits. The first launch is then held
# after its claim and before its record.
row reserve-to-claim
STUB_HOLD_CREATE="$ROW/release" STUB_HOLD_PASTE="$ROW/pasted" launch one 1 0 --lane "$LANE_A" CC-1 &
FIRST=$!
await_step one create
seed_claim CC-8 "$LANE_A"
STUB_PANES="$$ %0" STUB_HOLD_RECHECK="$ROW/counted" launch two 1 0 --lane "$LANE_B" CC-2 &
SECOND=$!
await_step two recheck
: > "$ROW/release"
await_step one paste
: > "$ROW/counted"
await_exit "$SECOND"
: > "$ROW/pasted"
await_exit "$FIRST"
assert_eq "one=$(rc one) two=$(rc two) $(key two)" "one=0 two=1 open-terminal: cap-reached item=CC-2 cap=1 running=0 claims=1" \
  "the second count holds the first lane by the reservation it read before the claim landed"

echo "=== a reservation whose launcher has exited holds no place ==="
row reserve-dead
( exit 0 ) &
DEAD=$!
wait "$DEAD"
mkdir -p "$CLAIMS/claims"
printf '%s\t-\t%s\tCC-8\t2026-01-01T00:00:00Z\t%s\n' "$DEAD" "$LANE_A" "$STATE/workflow-state-oversee.json" \
  > "$CLAIMS/claims/claim.dead.reserve"
launch one 1 0 --lane "$LANE_A" CC-1
assert_eq "rc=$(rc one) running=$(running) reservations=$(reservations) $(key one)" "rc=0 running=CC-1 reservations=0 " \
  "the count prunes the reservation and admits the launch into the fleet's only slot"

echo "=== a launch between its claim and its record counts once ==="
row claimed
STUB_HOLD_PASTE="$ROW/release" launch one 1 0 --lane "$LANE_A" CC-1 &
FIRST=$!
await_step one paste
launch two 1 0 --lane "$LANE_B" CC-2
: > "$ROW/release"
await_exit "$FIRST"
assert_eq "one=$(rc one) two=$(rc two) $(key two)" "one=0 two=1 open-terminal: cap-reached item=CC-2 cap=1 running=0 claims=1" \
  "the claim replaces the reservation it was written over"

echo "=== an unrecorded live claim counts toward the fleet cap ==="
row fleet-claim
seed_claim CC-8 "$LANE_B"
launch one 1 0 --lane "$LANE_A" CC-1
assert_eq "rc=$(rc one) $(key one)" "rc=1 open-terminal: cap-reached item=CC-1 cap=1 running=0 claims=1" \
  "a claim no running record names fills the fleet's only slot"

echo "=== fleets sharing one claim store count only their own claims toward the fleet cap ==="
# One store, as OVERSEE_WATCH_STATE_DIR set for every shell gives several
# fleets. The other fleet's lane and a launch that named no fleet are claims on
# lane A: each counts toward that account and toward no cap of this fleet's.
row fleets
seed_claim CC-8 "$LANE_A" "$TMP_ROOT/rows/other-fleet/state/workflow-state-oversee.json"
seed_claim CC-7 "$LANE_A" ""
launch one 1 3 --lane "$LANE_B" CC-1
assert_eq "rc=$(rc one) running=$(running) $(key one)" "rc=0 running=CC-1 " \
  "a fleet running no lane launches at a fleet cap of 1 beside another fleet's claim"
assert_eq "$(awk -F'\t' '$4 == "CC-1" { print $6 }' "$CLAIMS/claims"/*.claim)" "$STATE/workflow-state-oversee.json" \
  "the launch's own claim names its fleet by that fleet's state file"
launch two 5 2 --lane "$LANE_A" CC-2
assert_eq "rc=$(rc two) $(key two)" "rc=1 open-terminal: account-cap-reached item=CC-2 lane=$LANE_A cap=2 claims=2 records=0 claims-other=2" \
  "the account cap still counts the other fleet's claim and the fleetless one"

echo "=== a claim written before claims carried a fleet is its record's lane, not a second one ==="
# Five running records on lane A, each beside the five-field claim its launch
# wrote: five lanes, admitted at an account cap of 6 and refused at 5.
row unfleeted
for n in 11 12 13 14 15; do
  seed_running "CC-$n" running "$LANE_A"
  seed_claim_unfleeted "CC-$n" "$LANE_A"
done
launch one 10 5 --lane "$LANE_A" CC-1
assert_eq "rc=$(rc one) $(key one)" \
  "rc=1 open-terminal: account-cap-reached item=CC-1 lane=$LANE_A cap=5 claims=5 records=5 claims-other=0" \
  "five records beside their own five-field claims count five lanes"
launch two 10 6 --lane "$LANE_A" CC-2
assert_eq "rc=$(rc two) $(key two)" "rc=0 " "the same five lanes leave room at an account cap of 6"
row unfleeted-other
seed_claim_unfleeted CC-8 "$LANE_A"
seed_running CC-9 running "$LANE_A"
seed_claim CC-9 "$LANE_A" "$TMP_ROOT/rows/other-fleet/state/workflow-state-oversee.json"
seed_running CC-7 running "$LANE_B"
seed_claim_unfleeted CC-7 "$LANE_A"
launch one 10 4 --lane "$LANE_A" CC-1
assert_eq "rc=$(rc one) $(key one)" \
  "rc=1 open-terminal: account-cap-reached item=CC-1 lane=$LANE_A cap=4 claims=4 records=1 claims-other=3" \
  "a claim naming no held record, a claim of another fleet, and a claim on another account than its record's each count as another lane"

echo "=== a hosted lane handed to a background job holds its slot, and the job holds no launch lock ==="
# The host accepts CC-1 and keeps preparing it: the launch returns with its
# window, claim and preparing record in place and the job waiting on the host.
# A second launch, started while the job waits, takes the lock at once and
# counts the preparing lane. The seeded row is the same record with no claim
# beside it, which only the record itself can count.
row hosted
HOST_STUB="$TEST_DIR/fixtures/lane-host"
LANE_HOST_STUB_LOG="$ROW/host.log" LANE_HOST_STUB_WAIT_GATE="$ROW/gate" LANE_HOST_STUB_WAIT_STATUS=1 \
  LANE_HOST_STUB_CREATE_LINE=$'ssh-target=lane.example\tpath=/srv/lane\tremote-prefix=exec bash -lc\tstate=preparing' \
  launch one 1 0 --lane "$LANE_A" --host "$HOST_STUB" --repo o/r CC-1
launch two 1 0 --lane "$LANE_B" CC-2 &
SECOND=$!
n=0
while kill -0 "$SECOND" 2>/dev/null && ! grep -q '^open-terminal: lock-waiting' "$ROW/two.out" 2>/dev/null && (( n < 50 )); do sleep 0.1; n=$((n + 1)); done
: > "$ROW/gate"
await_exit "$SECOND"
assert_eq "one=$(rc one) handed=$(grep -c '^open-terminal: lane-preparing item=CC-1 ' "$ROW/one.out" || true) two=$(rc two) lock-waits=$(grep -c '^open-terminal: lock-waiting' "$ROW/two.out" || true) $(key two)" \
  "one=0 handed=1 two=1 lock-waits=0 open-terminal: cap-reached item=CC-2 cap=1 running=1 claims=0" \
  "the next launch finds the lock free while the job waits on the host, and the preparing lane fills the fleet's only slot"
n=0
while [[ "$(status_of CC-1)" == preparing ]] && (( n < 200 )); do sleep 0.1; n=$((n + 1)); done
assert_eq "$(status_of CC-1)" stopped "the job ends on the host's failed preparation, recording the lane stopped"
row preparing
seed_running CC-9 preparing
launch one 1 0 --lane "$LANE_A" CC-1
assert_eq "rc=$(rc one) $(key one)" "rc=1 open-terminal: cap-reached item=CC-1 cap=1 running=1 claims=0" \
  "a preparing record with no claim beside it fills the fleet's only slot"

echo "=== a relaunch is judged on the lane or account it adds ==="
# The same account's claim and the item's running record are the lane being
# replaced, so that relaunch passes at both caps.
row relaunch
launch one 1 1 --lane "$LANE_A" CC-1
launch two 1 1 --lane "$LANE_A" --relaunch CC-1
assert_eq "one=$(rc one) two=$(rc two) cap-lines=$(key two | wc -l | tr -d ' ') running=$(running)" \
  "one=0 two=0 cap-lines=0 running=CC-1" \
  "a relaunch of a running record on its own account at both caps proceeds"
row relaunch-account
launch one 10 1 --lane "$LANE_A" CC-1
seed_claim CC-8 "$LANE_B"
launch two 10 1 --lane "$LANE_B" --relaunch CC-1
assert_eq "rc=$(rc two) $(key two) account=$(account_of CC-1)" \
  "rc=1 open-terminal: account-cap-reached item=CC-1 lane=$LANE_B cap=1 claims=1 records=0 claims-other=1 account=$LANE_A" \
  "a relaunch onto another account at its cap is refused and the record keeps its account"
row relaunch-moving
# The relaunch is held in its create with its reservation on lane B while its
# record still names lane A: the fleet counts the lane once.
seed_running CC-1 running "$LANE_A"
STUB_HOLD_CREATE="$ROW/release" launch one 2 0 --lane "$LANE_B" --relaunch CC-1 &
FIRST=$!
await_step one create
launch two 2 0 --lane "$LANE_A" CC-2
: > "$ROW/release"
await_exit "$FIRST"
assert_eq "one=$(rc one) two=$(rc two) running=$(running) $(key two)" "one=0 two=0 running=CC-1,CC-2 " \
  "a fresh launch beside a relaunch moving to another account finds the fleet's second slot free"
row relaunch-stopped
launch one 1 0 --lane "$LANE_A" CC-1
"$WS" --state-dir "$STATE" update oversee '.lanes |= map(.status = "stopped")' >/dev/null
rm -f -- "${CLAIMS:?}/claims"/*.claim
seed_running CC-9
launch two 1 0 --lane "$LANE_A" --relaunch CC-1
assert_eq "rc=$(rc two) $(key two) running=$(running)" \
  "rc=1 open-terminal: cap-reached item=CC-1 cap=1 running=1 claims=0 running=CC-9" \
  "a relaunch of a stopped record adds a lane, and at the fleet cap it is refused"
row relaunch-preparing
seed_running CC-1 preparing
launch one 1 0 --lane "$LANE_A" --relaunch CC-1
assert_eq "rc=$(rc one) cap-lines=$(key one | wc -l | tr -d ' ') running=$(running)" "rc=0 cap-lines=0 running=CC-1" \
  "a relaunch of a preparing record replaces the lane it holds, and at the fleet cap it proceeds"

echo "=== --over-cap admits one launch at the fleet cap and records it ==="
row over-fleet
seed_running CC-9
launch one 1 0 --lane "$LANE_A" --over-cap CC-1
assert_eq "rc=$(rc one) over_cap=$(over_cap CC-1) running=$(running)" "rc=0 over_cap=fleet running=CC-9,CC-1" \
  "the exception launches and its record names the fleet cap it passed"
assert_eq "$(key one)" \
  "open-terminal: over-cap-admitted item=CC-1 passed=fleet cap=1 running=1 claims=0 lane=$LANE_A account-cap=0 account-claims=0" \
  "the exception is reported with the count it passed"
launch two 1 0 --lane "$LANE_A" --relaunch CC-1
assert_eq "rc=$(rc two) over_cap=$(over_cap CC-1)" "rc=0 over_cap=fleet" \
  "a relaunch keeps the exception its launch was admitted on"

echo "=== two concurrent launches onto one lane against an account cap of 1 admit one ==="
row account-race
race create 10 1 "$LANE_A" "$LANE_A"
assert_eq "one=$(rc one) two=$(rc two) running=$(running)" "one=0 two=1 running=CC-1" \
  "the launch admitted first takes the account's only claim"
assert_eq "$(key two)" "open-terminal: account-cap-reached item=CC-2 lane=$LANE_A cap=1 claims=1 records=0 claims-other=1" \
  "the refusal names the lane, the cap and the reservation it counted there"

echo "=== two fleets sharing one claim store race onto one lane against an account cap of 1 and admit one ==="
# Each fleet has room; only the account is shared. The second fleet's launch
# waits on the claim store's lock, not on any fleet lock, and counts the first
# fleet's reservation once that lock is free.
row store-race
STATE_TWO="$ROW/state-b" race count 10 1 "$LANE_A" "$LANE_A"
assert_eq "one=$(rc one) two=$(rc two) $(key two)" \
  "one=0 two=1 open-terminal: account-cap-reached item=CC-2 lane=$LANE_A cap=1 claims=1 records=0 claims-other=1" \
  "the launch holding the claim store's lock takes the account's only claim, and the other fleet's is refused"
assert_eq "$(grep -c "^open-terminal: lock-waiting item=CC-2 lock=$CLAIMS/claims.launch.lock wait-s=900$" "$ROW/two.out" || true)" "1" \
  "the other fleet's launch waits on the claim store's lock"

echo "=== a launch onto a second lane proceeds while the first is at its account cap ==="
row account-other
launch one 10 1 --lane "$LANE_A" CC-1
launch two 10 1 --lane "$LANE_B" CC-2
assert_eq "one=$(rc one) two=$(rc two) running=$(running)" "one=0 two=0 running=CC-1,CC-2" \
  "the account cap counts the lane the launch would use and no other"

echo "=== ORCH_LANE_ACCOUNT_CLAIMS=0 leaves only the fleet cap ==="
row account-off
seed_claim CC-7 "$LANE_A"
seed_claim CC-8 "$LANE_A"
launch one 3 0 --lane "$LANE_A" CC-1
launch two 3 0 --lane "$LANE_A" CC-2
assert_eq "one=$(rc one) two=$(rc two) running=$(running)" "one=0 two=1 running=CC-1" \
  "two unrecorded claims on the lane admit a launch with the account cap off, and the fleet cap still refuses the next"
assert_eq "$(key two)" "open-terminal: cap-reached item=CC-2 cap=3 running=1 claims=2" \
  "the refusal at a cap of 0 is the fleet's"

echo "=== --over-cap at the account cap records which cap it passed ==="
row over-account
seed_claim CC-8 "$LANE_A"
launch one 10 1 --lane "$LANE_A" --over-cap CC-1
assert_eq "rc=$(rc one) over_cap=$(over_cap CC-1)" "rc=0 over_cap=account" \
  "the exception at the account cap records the account cap"
row over-both
seed_claim CC-8 "$LANE_A"
launch one 1 1 --lane "$LANE_A" --over-cap CC-1
assert_eq "rc=$(rc one) over_cap=$(over_cap CC-1)" "rc=0 over_cap=fleet,account" \
  "an exception past both caps records both"
row within
launch one 1 1 --lane "$LANE_A" --over-cap CC-1
assert_eq "rc=$(rc one) over_cap=$(over_cap CC-1) lines=$(key one | wc -l | tr -d ' ')" "rc=0 over_cap=null lines=0" \
  "--over-cap inside both caps passes nothing and records nothing"

echo "=== --wait-slot waits for room and then launches ==="
row wait
seed_running CC-9
launch one 1 0 --lane "$LANE_A" --wait-slot CC-1 &
WAITER=$!
await_line one '^open-terminal: slot-waiting'
assert_eq "$(key one) opened=$([[ -e "$ROW/opened.one" ]] && echo yes || echo no)" \
  "open-terminal: slot-waiting item=CC-1 over=fleet cap=1 running=1 claims=0 lane=$LANE_A account-cap=0 account-claims=0 opened=no" \
  "a launch at the fleet cap waits, naming the count, and opens nothing"
seed_claim CC-8 "$LANE_B"
await_line one '^open-terminal: slot-waiting' 2
assert_eq "$(key one | tail -n 1)" \
  "open-terminal: slot-waiting item=CC-1 over=fleet cap=1 running=1 claims=1 lane=$LANE_A account-cap=0 account-claims=0" \
  "a change in the count it waits on is printed again"
rm -f -- "${CLAIMS:?}/claims/CC-8.claim"
"$WS" --state-dir "$STATE" update oversee '.lanes |= map(if .item == "CC-9" then .status = "done" else . end)' >/dev/null
await_exit "$WAITER"
assert_eq "rc=$(rc one) running=$(running) waits=$(key one | wc -l | tr -d ' ')" "rc=0 running=CC-1 waits=2" \
  "the waiting launch goes once the running lane closes"

echo "=== a --wait-slot wait ends with the lane judged again ==="
row wait-walled
seed_running CC-9
launch one 1 0 --lane "$LANE_A" --wait-slot CC-1 &
WAITER=$!
await_line one '^open-terminal: slot-waiting'
: > "$ROW/wall"
"$WS" --state-dir "$STATE" update oversee '.lanes |= map(.status = "done")' >/dev/null
await_exit "$WAITER"
assert_eq "rc=$(rc one) $(key one | tail -n 1) opened=$([[ -e "$ROW/opened.one" ]] && echo yes || echo no)" \
  "rc=1 open-terminal: lane-model-walled lane=$LANE_A model=opus pct=97 bucket=five_hour opened=no" \
  "a named lane whose window walled during the wait is refused rather than launched"
row wait-repick
printf 'CLAUDE_CONFIG_DIR=%s\n' "$LANE_A" > "$ROW/pick"
seed_claim CC-8 "$LANE_A"
launch one 10 1 --lane auto --wait-slot CC-1 &
WAITER=$!
await_line one '^open-terminal: slot-waiting item=CC-1 over=account '
printf 'CLAUDE_CONFIG_DIR=%s\n' "$LANE_B" > "$ROW/pick"
await_exit "$WAITER"
assert_eq "rc=$(rc one) account=$(account_of CC-1)" "rc=0 account=$LANE_B" \
  "an auto lane waiting on a full account alone launches on the account the next pick has room on"

echo "=== the account cap counts a lane by its record where it has no claim ==="
# A lane whose claim write failed, and a GUI lane, which writes none, each
# still hold their account through the record the launch wrote: the next
# launch onto that account, in a later invocation, counts them.
row gui-account
MODE=--ghostty launch one 10 1 --lane "$LANE_A" CC-1
launch two 10 1 --lane "$LANE_A" CC-2
assert_eq "one=$(rc one) two=$(rc two) $(key two)" \
  "one=0 two=1 open-terminal: account-cap-reached item=CC-2 lane=$LANE_A cap=1 claims=1 records=1 claims-other=0" \
  "a GUI lane recorded on the account fills its cap for the next launch"
# A GUI record names no window, so only the end of its item drops the
# reservation the next item would otherwise count beside it.
row gui-batch
MODE=--ghostty launch one 2 0 CC-1 CC-2
assert_eq "rc=$(rc one) running=$(running) $(key one)" "rc=0 running=CC-1,CC-2 " \
  "a GUI batch at a fleet cap of 2 launches both items"
if [[ "$(id -u)" -eq 0 ]]; then
  echo "  skip  running as root, whose writes a directory mode does not stop"
else
  # The claim store is readable and not writable: a judged launch cannot
  # write its reservation, and one naming no fleet cannot write its claim.
  # Each arm of the gate that admits a launch reserves: within both caps, and
  # past the fleet cap on --over-cap.
  for arm in within over; do
    row "reserve-lost-$arm"
    over=()
    if [[ "$arm" == over ]]; then seed_running CC-9; over=(--over-cap); fi
    mkdir -p "$CLAIMS/claims"
    chmod 555 "$CLAIMS/claims"
    launch one 1 5 --lane "$LANE_A" ${over[@]+"${over[@]}"} CC-1
    chmod 755 "$CLAIMS/claims"
    assert_eq "rc=$(rc one) $(key one) opened=$([[ -e "$ROW/opened.one" ]] && echo yes || echo no)" \
      "rc=1 open-terminal: cap-reserve-failed item=CC-1 store=$CLAIMS/claims opened=no" \
      "a claim store that takes no reservation refuses a launch admitted $arm the caps before any window, admitting nothing"
  done
  # The store stops taking writes after a launch naming no lane reserved its
  # place, so the item's end cannot remove the reservation.
  row reserve-stuck
  STUB_HOLD_CREATE="$ROW/release" launch one 10 0 CC-1 &
  FIRST=$!
  await_step one create
  chmod 555 "$CLAIMS/claims"
  : > "$ROW/release"
  await_exit "$FIRST"
  chmod 755 "$CLAIMS/claims"
  assert_eq "rc=$(rc one) $(grep -cxE "open-terminal: reserve-unremoved path=$CLAIMS/claims/claim\.[^/]+\.reserve" "$ROW/one.err" || true)" \
    "rc=0 1" "a reservation that cannot be removed is reported with its path, and the launch stands"
  # Under --lane auto the re-pick reads claims alone, so a batch whose claim
  # went unwritten stops rather than picking an account it cannot see.
  row claim-spread
  printf 'CLAUDE_CONFIG_DIR=%s\n' "$LANE_A" > "$ROW/pick"
  mkdir -p "$CLAIMS/claims"
  chmod 555 "$CLAIMS/claims"
  STATE="" launch one 10 0 --lane auto CC-1 CC-2
  chmod 755 "$CLAIMS/claims"
  assert_eq "rc=$(rc one) opened=$([[ -e "$ROW/opened.one" ]] && echo yes || echo no) $(key one)" \
    "rc=1 opened=yes open-terminal: claim-unrecorded item=CC-2 launched=1" \
    "the auto item after an unwritten claim is refused rather than picked on an account it cannot see"
  # A named lane needs no claim to pick its account, so its batch runs on.
  row claim-named
  mkdir -p "$CLAIMS/claims"
  chmod 555 "$CLAIMS/claims"
  STATE="" launch one 10 0 --lane "$LANE_A" CC-1 CC-2
  chmod 755 "$CLAIMS/claims"
  assert_eq "rc=$(rc one) $(grep -c '^open-terminal: summary launched=2 ' "$ROW/one.out" || true)" "rc=0 1" \
    "a named lane's batch naming no fleet runs on past unwritten claims"
fi

echo "=== a refusal stops the batch ==="
row batch
seed_running CC-9
launch one 1 0 --lane "$LANE_A" CC-1 CC-2
assert_eq "rc=$(rc one) $(key one) running=$(running)" \
  "rc=1 open-terminal: cap-reached item=CC-1 cap=1 running=1 claims=0 running=CC-9" \
  "the first refused item ends the batch, so the second is neither judged nor launched"

echo "=== a count or a lock that cannot be had refuses before any window ==="
row state-unreadable
"$WS" --state-dir "$STATE" init oversee >/dev/null
printf '%s\n' '{"lanes":[' > "$STATE/workflow-state-oversee.json"
launch one 5 0 --lane "$LANE_A" CC-1
assert_eq "rc=$(rc one) $(key one) opened=$([[ -e "$ROW/opened.one" ]] && echo yes || echo no)" \
  "rc=1 open-terminal: cap-unreadable item=CC-1 source=state opened=no" \
  "a fleet state that does not parse refuses the launch rather than counting nothing"
row lock-unopenable
"$WS" --state-dir "$STATE" init oversee >/dev/null
mkdir -p "$STATE/workflow-state-oversee.json.launch.lock"
launch one 5 0 --lane "$LANE_A" CC-1
assert_eq "rc=$(rc one) $(key one) opened=$([[ -e "$ROW/opened.one" ]] && echo yes || echo no)" \
  "rc=1 open-terminal: cap-lock-failed item=CC-1 lock=$STATE/workflow-state-oversee.json.launch.lock opened=no" \
  "a launch lock that cannot be opened refuses the launch rather than counting unlocked"

echo "=== refusals ahead of any count ==="
row options
for spec in \
  "no-fleet|1|open-terminal: cap-option-unanchored option=--wait-slot|--wait-slot" \
  "no-fleet|1|open-terminal: cap-option-unanchored option=--over-cap|--over-cap" \
  "fleet|1|open-terminal: over-cap-items count=2|--over-cap CC-2"; do
  IFS='|' read -r mode want_rc want words <<<"$spec"
  # shellcheck disable=SC2086
  if [[ "$mode" == no-fleet ]]; then
    rc=0
    err="$(cd "$REPO" && PATH="$BIN:$PATH" WORKTREE_CLI="$STUB" LANES_CLI="$BIN/lanes" TMUX=stub,1,0 \
      "$OT" --tmux --harness claude --cmd "true --model opus --effort high $QUESTION_OFF_ALL" $words CC-1 2>&1 >/dev/null)" || rc=$?
  else
    launch opt 1 0 $words CC-1
    rc="$(rc opt)"; err="$(cat "$ROW/opt.err")"
  fi
  assert_eq "rc=$rc $(grep -E '^open-terminal: (cap-option-unanchored|over-cap-items) ' <<<"$err" || true)" "rc=$want_rc $want" \
    "'$words' on a $mode launch is refused before anything launches"
done

echo "=== an unreadable claim store refuses rather than counting nothing ==="
row unreadable
mkdir -p "$CLAIMS"
: > "$CLAIMS/claims"
launch one 5 5 --lane "$LANE_A" CC-1
assert_eq "rc=$(rc one) $(key one) running=$(running)" "rc=1 open-terminal: cap-unreadable item=CC-1 source=claims running=" \
  "a claim store that is not a directory refuses the launch"

echo
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
