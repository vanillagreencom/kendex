#!/usr/bin/env bash
# What change-class reads orch's narrow-change list against: the files a
# package's risk sits in and not the package whole, the render inventory only
# where its change is more than the names the same diff adds or deletes, and
# an agent instruction file held to no lower than small.
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
repo="$(new_repo narrow-change)"
jq -c --arg kept "$KEPT_RENDER" --arg hash "$HASHED_A" \
  '. + [$kept, {path: "CLAUDE.md.tmpl", template: "claude", templateHash: $hash}]' \
  "$repo/$INVENTORY" >"$SANDBOX/base-inventory"
mv "$SANDBOX/base-inventory" "$repo/$INVENTORY"
commit_paths "$repo" baseline seed.txt runtime/kept.ts \
  "$KEPT_RENDER" skills/orch/tests/kept.test.sh
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
edit_inventory() { # FILTER
  jq -c --arg added "$RENDER" --arg kept "$KEPT_RENDER" --arg hash "$HASHED_B" \
    "$1" "$repo/$INVENTORY" >"$SANDBOX/inventory"
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
    *=*) write_lines "${1%=*}" "${1##*=}" ;;
    *) echo "unknown edit $1" >&2; exit 1 ;;
  esac
}

# The verdict's class, marker and cause key: a row pins which rule answered.
verdict_of() { # STDERR
  sed -n 's/^class: \(class=[a-z]* measured=[a-z]* cause=[a-z-]*\).*/\1/p' <<<"$1"
}

run_row() { # CLASSIFIER EDITS...
  local classifier="$1" edit
  shift
  reset_case
  for edit in "$@"; do apply_edit "$edit"; done
  git -C "$repo" add -A
  git -C "$repo" commit -q -m "row"
  "$classifier" --repo "$repo" --event pull_request --base "$base" --head HEAD \
    2>&1 >/dev/null
}

# label | expected verdict | edits
rows=0
while IFS='|' read -r label expected edits; do
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
a guard chain script is excluded|class=standard measured=true cause=excluded-path|skills/commit-guards/scripts/chain.sh=2
the lane launcher is excluded|class=standard measured=true cause=excluded-path|skills/orch/scripts/open-terminal=2
a root AGENTS.md edit is held to small|class=small measured=true cause=instruction-file|AGENTS.md=10
a nested AGENTS.md edit is held to small|class=small measured=true cause=instruction-file|skills/AGENTS.md=3
a SKILL.md edit is held to small|class=small measured=true cause=instruction-file|skills/orch/SKILL.md=3
an instruction edit past small stays standard|class=standard measured=true cause=production-past-small|skills/orch/SKILL.md=200
ROWS
require_rows narrow-change "$rows"

# The names-only judgement is harness-only's, carried to the log as it
# printed it, so an operator sees why the inventory left the path set.
names_err="$(run_row "$CHANGE_CLASS" test-added)"
assert_eq "the inventory's names-only change is in the log" \
  "inventory-change: names-only added=1 removed=0" \
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

# Must-fail control for the names-only rule: a harness-only that never judges
# the inventory's change leaves it on the path set, where the list excludes
# it and the test-added row answers standard.
sed 's/^  inventory_change="$(names_only_change)" || inventory_change=""$/  inventory_change=""/' \
  "$(dirname "$CHANGE_CLASS")/harness-only" >"$SANDBOX/harness-only.names"
assert_eq "the names-only control drops exactly one judgement" 1 \
  "$(grep -c '^  inventory_change=""$' "$SANDBOX/harness-only.names")"
names_mutant="$(plant "$SANDBOX/names-mutant" harness-only "$SANDBOX/harness-only.names")"
assert_eq "an unjudged inventory change is excluded" \
  "class=standard measured=true cause=excluded-path" \
  "$(verdict_of "$(run_row "$names_mutant" test-added)")"

# Must-fail control for the instruction-file floor: a classifier whose narrow
# answers skip the floor answers trivial on the root AGENTS.md row.
sed 's/^  \[ -n "\$instruction_file" \] || answer "\$1" "\$2"$/  answer "$1" "$2"/' \
  "$CHANGE_CLASS" >"$SANDBOX/change-class.floor"
assert_eq "the floor control skips exactly one check" 1 \
  "$(grep -c '^  answer "\$1" "\$2"$' "$SANDBOX/change-class.floor")"
floor_mutant="$(plant "$SANDBOX/floor-mutant" change-class "$SANDBOX/change-class.floor")"
assert_eq "a classifier with no floor lets AGENTS.md through unreviewed" \
  "class=trivial measured=true cause=documentation-paths" \
  "$(verdict_of "$(run_row "$floor_mutant" AGENTS.md=10)")"

# Must-fail control for the hook body glob: without extglob the one-segment
# pattern matches nothing, and a hook body measures as micro.
sed '/^shopt -s extglob$/d' "$CHANGE_CLASS" >"$SANDBOX/change-class.glob"
assert_eq "the glob control drops the one shopt" "1 0" \
  "$(grep -c '^shopt -s extglob$' "$CHANGE_CLASS") $(grep -c '^shopt -s extglob$' "$SANDBOX/change-class.glob" || true)"
glob_mutant="$(plant "$SANDBOX/glob-mutant" change-class "$SANDBOX/change-class.glob")"
assert_eq "a matcher without extglob measures a hook body" \
  "class=micro measured=true cause=production-within-micro" \
  "$(verdict_of "$(run_row "$glob_mutant" hooks/guard.sh=2)")"

report narrow-change
