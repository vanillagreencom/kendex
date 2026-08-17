#!/usr/bin/env bash
# Pins for reconcile-work-items (vstack #1388 / VST-318): the read-only sweep
# reports the three write-without-read-back shapes and stays quiet on their
# healthy twins. Fully offline: fixture cache + stubbed PR probe.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
RW="$SKILL_DIR/scripts/reconcile-work-items"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; }

R="$TMP/repo"
mkdir -p "$R/.cache/linear"
git -C "$R" init -q -b main 2>/dev/null || git -C "$R" init -q

now="$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"
old="$(date -u -d '3 days ago' +%Y-%m-%dT%H:%M:%S.000Z)"

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
} | jq -s 'map(if .identifier == "T-15" then .trashed = true else . end)' >"$R/.cache/linear/issues.json"

cat >"$TMP/gh-stub" <<'STUB'
#!/usr/bin/env bash
# args: pr list --state STATE --head BRANCH --json number --jq length
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
OUT="$(cd "$R" && RECONCILE_GH_CLI="$TMP/gh-stub" "$RW" 2>&1)" || RC=$?

[ "$RC" -eq 1 ] && ok "findings exit 1" || bad "exit code" "rc=$RC out=$OUT"
case "$OUT" in *"container-parked: T-1"*) ok "the parked container is reported" ;; *) bad "parked container" "$OUT" ;; esac
case "$OUT" in *"container-parked: T-5"*) bad "healthy container reported" "$OUT" ;; *) ok "a container with a pending child stays quiet" ;; esac
case "$OUT" in *"T-8"*) bad "closed container reported" "$OUT" ;; *) ok "a closed container stays quiet" ;; esac
case "$OUT" in *"started-stale: T-10"*"PR merged"*) ok "the stale started item with a merged PR is reported" ;; *) bad "stale merged" "$OUT" ;; esac
case "$OUT" in *"T-11"*) bad "fresh started reported" "$OUT" ;; *) ok "a fresh started item stays quiet" ;; esac
case "$OUT" in *"T-12"*) bad "live-PR started reported" "$OUT" ;; *) ok "a stale item with a live PR stays quiet" ;; esac
case "$OUT" in *"done-unchecked: T-13"*) ok "the Done item with open boxes is reported" ;; *) bad "done unchecked" "$OUT" ;; esac
case "$OUT" in *"T-14"*) bad "all-checked reported" "$OUT" ;; *) ok "a Done item with every box checked stays quiet" ;; esac
case "$OUT" in *"T-15"*) bad "trashed reported" "$OUT" ;; *) ok "a trashed row stays out of every check" ;; esac

# Clean fixture: only healthy rows -> exit 0 with the clean line.
jq '[.[] | select(.identifier == "T-5" or .identifier == "T-6" or .identifier == "T-7" or .identifier == "T-14" or .identifier == "T-11")]' \
  "$R/.cache/linear/issues.json" >"$R/.cache/linear/issues2.json"
mv "$R/.cache/linear/issues2.json" "$R/.cache/linear/issues.json"
OUT=""; RC=0
OUT="$(cd "$R" && RECONCILE_GH_CLI="$TMP/gh-stub" "$RW" 2>&1)" || RC=$?
[ "$RC" -eq 0 ] && case "$OUT" in *"clean"*) true ;; *) false ;; esac \
  && ok "a healthy tracker exits 0 with the clean line" || bad "clean run" "rc=$RC out=$OUT"

# Missing cache: loud config error, never a clean pass.
rm "$R/.cache/linear/issues.json"
OUT=""; RC=0
OUT="$(cd "$R" && "$RW" 2>&1)" || RC=$?
[ "$RC" -eq 2 ] && ok "a missing cache is a config error, never clean" || bad "missing cache" "rc=$RC out=$OUT"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
