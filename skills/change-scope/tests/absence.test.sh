#!/usr/bin/env bash
# Surface: scripts/change-scope, harness-ci's scripts/change-class. Inputs: this
# package's scripts and references, harness-ci/scripts.
#
# The classifier needs no other package: copied alone into an install layout
# with no harness-ci, agent-runtime, orch, linear, github or mailbox beside
# it, it still classifies a fixture diff. The wrapper does need this package:
# harness-ci's change-class copied without it refuses at startup with its
# keyed line and the wiring-error status, before it reads anything.
set -euo pipefail
# shellcheck source=lib/sandbox.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/sandbox.sh"

repo="$(new_repo absence)"
commit_paths "$repo" baseline seed.txt
base="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" checkout -q -B case "$base"
mkdir -p "$repo/runtime"
printf 'line 1\nline 2\n' >>"$repo/runtime/product.ts"
git -C "$repo" add -A
git -C "$repo" commit -q -m "two lines of product code"

# The layout holds this package alone, under a skills directory with nothing
# else in it. The absence is proved by listing the directory, never by a flag.
alone="$SANDBOX/alone/skills"
mkdir -p "$alone/change-scope"
cp -R "$CHANGE_SCOPE_PACKAGE/scripts" "$alone/change-scope/scripts"
cp -R "$CHANGE_SCOPE_PACKAGE/references" "$alone/change-scope/references"
assert_eq "the layout holds change-scope and no other package" "change-scope" \
  "$(ls "$alone" | tr '\n' ' ' | sed 's/ $//')"
for package in harness-ci agent-runtime orch linear github mailbox bot-instructions; do
  assert_eq "$package is absent from the layout" absent \
    "$([ -e "$alone/$package" ] && echo present || echo absent)"
done

# No kendex on PATH either: the fixture's class is earned by size, so the
# verifier is not reached, and a diff this size answers micro on every row of
# the recorded same-classification fixtures.
no_kendex_path=""
while IFS= read -r dir; do
  [ -n "$dir" ] || continue
  [ ! -x "$dir/kendex" ] || continue
  no_kendex_path="${no_kendex_path:+$no_kendex_path:}$dir"
done <<<"$(printf '%s' "$PATH" | tr ':' '\n')"
alone_out="$(PATH="$no_kendex_path" "$alone/change-scope/scripts/change-scope" --event pull_request \
  --repo "$repo" --base "$base" --head HEAD 2>"$SANDBOX/alone.err")" && alone_status=0 || alone_status=$?
assert_eq "the classifier alone classifies the fixture" \
  "change_class=micro exit 0" "$alone_out exit $alone_status"
assert_eq "and its class line is a measured verdict" \
  "class: class=micro measured=true cause=production-within-micro production=2" \
  "$(grep '^class: ' "$SANDBOX/alone.err")"
assert_eq "the reader alone reads the same range" "harness_only=false" \
  "$(PATH="$no_kendex_path" "$alone/change-scope/scripts/harness-only" --event pull_request \
    --repo "$repo" --base "$base" --head HEAD --output /dev/null 2>/dev/null)"

# The wrapper copied without this package refuses before it reads the range:
# the keyed line first, exit 2, and no class on stdout.
without="$SANDBOX/without/skills"
mkdir -p "$without/harness-ci"
cp -R "$HARNESS_CI_PACKAGE/scripts" "$without/harness-ci/scripts"
assert_eq "the wrapper's layout holds harness-ci alone" "harness-ci" \
  "$(ls "$without" | tr '\n' ' ' | sed 's/ $//')"
without_out="$("$without/harness-ci/scripts/change-class" --event pull_request \
  --repo "$repo" --base "$base" --head HEAD 2>"$SANDBOX/without.err")" && without_status=0 || without_status=$?
assert_eq "the wrapper without change-scope refuses at startup" \
  "wiring-error: cause=dependency-absent skill=change-scope path=$without/harness-ci/scripts/../../change-scope/scripts/change-scope exit 2 stdout=''" \
  "$(sed -n '1p' "$SANDBOX/without.err") exit $without_status stdout='$without_out'"
reader_out="$("$without/harness-ci/scripts/harness-only" --event pull_request \
  --repo "$repo" --base "$base" --head HEAD 2>"$SANDBOX/without-reader.err")" && reader_status=0 || reader_status=$?
assert_eq "the reader forwarder without change-scope refuses at startup" \
  "wiring-error: cause=dependency-absent skill=change-scope path=$without/harness-ci/scripts/../../change-scope/scripts/harness-only exit 2 stdout=''" \
  "$(sed -n '1p' "$SANDBOX/without-reader.err") exit $reader_status stdout='$reader_out'"
lib_status=0
lib_err="$(bash -c '. "$1"' sh "$without/harness-ci/scripts/lib/change-class.sh" 2>&1)" || lib_status=$?
assert_eq "the lane library without change-scope fails its load with the keyed line" \
  "wiring-error: cause=dependency-absent skill=change-scope path=$without/harness-ci/scripts/lib/../../../change-scope/scripts/lib/change-scope.sh exit 1" \
  "$lib_err exit $lib_status"

# With the classifier beside it but its library missing, the wrapper's load of
# harness-ci's lane library fails: that library's keyed line comes first, the
# wrapper's second, exit 2, and no class on stdout.
libless="$SANDBOX/libless/skills"
mkdir -p "$libless/harness-ci"
cp -R "$HARNESS_CI_PACKAGE/scripts" "$libless/harness-ci/scripts"
cp -R "$alone/change-scope" "$libless/change-scope"
rm -- "$libless/change-scope/scripts/lib/change-scope.sh"
libless_out="$("$libless/harness-ci/scripts/change-class" --event pull_request \
  --repo "$repo" --base "$base" --head HEAD 2>"$SANDBOX/libless.err")" && libless_status=0 || libless_status=$?
assert_eq "the wrapper with change-scope's library missing refuses at startup" \
  "wiring-error: cause=dependency-absent skill=change-scope path=$libless/harness-ci/scripts/lib/../../../change-scope/scripts/lib/change-scope.sh
wiring-error: cause=dependency-absent skill=change-scope path=$libless/harness-ci/scripts/../../change-scope/scripts/lib/change-scope.sh exit 2 stdout=''" \
  "$(grep '^wiring-error: ' "$SANDBOX/libless.err") exit $libless_status stdout='$libless_out'"

# The same wrapper copy answers once this package stands beside it, so the
# refusal above was the absence and nothing else.
cp -R "$alone/change-scope" "$without/change-scope"
with_out="$("$without/harness-ci/scripts/change-class" --event pull_request \
  --repo "$repo" --base "$base" --head HEAD 2>/dev/null)" && with_status=0 || with_status=$?
assert_eq "the wrapper with change-scope beside it classifies the fixture" \
  "change_class=micro exit 0" "$with_out exit $with_status"

report absence
