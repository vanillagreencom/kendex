#!/usr/bin/env bash
# review-artifact-check --issue: a finding at a location the key's
# `declined_items` records is reported under `repeats` as a candidate, carrying
# each decline recorded there, so review-pr § 4 and § 7 judge whether it is the
# declined defect re-raised or a new one at the same place. The producer is a
# re-review or QA reviewer re-raising a finding an earlier cycle declined.
# Each row seeds its own state and artifact and pins the exit status, the
# complete result object and stderr's first line. The planted controls below
# the table each name the row their mutant must turn red.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
CHECK="$REPO_ROOT/skills/orch/scripts/review-artifact-check"
WS="$REPO_ROOT/skills/orch/scripts/workflow-state"
source "$TEST_DIR/lib/waiter-assertions.sh"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
source "$TEST_DIR/lib/review-artifact-fixture.sh"

export BLK='src/x.rs (`f`)' SUG='src/y.rs (`g`)'
finding() { # LOCATION CATEGORY
  jq -n --arg l "$1" --arg c "$2" '{id: 1, title: "t", location: $l, description: "d", recommendation: "r", priority: 3, estimate: 2}
    + (if $c == "" then {} else {category: $c} end)'
}
artifact() { # KIND PATH
  case "$1" in
    std) jq -n --argjson b "$(finding "$BLK" "")" --argjson s "$(finding "$SUG" fix)" \
      '{verdict: "action_required", blockers: [$b], suggestions: [$s], qa_metadata: {}}' > "$2" ;;
    twin) jq -n --argjson b "$(finding "$BLK" "")" \
      '{verdict: "action_required", blockers: [$b, ($b | .id = 2)], suggestions: [], qa_metadata: {}}' > "$2" ;;
    notjson) printf 'not json' > "$2"; return 0 ;;
  esac
  review_fixture_stamp "$2"
}

# label ^ mode ^ artifact ^ declined_items (JSON) ^ key ^ exit ^ result (a jq
# program over $path, empty for none) ^ stderr's first line. key: `self` for
# the row's own state, `none` for no --issue, `empty` for a blank --issue,
# `dironly` for --state-dir alone, anything else a key with no state.
ROWS='a re-raised declined blocker is a candidate carrying its decline (file mode)^file^std^[{"location":env.BLK,"description":"d","reason":"r1"}]^self^0^{ok:true,path:$path,reason:"valid",repeats:[{array:"blockers",index:0,location:env.BLK,declined:[{description:"d",reason:"r1"}]}]}^
a re-raised declined suggestion is a candidate (glob mode)^glob^std^[{"location":env.SUG,"description":"d","reason":"r2"}]^self^0^{ok:true,path:$path,reason:"valid",repeats:[{array:"suggestions",index:0,location:env.SUG,declined:[{description:"d",reason:"r2"}]}]}^
a different defect at a declined location is a candidate carrying the recorded description^file^std^[{"location":env.BLK,"description":"another defect","reason":"r3"}]^self^0^{ok:true,path:$path,reason:"valid",repeats:[{array:"blockers",index:0,location:env.BLK,declined:[{description:"another defect",reason:"r3"}]}]}^
two findings at one declined location keep their own indexes^file^twin^[{"location":env.BLK,"description":"d","reason":"r4"}]^self^0^{ok:true,path:$path,reason:"valid",repeats:[0,1]|map({array:"blockers",index:.,location:env.BLK,declined:[{description:"d",reason:"r4"}]})}^
a finding at an undeclined location is no candidate^file^std^[{"location":"src/z.rs","description":"d","reason":"r"}]^self^0^{ok:true,path:$path,reason:"valid",repeats:[]}^
no declined items: --issue still answers, with no candidate^glob^std^[]^self^0^{ok:true,path:$path,reason:"valid",repeats:[]}^
without --issue the result carries no repeats field^file^std^[{"location":env.BLK,"description":"d","reason":"r"}]^none^0^{ok:true,path:$path,reason:"valid"}^
a malformed artifact under --issue is rejected on its parse, with no repeats^file^notjson^[{"location":env.BLK,"description":"d","reason":"r"}]^self^1^{ok:false,path:$path,reason:"invalid",detail:"review-artifact-check: gate_failed jq_exit=5"}^
unreadable declined state refuses, never reads as none declined^file^std^[]^KEN-404^2^^review-artifact-check: declined_state issue=KEN-404
--state-dir without --issue is a usage refusal^file^std^[]^dironly^2^^review-artifact-check: usage argc=3
a blank --issue value is a usage refusal^file^std^[]^empty^2^^review-artifact-check: option_value option=--issue'

# run_row CHECK ROW TAG — prints `GOT<TAB>WANT` for the row against that
# script, its state keyed KEN-TAG.
run_row() {
  local check="$1" label mode kind declined key want_rc want_prog want_err n="$3"
  IFS='^' read -r label mode kind declined key want_rc want_prog want_err <<<"$2"
  local sd="$TMP_ROOT/state-$n" wt="$TMP_ROOT" file="$TMP_ROOT/tmp/review-rev-20260101-000000.json"
  "$WS" --state-dir "$sd" init "KEN-$n" --worktree "$wt" --branch "ken-$n" >/dev/null
  "$WS" --state-dir "$sd" update "KEN-$n" ".declined_items = $declined" >/dev/null
  mkdir -p "$wt/tmp"
  rm -f -- "$wt"/tmp/review-rev-*.json
  artifact "$kind" "$file"
  local args=()
  case "$key" in
    none) ;;
    self) args=(--issue "KEN-$n" --state-dir "$sd") ;;
    empty) args=(--issue "") ;;
    dironly) args=(--state-dir "$sd") ;;
    *) args=(--issue "$key" --state-dir "$sd") ;;
  esac
  local rc=0 out
  case "$mode" in
    file) out=$("$check" --file "$file" "$wt" ${args[@]+"${args[@]}"} 2>"$TMP_ROOT/stderr") || rc=$? ;;
    glob) out=$("$check" "$wt" rev 0 ${args[@]+"${args[@]}"} 2>"$TMP_ROOT/stderr") || rc=$? ;;
  esac
  local got_json="" want_json=""
  [[ -z "$out" ]] || got_json=$(jq -c 'if has("detail") then .detail |= split("\n")[0] else . end' <<<"$out")
  [[ -z "$want_prog" ]] || want_json=$(jq -cn --arg path "$file" "$want_prog")
  local got_err="" want_line=""
  [[ -z "$want_err" ]] || { got_err=$(head -n 1 "$TMP_ROOT/stderr"); want_line="$want_err"; }
  printf '%s\t%s\n' "$rc|$got_json|$got_err" "$want_rc|$want_json|$want_line"
}

i=0
while IFS= read -r row; do
  i=$((i + 1))
  IFS=$'\t' read -r got want <<<"$(run_row "$CHECK" "$row" "$i")"
  assert_eq "$got" "$want" "${row%%^*}" "$TMP_ROOT/stderr"
done <<<"$ROWS"

# Controls: a planted mutant of the script must turn its named row red.
CTRL="$TMP_ROOT/scripts"
cp -R "$REPO_ROOT/skills/orch/scripts" "$CTRL"
while IFS='^' read -r name program target; do
  sed "$program" "$CHECK" > "$CTRL/review-artifact-check"
  if cmp -s "$CTRL/review-artifact-check" "$CHECK"; then
    FAIL=$((FAIL + 1)); printf '  FAIL  control %s planted nothing: its sed program matched no text\n' "$name"
    continue
  fi
  row=$(grep -F -- "$target^" <<<"$ROWS")
  IFS=$'\t' read -r got want <<<"$(run_row "$CTRL/review-artifact-check" "$row" "c-$name")"
  if [[ "$got" != "$want" ]]; then
    pass "control $name turns red: $target"
  else
    FAIL=$((FAIL + 1)); printf '  FAIL  control %s left its row green: %s\n' "$name" "$target"
  fi
done <<'CONTROLS'
no-match^s/select(\.location == \$l)/select(.location == $l and false)/^a re-raised declined blocker is a candidate carrying its decline (file mode)
no-ok-guard^s/"\$ok" == true && //^a malformed artifact under --issue is rejected on its parse, with no repeats
fixed-index^s/index: \.key/index: 0/^two findings at one declined location keep their own indexes
no-dironly-check^/declined_state_dir" || -n "\$declined_issue/d^--state-dir without --issue is a usage refusal
CONTROLS

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
