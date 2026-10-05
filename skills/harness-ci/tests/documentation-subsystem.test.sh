#!/usr/bin/env bash
# Launch estimates and CI classes for source changes with documentation.
set -euo pipefail
# shellcheck source=lib/sandbox.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/sandbox.sh"

SANDBOX="$(cd -- "$SANDBOX" && pwd -P)"
repo="$(new_repo documentation-subsystem)"
git -C "$repo" config gc.auto 0
git -C "$repo" config maintenance.auto false
commit_paths "$repo" baseline seed.txt
base="$(git -C "$repo" rev-parse HEAD)"

# The launch producer names Location paths and an estimate. Its branch also
# carries the architecture document and changelog the implementation adds.
# The CI class measures source and docs together. The launch tier reads the
# estimate and Location paths. Each row changes non-generated source.
rows=0
while IFS='|' read -r label estimate launch_tier class_line specs; do
  rows=$((rows + 1))
  git -C "$repo" checkout -q -B case "$base"
  git -C "$repo" clean -qfd
  location_args=()
  for spec in $specs; do
    path="${spec%:*}"
    count="${spec##*:}"
    mkdir -p "$repo/$(dirname -- "$path")"
    n=0
    while [ "$n" -lt "$count" ]; do
      n=$((n + 1))
      printf 'line %s\n' "$n" >>"$repo/$path"
    done
    location_args+=(--path "$path")
  done
  git -C "$repo" add -A
  git -C "$repo" commit -q -m "source and its documentation"
  if [ "$rows" -eq 1 ]; then
    docs_control_head="$(git -C "$repo" rev-parse HEAD)"
  fi
  class_err="$(env -i PATH="$PATH" HOME="$SANDBOX" TMPDIR="$SANDBOX" \
    "$CHANGE_CLASS" --repo "$repo" --event pull_request --base "$base" \
    --head HEAD --output /dev/null 2>&1 >/dev/null)"
  launch="$(env -i PATH="$PATH" HOME="$SANDBOX" TMPDIR="$SANDBOX" \
    "$ORCH_PACKAGE/scripts/item-tier" --repo "$repo" --production "$estimate" \
    "${location_args[@]}")"
  assert_eq "$label" "tier=$launch_tier $class_line" \
    "${launch%% *} $(sed -n '/^class: /p' <<<"$class_err")"
done <<'DOCS'
a source with its architecture document|40|small|class: class=small measured=true cause=production-within-small subsystem=runtime|runtime/product.ts:30 docs/architecture/runtime.md:10
a source with its changelog fragment|31|small|class: class=small measured=true cause=production-within-small subsystem=runtime|runtime/product.ts:30 changelog.d/fixed/runtime.md:1
a source with root documentation|40|small|class: class=small measured=true cause=production-within-small subsystem=runtime|runtime/product.ts:30 README.md:10
a source with a root instruction file|31|small|class: class=small measured=true cause=production-within-small subsystem=runtime|runtime/product.ts:30 AGENTS.md:1
documentation still counts at the small size ceiling|150|small|class: class=small measured=true cause=production-within-small subsystem=runtime|runtime/product.ts:30 docs/runtime.md:120
documentation still counts past the small size ceiling|151|standard|class: class=standard measured=true cause=production-past-small production=151|runtime/product.ts:30 docs/runtime.md:121
an all-docs change permits complete empty outside discovery|30|small|class: class=small measured=true cause=production-within-small subsystem=|docs/runtime.md:30
two source subsystems beside docs select the standard CI class|70|small|class: class=standard measured=true cause=several-subsystems production=70|runtime/product.ts:30 payload/data.conf:30 docs/runtime.md:10
an excluded path beside docs selects standard at launch and in CI|40|standard|class: class=standard measured=true cause=excluded-path path=.github/workflows/ci.yml glob=.github/workflows/*|runtime/product.ts:30 .github/workflows/ci.yml:1 docs/runtime.md:9
DOCS
require_rows documentation-subsystem "$rows"

# Keep the membership match but remove the docs skip in a disposable copy.
# The same regression assertion must reject the former subsystem count.
IFS= read -r docs_skip <<'LINE'
  case "$non_docs" in *$'\n'"$path"$'\n'*) ;; *) continue ;; esac
LINE
IFS= read -r docs_no_skip <<'LINE'
  case "$non_docs" in *$'\n'"$path"$'\n'*) ;; *) : ;; esac
LINE
docs_mutant="$(mutant docs-subsystem change-class "$docs_skip" "$docs_no_skip")"
old_err="$(env -i PATH="$PATH" HOME="$SANDBOX" TMPDIR="$SANDBOX" \
  "$docs_mutant" --repo "$repo" --event pull_request --base "$base" \
  --head "$docs_control_head" --output /dev/null 2>&1 >/dev/null)"
old_line="$(sed -n '/^class: /p' <<<"$old_err")"
if (PASS=0; FAIL=0; assert_eq docs-subsystem \
  'class: class=small measured=true cause=production-within-small subsystem=runtime' \
  "$old_line" >/dev/null 2>&1; [ "$FAIL" -eq 0 ]); then
  assert_eq "docs subsystem control must turn the regression red" red green
else
  assert_eq "docs subsystem control reaches the former rule" \
    'class: class=standard measured=true cause=several-subsystems production=40' "$old_line"
fi

# harness-only documents false plus an empty outside list after a read
# failure. Plant that dependency outcome, not a second docs classifier.
reader_line='if [ "$classification" = docs ]; then'
reader_failure='if [ "$classification" = docs ]; then
  verdict false "cause=unreadable-diff" "injected dependency read failure"
fi
if [ "$classification" = docs ]; then'
failed_reader="$(mutant docs-reader-failed harness-only "$reader_line" "$reader_failure")"
git -C "$repo" checkout -q -B micro-fallback "$base"
git -C "$repo" clean -qfd
commit_paths "$repo" "small independent size" runtime/product.ts docs/runtime.md
micro_head="$(git -C "$repo" rev-parse HEAD)"
fallback_rows=0
while IFS='|' read -r label head class_line; do
  fallback_rows=$((fallback_rows + 1))
  err="$(env -i PATH="$PATH" HOME="$SANDBOX" TMPDIR="$SANDBOX" \
    "$failed_reader" --repo "$repo" --event pull_request --base "$base" \
    --head "$head" --output /dev/null 2>&1 >/dev/null)"
  assert_eq "$label" "$class_line" "$(sed -n '/^class: /p' <<<"$err")"
done <<FALLBACK
incomplete docs discovery cannot narrow a small source diff|$docs_control_head|class: class=standard measured=false cause=documentation-paths-unreadable
micro retains its independent size proof without docs discovery|$micro_head|class: class=micro measured=true cause=production-within-micro production=2
FALLBACK
require_rows documentation-discovery "$fallback_rows"

empty_guard='if [ "$docs_verdict" = docs_only=false ] && [ -z "$non_docs" ]; then'
unchecked="$(mutant docs-discovery-unchecked change-class "$empty_guard" "if false; then # $empty_guard")"
cp "$(dirname -- "$failed_reader")/harness-only" "$(dirname -- "$unchecked")/harness-only"
unchecked_err="$(env -i PATH="$PATH" HOME="$SANDBOX" TMPDIR="$SANDBOX" \
  "$unchecked" --repo "$repo" --event pull_request --base "$base" \
  --head "$docs_control_head" --output /dev/null 2>&1 >/dev/null)"
unchecked_line="$(sed -n '/^class: /p' <<<"$unchecked_err")"
if (PASS=0; FAIL=0; assert_eq docs-discovery \
  'class: class=standard measured=false cause=documentation-paths-unreadable' \
  "$unchecked_line" >/dev/null 2>&1; [ "$FAIL" -eq 0 ]); then
  assert_eq "docs discovery control must turn the regression red" red green
else
  assert_eq "the unchecked discovery control loses the source subsystem" \
    'class: class=small measured=true cause=production-within-small subsystem=' "$unchecked_line"
fi

report documentation-subsystem
