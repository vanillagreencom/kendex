#!/usr/bin/env bash
# review-artifact-check --issue: a finding at a location the key's
# `declined_items` records is reported under `repeats`, so review-pr § 4 reads
# it as a decline re-raised rather than a new finding. The producer is a
# re-review panel reviewer re-raising a finding § 4 declined a cycle earlier.
# Each row seeds its own state, stamps one artifact and pins the exit status
# and the complete result object; one planted control follows the table.
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

BLK='src/x.rs (`f`)'
SUG='src/y.rs (`g`)'
artifact() { # PATH
  jq -n --arg b "$BLK" --arg s "$SUG" '{verdict: "action_required",
    blockers: [{id: 1, title: "t", location: $b, description: "d", recommendation: "r", priority: 1, estimate: 2}],
    suggestions: [{id: 2, title: "t", location: $s, description: "d", recommendation: "r", priority: 3, estimate: 2, category: "fix"}],
    qa_metadata: {}}' > "$1"
  review_fixture_stamp "$1"
}

# Row: label ^ mode ^ declined locations (JSON) ^ --issue key (`self` for the
# row's own, `no` for none) ^ exit ^ repeats (JSON; `absent` for a result that
# must carry no repeats field; `refused` for a keyed status 2 refusal).
n=0
while IFS='^' read -r label mode declined flag want_rc want_repeats; do
  n=$((n + 1))
  sd="$TMP_ROOT/state-$n"
  "$WS" --state-dir "$sd" init "KEN-$n" --worktree "$TMP_ROOT" --branch "ken-$n" >/dev/null
  "$WS" --state-dir "$sd" update "KEN-$n" --argjson locs "$declined" \
    '.declined_items = [$locs[] | {location: ., description: "d", reason: "cannot affect real usage", source: "pr-review"}]' >/dev/null
  mkdir -p "$TMP_ROOT/tmp"
  rm -f "$TMP_ROOT"/tmp/review-rev-*.json
  file="$TMP_ROOT/tmp/review-rev-20260101-000000.json"
  artifact "$file"
  issue_args=()
  key="$flag"
  [[ "$key" != self ]] || key="KEN-$n"
  [[ "$key" == no ]] || issue_args=(--issue "$key" --state-dir "$sd")
  rc=0
  case "$mode" in
    file) out=$("$CHECK" --file "$file" "$TMP_ROOT" ${issue_args[@]+"${issue_args[@]}"} 2>"$TMP_ROOT/stderr") || rc=$? ;;
    glob) out=$("$CHECK" "$TMP_ROOT" rev 0 ${issue_args[@]+"${issue_args[@]}"} 2>"$TMP_ROOT/stderr") || rc=$? ;;
  esac
  if [[ "$want_repeats" == refused ]]; then
    assert_eq "$rc [$out] $(head -n 1 "$TMP_ROOT/stderr")" \
      "$want_rc [] review-artifact-check: declined_state issue=$key" "$label" "$TMP_ROOT/stderr"
    continue
  fi
  if [[ "$want_repeats" == absent ]]; then
    expected=$(jq -cn --arg path "$file" '{ok: true, path: $path, reason: "valid"}')
  else
    expected=$(jq -cn --arg path "$file" --argjson r "$want_repeats" '{ok: true, path: $path, reason: "valid", repeats: $r}')
  fi
  assert_eq "$rc $(jq -c . <<<"$out")" "$want_rc $expected" "$label" "$TMP_ROOT/stderr"
done <<ROWS
a re-raised declined blocker is a repeat (file mode)^file^["$BLK"]^self^0^[{"array":"blockers","index":0,"location":"$BLK"}]
a re-raised declined suggestion is a repeat (glob mode)^glob^["$SUG"]^self^0^[{"array":"suggestions","index":0,"location":"$SUG"}]
a finding at an undeclined location is new^file^["src/z.rs (\`h\`)"]^self^0^[]
no declined items: --issue still answers, with nothing repeated^glob^[]^self^0^[]
without --issue the result carries no repeats field^file^["$BLK"]^no^0^absent
unreadable declined state refuses, never reads as none declined^file^["$BLK"]^KEN-404^2^refused
ROWS

# Control: the match predicate answers false while keeping its text shape. The
# first row's assertion must then see an empty repeats list.
CTRL="$TMP_ROOT/scripts"
cp -R "$REPO_ROOT/skills/orch/scripts" "$CTRL"
sed 's/any(\$declined\[\]; \. == \$l)/any($declined[]; . == $l and false)/' "$CHECK" > "$CTRL/review-artifact-check"
if cmp -s "$CTRL/review-artifact-check" "$CHECK"; then
  FAIL=$((FAIL + 1)); printf '  FAIL  control planted nothing: its sed program matched no text\n'
else
  sd="$TMP_ROOT/state-ctrl"
  "$WS" --state-dir "$sd" init KEN-C --worktree "$TMP_ROOT" --branch ken-c >/dev/null
  "$WS" --state-dir "$sd" update KEN-C --arg l "$BLK" '.declined_items = [{location: $l}]' >/dev/null
  file="$TMP_ROOT/tmp/review-rev-20260101-000000.json"
  artifact "$file"
  got=$("$CTRL/review-artifact-check" --file "$file" "$TMP_ROOT" --issue KEN-C --state-dir "$sd" | jq -c .repeats)
  if [[ "$got" == "[]" ]]; then
    pass "control: a predicate that matches nothing leaves the repeat unreported, which the first row catches"
  else
    FAIL=$((FAIL + 1)); printf '  FAIL  control: the planted predicate still reported %s\n' "$got"
  fi
fi

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
