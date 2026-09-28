#!/usr/bin/env bash
# What change-class reads orch's narrow-change list against: the files a
# package's risk sits in and not the package whole, the render inventory only
# where its change is more than the names the same diff adds or deletes, and
# an agent instruction file held to small where it would earn trivial or
# micro.
#
# The list is the real references/narrow-change.conf beside the script under
# test, so a row follows the shipped list rather than a copy of it. No row
# reaches the render proof: each diff carries a path the inventory does not
# list, so no kendex is run.
set -euo pipefail
# shellcheck source=lib/sandbox.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/sandbox.sh"

ORCH_PACKAGE="$(cd "$(dirname "$CHANGE_CLASS")/../../orch" && pwd)"
INVENTORY=.kendex-generated.json
RENDER=.agents/skills/orch/tests/added.test.sh
SOURCE=skills/orch/tests/added.test.sh
HASHED_A="sha256:$(printf 'a%.0s' $(seq 64))"
HASHED_B="sha256:$(printf 'b%.0s' $(seq 64))"

# The base holds a render and its source, a product file, and an inventory
# with one templated entry, so a row can move a name, a hash, or neither.
KEPT_RENDER=.agents/skills/orch/tests/kept.test.sh
# A file under a render root whose source the diff does not add.
HIDDEN_RENDER=.agents/tools/hidden.sh
# A hand-written file under a render root, on disk and unlisted at the base.
PRIOR_RENDER=.agents/misc/prior.sh
repo="$(new_repo narrow-change)"
jq -c --arg kept "$KEPT_RENDER" --arg hash "$HASHED_A" \
  '. + [$kept, {path: "CLAUDE.md.tmpl", template: "claude", templateHash: $hash}]' \
  "$repo/$INVENTORY" >"$SANDBOX/base-inventory"
mv "$SANDBOX/base-inventory" "$repo/$INVENTORY"
commit_paths "$repo" baseline seed.txt runtime/kept.ts \
  "$KEPT_RENDER" skills/orch/tests/kept.test.sh "$PRIOR_RENDER"
base="$(git -C "$repo" rev-parse HEAD)"

reset_case() {
  git -C "$repo" checkout -q -B case "$base"
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
    stays-listed)
      write_lines runtime/kept.ts 2
      edit_inventory '. + ["runtime/kept.ts"]' ;;
    added-unlisted-stays)
      write_lines "$SOURCE" 30
      write_lines "$RENDER" 30
      edit_inventory '. + [$added] | map(select(. != $kept))' ;;
    edited-unlisted)
      write_lines "$KEPT_RENDER" 2
      edit_inventory 'map(select(. != $kept))' ;;
    listed-no-source)
      write_lines "$HIDDEN_RENDER" 4
      edit_inventory --arg hidden "$HIDDEN_RENDER" '. + [$hidden]' ;;
    listed-existing)
      write_lines "$PRIOR_RENDER" 2
      write_lines misc/prior.sh 2
      edit_inventory --arg prior "$PRIOR_RENDER" '. + [$prior]' ;;
    listed-off-root)
      write_lines src/hidden.rs 4
      write_lines hidden.rs 4
      edit_inventory '. + ["src/hidden.rs"]' ;;
    listed-product)
      write_lines src/hidden.rs 4
      edit_inventory '. + ["src/hidden.rs"]' ;;
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
    --base "$base" --head HEAD 2>&1 >/dev/null
}

# label | expected verdict | edits | environment
rows=0
while IFS='|' read -r label expected edits ROW_ENV; do
  rows=$((rows + 1))
  # shellcheck disable=SC2086
  row_err="$(run_row "$CHANGE_CLASS" $edits)"
  assert_eq "$label" "$expected" "$(verdict_of "$row_err")"
done <<'ROWS'
a test added under a rendered skill, its inventory row beside it|class=micro measured=true cause=production-within-micro|test-added
a test deleted under a rendered skill, its inventory row with it|class=micro measured=true cause=production-within-micro|test-removed
an inventory entry whose hash changed stays excluded|class=standard measured=true cause=excluded-path|hash-changed
an inventory entry for a path that stays is excluded|class=standard measured=true cause=excluded-path|stays-listed
an inventory that also unlists a path still on disk is excluded|class=standard measured=true cause=excluded-path|added-unlisted-stays
an inventory that unlists a path the diff edits is excluded|class=standard measured=true cause=excluded-path|edited-unlisted
an inventory that lists a render root file with no source beside it is excluded|class=standard measured=true cause=excluded-path|listed-no-source
an inventory that claims a file already on disk is excluded|class=standard measured=true cause=excluded-path|listed-existing
an inventory that lists a paired file outside every render root is excluded|class=standard measured=true cause=excluded-path|listed-off-root
an inventory that lists a new product file is excluded|class=standard measured=true cause=excluded-path|listed-product
a prose schema document measures on its size|class=micro measured=true cause=production-within-micro|skills/orch/schemas/state.md=12
a package README measures on its size|class=micro measured=true cause=production-within-micro|skills/review-gate/README.md=12
a package suite measures as test lines|class=micro measured=true cause=production-within-micro|skills/review-gate/tests/gate.test.sh=200
a package reference measures on its size|class=micro measured=true cause=production-within-micro|skills/preflight/references/lanes.md=12
a hook suite measures as test lines|class=micro measured=true cause=production-within-micro|hooks/tests/guard.test.sh=200
a hook package's markdown measures on its size|class=micro measured=true cause=production-within-micro|hooks/README.md=12
a hook body is excluded|class=standard measured=true cause=excluded-path|hooks/guard.sh=2
a hook body a harness renders is excluded|class=standard measured=true cause=excluded-path|.claude/hooks/guard.sh=2
a gate script is excluded|class=standard measured=true cause=excluded-path|skills/review-gate/scripts/gate.sh=2
a gate writer template is excluded|class=standard measured=true cause=excluded-path|skills/review-gate/templates/writer.yml=2
the default review policy is excluded|class=standard measured=true cause=excluded-path|skills/review-gate/standard.json=2
the Pi extension that runs every hook is excluded|class=standard measured=true cause=excluded-path|pi-extensions/pi-hooks/extensions/dispatch.ts=2
a preflight script is excluded|class=standard measured=true cause=excluded-path|skills/preflight/scripts/run.sh=2
a doc-limits script is excluded|class=standard measured=true cause=excluded-path|skills/doc-limits/scripts/check.sh=2
a guard chain script is excluded|class=standard measured=true cause=excluded-path|skills/commit-guards/scripts/chain.sh=2
the lane launcher is excluded|class=standard measured=true cause=excluded-path|skills/orch/scripts/open-terminal=2
a root AGENTS.md edit is held to small|class=small measured=true cause=instruction-file|AGENTS.md=10
a nested AGENTS.md edit is held to small|class=small measured=true cause=instruction-file|skills/AGENTS.md=3
a SKILL.md edit is held to small|class=small measured=true cause=instruction-file|skills/orch/SKILL.md=3
a root SKILL.md edit is held to small|class=small measured=true cause=instruction-file|SKILL.md=3
an AGENTS.md edit an allowlist takes is held to small|class=small measured=true cause=instruction-file|AGENTS.md=10|HARNESS_CI_TRIVIAL_PATHS=*.md
a plan-directory AGENTS.md past the trivial ceiling is held to small|class=small measured=true cause=instruction-file|docs/plans/AGENTS.md=30
an instruction edit past small stays standard|class=standard measured=true cause=production-past-small|skills/orch/SKILL.md=200
ROWS
ROW_ENV=""
require_rows narrow-change "$rows"

# The names-only judgement is harness-only's, carried to the log as it
# printed it, so an operator sees why the inventory left the path set.
names_err="$(run_row "$CHANGE_CLASS" test-added)"
assert_eq "the inventory's names-only change is in the log" \
  "inventory-change: names-only added=1 removed=0 roots=.agents" \
  "$(grep '^inventory-change: ' <<<"$names_err")"
names_err="$(run_row "$CHANGE_CLASS" hash-changed)"
assert_eq "a hash change prints no names-only line" "" \
  "$(grep '^inventory-change: ' <<<"$names_err" || true)"

# A package laid out as the real one, with the script under test swapped for
# a planted copy.
plant() { # ROOT SCRIPT PLANTED -> prints the planted change-class path
  mkdir -p "$1/harness-ci/scripts"
  cp "$(dirname "$CHANGE_CLASS")/harness-only" "$(dirname "$CHANGE_CLASS")/change-class" \
    "$1/harness-ci/scripts/"
  ln -s "$ORCH_PACKAGE" "$1/orch"
  cp "$3" "$1/harness-ci/scripts/$2"
  chmod +x "$1/harness-ci/scripts/"*
  printf '%s' "$1/harness-ci/scripts/change-class"
}

# A copy of the package's SCRIPT with each exact LINE replaced by
# REPLACEMENT, `-` deleting it, planted beside the real scripts. Each LINE
# has to occur exactly once in the copy, or the control is not an edit.
mutant() { # NAME SCRIPT LINE REPLACEMENT [LINE REPLACEMENT]...
  local name="$1" script="$2" copy
  shift 2
  copy="$SANDBOX/$name.$script"
  cp "$(dirname "$CHANGE_CLASS")/$script" "$copy"
  while [ "$#" -ge 2 ]; do
    if ! LINE="$1" WITH="$2" awk '
      $0 == ENVIRON["LINE"] { hits++; if (ENVIRON["WITH"] != "-") print ENVIRON["WITH"]; next }
      { print }
      END { exit hits == 1 ? 0 : 3 }
    ' "$copy" >"$copy.next"; then
      echo "FAIL: control $name: '$1' does not occur once in $script" >&2
      exit 1
    fi
    mv "$copy.next" "$copy"
    shift 2
  done
  plant "$SANDBOX/$name" "$script" "$copy"
}

# One must-fail control per rule: the planted copy drops that rule alone, and
# the row it reaches answers the class the rule was refusing.
control() { # LABEL EXPECTED EDIT NAME SCRIPT LINE REPLACEMENT...
  local label="$1" expected="$2" edit="$3" planted
  shift 3
  if ! planted="$(mutant "$@")"; then
    assert_eq "$label: the control is an edit" edited "not edited"
    return
  fi
  assert_eq "$label" "$expected" "$(verdict_of "$(run_row "$planted" "$edit")")"
}

MICRO="class=micro measured=true cause=production-within-micro"

# harness-only that never judges the inventory's change leaves it on the
# path set, where the list excludes it and the test-added row answers
# standard.
control "an unjudged inventory change is excluded" \
  "class=standard measured=true cause=excluded-path" test-added \
  names harness-only \
  '  inventory_change="$(names_only_change)" || inventory_change=""' \
  '  inventory_change=""'
# harness-only that pairs no source with an added entry lets a render root
# file nothing renders leave the path set.
control "an added entry with no source leaves the path set" "$MICRO" \
  listed-no-source pairing harness-only \
  '        diff_moves "${path#*/}" absent present || return 1' -
# harness-only that does not hold a removed entry's path absent at the head
# lets a de-listed render with a hand edit leave the path set.
control "an unlisted path the diff edits leaves the path set" "$MICRO" \
  edited-unlisted head-state harness-only \
  '    [ "$3" = "$([ -n "$at_head" ] && echo present || echo absent)" ]' \
  '    :'
# harness-only that does not hold an added entry's path absent at the base
# lets a diff claim a hand-written file under a render root as generated.
control "a claimed file already on disk leaves the path set" "$MICRO" \
  listed-existing base-state harness-only \
  '  [ "$2" = "$([ -n "$at_base" ] && echo present || echo absent)" ] &&' \
  '  : &&'
# change-class that takes every root harness-only names lets a paired file
# outside the render roots leave the path set.
control "a root outside the render roots leaves the path set" "$MICRO" \
  listed-off-root roots change-class \
  '      [ "$root" = "$listed" ] && continue 2' \
  '      continue 2'
# change-class whose narrow answers skip the floor answers trivial on the
# root AGENTS.md row.
control "a classifier with no floor lets AGENTS.md through unreviewed" \
  "class=trivial measured=true cause=documentation-paths" AGENTS.md=10 \
  floor change-class \
  '  [ -n "$instruction_file" ] || answer "$1" "$2"' \
  '  answer "$1" "$2"'
# Without extglob the one-segment pattern matches nothing, and a hook body
# measures as micro.
control "a matcher without extglob measures a hook body" "$MICRO" \
  hooks/guard.sh=2 glob change-class 'shopt -s extglob' -
# A reader from before the extglob grammar: no extglob, and every `path`
# line read, the superseded one too. The broad line keeps its refusal.
control "a reader before the extglob grammar still refuses a hook body" \
  "class=standard measured=true cause=excluded-path" hooks/guard.sh=2 \
  pre-extglob change-class 'shopt -s extglob' - \
  '    $1 == "superseded" { drop[$2] = 1 }' -
control "a reader before the extglob grammar still refuses a rendered hook body" \
  "class=standard measured=true cause=excluded-path" .claude/hooks/guard.sh=2 \
  pre-extglob-render change-class 'shopt -s extglob' - \
  '    $1 == "superseded" { drop[$2] = 1 }' -

# A list from before the floor carries no `instruction` line; the classifier
# refuses it rather than reading AGENTS.md with no floor.
mkdir -p "$SANDBOX/floorless/harness-ci/scripts"
cp -R "$ORCH_PACKAGE" "$SANDBOX/floorless/orch"
grep -v '^instruction ' "$ORCH_PACKAGE/references/narrow-change.conf" \
  >"$SANDBOX/floorless/orch/references/narrow-change.conf"
cp "$(dirname "$CHANGE_CLASS")/harness-only" "$(dirname "$CHANGE_CLASS")/change-class" \
  "$SANDBOX/floorless/harness-ci/scripts/"
assert_eq "a list with no floor is refused" \
  "class=standard measured=false cause=narrow-change-floor-missing" \
  "$(verdict_of "$(run_row "$SANDBOX/floorless/harness-ci/scripts/change-class" AGENTS.md=10)")"

report narrow-change
