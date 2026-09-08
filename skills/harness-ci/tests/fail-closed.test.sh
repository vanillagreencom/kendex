#!/usr/bin/env bash
# Inputs the classifier cannot prove answer false with a successful exit. This
# runs every lane without turning a data problem into a wiring error.
set -euo pipefail
# shellcheck source=lib/sandbox.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/sandbox.sh"

repo="$(new_repo fail-closed)"
commit_paths "$repo" baseline README.md
base="$(git -C "$repo" rev-parse HEAD)"
commit_paths "$repo" "render only" .agents/skills/orch/SKILL.md
head="$(git -C "$repo" rev-parse HEAD)"

assert_verdict valid-endpoints true \
  --repo "$repo" --event push --base "$base" --head "$head"

closed() { # LABEL ARGS...
  local label="$1" out status
  shift
  if out="$("$HARNESS_ONLY" "$@" 2>/dev/null)"; then
    status=0
  else
    status=$?
  fi
  assert_eq "$label" "harness_only=false exit 0" "$out exit $status"
}

tree_base="$(git -C "$repo" rev-parse "HEAD^{tree}")"
empty="$(new_repo empty)"

run_rejected_input() { # LABEL REPO EVENT BASE HEAD
  local label="$1" case_repo="$2" event="$3" case_base="$4" case_head="$5"
  local args=(--repo "$case_repo" --event "$event")
  case "$case_base" in
    '<omit>') ;;
    '<empty>') args+=(--base "") ;;
    *) args+=(--base "$case_base") ;;
  esac
  case "$case_head" in
    '<default>') ;;
    '<empty>') args+=(--head "") ;;
    *) args+=(--head "$case_head") ;;
  esac
  closed "$label" "${args[@]}"
}

# label | repository | event | base | head
while IFS='|' read -r label case_repo event case_base case_head; do
  run_rejected_input "$label" "$case_repo" "$event" "$case_base" "$case_head"
done <<CASES
schedule|$repo|schedule|$base|$head
workflow-dispatch|$repo|workflow_dispatch|$base|$head
missing-base|$repo|push|<omit>|$head
empty-base|$repo|push|<empty>|$head
zero-base|$repo|push|0000000000000000000000000000000000000000|$head
zero-head|$repo|push|$base|0000000000000000000000000000000000000000
unknown-base|$repo|push|1234567890123456789012345678901234567890|$head
unknown-head|$repo|pull_request|$base|1234567890123456789012345678901234567890
tree-base|$repo|push|$tree_base|$head
identical-endpoints|$repo|push|$head|$head
non-checkout|$SANDBOX|push|$base|$head
absent-checkout|$SANDBOX/absent|push|$base|$head
unborn-checkout|$empty|push|HEAD|<default>
CASES

# Two valid roots with no shared ancestor make the pull-request diff fail.
orphan="$(new_repo unrelated-histories)"
commit_paths "$orphan" "first root" README.md
root_a="$(git -C "$orphan" rev-parse HEAD)"
git -C "$orphan" checkout -q --orphan second
git -C "$orphan" rm -q -rf .
write_inventory "$orphan"
commit_paths "$orphan" "second root" .agents/skills/orch/SKILL.md
root_b="$(git -C "$orphan" rev-parse HEAD)"
if git -C "$orphan" merge-base "$root_a" "$root_b" >/dev/null 2>&1; then
  echo "FAIL: the fixture roots share a merge base" >&2
  exit 1
fi
closed unrelated-histories \
  --repo "$orphan" --event pull_request --base "$root_a" --head "$root_b"

# Git quotes this product path. The fixture keeps the existing fail-closed
# contract without claiming that quoting is the only rejection.
quoted="$(new_repo quoted-path)"
commit_paths "$quoted" baseline README.md
quoted_base="$(git -C "$quoted" rev-parse HEAD)"
commit_paths "$quoted" "quoted product path" \
  '.agents/skills/orch/we"ird.md' .agents/skills/orch/SKILL.md
listed="$(git -C "$quoted" -c core.quotePath=false diff --name-only --no-renames "$quoted_base" HEAD)"
case "$listed" in
  *'"'*) : ;;
  *) echo "FAIL: git did not quote the fixture path" >&2; exit 1 ;;
esac
closed git-quoted-path \
  --repo "$quoted" --event push --base "$quoted_base"

if reason="$("$HARNESS_ONLY" --repo "$repo" --event schedule --base "$base" 2>&1 >/dev/null)"; then
  reason_status=0
else
  reason_status=$?
fi
case "$reason" in
  *"event 'schedule'"*"running every lane"*) reason_contract=present ;;
  *) reason_contract="$reason" ;;
esac
assert_eq unsupported-event-report "present exit 0" \
  "$reason_contract exit $reason_status"

git -C "$repo" rm -q .kendex-generated.json
git -C "$repo" commit -qm "missing inventory"
closed missing-head-inventory --repo "$repo" --event push --base "$base"
printf '%s\n' invalid >"$repo/.kendex-generated.json"
git -C "$repo" add -A
git -C "$repo" commit -qm "invalid inventory"
closed invalid-head-inventory --repo "$repo" --event push --base "$base"

report fail-closed
