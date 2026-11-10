#!/usr/bin/env bash
# What change-scope reads this package's narrow-change list against: the files
# a package's risk sits in and not the package whole, the render inventory only
# where its change is more than the names the same diff adds or deletes, an
# agent instruction file held to small where it would earn trivial or micro,
# and the repository's own standard paths, read off the base commit alone.
# The list's `queue` group is harness-ci's: its queue-only.test.sh holds it.
#
# The list is the real references/narrow-change.conf beside the script under
# test, so a row follows the shipped list rather than a copy of it. Ownership
# gains are covered by change-scope.test.sh. The size rows carry no gains and
# a path the inventory does not list, so no kendex is run.
set -euo pipefail
# shellcheck source=lib/sandbox.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/sandbox.sh"

INVENTORY=.kendex-generated.json
RENDER=.agents/skills/orch/tests/added.test.sh
SOURCE=skills/orch/tests/added.test.sh
HASHED_A="sha256:$(printf 'a%.0s' $(seq 64))"
HASHED_B="sha256:$(printf 'b%.0s' $(seq 64))"

# The base holds a render and its source, a product file, and an inventory
# with one templated entry, so a row can move a name, a hash, or neither.
KEPT_RENDER=.agents/skills/orch/tests/kept.test.sh
repo="$(new_repo narrow-change)"
jq -c --arg kept "$KEPT_RENDER" --arg hash "$HASHED_A" \
  '. + [$kept, {path: "CLAUDE.md.tmpl", template: "claude", templateHash: $hash}]' \
  "$repo/$INVENTORY" >"$SANDBOX/base-inventory"
mv "$SANDBOX/base-inventory" "$repo/$INVENTORY"
commit_paths "$repo" baseline seed.txt runtime/kept.ts \
  "$KEPT_RENDER" skills/orch/tests/kept.test.sh
base="$(git -C "$repo" rev-parse HEAD)"

# ROW_BASE, when set, is the base commit a row's diff is made on and judged
# against, in place of the fixture's own.
ROW_BASE=""
reset_case() {
  git -C "$repo" checkout -q -B case "${ROW_BASE:-$base}"
  git -C "$repo" clean -qfd
}

# LINES lines of content under PATH.
write_lines() { # PATH COUNT
  local n=0
  mkdir -p "$repo/$(dirname "$1")"
  while [ "$n" -lt "$2" ]; do
    n=$((n + 1))
    printf 'line %d\n' "$n" >>"$repo/$1"
  done
}

# One edit of the inventory, as jq over the base's document.
edit_inventory() { # [JQ_ARGS...] FILTER
  jq -c --arg added "$RENDER" --arg kept "$KEPT_RENDER" --arg hash "$HASHED_B" \
    "$@" "$repo/$INVENTORY" >"$SANDBOX/inventory"
  mv "$SANDBOX/inventory" "$repo/$INVENTORY"
}

# The row's edit, by name: each is the diff a real change of that kind makes.
apply_edit() { # EDIT
  case "$1" in
    test-added)
      write_lines "$SOURCE" 30
      write_lines "$RENDER" 30
      edit_inventory '. + [$added]' ;;
    test-removed)
      git -C "$repo" rm -q -- skills/orch/tests/kept.test.sh "$KEPT_RENDER"
      edit_inventory 'map(select(. != $kept))' ;;
    hash-changed)
      write_lines runtime/product.ts 2
      edit_inventory 'map(if type == "object" then .templateHash = $hash else . end)' ;;
    edited-unlisted)
      write_lines "$KEPT_RENDER" 2
      edit_inventory 'map(select(. != $kept))' ;;
    inventory-invalid) printf '{unparsed\n' >"$repo/$INVENTORY" ;;
    standard-head-clear) printf '[env]\nHARNESS_CI_STANDARD_PATHS = ""\n' >"$repo/kendex.settings.toml" ;;
    standard-head-add) printf '[env]\nHARNESS_CI_STANDARD_PATHS = "runtime/*"\n' >"$repo/kendex.settings.toml" ;;
    unmark-bench) printf 'bench benches/*\n' >"$repo/.github/ci-lanes.conf" ;;
    *=*) write_lines "${1%=*}" "${1##*=}" ;;
    *) echo "unknown edit $1" >&2; exit 1 ;;
  esac
}

# The verdict's class, marker and cause key: a row pins which rule answered.
verdict_of() { # STDERR
  sed -n 's/^class: \(class=[a-z]* measured=[a-z]* cause=[a-z-]*\).*/\1/p' <<<"$1"
}

# ROW_ENV, when set, is one NAME=VALUE the classifier runs with.
ROW_ENV=""
run_row() { # CLASSIFIER EDITS...
  local classifier="$1" edit
  shift
  reset_case
  for edit in "$@"; do apply_edit "$edit"; done
  git -C "$repo" add -A
  git -C "$repo" commit -q -m "row"
  env ${ROW_ENV:+"$ROW_ENV"} "$classifier" --repo "$repo" --event pull_request \
    --base "${ROW_BASE:-$base}" --head HEAD 2>&1 >/dev/null
}

# label | expected verdict | edits | environment
rows=0
while IFS='|' read -r label expected edits ROW_ENV; do
  rows=$((rows + 1))
  # shellcheck disable=SC2086
  row_err="$(run_row "$CHANGE_SCOPE" $edits)"
  assert_eq "$label" "$expected" "$(verdict_of "$row_err")"
done <<'ROWS'
a test deleted under a rendered skill, its inventory row with it|class=micro measured=true cause=production-within-micro|test-removed
an inventory entry whose hash changed stays excluded|class=standard measured=true cause=excluded-path|hash-changed
an inventory that unlists a path the diff edits is excluded|class=standard measured=true cause=excluded-path|edited-unlisted
a prose schema document measures on its size|class=micro measured=true cause=production-within-micro|skills/orch/schemas/state.md=12
a package README measures on its size|class=micro measured=true cause=production-within-micro|skills/review-gate/README.md=12
a package suite measures as test lines|class=micro measured=true cause=production-within-micro|skills/review-gate/tests/gate.test.sh=200
a package reference measures on its size|class=micro measured=true cause=production-within-micro|skills/preflight/references/lanes.md=12
a hook suite measures as test lines|class=micro measured=true cause=production-within-micro|hooks/tests/guard.test.sh=200
a hook package's markdown measures on its size|class=micro measured=true cause=production-within-micro|hooks/README.md=12
a hook body is excluded|class=standard measured=true cause=excluded-path|hooks/guard.sh=2
a hook body a harness renders is excluded|class=standard measured=true cause=excluded-path|.claude/hooks/guard.sh=2
a gate script is excluded|class=standard measured=true cause=excluded-path|skills/review-gate/scripts/gate.sh=2
a consumer refresh template is excluded|class=standard measured=true cause=excluded-path|skills/review-gate/templates/kendex-refresh.yml=2
the organization standard is excluded|class=standard measured=true cause=excluded-path|skills/review-gate/standard.json=2
the Pi extension that runs every hook is excluded|class=standard measured=true cause=excluded-path|pi-extensions/pi-hooks/extensions/dispatch.ts=2
a preflight script is excluded|class=standard measured=true cause=excluded-path|skills/preflight/scripts/run.sh=2
a doc-limits script is excluded|class=standard measured=true cause=excluded-path|skills/doc-limits/scripts/check.sh=2
a guard chain script is excluded|class=standard measured=true cause=excluded-path|skills/commit-guards/scripts/chain.sh=2
the lane host dispatcher is excluded|class=standard measured=true cause=excluded-path|skills/orch/scripts/lane-host=2
the restack validation gate is excluded|class=standard measured=true cause=excluded-path|skills/orch/scripts/restack-skip=2
the validation runner is excluded|class=standard measured=true cause=excluded-path|skills/orch/scripts/dev-validate-run=2
a root AGENTS.md edit is held to small|class=small measured=true cause=instruction-file|AGENTS.md=10
a nested AGENTS.md edit is held to small|class=small measured=true cause=instruction-file|skills/AGENTS.md=3
a SKILL.md edit is held to small|class=small measured=true cause=instruction-file|skills/orch/SKILL.md=3
a root SKILL.md edit is held to small|class=small measured=true cause=instruction-file|SKILL.md=3
an AGENTS.md edit an allowlist takes is held to small|class=small measured=true cause=instruction-file|AGENTS.md=10|HARNESS_CI_TRIVIAL_PATHS=*.md
an instruction edit past small stays standard|class=standard measured=true cause=production-past-small|skills/orch/SKILL.md=200
ROWS
ROW_ENV=""
require_rows narrow-change "$rows"

# The names-only judgement is harness-only's, carried to the log as it
# printed it, so an operator sees why the inventory left the path set.
names_err="$(run_row "$HARNESS_ONLY" test-added)"
assert_eq "the inventory's names-only change is in the log" \
  "inventory-change: names-only added=1 removed=0 roots=.agents" \
  "$(grep '^inventory-change: ' <<<"$names_err")"
names_err="$(run_row "$CHANGE_SCOPE" hash-changed)"
assert_eq "a hash change prints no names-only line" "" \
  "$(grep '^inventory-change: ' <<<"$names_err" || true)"

# One must-fail control per rule: the planted copy drops that rule alone, and
# the row it reaches answers the class the rule was refusing.
control() { # LABEL EXPECTED EDIT NAME SCRIPT LINE REPLACEMENT...
  local label="$1" expected="$2" edit="$3" planted
  shift 3
  if ! planted="$(mutant "$@")"; then
    assert_eq "$label: the control is an edit" edited "not edited"
    return
  fi
  assert_eq "$label" "$expected" "$("$CONTROL_READ" "$(run_row "$planted" "$edit")")"
}
# What a control reads off the planted copy's stderr: the class line.
CONTROL_READ=verdict_of

MICRO="class=micro measured=true cause=production-within-micro"

# Removing a validation gate's exclusion lets its small edit measure as micro.
awk '
  $0 == "path *skills/orch/scripts/dev-validate-run" { hits++; next }
  { print }
  END { exit hits == 1 ? 0 : 3 }
' "$CHANGE_SCOPE_PACKAGE/references/narrow-change.conf" >"$SANDBOX/validation-gate.conf"
control "a list without the validation runner measures its edit as micro" "$MICRO" \
  skills/orch/scripts/dev-validate-run=2 validation-gate change-scope \
  'NARROW_CONF="$SCRIPT_DIR/../references/narrow-change.conf"' \
  "NARROW_CONF=\"$SANDBOX/validation-gate.conf\""

# harness-only that never judges the inventory's change leaves it on the
# path set, where the list excludes it and the test-removed row answers
# standard.
control "an unjudged inventory change is excluded" \
  "class=standard measured=true cause=excluded-path" test-removed \
  names harness-only \
  '  inventory_change="$(names_only_change)" || inventory_change=""' \
  '  inventory_change=""'
# harness-only that does not hold a removed entry's path absent at the head
# lets a de-listed render with a hand edit leave the path set.
control "an unlisted path the diff edits leaves the path set" "$MICRO" \
  edited-unlisted head-state harness-only \
  '    [ "$3" = "$([ -n "$at_head" ] && echo present || echo absent)" ]' \
  '    :'
# change-scope whose narrow answers skip the floor answers trivial on the
# root AGENTS.md row.
control "a classifier with no floor lets AGENTS.md through unreviewed" \
  "class=trivial measured=true cause=documentation-paths" AGENTS.md=10 \
  floor change-scope \
  '  [ -n "$instruction_file" ] || answer "$1" "$2"' \
  '  answer "$1" "$2"'
# Without extglob the one-segment pattern matches nothing, and a hook body
# measures as micro.
control "a matcher without extglob measures a hook body" "$MICRO" \
  hooks/guard.sh=2 glob change-scope 'shopt -s extglob' -
# A reader from before the extglob grammar: no extglob, and every `path`
# line read, the superseded one too. The broad line keeps its refusal.
control "a reader before the extglob grammar still refuses a hook body" \
  "class=standard measured=true cause=excluded-path" hooks/guard.sh=2 \
  pre-extglob lib/change-scope.sh \
  'change_class_list_globs() { # CONF KEYWORD' 'change_class_list_globs() { shopt -u extglob # CONF KEYWORD' \
  '    $1 == "superseded" { drop[$2] = 1 }' -
control "a reader before the extglob grammar still refuses a rendered hook body" \
  "class=standard measured=true cause=excluded-path" .claude/hooks/guard.sh=2 \
  pre-extglob-render lib/change-scope.sh \
  'change_class_list_globs() { # CONF KEYWORD' 'change_class_list_globs() { shopt -u extglob # CONF KEYWORD' \
  '    $1 == "superseded" { drop[$2] = 1 }' -

# A list from before the floor carries no `instruction` line; the classifier
# refuses it rather than reading AGENTS.md with no floor.
plant_layout "$SANDBOX/floorless" >/dev/null
grep -v '^instruction ' "$CHANGE_SCOPE_PACKAGE/references/narrow-change.conf" \
  >"$SANDBOX/floorless/change-scope/references/narrow-change.conf"
assert_eq "a list with no floor is refused" \
  "class=standard measured=false cause=narrow-change-floor-missing" \
  "$(verdict_of "$(run_row "$SANDBOX/floorless/change-scope/scripts/change-scope" AGENTS.md=10)")"

# A base commit of the fixture repository whose settings hold CONTENT.
settings_base() { # CONTENT -> prints the base commit
  ROW_BASE="" reset_case
  printf '%s\n' "$1" >"$repo/kendex.settings.toml"
  git -C "$repo" add -A
  git -C "$repo" commit -q -m "settings base"
  git -C "$repo" rev-parse HEAD
}
# Orch reads this machine line. Assert its path and glob as well as its class.
class_line_of() { # STDERR
  sed -n 's/^class: //p' <<<"$1"
}
standard_base="$(settings_base $'[env]\nHARNESS_CI_STANDARD_PATHS = "docs/* runtime/*"')"
standard_empty_base="$(settings_base $'[env]\nHARNESS_CI_STANDARD_PATHS = ""')"
standard_miss_base="$(settings_base $'[env]\nHARNESS_CI_STANDARD_PATHS = "other/*"')"
standard_glob_base="$(settings_base $'[env]\nHARNESS_CI_STANDARD_PATHS = "runtime/!(kept).ts"')"
ROW_BASE="$standard_miss_base" reset_case
mkdir -p "$repo/.kendex"
printf '[env]\nHARNESS_CI_STANDARD_PATHS = "runtime/*"\n' >"$repo/.kendex/settings.toml"
git -C "$repo" add -A
git -C "$repo" commit -q -m "settings overlay base"
standard_overlay_base="$(git -C "$repo" rev-parse HEAD)"

# label | base | edit | environment | exact structured class line
standard_rows=0
while IFS='|' read -r label row_base edit ROW_ENV expected; do
  standard_rows=$((standard_rows + 1))
  ROW_BASE="${!row_base}"
  assert_eq "$label" "$expected" "$(class_line_of "$(run_row "$CHANGE_SCOPE" "$edit")")"
done <<'ROWS'
a declared path forces trivial to standard|standard_base|docs/risk.md=2||class=standard measured=true cause=repository-standard-path path=docs/risk.md glob=docs/*
the same trivial diff without a declaration stays trivial|base|docs/risk.md=2||class=trivial measured=true cause=documentation-paths lines=2
a declared path forces micro to standard|standard_base|runtime/product.ts=2||class=standard measured=true cause=repository-standard-path path=runtime/product.ts glob=runtime/*
the same micro diff without a declaration stays micro|base|runtime/product.ts=2||class=micro measured=true cause=production-within-micro production=2
a declared path forces small to standard|standard_base|runtime/product.ts=40||class=standard measured=true cause=repository-standard-path path=runtime/product.ts glob=runtime/*
the same small diff without a declaration stays small|base|runtime/product.ts=40||class=small measured=true cause=production-within-small subsystem=runtime
a miss keeps trivial|standard_miss_base|docs/risk.md=2||class=trivial measured=true cause=documentation-paths lines=2
a miss keeps micro|standard_miss_base|runtime/product.ts=2||class=micro measured=true cause=production-within-micro production=2
a miss keeps small|standard_miss_base|runtime/product.ts=40||class=small measured=true cause=production-within-small subsystem=runtime
an empty declaration adds no exclusions|standard_empty_base|runtime/product.ts=2||class=micro measured=true cause=production-within-micro production=2
an empty declaration keeps shared exclusions|standard_empty_base|hooks/guard.sh=2||class=standard measured=true cause=excluded-path path=hooks/guard.sh glob=hooks/!(*/*|*.md)
a nonempty declaration keeps shared-only exclusions|standard_base|hooks/guard.sh=2||class=standard measured=true cause=excluded-path path=hooks/guard.sh glob=hooks/!(*/*|*.md)
the environment cannot clear base exclusions|standard_base|runtime/product.ts=2|HARNESS_CI_STANDARD_PATHS=|class=standard measured=true cause=repository-standard-path path=runtime/product.ts glob=runtime/*
the environment cannot add exclusions|base|runtime/product.ts=2|HARNESS_CI_STANDARD_PATHS=runtime/*|class=micro measured=true cause=production-within-micro production=2
the settings overlay wins over the root table|standard_overlay_base|runtime/product.ts=2||class=standard measured=true cause=repository-standard-path path=runtime/product.ts glob=runtime/*
repository paths use the shared extglob grammar|standard_glob_base|runtime/product.ts=2||class=standard measured=true cause=repository-standard-path path=runtime/product.ts glob=runtime/!(kept).ts
an extglob miss keeps micro|standard_glob_base|runtime/kept.ts=2||class=micro measured=true cause=production-within-micro production=2
clearing the setting in the head cannot narrow its class|standard_base|standard-head-clear||class=standard measured=true cause=configuration-source path=kendex.settings.toml glob=kendex.settings.toml
adding the setting in the head cannot select its cause|base|standard-head-add||class=standard measured=true cause=configuration-source path=kendex.settings.toml glob=kendex.settings.toml
ROWS
require_rows repository-standard-path "$standard_rows"
ROW_ENV=""

# The supplied base endpoint can acquire its declaration after the fork.
ROW_BASE="$base" reset_case
write_lines runtime/product.ts 2
git -C "$repo" add -A
git -C "$repo" commit -q -m "old fork"
assert_eq "the base endpoint declares exclusions after the fork" \
  "class=standard measured=true cause=repository-standard-path path=runtime/product.ts glob=runtime/*" \
  "$(class_line_of "$("$CHANGE_SCOPE" --repo "$repo" --event pull_request --base "$standard_base" --head HEAD 2>&1 >/dev/null)")"
standard_head_mutant="$(mutant standard-head lib/change-scope.sh \
  '    BASE_REV="$(git -C "$repo" rev-parse --verify --quiet "$base^{commit}" 2>/dev/null)" ||' \
  '    BASE_REV="$(git -C "$repo" rev-parse --verify --quiet "$head^{commit}" 2>/dev/null)" ||')"
assert_eq "a reader of head settings loses the base endpoint exclusion" "$MICRO" \
  "$(verdict_of "$("$standard_head_mutant" --repo "$repo" --event pull_request --base "$standard_base" --head HEAD 2>&1 >/dev/null)")"

# Controls change each independent rule in a disposable script copy.
ROW_BASE="$standard_base"
control "a nonempty declaration cannot replace shared exclusions" "$MICRO" \
  hooks/guard.sh=2 standard-additive change-scope \
  'if path_class_matches narrow standard; then' \
  'if path_class_matches narrow standard && [ -z "${HARNESS_CI_STANDARD_PATHS:-}" ]; then'
control "skipping repository matching lets its path through" "$MICRO" \
  runtime/product.ts=2 standard-match change-scope \
  '  answer standard "cause=repository-standard-path $PATH_MATCH_HIT" measured' \
  '  : "cause=repository-standard-path $PATH_MATCH_HIT" measured'
control "omitting the key loses the base declaration" "$MICRO" \
  runtime/product.ts=2 standard-reader change-scope \
  "BASE_SETTINGS_KEYS='ORCH_SIZE_RENDER_ROOTS ORCH_SIZE_TEST_PATHS HARNESS_CI_TRIVIAL_MAX_LINES HARNESS_CI_TRIVIAL_PATHS HARNESS_CI_STANDARD_PATHS'" \
  "BASE_SETTINGS_KEYS='ORCH_SIZE_RENDER_ROOTS ORCH_SIZE_TEST_PATHS HARNESS_CI_TRIVIAL_MAX_LINES HARNESS_CI_TRIVIAL_PATHS'"
ROW_ENV="HARNESS_CI_STANDARD_PATHS="
control "keeping the caller setting loses the base exclusion" "$MICRO" \
  runtime/product.ts=2 standard-environment change-scope \
  'unset HARNESS_CI_STANDARD_PATHS' ':'
ROW_ENV=""
ROW_BASE=""

report narrow-change
