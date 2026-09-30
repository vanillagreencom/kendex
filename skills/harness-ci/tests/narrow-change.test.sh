#!/usr/bin/env bash
# What change-class reads orch's narrow-change list against: the files a
# package's risk sits in and not the package whole, the render inventory only
# where its change is more than the names the same diff adds or deletes, an
# agent instruction file held to small where it would earn trivial or micro,
# and the `queue` group that makes a change queue-only.
#
# The list is the real references/narrow-change.conf beside the script under
# test, so a row follows the shipped list rather than a copy of it. No row
# reaches the render proof: each diff carries a path the inventory does not
# list, so no kendex is run.
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
    inventory-invalid) printf '{unparsed\n' >"$repo/$INVENTORY" ;;
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
the organization standard is excluded|class=standard measured=true cause=excluded-path|skills/review-gate/standard.json=2
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
# What a control reads off the planted copy's stderr: the class line, or the
# queue-only line for the queue group's controls.
CONTROL_READ=verdict_of

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
  pre-extglob lib/change-class.sh \
  'change_class_list_globs() { # CONF KEYWORD' 'change_class_list_globs() { shopt -u extglob # CONF KEYWORD' \
  '    $1 == "superseded" { drop[$2] = 1 }' -
control "a reader before the extglob grammar still refuses a rendered hook body" \
  "class=standard measured=true cause=excluded-path" .claude/hooks/guard.sh=2 \
  pre-extglob-render lib/change-class.sh \
  'change_class_list_globs() { # CONF KEYWORD' 'change_class_list_globs() { shopt -u extglob # CONF KEYWORD' \
  '    $1 == "superseded" { drop[$2] = 1 }' -

# A list from before the floor carries no `instruction` line; the classifier
# refuses it rather than reading AGENTS.md with no floor.
mkdir -p "$SANDBOX/floorless/harness-ci/scripts"
cp -R "$ORCH_PACKAGE" "$SANDBOX/floorless/orch"
grep -v '^instruction ' "$ORCH_PACKAGE/references/narrow-change.conf" \
  >"$SANDBOX/floorless/orch/references/narrow-change.conf"
cp "$(dirname "$CHANGE_CLASS")/harness-only" "$(dirname "$CHANGE_CLASS")/change-class" \
  "$SANDBOX/floorless/harness-ci/scripts/"
cp -R "$(dirname "$CHANGE_CLASS")/lib" "$SANDBOX/floorless/harness-ci/scripts/"
assert_eq "a list with no floor is refused" \
  "class=standard measured=false cause=narrow-change-floor-missing" \
  "$(verdict_of "$(run_row "$SANDBOX/floorless/harness-ci/scripts/change-class" AGENTS.md=10)")"

# The queue-only line: its value, its cause key and the path and glob that
# answered, where one did.
queue_of() { # STDERR
  sed -n 's/^queue-only: //p' <<<"$1"
}

# A base commit of the fixture repository whose settings hold CONTENT.
settings_base() { # CONTENT -> prints the base commit
  ROW_BASE="" reset_case
  printf '%s\n' "$1" >"$repo/kendex.settings.toml"
  git -C "$repo" add -A
  git -C "$repo" commit -q -m "settings base"
  git -C "$repo" rev-parse HEAD
}
# A base declaring GLOBS as the repository's queue list.
list_base() { # GLOBS -> prints the base commit
  settings_base "$(printf '[env]\nHARNESS_CI_QUEUE_PATHS = "%s"' "$1")"
}
empty_base="$(list_base "")"

# One row per `queue` entry, each touching one path that entry alone names,
# in the source or the render spelling; a queue path beside others; a path
# git quotes, alone and beside a product file; a path the repository's own
# HARNESS_CI_QUEUE_PATHS names; and the control, a diff of paths no entry
# names, which is queue-only where the repository declares no list of its
# own and not where it declares one, empty or not. A row's path is the edit's
# own, and a `list=` field is the list its base's settings declare.
# label | expected queue-only line | edits | declared list
queue_rows=0
queue_paths=""
while IFS='|' read -r label expected edits declared; do
  queue_rows=$((queue_rows + 1))
  ROW_BASE=""
  case "$declared" in
    list=*) ROW_BASE="$(list_base "${declared#list=}")" ;;
  esac
  # shellcheck disable=SC2086
  assert_eq "$label" "$expected" "$(queue_of "$(run_row "$CHANGE_CLASS" $edits)")"
  case "$expected" in
    "queue_only=true cause=queue-path path="*) queue_paths="$queue_paths${edits%%=*}"$'\n' ;;
  esac
done <<'ROWS'
a CI workflow is queue-only|queue_only=true cause=queue-path path=.github/workflows/ci.yml glob=.github/workflows/*|.github/workflows/ci.yml=2
a CI action is queue-only|queue_only=true cause=queue-path path=.github/actions/change-class/classify glob=.github/actions/*|.github/actions/change-class/classify=2
the gate writer's engine is queue-only|queue_only=true cause=queue-path path=skills/review-gate/scripts/review-predicate.sh glob=*skills/review-gate/scripts/*|skills/review-gate/scripts/review-predicate.sh=2
the gate writer template's render is queue-only|queue_only=true cause=queue-path path=.agents/skills/review-gate/templates/review-gate-writer.yml glob=*skills/review-gate/templates/*|.agents/skills/review-gate/templates/review-gate-writer.yml=2
the organization standard is queue-only|queue_only=true cause=queue-path path=skills/review-gate/standard.json glob=*skills/review-gate/standard.json|skills/review-gate/standard.json=2
the settings naming the gate's context are queue-only|queue_only=true cause=queue-path path=kendex.settings.toml glob=kendex.settings.toml|kendex.settings.toml=2
the machine-local settings naming the gate's context are queue-only|queue_only=true cause=queue-path path=.kendex/settings.toml glob=.kendex/settings.toml|.kendex/settings.toml=2
the classifier is queue-only|queue_only=true cause=queue-path path=skills/harness-ci/scripts/change-class glob=*skills/harness-ci/scripts/*|skills/harness-ci/scripts/change-class=2
the classifier's list is queue-only|queue_only=true cause=queue-path path=skills/orch/references/narrow-change.conf glob=*skills/orch/references/narrow-change.conf|skills/orch/references/narrow-change.conf=2
the branch measurement is queue-only|queue_only=true cause=queue-path path=skills/orch/scripts/branch-size-check glob=*skills/orch/scripts/branch-size-check|skills/orch/scripts/branch-size-check=2
the branch measurement's library is queue-only|queue_only=true cause=queue-path path=.agents/skills/orch/scripts/lib/branch-growth.sh glob=*skills/orch/scripts/lib/branch-growth.sh|.agents/skills/orch/scripts/lib/branch-growth.sh=2
the measurement's settings reader is queue-only|queue_only=true cause=queue-path path=skills/orch/scripts/lib/kendex-env.sh glob=*skills/orch/scripts/lib/kendex-env.sh|skills/orch/scripts/lib/kendex-env.sh=2
the measurement's base resolver is queue-only|queue_only=true cause=queue-path path=skills/orch/scripts/resolve-base-branch glob=*skills/orch/scripts/resolve-base-branch|skills/orch/scripts/resolve-base-branch=2
the job selection is queue-only|queue_only=true cause=queue-path path=tools/ci-job-set glob=tools/ci-job-set|tools/ci-job-set=2
the Rust reads the job selection takes are queue-only|queue_only=true cause=queue-path path=tools/rust-reads glob=tools/rust-reads|tools/rust-reads=2
a skill's test library is queue-only|queue_only=true cause=queue-path path=skills/orch/tests/lib/git-env.sh glob=*skills/*/tests/lib/*|skills/orch/tests/lib/git-env.sh=2
a tools suite is queue-only|queue_only=true cause=queue-path path=tools/tests/ci-aggregate.test.sh glob=tools/tests/*|tools/tests/ci-aggregate.test.sh=2
the CI test aggregator is queue-only|queue_only=true cause=queue-path path=tools/ci-aggregate glob=tools/ci-aggregate|tools/ci-aggregate=2
kendex.toml is queue-only|queue_only=true cause=queue-path path=kendex.toml glob=kendex.toml|kendex.toml=2
this repository's manifest is queue-only|queue_only=true cause=queue-path path=kendex-local.toml glob=kendex-local.toml|kendex-local.toml=2
the bot-instruction doctrine is queue-only|queue_only=true cause=queue-path path=skills/bot-instructions/SKILL.md glob=*skills/bot-instructions/SKILL.md|skills/bot-instructions/SKILL.md=2
the bot-instruction render rules' render are queue-only|queue_only=true cause=queue-path path=.agents/skills/bot-instructions/schemas/renders.md glob=*skills/bot-instructions/schemas/renders.md|.agents/skills/bot-instructions/schemas/renders.md=2
the Copilot instruction file is queue-only|queue_only=true cause=queue-path path=.github/copilot-instructions.md glob=.github/copilot-instructions.md|.github/copilot-instructions.md=2
a review-bot instruction file is queue-only|queue_only=true cause=queue-path path=.github/instructions/code-review.md glob=.github/instructions/*|.github/instructions/code-review.md=2
a queue path beside a product file is queue-only|queue_only=true cause=queue-path path=tools/ci-aggregate glob=tools/ci-aggregate|runtime/product.ts=2 tools/ci-aggregate=2
a diff no entry names is not queue-only where the repository declares an empty list|queue_only=false cause=no-queue-path|docs/guide.md=2 runtime/product.ts=2 skills/orch/tests/added.test.sh=30|list=
a diff no entry names is not queue-only where the repository's list names none of it|queue_only=false cause=no-queue-path|docs/guide.md=2 runtime/product.ts=2|list=scripts/ci/* tools/aggregate
a diff no entry names is queue-only where the repository declares no list|queue_only=true cause=queue-list-undeclared|docs/guide.md=2 runtime/product.ts=2
a path the repository's own list names is queue-only|queue_only=true cause=repository-queue-path path=scripts/ci/run.sh glob=scripts/ci/*|runtime/product.ts=2 scripts/ci/run.sh=2|list=tools/aggregate scripts/ci/*
a refusal raised after the paths were read carries their class|queue_only=false cause=no-queue-path|inventory-invalid runtime/product.ts=2|list=
a workflow path git quotes is queue-only|queue_only=true cause=path-quoted path=".github/workflows/we\"ird.yml"|.github/workflows/we"ird.yml=2
a quoted workflow path beside a product file is queue-only|queue_only=true cause=path-quoted path=".github/workflows/we\"ird.yml"|runtime/product.ts=2 .github/workflows/we"ird.yml=2
ROWS
ROW_BASE=""
require_rows queue-only "$queue_rows"

# The repository's list as its base commit's settings declare it, and a base
# whose settings the loader rejects, which reads queue-only. The list is read
# off the base alone: a process environment that names another list, as a
# caller's own checkout exports it, changes nothing. Each base is a commit of
# the fixture repository, and the diff edits the same script.
settings_queue() { # CLASSIFIER BASE [NAME=VALUE] -> the queue-only line
  git -C "$repo" checkout -q -B settings-case "$2"
  write_lines scripts/ci/run.sh 2
  git -C "$repo" add -A
  git -C "$repo" commit -q -m "settings row"
  queue_of "$(env ${3:+"$3"} "$1" --repo "$repo" --event pull_request --base "$2" --head HEAD 2>&1 >/dev/null)" || true
}
declared_base="$(settings_base $'[env]\nHARNESS_CI_QUEUE_PATHS = "scripts/ci/*"')"
rejected_base="$(settings_base $'[env]\nHARNESS_CI_QUEUE_PATHS = ""\nHARNESS_CI_QUEUE_PATHS = ""')"
assert_eq "the base commit's settings declare the repository's list" \
  "queue_only=true cause=repository-queue-path path=scripts/ci/run.sh glob=scripts/ci/*" \
  "$(settings_queue "$CHANGE_CLASS" "$declared_base")"
assert_eq "the base's list decides where the process environment names another" \
  "queue_only=true cause=repository-queue-path path=scripts/ci/run.sh glob=scripts/ci/*" \
  "$(settings_queue "$CHANGE_CLASS" "$declared_base" "HARNESS_CI_QUEUE_PATHS=")"
assert_eq "a base whose settings the loader rejects reads queue-only" \
  "queue_only=true cause=queue-settings-unreadable" \
  "$(settings_queue "$CHANGE_CLASS" "$rejected_base")"

# Every `queue` entry of the shipped list has a row above, read off the list
# itself. The floor and the one required entry say the reader found the
# group; a reader that found nothing has broken, not found an empty list.
queue_globs="$(sed -n 's/^queue //p' "$ORCH_PACKAGE/references/narrow-change.conf")"
assert_eq "the queue group is read" 1 \
  "$(grep -cxF '.github/workflows/*' <<<"$queue_globs" || true)"
while IFS= read -r glob; do
  [ -n "$glob" ] || continue
  hit=""
  while IFS= read -r path; do
    # shellcheck disable=SC2254
    case "$path" in $glob) hit="$path"; break ;; esac
  done <<<"$queue_paths"
  assert_eq "the queue entry $glob has a row" covered "${hit:+covered}"
done <<<"$queue_globs"

# A diff whose paths were never read is queue-only: an unknown base is
# refused before the changed paths are.
unread_err="$("$CHANGE_CLASS" --repo "$repo" --event pull_request \
  --base 0123456789abcdef0123456789abcdef01234567 --head HEAD 2>&1 >/dev/null)" || true
assert_eq "a diff whose paths were not read is queue-only" \
  "queue_only=true cause=paths-unread" "$(queue_of "$unread_err")"

# An empty diff is read, and names no path: queue-only, under its own cause.
empty_err="$("$CHANGE_CLASS" --repo "$repo" --event pull_request \
  --base "$base" --head "$base" 2>&1 >/dev/null)" || true
assert_eq "an empty diff is queue-only under its own cause" \
  "queue_only=true cause=no-changed-paths" "$(queue_of "$empty_err")"

# Every row of the boundary group names a file whose edit changes the class
# the classifier answers, so each is queue-only. The rows are read off the
# shipped list, each a literal path behind a leading `*`; the floor and the
# one required row say the reader found the group.
boundary_rows="$(boundary_globs "$ORCH_PACKAGE/references/narrow-change.conf")"
assert_eq "the boundary group is read" 1 \
  "$(grep -cxF '*skills/orch/scripts/branch-size-check' <<<"$boundary_rows" || true)"
while IFS= read -r glob; do
  [ -n "$glob" ] || continue
  path="${glob#\*}"
  case "$path" in
    *[][*?!\(\)]*) assert_eq "the boundary row $glob is a literal path" literal "$glob"; continue ;;
  esac
  row_queue="$(queue_of "$(run_row "$CHANGE_CLASS" "$path=2")")"
  assert_eq "the boundary row $glob is queue-only" "queue_only=true cause=queue-path path=$path" \
    "${row_queue% glob=*}"
done <<<"$boundary_rows"

# A list with no `queue` group is one from before it, and reads queue-only.
queueless="$SANDBOX/queueless"
mkdir -p "$queueless/harness-ci/scripts"
cp -R "$ORCH_PACKAGE" "$queueless/orch"
grep -v '^queue ' "$ORCH_PACKAGE/references/narrow-change.conf" \
  >"$queueless/orch/references/narrow-change.conf"
cp "$(dirname "$CHANGE_CLASS")/harness-only" "$(dirname "$CHANGE_CLASS")/change-class" \
  "$queueless/harness-ci/scripts/"
cp -R "$(dirname "$CHANGE_CLASS")/lib" "$queueless/harness-ci/scripts/"
assert_eq "a list with no queue group reads queue-only" \
  "queue_only=true cause=queue-list-missing" \
  "$(queue_of "$(run_row "$queueless/harness-ci/scripts/change-class" docs/guide.md=2)")"

# An orch beside the package that carries no list reads queue-only.
listless="$SANDBOX/listless"
mkdir -p "$listless/harness-ci/scripts"
cp -R "$ORCH_PACKAGE" "$listless/orch"
rm -- "${listless:?}/orch/references/narrow-change.conf"
cp "$(dirname "$CHANGE_CLASS")/harness-only" "$(dirname "$CHANGE_CLASS")/change-class" \
  "$listless/harness-ci/scripts/"
cp -R "$(dirname "$CHANGE_CLASS")/lib" "$listless/harness-ci/scripts/"
assert_eq "an orch with no list reads queue-only" \
  "queue_only=true cause=queue-list-unreadable" \
  "$(queue_of "$(run_row "$listless/harness-ci/scripts/change-class" docs/guide.md=2)")"

# One must-fail control per queue rule. A classifier that never matches the
# group answers not queue-only on a CI workflow; one that reads a quoted path
# against the globs answers not queue-only on a quoted workflow; one whose
# default before the paths are read is false answers not queue-only on an
# unread diff; one that
# reads an empty group as a list answers not queue-only on the queueless list;
# one that reads a missing list as not queue-only answers so on the listless
# orch; one that judges the class after harness-only's refusals, as it once
# did, answers paths-unread on a refusal raised after the paths were read.
# One that reads an undeclared repository list as not queue-only, one that
# never matches the repository's list, one that never reads the base's
# settings and one that reads unreadable settings as not queue-only each let
# through the row that rule holds. The shipped-list controls run where the
# repository declares an empty list, so only the rule under control answers.
CONTROL_READ=queue_of
ROW_BASE="$empty_base"
control "a classifier that never matches the queue group lets a workflow through" \
  "queue_only=false cause=no-queue-path" .github/workflows/ci.yml=2 \
  queue-match change-class '  if path_matches any; then' '  if false; then'
control "a classifier that matches a quoted path against the globs lets a quoted workflow through" \
  "queue_only=false cause=no-queue-path" '.github/workflows/we"ird.yml=2' \
  queue-quoted change-class \
  '      \"*) QUEUE_CAUSE="cause=path-quoted path=$path"; return ;;' -
unread_mutant="$(mutant queue-default change-class 'QUEUE_ONLY=true' 'QUEUE_ONLY=false')"
unread_err="$("$unread_mutant" --repo "$repo" --event pull_request \
  --base 0123456789abcdef0123456789abcdef01234567 --head HEAD 2>&1 >/dev/null)" || true
assert_eq "a classifier whose unread default is false lets an unread diff through" \
  "queue_only=false cause=paths-unread" "$(queue_of "$unread_err")"
missing_mutant="$(mutant queue-missing change-class '  if [ -z "$globs" ]; then' '  if false; then')"
cp "$missing_mutant" "$queueless/harness-ci/scripts/change-class"
assert_eq "a classifier that reads an empty queue group lets the queueless list through" \
  "queue_only=false cause=no-queue-path" \
  "$(queue_of "$(run_row "$queueless/harness-ci/scripts/change-class" docs/guide.md=2)")"
unreadable_mutant="$(mutant queue-unreadable change-class \
  '    QUEUE_CAUSE="cause=queue-list-unreadable"' \
  '    QUEUE_ONLY=false QUEUE_CAUSE="cause=queue-list-unreadable"')"
cp "$unreadable_mutant" "$listless/harness-ci/scripts/change-class"
assert_eq "a classifier that reads a missing list as not queue-only lets the listless orch through" \
  "queue_only=false cause=queue-list-unreadable" \
  "$(queue_of "$(run_row "$listless/harness-ci/scripts/change-class" docs/guide.md=2)")"
order_mutant="$(mutant queue-order change-class '  queue_only_of_paths' '  :' \
  'if [ ! -s "$paths_file" ]; then' \
  '[ ! -s "$paths_file" ] || queue_only_of_paths; if [ ! -s "$paths_file" ]; then')"
assert_eq "a classifier that judges the class after the refusals loses it on a refusal" \
  "queue_only=true cause=paths-unread" \
  "$(queue_of "$(run_row "$order_mutant" inventory-invalid runtime/product.ts=2)")"
ROW_BASE=""
control "a classifier that reads an undeclared list as not queue-only lets an unlisted diff through" \
  "queue_only=false cause=queue-list-undeclared" runtime/product.ts=2 \
  queue-undeclared change-class \
  '    QUEUE_CAUSE="cause=queue-list-undeclared"' \
  '    QUEUE_ONLY=false QUEUE_CAUSE="cause=queue-list-undeclared"'
ROW_BASE="$declared_base"
control "a classifier that never matches the repository's list lets its path through" \
  "queue_only=false cause=no-queue-path" scripts/ci/run.sh=2 \
  queue-repository change-class '  if ! path_matches any; then' '  if true; then'
ROW_BASE=""
base_mutant="$(mutant queue-base-settings change-class \
  '  if ! base_settings; then' '  if false; then')"
assert_eq "a classifier that never reads the base's settings loses the declared list" \
  "queue_only=true cause=queue-list-undeclared" \
  "$(settings_queue "$base_mutant" "$declared_base")"
environment_mutant="$(mutant queue-environment change-class \
  'unset HARNESS_CI_QUEUE_PATHS' ':')"
assert_eq "a classifier that keeps the process environment's list lets the base's newly listed path through" \
  "queue_only=false cause=no-queue-path" \
  "$(settings_queue "$environment_mutant" "$declared_base" "HARNESS_CI_QUEUE_PATHS=")"
rejected_mutant="$(mutant queue-settings-unreadable change-class \
  '    QUEUE_CAUSE="cause=queue-settings-unreadable"' \
  '    QUEUE_ONLY=false QUEUE_CAUSE="cause=queue-settings-unreadable"')"
assert_eq "a classifier that reads rejected settings as not queue-only lets the diff through" \
  "queue_only=false cause=queue-settings-unreadable" \
  "$(settings_queue "$rejected_mutant" "$rejected_base")"
CONTROL_READ=verdict_of

report narrow-change
