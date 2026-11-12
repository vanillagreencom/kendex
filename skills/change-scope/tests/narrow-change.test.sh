#!/usr/bin/env bash
# What change-scope reads this package's narrow-change list against: the files
# a package's risk sits in and not the package whole, the render inventory only
# where its change is more than the names the same diff adds or deletes, an
# agent instruction file held to small where it would earn trivial or micro,
# a diff that removes test protection held to small the same way, and the
# repository's own standard paths, read off the base commit alone.
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

# The protection rows' files, as the protection base holds them or as one
# edit leaves them: a source file with two test cases in its test module, a
# shell suite with assert lines and a table, and a Cargo test roster.
lib_rs() { # base|case-removed|case-rewritten|ignore-added|case-added
  printf '%s\n' 'pub fn one() -> u32 {' '    1' '}' '' '#[cfg(test)]' 'mod tests {'
  if [ "$1" = case-rewritten ]; then
    printf '%s\n' '    #[tokio::test]' '    async fn one_is_one() {' '        assert_eq!(super::one(), 2 - 1);'
  else
    printf '%s\n' '    #[test]' '    fn one_is_one() {' '        assert_eq!(super::one(), 1);'
  fi
  printf '%s\n' '    }'
  if [ "$1" != case-removed ]; then
    printf '\n'
    [ "$1" != ignore-added ] || printf '%s\n' '    #[ignore]'
    printf '%s\n' '    #[test]' '    fn one_is_positive() {' '        assert!(super::one() > 0);' '    }'
  fi
  [ "$1" != case-added ] ||
    printf '%s\n' '' '    #[test]' '    fn one_is_odd() {' '        assert_eq!(super::one() % 2, 1);' '    }'
  printf '%s\n' '}'
}
guard_suite() { # base|rows-removed
  printf '%s\n' '#!/usr/bin/env bash' 'assert_eq "one" 1 1'
  [ "$1" = rows-removed ] || printf '%s\n' 'assert_eq "two" 2 2'
  printf '%s\n' "while IFS='|' read -r label want; do" '  assert_eq "$label" "$want" "$want"' \
    "done <<'TABLE'" 'first row|1'
  [ "$1" = rows-removed ] || printf '%s\n' 'second row|2'
  printf '%s\n' 'TABLE'
}
cargo_roster() { # base|target-removed
  printf '%s\n' '[package]' 'name = "runtime"' '' '[[test]]' 'name = "moved"' 'path = "tests/moved.rs"'
  [ "$1" = target-removed ] || printf '%s\n' '' '[[test]]' 'name = "target"' 'path = "tests/target.rs"'
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
    case-removed | case-rewritten | ignore-added | case-added) lib_rs "$1" >"$repo/runtime/src/lib.rs" ;;
    case-moved)
      printf '%s\n' '#[test]' 'fn stays() {}' >"$repo/runtime/tests/moved.rs"
      printf '%s\n' '#[test]' 'fn kept() {}' '' '#[test]' 'fn moved() {}' >"$repo/runtime/tests/target.rs" ;;
    rows-removed) guard_suite "$1" >"$repo/runtime/tests/guard.test.sh" ;;
    target-removed) cargo_roster "$1" >"$repo/runtime/Cargo.toml" ;;
    lanes-changed) printf 'check runtime/src/*\n' >"$repo/.github/ci-lanes.conf" ;;
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
a test deleted under a rendered skill, its inventory row with it|class=small measured=true cause=protection-removed|test-removed
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

# The suite's must-fail control: a planted copy reading a list without the
# validation gate's exclusion lets that gate's small edit measure as micro.
awk '
  $0 == "path *skills/orch/scripts/dev-validate-run" { hits++; next }
  { print }
  END { exit hits == 1 ? 0 : 3 }
' "$CHANGE_SCOPE_PACKAGE/references/narrow-change.conf" >"$SANDBOX/validation-gate.conf"
if planted="$(mutant validation-gate change-scope \
  'NARROW_CONF="$SCRIPT_DIR/../references/narrow-change.conf"' \
  "NARROW_CONF=\"$SANDBOX/validation-gate.conf\"")"; then
  assert_eq "a list without the validation runner measures its edit as micro" \
    "class=micro measured=true cause=production-within-micro" \
    "$(verdict_of "$(run_row "$planted" skills/orch/scripts/dev-validate-run=2)")"
else
  assert_eq "the validation-gate control is an edit" edited "not edited"
fi

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

# The protection floor. Deleted lines cost nothing in the size rules, so each
# row's diff measures micro; the floor reads what it removes, net over the
# whole range.
ROW_BASE="" reset_case
mkdir -p "$repo/runtime/src" "$repo/runtime/tests" "$repo/.github"
lib_rs base >"$repo/runtime/src/lib.rs"
printf '%s\n' '#[test]' 'fn moved() {}' '' '#[test]' 'fn stays() {}' >"$repo/runtime/tests/moved.rs"
printf '%s\n' '#[test]' 'fn kept() {}' >"$repo/runtime/tests/target.rs"
guard_suite base >"$repo/runtime/tests/guard.test.sh"
cargo_roster base >"$repo/runtime/Cargo.toml"
printf 'check runtime/*\n' >"$repo/.github/ci-lanes.conf"
git -C "$repo" add -A
git -C "$repo" commit -q -m "protection base"
ROW_BASE="$(git -C "$repo" rev-parse HEAD)"

# label | edit | exact structured class line
protection_rows=0
while IFS='|' read -r label edit expected; do
  protection_rows=$((protection_rows + 1))
  assert_eq "$label" "$expected" "$(class_line_of "$(run_row "$CHANGE_SCOPE" "$edit")")"
done <<'ROWS'
a test case deleted from a source file's test module is held to small|case-removed|class=small measured=true cause=protection-removed kind=case path=runtime/src/lib.rs removed=1 added=0 measured-class=micro
a test rewritten in place, its marker line changed, loses nothing|case-rewritten|class=micro measured=true cause=production-within-micro production=3
a test moved between two files loses nothing|case-moved|class=micro measured=true cause=production-within-micro production=0
an added ignore is held to small|ignore-added|class=small measured=true cause=protection-removed kind=skip path=runtime/src/lib.rs removed=0 added=1 measured-class=micro
a shell suite that loses an assert line and a table row is held to small|rows-removed|class=small measured=true cause=protection-removed kind=case path=runtime/tests/guard.test.sh removed=1 added=0 measured-class=micro
a test target removed from the Cargo roster is held to small|target-removed|class=small measured=true cause=protection-removed kind=case path=runtime/Cargo.toml removed=1 added=0 measured-class=micro
a test added with none removed stays micro|case-added|class=micro measured=true cause=production-within-micro production=5
a changed CI lane declaration is held to small|lanes-changed|class=small measured=true cause=protection-removed kind=selection path=.github/ci-lanes.conf removed=1 added=1 measured-class=micro
ROWS
require_rows protection "$protection_rows"

# A protection read git refuses is standard, unmeasured: a planted git that
# refuses the line read alone.
mkdir -p "$SANDBOX/refusing-git"
printf '#!/bin/sh\nfor a in "$@"; do [ "$a" != -U0 ] || exit 128; done\nexec "%s" "$@"\n' \
  "$(command -v git)" >"$SANDBOX/refusing-git/git"
chmod +x "$SANDBOX/refusing-git/git"
REFUSING_ENV="PATH=$SANDBOX/refusing-git:$PATH"
assert_eq "an unreadable protection read is standard, unmeasured" \
  "class=standard measured=false cause=protection-unreadable" \
  "$(verdict_of "$(ROW_ENV="$REFUSING_ENV" run_row "$CHANGE_SCOPE" case-removed)")"

# The floor's controls: each changes one line of the rule, or drops one
# marker from a planted list, and its row answers the class the floor exists
# to refuse. Each reaches the printed class alone.
protection_control() { # LABEL EXPECTED PLANTED EDIT [BASE]
  assert_eq "control: $1" "$2" "$(verdict_of "$(ROW_BASE="${5:-$ROW_BASE}" run_row "$3" "$4")")"
}
# A planted classifier reading the shipped list without the lines that start
# with PREFIX.
list_without() { # NAME PREFIX
  PREFIX="$2" awk 'index($0, ENVIRON["PREFIX"]) == 1 { hits++; next } { print } END { exit hits > 0 ? 0 : 3 }' \
    "$CHANGE_SCOPE_PACKAGE/references/narrow-change.conf" >"$SANDBOX/$1.conf" ||
    { echo "FAIL: control $1: no list line starts '$2'" >&2; exit 1; }
  mutant "$1" change-scope 'NARROW_CONF="$SCRIPT_DIR/../references/narrow-change.conf"' \
    "NARROW_CONF=\"$SANDBOX/$1.conf\""
}
MICRO="class=micro measured=true cause=production-within-micro"
SMALL="class=small measured=true cause=protection-removed"
protection_control "without the floor a deleted test case is micro" "$MICRO" \
  "$(mutant no-floor change-scope '  [ -z "$BRANCH_PROTECTION_KIND" ] ||' '  true ||')" case-removed
protection_control "without the deleted-suite count a deleted suite is micro" "$MICRO" \
  "$(mutant no-suite lib/branch-growth.sh \
    '        if (from && !to) { suite_removed[g]++; if (suite_first[g] == "") suite_first[g] = gone }' -)" \
  test-removed "$base"
gross="$(mutant gross lib/branch-growth.sh \
  '      for (k = 1; k <= n; k++) if (kind[k] == "case" && lost[k] > gained[k]) {' \
  '      for (k = 1; k <= n; k++) if (kind[k] == "case" && lost[k] > 0) {')"
protection_control "a gross count floors a test rewritten in place" "$SMALL" "$gross" case-rewritten
protection_control "a gross count floors a moved test" "$SMALL" "$gross" case-moved
protection_control "a list without the ignore marker reads an added ignore as micro" "$MICRO" \
  "$(list_without no-ignore 'skip *.rs ')" ignore-added
protection_control "a list without the shell markers reads lost rows as micro" "$MICRO" \
  "$(list_without no-shell 'case *.test.sh ')" rows-removed
protection_control "a list without the roster marker reads a removed target as micro" "$MICRO" \
  "$(list_without no-roster 'case *Cargo.toml ')" target-removed
protection_control "added lines read as removed floor an added test" "$SMALL" \
  "$(mutant swapped lib/branch-growth.sh '      removed = (sign == "-")' '      removed = (sign == "+")')" \
  case-added
protection_control "a list without the selection line reads a lane change as micro" "$MICRO" \
  "$(list_without no-selection 'selection ')" lanes-changed
assert_eq "control: a protection read failure that continues answers micro" "$MICRO" \
  "$(verdict_of "$(ROW_ENV="$REFUSING_ENV" run_row "$(mutant read-continues change-scope \
    '    answer standard "cause=protection-unreadable detail=$BRANCH_GROWTH_ERROR"' '    true')" case-removed)")"
ROW_ENV=""

report narrow-change
