#!/usr/bin/env bash
# Local --output and the action share the lane decision for real git diffs.
# Inputs: harness-ci scripts, orch measurement and the change-class action.
# Render causes are covered by render-moved-claims.test.sh.
set -euo pipefail
# shellcheck source=lib/sandbox.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/sandbox.sh"

ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
mkdir -p "$SANDBOX/action" "$SANDBOX/default/.github" "$SANDBOX/runner/change-class-record"
cp "$ROOT/.github/actions/change-class/classify" "$SANDBOX/action/classify"
cat >"$SANDBOX/action/proof" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [ "${USE_PROOF:-false}" = true ]; then
  printf 'reuse=true\nreason=exact-proof\nrun=42\ntree=t1\nrecord=%s\n' "$RUNNER_TEMP/change-class-record/record"
else
  printf 'reuse=false\nreason=ineligible-event\n'
fi
STUB
chmod +x "$SANDBOX/action/proof"
printf 'covers=all\n' >"$SANDBOX/runner/change-class-record/record"
printf 'check:event-uniform src/*\nother elsewhere/*\n' >"$SANDBOX/default/.github/ci-lanes.conf"
repo="$(new_repo lanes-output)"
commit_paths "$repo" baseline seed.txt
base="$(git -C "$repo" rev-parse HEAD)"

run_local() { # COMMAND DECLARATION COVERAGE
  local command="$1" declaration="$2" coverage="$3"
  : >"$SANDBOX/local-output"
  RUNNER_TEMP="$SANDBOX/runner" USE_PROOF=true "$command" \
    --event pull_request --base "$base" --head HEAD --repo "$repo" \
    --lanes-from "$declaration" --covers-all-lanes "$coverage" \
    --output "$SANDBOX/local-output" >"$SANDBOX/local-stdout" 2>"$SANDBOX/local-stderr"
}
lane_answer() { sed -n '/^lanes=/p; /^lanes_cause=/p' "$1"; }

rows=0
while IFS='|' read -r cause path lines expected declaration; do
  rows=$((rows + 1))
  git -C "$repo" checkout -q -B row "$base"
  git -C "$repo" clean -qfd
  mkdir -p "$repo/$(dirname "$path")"
  awk -v lines="$lines" 'BEGIN { for (i=1; i<=lines; i++) print "line " i }' >"$repo/$path"
  git -C "$repo" add -A
  git -C "$repo" commit -qm "$cause"
  decl=""
  [ "$declaration" != declared ] || decl="$SANDBOX/default"
  : >"$SANDBOX/action-output"
  CLASSIFIER="$ROOT" EVENT=pull_request BASE="$base" HEAD=HEAD REPO="$repo" \
    LANES_FROM="$decl" COVERS_ALL_LANES=true GITHUB_OUTPUT="$SANDBOX/action-output" \
    "$SANDBOX/action/classify" >"$SANDBOX/action-stdout" 2>"$SANDBOX/action-stderr"
  run_local "$CHANGE_CLASS" "$decl" true
  assert_eq "$cause: action cause" "lanes_cause=$cause" \
    "$(sed -n '/^lanes_cause=/p' "$SANDBOX/action-output")"
  assert_eq "$cause: local gate" "lanes=$expected" \
    "$(sed -n '/^lanes=/p' "$SANDBOX/local-output")"
  assert_eq "$cause: local and action agree" "$(lane_answer "$SANDBOX/action-output")" \
    "$(lane_answer "$SANDBOX/local-output")"
  assert_eq "$cause: stdout keeps its class contract" \
    "$(sed -n '/^change_class=/p' "$SANDBOX/local-output")" "$(cat "$SANDBOX/local-stdout")"
done <<'ROWS'
trivial|docs/guide.md|1|false|none
docs-only|docs/guide.md|21|false|declared
micro|src/main.sh|1|true|declared
small|src/main.sh|21|true|declared
standard|src/main.sh|151|true|declared
ROWS
require_rows lanes-output "$rows"

# The action can reuse a CI record. A local run with the same record still
# opens the gate. Coverage describes the workflow; it grants no local proof.
: >"$SANDBOX/action-output"
CLASSIFIER="$ROOT" EVENT=pull_request BASE="$base" HEAD=HEAD REPO="$repo" \
  LANES_FROM="$SANDBOX/default" GITHUB_OUTPUT="$SANDBOX/action-output" \
  RUNNER_TEMP="$SANDBOX/runner" USE_PROOF=true "$SANDBOX/action/classify" \
  >"$SANDBOX/action-stdout" 2>"$SANDBOX/action-stderr"
assert_eq 'CI keeps proof reuse' lanes_cause=proof-reused \
  "$(sed -n '/^lanes_cause=/p' "$SANDBOX/action-output")"
for coverage in true false; do
  run_local "$CHANGE_CLASS" "$SANDBOX/default" "$coverage"
  assert_eq "local ignores proof with coverage=$coverage" \
    "$(printf 'lanes=true\nlanes_cause=standard')" "$(lane_answer "$SANDBOX/local-output")"
done

# Restore the base command's missing output in a disposable package copy.
# The control must complete, then fail the same machine-output assertion.
mkdir -p "$SANDBOX/control"
cp -R "$TEST_DIR/.." "$SANDBOX/control/harness-ci"
cp -R "$TEST_DIR/../../orch" "$SANDBOX/control/orch"
needle='      [ "$output" = /dev/null ] || printf '\''lanes=%s\nlanes_cause=%s\n'\'' "$lanes" "$lanes_cause"'
NEEDLE="$needle" awk '$0 == ENVIRON["NEEDLE"] { hits++; print "      :"; next }
  { print } END { if (hits != 1) exit 2 }' "$CHANGE_CLASS" >"$SANDBOX/control/harness-ci/scripts/change-class"
! cmp -s "$CHANGE_CLASS" "$SANDBOX/control/harness-ci/scripts/change-class" || exit 1
run_local "$SANDBOX/control/harness-ci/scripts/change-class" "$SANDBOX/default" true
assert_eq 'must-fail: base output contract omits the local lane answer' "" \
  "$(lane_answer "$SANDBOX/local-output")"

# Local callers read the structured cause field, not the explanation. Both
# checkout refusals are reachable from --lanes-from on the public command.
# The control restores the bare field that the action formatter accepts.
cp "$CHANGE_CLASS" "$SANDBOX/control/harness-ci/scripts/change-class"
library="$SANDBOX/control/harness-ci/scripts/lib/change-class.sh"
needle='    die "cause=lanes-from-judged-tree root=$lanes_from" \'
NEEDLE="$needle" awk '$0 == ENVIRON["NEEDLE"] {
    hits++; sub(/cause=/, ""); print; next
  } { print } END { if (hits != 1) exit 2 }' \
  "$TEST_DIR/../scripts/lib/change-class.sh" >"$library"
! cmp -s "$TEST_DIR/../scripts/lib/change-class.sh" "$library" || exit 1
rows=0
while IFS='|' read -r name declaration expected command; do
  rows=$((rows + 1))
  classifier="$CHANGE_CLASS"
  [ "$command" != control ] || classifier="$SANDBOX/control/harness-ci/scripts/change-class"
  status=0
  run_local "$classifier" "$declaration" true || status=$?
  assert_eq "$name: lane checkout refusal exits 2" 2 "$status"
  assert_eq "$name: structured local cause" "$expected" \
    "$(sed -n 's/^wiring-error: cause=\([^ ]*\).*/\1/p' "$SANDBOX/local-stderr")"
  if [ "$command" = control ]; then
    assert_eq "$name: reaches the planted lane refusal" \
      "wiring-error: lanes-from-judged-tree root=$declaration" \
      "$(sed -n '/^wiring-error:/p' "$SANDBOX/local-stderr")"
  fi
  assert_eq "$name: refusal publishes no class" "" "$(cat "$SANDBOX/local-stdout")"
  assert_eq "$name: refusal publishes no lane outputs" "" "$(cat "$SANDBOX/local-output")"
done <<ROWS
judged checkout|$repo|lanes-from-judged-tree|production
absent checkout|$SANDBOX/missing-checkout|lanes-from-unreadable|production
must-fail bare cause control|$repo||control
ROWS
require_rows local-lane-refusals "$rows"
report lanes-output
