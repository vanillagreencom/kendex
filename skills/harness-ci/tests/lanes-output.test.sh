#!/usr/bin/env bash
# Local --output and the action share the lane decision for real git diffs,
# and both answer the queue-only default where the workflow asks for it: a
# pull request or push stands every lane down, a change to a path on the
# shipped queue list included, the merge group runs the
# lanes its diff selects, and the nightly full run runs every lane. A
# workflow that does not ask, a ci.yml copied before the default, keeps its
# lanes once a refresh delivers the render.
# Inputs: harness-ci scripts, the change-scope classifier and the change-class action.
# Proved render claims are covered by render-claims.test.sh.
set -euo pipefail
if [ -n "${LANE_REACH_PYTHON_BIN:-}" ]; then
  export PATH="$LANE_REACH_PYTHON_BIN:$PATH"
fi
# shellcheck source=../../change-scope/tests/lib/sandbox.sh
. "$(dirname "${BASH_SOURCE[0]}")/../../change-scope/tests/lib/sandbox.sh"
PLANT_ENTRY=change-class

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
# A declaration whose `check` lane claims the consumer manifest.
mkdir -p "$SANDBOX/manifest-claim/.github"
printf 'check src/* kendex.toml\nother elsewhere/*\nmac:nightly macos/*\n' \
  >"$SANDBOX/manifest-claim/.github/ci-lanes.conf"

repo="$(new_repo lanes-output)"
mkdir -p "$repo/$(dirname "$READER")"
cp "$CHANGE_CLASS" "$repo/$READER"
# The manifest a manifest row replaces.
printf 'schema = 7\n' >"$repo/kendex.toml"
rendered_skill=.agents/skills/orch/SKILL.md
commit_paths "$repo" baseline seed.txt "$rendered_skill"
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
# A repository whose standard paths hold its docs: their class is standard,
# and the docs-only waiver still stands the lanes down.
base_docsstandard="$(base_with_settings base-docsstandard "$(printf '[env]\nHARNESS_CI_STANDARD_PATHS = "docs/*"')")"
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
  CLASSIFIER="${ACTION_ROOT:-$ROOT}" EVENT="$1" BASE="$2" HEAD="$(git -C "$repo" rev-parse HEAD)" REPO="$repo" \
    LANES_FROM="$3" QUEUE_ONLY_DEFAULT="$4" GITHUB_OUTPUT="$SANDBOX/action-output" \
    "$CLASSIFY" >"$SANDBOX/action-stdout" 2>"$SANDBOX/action-stderr"
}
lane_answer() { sed -n '/^queue_only=/p; /^lanes=/p; /^lanes_cause=/p' "$1"; }
# The action's lane_verdicts value, its lines joined with commas.
verdicts() {
  awk '$0 == "lane_verdicts<<__change_class_lane_verdicts_end__" { on = 1; next }
    $0 == "__change_class_lane_verdicts_end__" { on = 0 } on' "${1:-$SANDBOX/action-output}" |
    tr '\n' ',' | sed 's/,$//'
}

# ROW|EVENT|BASE|PATHS|LINES|DECLARATION|DEFAULT|LANES|LANES_CAUSE|QUEUE_ONLY|LANE VERDICTS
# BASE is the opt-back's state: default (unset), optback (a reason and an
# empty queue list), undeclared (a reason, no queue list) or blank. PATHS
# are blank-separated, each written with LINES lines. DEFAULT
# is the queue-only-default input; `no` passes none, as a copied ci.yml from
# before the default does, and the local command then passes false.
# LANE VERDICTS is the action's; `-` where no declaration is read.
write_row() { # NAME BASE PATHS LINES: commits the row's change on BASE
  local path prefix
  git -C "$repo" checkout -q -B row "$2"
  git -C "$repo" clean -qfd
  for path in $3; do
    mkdir -p "$repo/$(dirname "$path")"
    # A manifest stays a TOML document the sources check parses.
    prefix=""
    [ "$path" != kendex.toml ] || prefix="# "
    awk -v lines="$4" -v prefix="$prefix" 'BEGIN { for (i=1; i<=lines; i++) print prefix "line " i }' \
      >"$repo/$path"
  done
  git -C "$repo" add -A
  git -C "$repo" commit -qm "$1"
}

# Both callers read the render proof for an inventoried Markdown file that
# also matches the docs path set. The verifier can refuse with a mirror remedy.
mkdir -p "$SANDBOX/refusing-verifier"
cat >"$SANDBOX/refusing-verifier/kendex" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  --version) printf 'kendex 0.0.0-stub\n' ;;
  'verify --help') exit 0 ;;
  *)
    if [ "${MIRROR_MISSING:-false}" = true ]; then
      printf '%s\n' 'verb=source operation=refresh' >&2
    fi
    exit 1 ;;
esac
STUB
chmod +x "$SANDBOX/refusing-verifier/kendex"
no_verifier_path=""
while IFS= read -r dir; do
  [ -n "$dir" ] && [ ! -x "$dir/kendex" ] || continue
  no_verifier_path="${no_verifier_path:+$no_verifier_path:}$dir"
done <<<"$(printf '%s' "$PATH" | tr ':' '\n')"

# Let Git report a failed blob read for the base inventory while the docs
# reader still sees the same committed range and all of its paths.
mkdir -p "$SANDBOX/unreadable-inventory"
real_git="$(command -v git)"
cat >"$SANDBOX/unreadable-inventory/git" <<'STUB'
#!/usr/bin/env bash
if [ "${5:-}" = show ] && [ "${6:-}" = "$UNREADABLE_INVENTORY:.kendex-generated.json" ]; then
  exit 1
fi
exec "$REAL_GIT" "$@"
STUB
chmod +x "$SANDBOX/unreadable-inventory/git"
git -C "$repo" checkout -qb invalid-inventory "$base_default"
printf '%s\n' 'invalid inventory' >"$repo/.kendex-generated.json"
git -C "$repo" commit -qam invalid-inventory
base_invalid_inventory="$(git -C "$repo" rev-parse HEAD)"

rows=0
while IFS='|' read -r name mixed_base classifier_path mirror_missing expected_cause; do
  rows=$((rows + 1))
  write_row "$name" "$mixed_base" "docs/guide.md $rendered_skill" 3
  PATH="$classifier_path" MIRROR_MISSING="$mirror_missing" UNREADABLE_INVENTORY="$mixed_base" REAL_GIT="$real_git" \
    run_action merge_group "$mixed_base" "$SANDBOX/default" true
  PATH="$classifier_path" MIRROR_MISSING="$mirror_missing" UNREADABLE_INVENTORY="$mixed_base" REAL_GIT="$real_git" \
    run_local "$CHANGE_CLASS" merge_group "$mixed_base" "$SANDBOX/default" true
  assert_eq "$name: class and docs membership" $'change_class=standard\ndocs_only=true' \
    "$(sed -n '/^change_class=/p; /^docs_only=/p' "$SANDBOX/action-output")"
  assert_eq "$name: class cause" "$expected_cause" \
    "$(sed -n 's/^class: class=[^ ]* measured=[^ ]* cause=\([^ ]*\).*/\1/p' "$SANDBOX/action-stderr")"
  assert_eq "$name: aggregate lane eligibility" lanes=true \
    "$(sed -n '/^lanes=/p' "$SANDBOX/action-output")"
  assert_eq "$name: per-lane eligibility" lane_check=true,lane_other=true,lane_mac=false "$(verdicts)"
  assert_eq "$name: local and action agree" "$(lane_answer "$SANDBOX/action-output") $(verdicts)" \
    "$(lane_answer "$SANDBOX/local-output") $(verdicts "$SANDBOX/local-output")"
done <<ROWS
mixed-verify-refused|$base_default|$SANDBOX/refusing-verifier:$PATH|false|verify-refused
mixed-source-mirror-missing|$base_default|$SANDBOX/refusing-verifier:$PATH|true|source-mirror-missing
mixed-no-verifier|$base_default|$no_verifier_path|false|no-verifier
mixed-invalid-inventory|$base_invalid_inventory|$no_verifier_path|false|invalid-generated-paths
mixed-unreadable-base-inventory|$base_default|$SANDBOX/unreadable-inventory:$no_verifier_path|false|unreadable-base-inventory
ROWS
require_rows mixed-render-docs "$rows"

# A newly selected derived job needs its gated nightly prerequisite. Its
# render has known package ownership and none of the jobs reads either path.
git -C "$repo" checkout -qb derived-base "$base_default"
mkdir -p "$repo/.github/workflows" "$repo/tools" "$SANDBOX/derived/.github"
cat >"$repo/.github/ci-lanes.conf" <<'LANES'
slow:nightly slow/* # reason: external build inputs
unrelated:nightly unrelated/* # reason: external platform fixtures
LANES
cp "$repo/.github/ci-lanes.conf" "$SANDBOX/derived/.github/ci-lanes.conf"
printf '%s\n' 'true' >"$repo/tools/check.sh"
printf '%s\n' '{"entries":{"skill:orch:codex":{"sourceRepo":"example/catalog","emitted":{"paths":[".agents/skills/orch"]}}}}' \
  >"$repo/.kendex-lock.json"
cat >"$repo/.github/workflows/ci.yml" <<'YAML'
name: CI
on: merge_group
jobs:
  changes:
    runs-on: ubuntu-latest
    outputs:
      lanes: ${{ steps.classify.outputs.lanes }}
      lane_test: ${{ steps.lanes.outputs.lane_test }}
      lane_slow: ${{ steps.lanes.outputs.lane_slow }}
      lane_unrelated: ${{ steps.lanes.outputs.lane_unrelated }}
    steps:
      - id: classify
        uses: vanillagreencom/kendex/.github/actions/change-class@main
      - id: lanes
        env:
          LANE_VERDICTS: ${{ steps.classify.outputs.lane_verdicts }}
        run: printf '%s\n' "$LANE_VERDICTS" >>"$GITHUB_OUTPUT"
YAML
while IFS='|' read -r lane needs; do
  cat >>"$repo/.github/workflows/ci.yml" <<YAML
  $lane:
    needs: $needs
    if: \${{ !cancelled() && (needs.changes.result != 'success' || (needs.changes.outputs.lanes != 'false' && needs.changes.outputs.lane_$lane != 'false')) }}
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - run: bash ./tools/check.sh
YAML
done <<'ROWS'
test|[changes, slow]
slow|changes
unrelated|changes
ROWS
git -C "$repo" add -A
git -C "$repo" commit -qm derived-base
base_derived="$(git -C "$repo" rev-parse HEAD)"
write_row derived-refusal "$base_derived" "docs/guide.md $rendered_skill" 3
PATH="$no_verifier_path" GITHUB_REPOSITORY=example/derived GITHUB_JOB=changes \
  GITHUB_WORKFLOW_REF=example/derived/.github/workflows/ci.yml@refs/heads/main \
  run_action merge_group "$base_derived" "$SANDBOX/derived" true
assert_eq 'derived refusal: a required nightly lane runs and an unrelated one skips' \
  lane_slow=true,lane_unrelated=false,lane_test=true "$(verdicts)"
assert_eq 'derived refusal: the existing prerequisite closure selects the required lane' \
  'lane: name=slow verdict=true cause=derived-reach evidence=prerequisite' \
  "$(sed -n '/^lane: name=slow /p' "$SANDBOX/action-stderr")"

rows=0
while IFS='|' read -r name event base_name paths lines declaration default expected cause queue lane_verdicts; do
  rows=$((rows + 1))
  base_var="base_$base_name"
  base="${!base_var}"
  write_row "$name" "$base" "$paths" "$lines"
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
  assert_eq "$name: local and action per-lane verdicts agree" "$(verdicts)" \
    "$(verdicts "$SANDBOX/local-output")"
  assert_eq "$name: local and action per-lane causes agree" \
    "$(sed -n '/^lane: /p' "$SANDBOX/action-stderr")" \
    "$(sed -n '/^lane: /p' "$SANDBOX/local-stderr")"
  [ "$lane_verdicts" = - ] ||
    assert_eq "$name: lane verdicts" "$lane_verdicts" "$(verdicts)"
  assert_eq "$name: stdout keeps its class contract" \
    "$(sed -n '/^change_class=/p' "$SANDBOX/local-output")" "$(cat "$SANDBOX/local-stdout")"
done <<'ROWS'
trivial|pull_request|default|docs/guide.md|1|none|yes|false|trivial|true|-
docs-only|merge_group|docsstandard|docs/guide.md|21|default|yes|false|docs-only|true|lane_check=false,lane_other=false,lane_mac=false
pull-request-code|pull_request|default|src/main.sh|21|default|yes|false|queue-only|true|lane_check=false,lane_other=false,lane_mac=false
pull-request-standard|pull_request|default|src/main.sh|151|default|yes|false|queue-only|true|-
push-code|push|default|src/main.sh|21|default|yes|false|queue-only|true|-
queue-path|pull_request|default|src/main.sh .github/workflows/ci.yml|21|default|yes|false|queue-only|true|lane_check=false,lane_other=false,lane_mac=false
queue-path-opted-back|pull_request|optback|src/main.sh .github/workflows/ci.yml|21|default|yes|true|standard|true|lane_check=true,lane_other=true,lane_mac=false
copied-template|pull_request|default|src/main.sh|21|default|no|true|small|true|lane_check=true,lane_other=false,lane_mac=false
merge-group-code|merge_group|default|src/main.sh|21|default|yes|true|small|true|lane_check=true,lane_other=false,lane_mac=false
merge-group-unclaimed|merge_group|default|Makefile|21|default|yes|true|small|true|lane_check=true,lane_other=true,lane_mac=false
merge-group-nightly-path|merge_group|default|macos/run.sh|21|default|yes|true|small|true|lane_check=false,lane_other=false,lane_mac=true
schedule|schedule|default|src/main.sh|21|default|yes|true|full-run|true|lane_check=true,lane_other=true,lane_mac=true
reader-absent|pull_request|default|src/main.sh|21|no-reader|yes|true|queue-only-reader-absent|true|lane_check=true,lane_other=false,lane_mac=false
opted-back|pull_request|optback|src/main.sh|21|default|yes|true|small|false|lane_check=true,lane_other=false,lane_mac=false
opted-back-queue-only|pull_request|undeclared|src/main.sh|21|default|yes|true|small|true|lane_check=true,lane_other=false,lane_mac=false
blank-reason|pull_request|blank|src/main.sh|21|default|yes|false|queue-only|true|-
manifest|merge_group|default|kendex.toml|3|default|yes|false|trivial|true|lane_check=false,lane_other=false,lane_mac=false
manifest-claim|merge_group|default|kendex.toml|3|manifest-claim|yes|false|trivial|true|lane_check=false,lane_other=false,lane_mac=false
manifest-past-small|merge_group|default|kendex.toml|151|default|yes|false|trivial|true|lane_check=false,lane_other=false,lane_mac=false
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
blank_control="$(mutant blank-is-reason change-class '    *[![:space:]]*) PER_PUSH=set ;;' '    ?*) PER_PUSH=set ;;')"
assert_eq "must-fail: a blank value read as a reason opts the change back" "queue_only=false 0" \
  "$(per_push_answer "$blank_control" "$base_blank")"

# The retired proof-reuse flag is still read, with one machine notice.
: >"$SANDBOX/local-output"
"$CHANGE_CLASS" --event pull_request --base "$base_default" --head HEAD --repo "$repo" \
  --covers-all-lanes true --output "$SANDBOX/local-output" >/dev/null 2>"$SANDBOX/local-stderr"
assert_eq "the retired coverage flag is read with one notice" "1 queue_only=true" \
  "$(grep -cxF 'option-retired: option=--covers-all-lanes' "$SANDBOX/local-stderr") $(sed -n '/^queue_only=/p' "$SANDBOX/local-output")"

# Local callers read the structured cause field, not the explanation. Both
# checkout refusals are reachable from --lanes-from on the public command.
rows=0
while IFS='|' read -r name declaration expected; do
  rows=$((rows + 1))
  status=0
  run_local "$CHANGE_CLASS" pull_request "$base_default" "$declaration" || status=$?
  assert_eq "$name: lane checkout refusal exits 2" 2 "$status"
  assert_eq "$name: structured local cause" "$expected" \
    "$(sed -n 's/^wiring-error: cause=\([^ ]*\).*/\1/p' "$SANDBOX/local-stderr")"
  assert_eq "$name: refusal publishes no class" "" "$(cat "$SANDBOX/local-stdout")"
  assert_eq "$name: refusal publishes no lane outputs" "" "$(cat "$SANDBOX/local-output")"
done <<ROWS
judged checkout|$repo|lanes-from-judged-tree
absent checkout|$SANDBOX/missing-checkout|lanes-from-unreadable
ROWS
require_rows local-lane-refusals "$rows"
# One input contract through both real producers. The docs owner supplies the
# extra membership evidence; the lane owner must retain every text claim.
text_decl='check src/*
text product/text.md
also product/text.md
other elsewhere/*
mac:nightly macos/*
'
mkdir -p "$SANDBOX/text/.github" "$SANDBOX/text-bad/.github"
mkdir -p "$SANDBOX/text/$(dirname "$READER")"
cp "$CHANGE_CLASS" "$SANDBOX/text/$READER"
printf '%s' "$text_decl" >"$SANDBOX/text/.github/ci-lanes.conf"
printf 'Bad product/*\n' >"$SANDBOX/text-bad/.github/ci-lanes.conf"
base_text="$(base_with_settings base-text "$(printf '[env]\nHARNESS_CI_DOCS_PATHS = "product/text.md"')")"
base_glob="$(base_with_settings base-glob "$(printf '[env]\nHARNESS_CI_DOCS_PATHS = "product/*.md"')")"
base_instruction="$(base_with_settings base-instruction "$(printf '[env]\nHARNESS_CI_DOCS_PATHS = "product/AGENTS.md"')")"
base_invalid="$(base_with_settings base-invalid "$(printf '[env]\nHARNESS_CI_DOCS_PATHS = true')")"
base_standard="$(base_with_settings base-standard "$(printf '[env]\nHARNESS_CI_DOCS_PATHS = "product/text.md"\nHARNESS_CI_STANDARD_PATHS = "elsewhere/* product/*"')")"
git -C "$repo" checkout -q -B base-overlay "$base_text"
mkdir -p "$repo/.kendex"
printf '[env]\nHARNESS_CI_DOCS_PATHS = ""\n' >"$repo/.kendex/settings.toml"
git -C "$repo" add -A
git -C "$repo" commit -qm overlay
base_overlay="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" checkout -q -B base-unreadable "$base_default"
mkdir -p "$repo/kendex.settings.toml"
printf 'not settings\n' >"$repo/kendex.settings.toml/child"
git -C "$repo" add -A
git -C "$repo" commit -qm unreadable
base_unreadable="$(git -C "$repo" rev-parse HEAD)"

# NAME|BASE|PATHS|LINES|HEAD/ENV EDIT|EVENT|LANE ROOT|STATUS|DOCS|CLASS|LANES/CAUSE|VERDICTS|CLASS-ONLY
# `none` owns no declared lanes, so the aggregate answer must keep checks on.
# CLASS-ONLY checks the class-only caller review-depth, which runs
# change-scope for the class alone.
declared_rows() {
  cat <<'ROWS'
no-declaration|default|product/text.md|1|none|merge_group|text|0|true|trivial|false/trivial|lane_check=false,lane_text=false,lane_also=false,lane_other=false,lane_mac=false
declared-owner|text|product/text.md|1|none|merge_group|text|0|true|trivial|true/declared-text|lane_check=false,lane_text=true,lane_also=true,lane_other=false,lane_mac=false
declared-large|text|product/text.md|200|none|merge_group|text|0|true|trivial|true/declared-text|lane_check=false,lane_text=true,lane_also=true,lane_other=false,lane_mac=false
mixed-source|text|product/text.md src/main.sh|21|none|merge_group|text|0|false|small|true/small|lane_check=true,lane_text=true,lane_also=true,lane_other=false,lane_mac=false|small
mixed-unclaimed|text|product/text.md Makefile|21|none|merge_group|text|0|false|small|true/small|lane_check=true,lane_text=true,lane_also=true,lane_other=true,lane_mac=false
unclaimed-text|text|product/text.md|1|none|merge_group|default|0|true|trivial|true/declared-text|lane_check=true,lane_other=true,lane_mac=false
no-lane-declaration|text|product/text.md|1|none|merge_group|none|0|true|trivial|true/declared-text|-
malformed-lanes|text|product/text.md|1|none|merge_group|text-bad|0|true|trivial|true/declared-text|-
head-only-declaration|default|product/text.md|1|setting|merge_group|text|0|false|trivial|false/trivial|lane_check=false,lane_text=false,lane_also=false,lane_other=false,lane_mac=false
environment-declaration|default|product/text.md|1|env|merge_group|text|0|true|trivial|false/trivial|lane_check=false,lane_text=false,lane_also=false,lane_other=false,lane_mac=false
overriding-empty|overlay|product/text.md|1|none|merge_group|text|0|true|trivial|false/trivial|lane_check=false,lane_text=false,lane_also=false,lane_other=false,lane_mac=false
invalid-glob|glob|product/text.md|1|none|merge_group|text|2|-|-|-|-
instruction-declaration|instruction|product/AGENTS.md|1|none|merge_group|text|0|true|trivial|true/declared-text|lane_check=true,lane_text=true,lane_also=true,lane_other=true,lane_mac=false
protected-standard|standard|product/text.md|1|none|merge_group|text|2|-|-|-|-
executable-text|text|product/text.md|1|executable|merge_group|text|2|-|-|-|-|micro
mixed-executable|text|alpha/source.rs product/text.md zeta/source.rs|21|executable|merge_group|text|2|-|-|-|-|standard
symlink-text|text|product/text.md|1|symlink|merge_group|text|2|-|-|-|-
invalid-settings|invalid|product/text.md|1|none|merge_group|text|2|-|-|-|-
unreadable-settings|unreadable|product/text.md|1|none|merge_group|text|2|-|-|-|-
queue-default|text|product/text.md|1|none|pull_request|text|0|true|trivial|false/queue-only|lane_check=false,lane_text=false,lane_also=false,lane_other=false,lane_mac=false
nightly-text|text|product/text.md|1|none|schedule|text|0|false|standard|true/full-run|lane_check=true,lane_text=true,lane_also=true,lane_other=true,lane_mac=true
ROWS
}
declared_case() { # COMMAND ROW
  local command="$1" name base_name paths lines edit event declaration expected_status docs class lane_result expected_verdicts
  local base_var base decl class_only local_status=0 action_status=0
  IFS='|' read -r name base_name paths lines edit event declaration expected_status docs class lane_result expected_verdicts class_only <<<"$2"
  base_var="base_$base_name"
  base="${!base_var}"
  write_row "$name" "$base" "$paths" "$lines"
  case "$edit" in
    setting) printf '[env]\nHARNESS_CI_DOCS_PATHS = "product/text.md"\n' >"$repo/kendex.settings.toml" ;;
    executable) chmod +x "$repo/product/text.md" ;;
    symlink) ln -sf elsewhere "$repo/product/text.md" ;;
  esac
  if [ "$edit" = setting ] || [ "$edit" = executable ] || [ "$edit" = symlink ]; then
    git -C "$repo" add -A
    git -C "$repo" commit -qm "$edit"
  fi
  decl=""
  [ "$declaration" = none ] || decl="$SANDBOX/$declaration"
  if [ "$edit" = env ]; then export HARNESS_CI_DOCS_PATHS=product/text.md; fi
  run_action "$event" "$base" "$decl" true || action_status=$?
  run_local "$command" "$event" "$base" "$decl" true || local_status=$?
  unset HARNESS_CI_DOCS_PATHS
  assert_eq "$name: command/action status" "$expected_status/$expected_status" "$local_status/$action_status"
  if [ "$expected_status" = 0 ]; then
    assert_eq "$name: docs membership and class" "docs_only=$docs change_class=$class" \
      "$(sed -n '/^docs_only=/p' "$SANDBOX/action-output") $(cat "$SANDBOX/local-stdout")"
    assert_eq "$name: command/action lanes agree" "$(lane_answer "$SANDBOX/action-output")" "$(lane_answer "$SANDBOX/local-output")"
    assert_eq "$name: aggregate lanes" "$lane_result" \
      "$(sed -n 's/^lanes=//p' "$SANDBOX/local-output")/$(sed -n 's/^lanes_cause=//p' "$SANDBOX/local-output")"
    if [ "$expected_verdicts" != - ]; then
      assert_eq "$name: owning lanes" "$expected_verdicts" "$(verdicts)"
    fi
  else
    assert_eq "$name: command publishes no waiver" "" "$(cat "$SANDBOX/local-output")$(cat "$SANDBOX/local-stdout")"
    assert_eq "$name: action publishes no waiver" "" "$(cat "$SANDBOX/action-output")"
  fi
  if [ -n "$class_only" ]; then
    assert_class "$name: class-only consumer" "$class_only" \
      --event "$event" --base "$base" --head HEAD --repo "$repo"
  fi
}
rows=0
while IFS= read -r row; do
  rows=$((rows + 1))
  declared_case "$CHANGE_CLASS" "$row"
done < <(declared_rows)
require_rows declared-text "$rows"

# One control for the changed guard, using the same real input and assertions.
# Keep the text and docs verdict, but restore the global trivial/docs waiver.
claim_guard='if [ -n "$declared_paths" ] && [ "$lanes" = false ] && [ "$class" != render ]; then'
claim_mutant="$(mutant declared-claim lib/change-class.sh "$claim_guard" 'if false; then')"
control_row="$(declared_rows | sed -n '/^declared-owner|/p')"
control_status=0
(PASS=0; FAIL=0; declared_case "$claim_mutant" "$control_row"; [ "$FAIL" -eq 0 ]) \
  >"$SANDBOX/declared-control.log" 2>&1 || control_status=$?
assert_eq "the declared owner row rejects the restored global waiver" 1 "$control_status"
assert_eq "the control still completes with its original trivial class" \
  change_class=trivial "$(cat "$SANDBOX/local-stdout")"
assert_eq "the control reaches the wrong successful stand-down" \
  false/trivial "$(sed -n 's/^lanes=//p' "$SANDBOX/local-output")/$(sed -n 's/^lanes_cause=//p' "$SANDBOX/local-output")"

# Paths the base declares no lane reads turn no lane on in the action. A
# glob takes extglob patterns whatever the caller's shell sets. A lane claim
# still selects its lane, an undeclared unclaimed path beside one still runs
# every lane, declared text, a path git quotes and a path on the shipped
# queue list keep the fallback whatever glob matches them, and the caller's
# environment declares nothing.
base_unread="$(base_with_settings base-unread "$(printf '[env]\nHARNESS_CI_UNREAD_PATHS = ".github/@(dependabot|renovate).yml  src/declared.sh"')")"
base_unreadtext="$(base_with_settings base-unreadtext "$(printf '[env]\nHARNESS_CI_DOCS_PATHS = "product/text.md"\nHARNESS_CI_UNREAD_PATHS = "product/*"')")"
base_unreadwide="$(base_with_settings base-unreadwide "$(printf '[env]\nHARNESS_CI_UNREAD_PATHS = ".github/*.yml"')")"
base_unreadquote="$(base_with_settings base-unreadquote "$(printf '[env]\nHARNESS_CI_UNREAD_PATHS = "*"')")"
# NAME|BASE|PATHS|ENVIRONMENT|VERDICTS|OTHER LANE
unread_rows() {
  cat <<'ROWS'
only-unread|unread|.github/dependabot.yml|-|lane_check=false,lane_other=false,lane_mac=false|verdict=false cause=unread-path setting=HARNESS_CI_UNREAD_PATHS path=.github/dependabot.yml glob=.github/@(dependabot|renovate).yml
unread-beside-unclaimed|unread|.github/dependabot.yml Makefile|-|lane_check=true,lane_other=true,lane_mac=false|verdict=true cause=unclaimed-path path=Makefile claim=none
unread-claimed|unread|src/declared.sh|-|lane_check=true,lane_other=false,lane_mac=false|verdict=false cause=unreached
environment-unread|default|.github/dependabot.yml|.github/dependabot.yml|lane_check=true,lane_other=true,lane_mac=false|verdict=true cause=unclaimed-path path=.github/dependabot.yml claim=none
unread-text|unreadtext|product/text.md|-|lane_check=true,lane_other=true,lane_mac=false|verdict=true cause=unclaimed-path path=product/text.md claim=none
unread-ci-input|unreadwide|.github/dependabot.yml .github/workflows/ci.yml|-|lane_check=true,lane_other=true,lane_mac=false|verdict=true cause=unclaimed-path path=.github/workflows/ci.yml claim=none
unread-quoted|unreadquote|.github/workflows/a"b.yml|-|lane_check=true,lane_other=true,lane_mac=false|verdict=true cause=unclaimed-path path=".github/workflows/a\"b.yml" claim=none
ROWS
}
unread_case() { # ROW, through the action at ACTION_ROOT
  local name base_name paths environment expected other base_var base
  IFS='|' read -r name base_name paths environment expected other <<<"$1"
  base_var="base_$base_name"
  base="${!base_var}"
  write_row "$name" "$base" "$paths" 3
  [ "$environment" = - ] || export HARNESS_CI_UNREAD_PATHS="$environment"
  run_action merge_group "$base" "$SANDBOX/default" true
  run_local "${LOCAL_COMMAND:-$CHANGE_CLASS}" merge_group "$base" "$SANDBOX/default" true
  unset HARNESS_CI_UNREAD_PATHS
  assert_eq "$name: lane verdicts" "$expected" "$(verdicts)"
  assert_eq "$name: other lane's cause" "lane: name=other $other" \
    "$(sed -n '/^lane: name=other /p' "$SANDBOX/action-stderr")"
  assert_eq "$name: local per-lane evidence" "$expected" "$(verdicts "$SANDBOX/local-output")"
  assert_eq "$name: local and action causes agree" \
    "$(sed -n '/^lane: /p' "$SANDBOX/action-stderr")" \
    "$(sed -n '/^lane: /p' "$SANDBOX/local-stderr")"
}
rows=0
while IFS= read -r row; do
  rows=$((rows + 1))
  unread_case "$row"
done < <(unread_rows)
require_rows unread-paths "$rows"
# The local carrier must include the base declaration in its lane evidence.
local_unread_mutant="$(mutant local-unread-omitted change-class \
  '  { cat -- "$work/class-log-head"; printf '\''%s\n%s\n%s\n%s\n'\'' "$queue_line" "$per_push_line" "$unread_line" "$class_record"; } >"$work/class-log"' \
  '  { cat -- "$work/class-log-head"; printf '\''%s\n%s\n%s\n'\'' "$queue_line" "$per_push_line" "$class_record"; } >"$work/class-log"')"
control_status=0
(PASS=0; FAIL=0; LOCAL_COMMAND="$local_unread_mutant"
  unread_case "$(unread_rows | sed -n '/^only-unread|/p')"; [ "$FAIL" -eq 0 ]) \
  >"$SANDBOX/local-unread-control.log" 2>&1 || control_status=$?
assert_eq "must-fail: local unread evidence rejects an omitted declaration" 1 "$control_status"
assert_eq "the local carrier control reaches the unclaimed fallback" \
  lane_check=true,lane_other=true,lane_mac=false "$(verdicts "$SANDBOX/local-output")"
# The control ignores the declaration and must reach the unclaimed fallback.
unread_mutant="$(mutant unread-ignored lib/change-class.sh \
  '  unread_list_match "$1" "$unread_globs" || return 0' '  return 0')"
mkdir -p "$SANDBOX/unread-root"
ln -s "${unread_mutant%/harness-ci/scripts/change-class}" "$SANDBOX/unread-root/skills"
control_status=0
(PASS=0; FAIL=0; ACTION_ROOT="$SANDBOX/unread-root"
  unread_case "$(unread_rows | sed -n '/^only-unread|/p')"; [ "$FAIL" -eq 0 ]) \
  >"$SANDBOX/unread-control.log" 2>&1 || control_status=$?
assert_eq "must-fail: the only-unread row rejects an ignored declaration" 1 "$control_status"
assert_eq "the control reaches the unclaimed fallback" \
  lane_check=true,lane_other=true,lane_mac=false "$(verdicts)"
# The action sources the library with extglob off, so the unread match sets
# it for itself and restores the caller's setting. The control drops the
# shopt: the extglob glob then misses, and the unclaimed fallback runs.
extglob_mutant="$(mutant unread-no-extglob lib/change-class.sh \
  '  shopt -q extglob || { extglob=false; shopt -s extglob; }' -)"
mkdir -p "$SANDBOX/extglob-root"
ln -s "${extglob_mutant%/harness-ci/scripts/change-class}" "$SANDBOX/extglob-root/skills"
control_status=0
(PASS=0; FAIL=0; ACTION_ROOT="$SANDBOX/extglob-root"
  unread_case "$(unread_rows | sed -n '/^only-unread|/p')"; [ "$FAIL" -eq 0 ]) \
  >"$SANDBOX/extglob-control.log" 2>&1 || control_status=$?
assert_eq "must-fail: the only-unread row rejects a match with extglob off" 1 "$control_status"
assert_eq "the extglob control reaches the unclaimed fallback" \
  lane_check=true,lane_other=true,lane_mac=false "$(verdicts)"
for setting in -s -u; do
  assert_eq "the unread match restores the caller's extglob, shopt $setting" \
    "hit $setting" "$(
      shopt "$setting" extglob
      die() { exit 2; }
      . "${CHANGE_CLASS%/*}/lib/change-class.sh"
      unread_list_match a.yml '@(a|b).yml' && printf 'hit '
      shopt -q extglob && printf -- -s || printf -- -u
    )"
done
# A workflow on the shipped queue list keeps its fallback whatever glob
# matches it. The control drops that rule: the workflow then reads unread
# beside the declared file, and no lane runs.
queue_mutant="$(mutant unread-queue-ignored lib/change-class.sh \
  '  ! unread_list_match "$1" "$queue_globs" || return 0' -)"
mkdir -p "$SANDBOX/queue-root"
ln -s "${queue_mutant%/harness-ci/scripts/change-class}" "$SANDBOX/queue-root/skills"
control_status=0
(PASS=0; FAIL=0; ACTION_ROOT="$SANDBOX/queue-root"
  unread_case "$(unread_rows | sed -n '/^unread-ci-input|/p')"; [ "$FAIL" -eq 0 ]) \
  >"$SANDBOX/queue-control.log" 2>&1 || control_status=$?
assert_eq "must-fail: the ci-input row rejects a dropped queue rule" 1 "$control_status"
assert_eq "the queue control reaches no lane" \
  lane_check=false,lane_other=false,lane_mac=false "$(verdicts)"

# The pre-declaration library contract takes eight arguments and writes no
# declared file. The control restores the unconditional evidence read.
legacy_work="$SANDBOX/legacy-work"
mkdir -p "$legacy_work"
printf 'docs/guide.md\n' >"$legacy_work/paths"
: >"$legacy_work/class-log"
legacy_control="$(mutant legacy-declared lib/change-class.sh \
  '  if [ -e "${work:?}/declared" ] || [ -L "$work/declared" ]; then' \
  '  if true; then')"
for command in "$CHANGE_CLASS" "$legacy_control"; do
  status=0
  answer="$(
    shopt -s extglob
    . "${command%/*}/lib/change-class.sh"
    die() { printf '%s\n' "$1"; exit 2; }
    change_class_lanes trivial docs_only=true merge_group "$repo" HEAD true "$legacy_work" ""
    printf 'lanes=%s lanes_cause=%s\n' "$lanes" "$lanes_cause"
  )" || status=$?
  expected='lanes=false lanes_cause=trivial exit=0'
  [ "$command" = "$CHANGE_CLASS" ] || expected='cause=declared-paths-unreadable exit=2'
  assert_eq "an older library caller without declaration evidence: $command" \
    "$expected" "$answer exit=$status"
done

report lanes-output
