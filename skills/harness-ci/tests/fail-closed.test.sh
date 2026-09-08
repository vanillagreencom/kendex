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

closed() { # LABEL EXPECTED-FIRST ARGS...
  local label="$1" expected_first="$2" out status first
  local stderr_file="$SANDBOX/closed-$1.stderr"
  shift 2
  if out="$("$HARNESS_ONLY" "$@" 2>"$stderr_file")"; then
    status=0
  else
    status=$?
  fi
  assert_eq "$label" "harness_only=false exit 0" "$out exit $status"
  first="$(sed -n '1p' "$stderr_file")"
  assert_eq "$label first-line" "$expected_first" "$first"
}

tree_base="$(git -C "$repo" rev-parse "HEAD^{tree}")"
empty="$(new_repo empty)"

run_rejected_input() { # LABEL REPO EVENT BASE HEAD
  local label="$1" case_repo="$2" event="$3" case_base="$4" case_head="$5"
  local expected=""
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
  case "$label" in
    schedule | workflow-dispatch)
      expected="fallback: cause=unsupported-event event=$event"
      ;;
    missing-base | empty-base)
      expected="fallback: cause=missing-base event=push"
      ;;
    zero-base | unknown-base | tree-base | non-checkout | absent-checkout)
      expected="fallback: cause=unresolved-endpoint endpoint=$case_base"
      ;;
    zero-head | unknown-head)
      expected="fallback: cause=unresolved-endpoint endpoint=$case_head"
      ;;
    identical-endpoints)
      expected="fallback: cause=empty-diff base=$case_base head=$case_head"
      ;;
    unborn-checkout)
      expected="fallback: cause=unresolved-endpoint endpoint=HEAD"
      ;;
    *) echo "FAIL: unknown rejected input '$label'" >&2; exit 1 ;;
  esac
  closed "$label" "$expected" "${args[@]}"
}

# label | repository | event | base | head
rejected_row_count=0
while IFS='|' read -r label case_repo event case_base case_head; do
  rejected_row_count=$((rejected_row_count + 1))
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
require_rows rejected-input "$rejected_row_count"

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
  "fallback: cause=unreadable-diff range=$root_a...$root_b" \
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
quoted_changed="$(sed -n '$p' <<<"$listed")"
printf -v quoted_field '%q' "$quoted_changed"
closed git-quoted-path \
  "fallback: cause=unreadable-changed-path path=$quoted_field" \
  --repo "$quoted" --event push --base "$quoted_base"

git -C "$repo" rm -q .kendex-generated.json
git -C "$repo" commit -qm "missing inventory"
closed missing-head-inventory \
  "fallback: cause=unreadable-head-inventory head=HEAD" \
  --repo "$repo" --event push --base "$base"
printf '%s\n' invalid >"$repo/.kendex-generated.json"
git -C "$repo" add -A
git -C "$repo" commit -qm "invalid inventory"
closed invalid-head-inventory "fallback: cause=invalid-generated-paths" \
  --repo "$repo" --event push --base "$base"

product="$(new_repo product-source)"
commit_paths "$product" baseline README.md
product_base="$(git -C "$product" rev-parse HEAD)"
commit_paths "$product" product src/app.rs
closed product-source \
  "fallback: cause=product-source-or-unreadable-ownership path=src/app.rs" \
  --repo "$product" --event push --base "$product_base"

missing_base_inventory="$(new_repo missing-base-inventory)"
rm -- "$missing_base_inventory/.kendex-generated.json"
commit_paths "$missing_base_inventory" baseline README.md
missing_inventory_base="$(git -C "$missing_base_inventory" rev-parse HEAD)"
write_inventory "$missing_base_inventory"
commit_paths "$missing_base_inventory" render .agents/skills/orch/SKILL.md
closed missing-base-inventory \
  "fallback: cause=unreadable-base-inventory base=$missing_inventory_base" \
  --repo "$missing_base_inventory" --event push --base "$missing_inventory_base"

ownership="$(new_repo ownership-gain)"
commit_paths "$ownership" baseline README.md
ownership_base="$(git -C "$ownership" rev-parse HEAD)"
jq '. + ["runtime/new.conf"]' "$ownership/.kendex-generated.json" \
  >"$ownership/.kendex-generated.next.json"
mv -- "$ownership/.kendex-generated.next.json" "$ownership/.kendex-generated.json"
commit_paths "$ownership" "ownership gain" runtime/new.conf
closed ownership-gain "fallback: cause=generated-ownership-gain" \
  --repo "$ownership" --event push --base "$ownership_base"

report fail-closed
