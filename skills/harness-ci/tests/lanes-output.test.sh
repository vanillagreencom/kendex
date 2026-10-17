#!/usr/bin/env bash
# Local --output and the action share the lane decision for real git diffs,
# and both answer the queue-only default where the workflow asks for it: a
# pull request or push stands every lane down, the merge group runs the
# lanes its diff selects, and the nightly full run runs every lane. A
# workflow that does not ask, a ci.yml copied before the default, keeps its
# lanes once a refresh delivers the render.
# Inputs: harness-ci scripts, orch measurement and the change-class action.
# Render causes are covered by render-moved-claims.test.sh.
set -euo pipefail
# shellcheck source=lib/sandbox.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/sandbox.sh"

ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
CLASSIFY="$ROOT/.github/actions/change-class/classify"
# The stand-down needs the render that reads the opt-back in both trees a
# merge can run pr-merge from. `default` carries it; `no-reader` does not.
READER=.agents/skills/harness-ci/scripts/change-class
DECLARATION='check:event-uniform src/*
other elsewhere/*
mac:nightly macos/*
'
for root in default no-reader; do
  mkdir -p "$SANDBOX/$root/.github"
  printf '%s' "$DECLARATION" >"$SANDBOX/$root/.github/ci-lanes.conf"
done
mkdir -p "$SANDBOX/default/$(dirname "$READER")"
cp "$CHANGE_CLASS" "$SANDBOX/default/$READER"

repo="$(new_repo lanes-output)"
mkdir -p "$repo/$(dirname "$READER")"
cp "$CHANGE_CLASS" "$repo/$READER"
commit_paths "$repo" baseline seed.txt
# One base per state of the opt-back in the base commit's settings.
base_with_settings() { # NAME SETTINGS — prints the base commit
  git -C "$repo" checkout -q -B "$1" main
  if [ -n "$2" ]; then
    printf '%s\n' "$2" >"$repo/kendex.settings.toml"
    git -C "$repo" add -A
    git -C "$repo" commit -qm "$1"
  fi
  git -C "$repo" rev-parse HEAD
}
base_default="$(base_with_settings base-default '')"
base_optback="$(base_with_settings base-optback "$(printf '[env]\nHARNESS_CI_PER_PUSH_REASON = "no merge queue"\nHARNESS_CI_QUEUE_PATHS = ""')")"
base_blank="$(base_with_settings base-blank "$(printf '[env]\nHARNESS_CI_PER_PUSH_REASON = "  "\nHARNESS_CI_QUEUE_PATHS = ""')")"
base_undeclared="$(base_with_settings base-undeclared "$(printf '[env]\nHARNESS_CI_PER_PUSH_REASON = "no merge queue"')")"

run_local() { # COMMAND EVENT BASE DECLARATION [DEFAULT]
  : >"$SANDBOX/local-output"
  "$1" --event "$2" --base "$3" --head HEAD --repo "$repo" \
    --lanes-from "$4" --queue-only-default "${5:-true}" --output "$SANDBOX/local-output" \
    >"$SANDBOX/local-stdout" 2>"$SANDBOX/local-stderr"
}
run_action() { # EVENT BASE DECLARATION DEFAULT — DEFAULT empty passes no input
  : >"$SANDBOX/action-output"
  CLASSIFIER="$ROOT" EVENT="$1" BASE="$2" HEAD="$(git -C "$repo" rev-parse HEAD)" REPO="$repo" \
    LANES_FROM="$3" QUEUE_ONLY_DEFAULT="$4" GITHUB_OUTPUT="$SANDBOX/action-output" \
    "$CLASSIFY" >"$SANDBOX/action-stdout" 2>"$SANDBOX/action-stderr"
}
lane_answer() { sed -n '/^queue_only=/p; /^lanes=/p; /^lanes_cause=/p' "$1"; }
# The action's lane_verdicts value, its lines joined with commas.
verdicts() {
  awk '$0 == "lane_verdicts<<__change_class_lane_verdicts_end__" { on = 1; next }
    $0 == "__change_class_lane_verdicts_end__" { on = 0 } on' "$SANDBOX/action-output" |
    tr '\n' ',' | sed 's/,$//'
}

# ROW|EVENT|BASE|PATH|LINES|DECLARATION|DEFAULT|LANES|LANES_CAUSE|QUEUE_ONLY|LANE VERDICTS
# BASE is the opt-back's state: default (unset), optback (a reason and an
# empty queue list), undeclared (a reason, no queue list) or blank. DEFAULT
# is the queue-only-default input; `no` passes none, as a copied ci.yml from
# before the default does, and the local command then passes false.
# LANE VERDICTS is the action's; `-` where no declaration is read.
rows=0
while IFS='|' read -r name event base_name path lines declaration default expected cause queue lane_verdicts; do
  rows=$((rows + 1))
  base_var="base_$base_name"
  base="${!base_var}"
  git -C "$repo" checkout -q -B row "$base"
  git -C "$repo" clean -qfd
  mkdir -p "$repo/$(dirname "$path")"
  awk -v lines="$lines" 'BEGIN { for (i=1; i<=lines; i++) print "line " i }' >"$repo/$path"
  git -C "$repo" add -A
  git -C "$repo" commit -qm "$name"
  decl=""
  [ "$declaration" = none ] || decl="$SANDBOX/$declaration"
  input=true
  [ "$default" = yes ] || input=""
  run_action "$event" "$base" "$decl" "$input"
  run_local "$CHANGE_CLASS" "$event" "$base" "$decl" "${input:-false}"
  assert_eq "$name: local answer" \
    "$(printf 'queue_only=%s\nlanes=%s\nlanes_cause=%s' "$queue" "$expected" "$cause")" \
    "$(lane_answer "$SANDBOX/local-output")"
  assert_eq "$name: local and action agree" "$(lane_answer "$SANDBOX/action-output")" \
    "$(lane_answer "$SANDBOX/local-output")"
  [ "$lane_verdicts" = - ] ||
    assert_eq "$name: lane verdicts" "$lane_verdicts" "$(verdicts)"
  assert_eq "$name: stdout keeps its class contract" \
    "$(sed -n '/^change_class=/p' "$SANDBOX/local-output")" "$(cat "$SANDBOX/local-stdout")"
done <<'ROWS'
trivial|pull_request|default|docs/guide.md|1|none|yes|false|trivial|true|-
docs-only|pull_request|default|docs/guide.md|21|default|yes|false|docs-only|true|lane_check=false,lane_other=false,lane_mac=false
pull-request-code|pull_request|default|src/main.sh|21|default|yes|false|queue-only|true|lane_check=false,lane_other=false,lane_mac=false
pull-request-standard|pull_request|default|src/main.sh|151|default|yes|false|queue-only|true|-
push-code|push|default|src/main.sh|21|default|yes|false|queue-only|true|-
copied-template|pull_request|default|src/main.sh|21|default|no|true|small|true|lane_check=true,lane_other=false,lane_mac=false
merge-group-code|merge_group|default|src/main.sh|21|default|yes|true|small|true|lane_check=true,lane_other=false,lane_mac=false
merge-group-unclaimed|merge_group|default|Makefile|21|default|yes|true|small|true|lane_check=true,lane_other=true,lane_mac=false
merge-group-nightly-path|merge_group|default|macos/run.sh|21|default|yes|true|small|true|lane_check=false,lane_other=false,lane_mac=true
schedule|schedule|default|src/main.sh|21|default|yes|true|full-run|true|lane_check=true,lane_other=true,lane_mac=true
reader-absent|pull_request|default|src/main.sh|21|no-reader|yes|true|queue-only-reader-absent|true|lane_check=true,lane_other=false,lane_mac=false
opted-back|pull_request|optback|src/main.sh|21|default|yes|true|small|false|lane_check=true,lane_other=false,lane_mac=false
opted-back-queue-only|pull_request|undeclared|src/main.sh|21|default|yes|true|small|true|lane_check=true,lane_other=false,lane_mac=false
blank-reason|pull_request|blank|src/main.sh|21|default|yes|false|queue-only|true|-
ROWS
require_rows lanes-output "$rows"

# A merge group whose diff could not be read runs every lane, the `:nightly`
# lane included: no changed path proves the platform lane's paths untouched.
unread_base=0000000000000000000000000000000000000001
run_action merge_group "$unread_base" "$SANDBOX/default" true
run_local "$CHANGE_CLASS" merge_group "$unread_base" "$SANDBOX/default" true
assert_eq "an unread merge-group diff runs the nightly lane" \
  "$(printf 'queue_only=true\nlanes=true\nlanes_cause=standard') lane_check=true,lane_other=true,lane_mac=true" \
  "$(lane_answer "$SANDBOX/action-output") $(verdicts)"
assert_eq "an unread merge-group diff: local and action agree" \
  "$(lane_answer "$SANDBOX/action-output")" "$(lane_answer "$SANDBOX/local-output")"

# An empty reason is refused by one machine line and answered as unset, never
# as a wiring error; an unset reason prints no refusal. The control counts a
# blank value as a reason, so the blank base reads queue_only=false.
refusal_line='setting-refused: setting=HARNESS_CI_PER_PUSH_REASON cause=empty-reason'
refusals() { grep -cxF -- "$refusal_line" "$SANDBOX/local-stderr" || true; }
per_push_answer() { # COMMAND BASE
  git -C "$repo" checkout -q -B row "$2"
  mkdir -p "$repo/src"
  printf 'line\n' >"$repo/src/refusal.sh"
  git -C "$repo" add -A
  git -C "$repo" commit -qm refusal >/dev/null
  run_local "$1" pull_request "$2" "$SANDBOX/default"
  printf '%s %s' "$(sed -n '/^queue_only=/p' "$SANDBOX/local-output")" "$(refusals)"
}
assert_eq "a blank reason is refused and stays queue-only" "queue_only=true 1" \
  "$(per_push_answer "$CHANGE_CLASS" "$base_blank")"
assert_eq "an unset reason prints no refusal" "queue_only=true 0" \
  "$(per_push_answer "$CHANGE_CLASS" "$base_default")"
assert_eq "a reason opts the change back" "queue_only=false 0" \
  "$(per_push_answer "$CHANGE_CLASS" "$base_optback")"
blank_control="$(mutant blank-is-reason change-class '    *[![:space:]]*) ;;' '    ?*) ;;')"
assert_eq "must-fail: a blank value read as a reason opts the change back" "queue_only=false 0" \
  "$(per_push_answer "$blank_control" "$base_blank")"

# The retired proof-reuse flag is still read, with one machine notice.
: >"$SANDBOX/local-output"
"$CHANGE_CLASS" --event pull_request --base "$base_default" --head HEAD --repo "$repo" \
  --covers-all-lanes true --output "$SANDBOX/local-output" >/dev/null 2>"$SANDBOX/local-stderr"
assert_eq "the retired coverage flag is read with one notice" "1 queue_only=true" \
  "$(grep -cxF 'option-retired: option=--covers-all-lanes' "$SANDBOX/local-stderr") $(sed -n '/^queue_only=/p' "$SANDBOX/local-output")"

# Restore the base command's missing output in a disposable package copy.
# The control must complete, then fail the same machine-output assertion.
mkdir -p "$SANDBOX/control"
cp -R "$TEST_DIR/.." "$SANDBOX/control/harness-ci"
cp -R "$TEST_DIR/../../orch" "$SANDBOX/control/orch"
needle='      [ "$output" = /dev/null ] || printf '\''lanes=%s\nlanes_cause=%s\n'\'' "$lanes" "$lanes_cause"'
NEEDLE="$needle" awk '$0 == ENVIRON["NEEDLE"] { hits++; print "      :"; next }
  { print } END { if (hits != 1) exit 2 }' "$CHANGE_CLASS" >"$SANDBOX/control/harness-ci/scripts/change-class"
! cmp -s "$CHANGE_CLASS" "$SANDBOX/control/harness-ci/scripts/change-class" || exit 1
run_local "$SANDBOX/control/harness-ci/scripts/change-class" pull_request "$base_default" "$SANDBOX/default"
assert_eq 'must-fail: base output contract omits the local lane answer' "" \
  "$(sed -n '/^lanes/p' "$SANDBOX/local-output")"

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
  run_local "$classifier" pull_request "$base_default" "$declaration" || status=$?
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
