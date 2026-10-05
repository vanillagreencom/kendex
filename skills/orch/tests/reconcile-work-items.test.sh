#!/usr/bin/env bash
# Pins for reconcile-work-items: the read-only sweep
# reports the three write-without-read-back shapes and stays quiet on their
# healthy twins. Fully offline: a Linear CLI stand-in answers the sweep's one
# live read, `issues list --max [--team T] --format=raw`, from fixture rows,
# and the PR probe is stubbed. LINEAR_TEAM is unset unless a case sets it.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP:?}"' EXIT
# The sweep runs from a copy of the orch scripts with the stand-in at the
# sibling linear path, where it looks for the CLI.
mkdir -p "$TMP/skills/orch" "$TMP/skills/linear/scripts"
cp -R "$SKILL_DIR/scripts" "$TMP/skills/orch/scripts"
RW="$TMP/skills/orch/scripts/reconcile-work-items"
cat >"$TMP/skills/linear/scripts/linear.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$LINEAR_CALLS"
case "$*" in
  "issues list --max --format=raw" | "issues list --max --team "?*" --format=raw") ;;
  *) echo "linear stand-in: unsupported call: $*" >&2; exit 2 ;;
esac
[ -z "${LINEAR_FAIL:-}" ] || { echo '{"error":"linear-pages: incomplete=issues"}' >&2; exit 1; }
jq -c '{issues: {nodes: .}}' .tracker-fixture/issues.json
STUB
chmod +x "$TMP/skills/linear/scripts/linear.sh"
export LINEAR_CALLS="$TMP/linear-calls"
unset LINEAR_TEAM

# shellcheck source=lib/assertions.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/assertions.sh"

R="$TMP/repo"
mkdir -p "$R/.tracker-fixture"
git -C "$R" init -q -b main 2>/dev/null || git -C "$R" init -q

now="$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"
old="$(date -u -d '3 days ago' +%Y-%m-%dT%H:%M:%S.000Z 2>/dev/null || date -j -u -v-3d +%Y-%m-%dT%H:%M:%S.000Z)"

issue() { # ID TITLE STATE_NAME STATE_TYPE UPDATED [PARENT] [DESC]
  local parent="null"
  [ -n "${6:-}" ] && parent="{\"identifier\":\"$6\"}"
  jq -cn --arg id "$1" --arg t "$2" --arg sn "$3" --arg st "$4" --arg up "$5" --argjson p "$parent" --arg d "${7:-}" \
    '{identifier:$id, title:$t, state:{name:$sn,type:$st}, updatedAt:$up, parent:$p, description:$d, trashed:false, archivedAt:null}'
}

{
  issue "T-1"  "parked container"        "Todo"        "unstarted" "$now"
  issue "T-2"  "done child a"            "Done"        "completed" "$now" "T-1"
  issue "T-3"  "done child b"            "Done"        "completed" "$now" "T-1"
  issue "T-4"  "canceled child"          "Canceled"    "canceled"  "$now" "T-1"
  issue "T-5"  "healthy container"       "Todo"        "unstarted" "$now"
  issue "T-6"  "done child"              "Done"        "completed" "$now" "T-5"
  issue "T-7"  "pending child"           "In Progress" "started"   "$now" "T-5"
  issue "T-8"  "closed container"        "Done"        "completed" "$now"
  issue "T-9"  "done child of closed"    "Done"        "completed" "$now" "T-8"
  issue "T-10" "stale started merged"    "In Review"   "started"   "$old"
  issue "T-11" "fresh started"           "In Progress" "started"   "$now"
  issue "T-12" "stale started live pr"   "In Progress" "started"   "$old"
  issue "T-13" "done with open boxes"    "Done"        "completed" "$now" "" "did:\n- [x] one\n- [ ] two"
  issue "T-14" "done all checked"        "Done"        "completed" "$now" "" "did:\n- [x] one\n- [x] two"
  issue "T-15" "trashed parked"          "Todo"        "unstarted" "$now"
  issue "T-16" "ship the widget (One PR)" "In Review"  "started"   "$now"
  issue "T-17" "done bundle child"       "Done"        "completed" "$now" "T-16"
} | jq -s 'map(if .identifier == "T-15" then .trashed = true else . end)' >"$R/.tracker-fixture/issues.json"

cat >"$TMP/gh-stub" <<'STUB'
#!/usr/bin/env bash
# args: pr list --state STATE --head BRANCH --json number --jq length
# A leaked repo redirect must never reach the probe.
if [ -n "${GH_REPO:-}" ] || [ -n "${GITHUB_REPOSITORY:-}" ]; then
  echo "gh-stub: GH_REPO/GITHUB_REPOSITORY leaked into the probe" >&2
  exit 9
fi
state=""; head=""
while [ $# -gt 0 ]; do
  case "$1" in
    --state) state="$2"; shift ;;
    --head) head="$2"; shift ;;
  esac
  shift
done
case "$head:$state" in
  t-10:merged) echo 1 ;;
  t-12:open) echo 1 ;;
  *) echo 0 ;;
esac
STUB
chmod +x "$TMP/gh-stub"

OUT=""; RC=0
OUT="$(cd "$R" && GH_REPO=elsewhere/other GITHUB_REPOSITORY=elsewhere/other RECONCILE_GH_CLI="$TMP/gh-stub" "$RW" 2>&1)" || RC=$?

[ "$RC" -eq 1 ] && pass "findings exit 1" || fail "exit code" "rc=$RC out=$OUT"
assert_eq "$(sort -u "$LINEAR_CALLS")" "issues list --max --format=raw" "the sweep reads every issue live, every page"
: >"$LINEAR_CALLS"
(cd "$R" && LINEAR_TEAM=kendex RECONCILE_GH_CLI="$TMP/gh-stub" "$RW" >/dev/null 2>&1) || true
assert_eq "$(sort -u "$LINEAR_CALLS")" "issues list --max --team kendex --format=raw" "the sweep reads the project's team where one is set"
assert_contains "$OUT" "container-parked issue=T-1" "the parked container is reported"
# A "(one PR)" root with Done children is the single-PR bundle contract
# working, never a parked container.
assert_not_contains "$OUT" "container-parked issue=T-16" "a (One PR) bundle root is not container-parked (case-insensitive marker)"
assert_not_contains "$OUT" "container-parked issue=T-5" "a container with a pending child stays quiet"
assert_not_contains "$OUT" "T-8" "a closed container stays quiet"
case "$OUT" in *"started-stale issue=T-10"*"pr=merged"*) pass "the stale started item with a merged PR is reported" ;; *) fail "stale merged" "$OUT" ;; esac
assert_not_contains "$OUT" "T-11" "a fresh started item stays quiet"
assert_not_contains "$OUT" "T-12" "a stale item with a live PR stays quiet"
assert_contains "$OUT" "done-unchecked issue=T-13" "the Done item with open boxes is reported"
assert_not_contains "$OUT" "T-14" "a Done item with every box checked stays quiet"
assert_not_contains "$OUT" "T-15" "a trashed row stays out of every check"

# Clean fixture: only healthy rows -> exit 0 with the clean line.
jq '[.[] | select(.identifier == "T-5" or .identifier == "T-6" or .identifier == "T-7" or .identifier == "T-14" or .identifier == "T-11")]' \
  "$R/.tracker-fixture/issues.json" >"$R/.tracker-fixture/issues2.json"
mv "$R/.tracker-fixture/issues2.json" "$R/.tracker-fixture/issues.json"
OUT=""; RC=0
OUT="$(cd "$R" && RECONCILE_GH_CLI="$TMP/gh-stub" "$RW" 2>&1)" || RC=$?
[ "$RC" -eq 0 ] && case "$OUT" in *"clean"*) true ;; *) false ;; esac \
  && pass "a healthy tracker exits 0 with the clean line" || fail "clean run" "rc=$RC out=$OUT"

# A malformed row inside the issue read: the scan must die loudly, never end
# early as a clean pass.
printf '[{"identifier":"T-BAD"}, 42]' >"$R/.tracker-fixture/issues.json"
OUT=""; RC=0
OUT="$(cd "$R" && RECONCILE_GH_CLI="$TMP/gh-stub" "$RW" 2>&1)" || RC=$?
[ "$RC" -eq 2 ] && pass "a malformed issue row is a loud collection error" || fail "malformed row" "rc=$RC out=$OUT"

# Object-shaped but incomplete rows must not read as a clean tracker: a row
# without identifier/state carries nothing the scans can inspect.
printf '[{}]' >"$R/.tracker-fixture/issues.json"
OUT=""; RC=0
OUT="$(cd "$R" && RECONCILE_GH_CLI="$TMP/gh-stub" "$RW" 2>&1)" || RC=$?
[ "$RC" -eq 2 ] && pass "an empty-object row is a config error, never clean" || fail "empty-object row" "rc=$RC out=$OUT"
printf '[{"identifier":"T-1","state":{"name":"Todo"}}]' >"$R/.tracker-fixture/issues.json"
OUT=""; RC=0
OUT="$(cd "$R" && RECONCILE_GH_CLI="$TMP/gh-stub" "$RW" 2>&1)" || RC=$?
[ "$RC" -eq 2 ] && pass "a row missing state.type is a config error" || fail "missing state.type" "rc=$RC out=$OUT"

# A started row without a usable timestamp must be a config error: GNU date
# parses an empty field as midnight today, which would quietly read as fresh.
printf '[{"identifier":"T-1","title":"t","state":{"name":"In Progress","type":"started"},"parent":null,"description":"","updatedAt":""}]' >"$R/.tracker-fixture/issues.json"
OUT=""; RC=0
OUT="$(cd "$R" && RECONCILE_GH_CLI="$TMP/gh-stub" "$RW" 2>&1)" || RC=$?
[ "$RC" -eq 2 ] && pass "a started row with an empty updatedAt is a config error, never fresh" || fail "empty updatedAt" "rc=$RC out=$OUT"
printf '[{"identifier":"T-1","title":"t","state":{"name":"In Progress","type":"started"},"parent":null,"description":"","updatedAt":"   "}]' >"$R/.tracker-fixture/issues.json"
OUT=""; RC=0
OUT="$(cd "$R" && RECONCILE_GH_CLI="$TMP/gh-stub" "$RW" 2>&1)" || RC=$?
[ "$RC" -eq 2 ] && pass "a whitespace-only updatedAt is a config error (GNU date parses it as midnight)" || fail "blank updatedAt" "rc=$RC out=$OUT"
printf '[{"identifier":"T-1","title":"t","state":{"name":"In Progress","type":"started"},"parent":null,"description":""}]' >"$R/.tracker-fixture/issues.json"
OUT=""; RC=0
OUT="$(cd "$R" && RECONCILE_GH_CLI="$TMP/gh-stub" "$RW" 2>&1)" || RC=$?
[ "$RC" -eq 2 ] && pass "a started row with no updatedAt key at all is a config error" || fail "missing updatedAt key" "rc=$RC out=$OUT"

# A failed live read: loud collection error, never a clean pass.
printf '[]' >"$R/.tracker-fixture/issues.json"
OUT=""; RC=0
OUT="$(cd "$R" && LINEAR_FAIL=1 RECONCILE_GH_CLI="$TMP/gh-stub" "$RW" 2>&1)" || RC=$?
[ "$RC" -eq 2 ] && pass "a failed issue read is a collection error, never clean" || fail "failed read" "rc=$RC out=$OUT"
assert_contains "$OUT" "reconcile-work-items: collection-failed source=linear" "a failed issue read names the read"
OUT=""; RC=0
OUT="$(cd "$R" && RECONCILE_GH_CLI="$TMP/gh-stub" "$RW" 2>&1)" || RC=$?
[ "$RC" -eq 0 ] && pass "an empty tracker is clean" || fail "empty tracker" "rc=$RC out=$OUT"

# Control: a sweep that carries on past a failed read reports a clean
# tracker it never read. The copy is private; the shipped script is untouched.
# shellcheck source=lib/growth-state.sh
source "$TEST_DIR/lib/growth-state.sh"
cp -- "$RW" "$RW.mutant"
mutate_file "$RW.mutant" \
  '"$LINEAR" issues list --max ${LINEAR_TEAM:+--team "$LINEAR_TEAM"} --format=raw >"$TMPD/raw.json" || config_error collection-failed source=linear' \
  '"$LINEAR" issues list --max ${LINEAR_TEAM:+--team "$LINEAR_TEAM"} --format=raw >"$TMPD/raw.json" || printf '"'"'{"issues":{"nodes":[]}}'"'"' >"$TMPD/raw.json"'
OUT=""; RC=0
OUT="$(cd "$R" && LINEAR_FAIL=1 RECONCILE_GH_CLI="$TMP/gh-stub" bash "$RW.mutant" 2>&1)" || RC=$?
[ "$RC" -eq 0 ] && pass "control: without the read refusal a failed read reports clean" \
  || fail "control: failed read" "rc=$RC out=$OUT"
# Control: a sweep that drops the team reads every team the key reaches.
cp -- "$RW" "$RW.team-mutant"
mutate_file "$RW.team-mutant" '${LINEAR_TEAM:+--team "$LINEAR_TEAM"} ' ''
: >"$LINEAR_CALLS"
(cd "$R" && LINEAR_TEAM=kendex RECONCILE_GH_CLI="$TMP/gh-stub" bash "$RW.team-mutant" >/dev/null 2>&1) || true
[ "$(sort -u "$LINEAR_CALLS")" != "issues list --max --team kendex --format=raw" ] \
  && pass "control: without the team the team row fails" || fail "control: team row missed the dropped team"

# --- settings-file threshold -------------------------------------------------
# RECONCILE_STALE_HOURS set in the project's kendex.settings.toml (not the
# environment) must reach the sweep: a 2h-old In Progress item is quiet at the
# 24h default and a finding at a 1h threshold.
R2="$TMP/settings-repo"
mkdir -p "$R2/.tracker-fixture"
git -C "$R2" init -q
TWO_H_AGO="$(date -u -d '2 hours ago' '+%Y-%m-%dT%H:%M:%S.000Z' 2>/dev/null || date -j -u -v-2H '+%Y-%m-%dT%H:%M:%S.000Z')"
cat >"$R2/.tracker-fixture/issues.json" <<JSON
[{"identifier":"VST-900","title":"stale candidate","state":{"name":"In Progress","type":"started"},"parent":null,"description":"","updatedAt":"$TWO_H_AGO"}]
JSON
RC=0
OUT="$(cd "$R2" && RECONCILE_GH_CLI="$TMP/gh-stub" "$RW" 2>&1)" || RC=$?
[ "$RC" -eq 0 ] && pass "default 24h threshold stays quiet at 2h" || fail "default threshold" "rc=$RC out=$OUT"
printf '[env]\nRECONCILE_STALE_HOURS = "1"\n' >"$R2/kendex.settings.toml"
RC=0
OUT="$(cd "$R2" && RECONCILE_GH_CLI="$TMP/gh-stub" "$RW" 2>&1)" || RC=$?
{ [ "$RC" -eq 1 ] && grep -q "VST-900" <<<"$OUT"; } && pass "settings-file RECONCILE_STALE_HOURS reaches the sweep" || fail "settings-file threshold" "rc=$RC out=$OUT"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
