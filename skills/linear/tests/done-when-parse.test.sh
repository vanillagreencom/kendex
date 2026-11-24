#!/usr/bin/env bash
# bash-runtime: 4
# `done-when parse` is the one Done-when read another package consumes (the
# orch watch's terminal judgement and its GitHub item ticks): it prints the
# checklist `done_when_parse` builds, from an inline description or a file,
# with no credential resolved and no request made, and with `--met N
# --evidence TEXT` the description with box N ticked. It refuses a call
# that names neither or both inputs, or a `--met` without its `--evidence`
# or its box number.
set -euo pipefail
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)" || exit 1
source "$SCRIPT_DIR/lib/assert.sh"
SKILL_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd -P)" || exit 1
assert_tmpdir TMP_ROOT
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || exit 1

LINEAR="$SKILL_DIR/scripts/linear.sh"
description=$'Intro\n\n## Done when\n- [x] Branch proof\n  Evidence: the test\n- [ ] Post-merge: Read release; Where: feed; Why after merge: publish; Trigger: release owner/repo v*; Deadline: +24h\n'

# Inline: two boxes, the first checked, the second an open post-merge box;
# no credential is read: the private env file is unreadable here and an
# API key is absent, which a request would refuse on.
out="$(cd "$TMP_ROOT" && env -u LINEAR_API_KEY -u LINEAR_APP_TOKEN "$LINEAR" done-when parse --description "$description")"
assert_eq 'the inline description parses to its boxes' \
  "$(jq -c '[.boxes[] | {number, checked, post_merge}]' <<<"$out")" \
  '[{"number":1,"checked":true,"post_merge":false},{"number":2,"checked":false,"post_merge":true}]'
assert_eq 'an open post-merge box reads Verifying' "$(jq -r '.completion_state' <<<"$out")" Verifying

# From a file, byte for byte the same answer.
printf '%s' "$description" > "$TMP_ROOT/description.md"
from_file="$(cd "$TMP_ROOT" && "$LINEAR" done-when parse --description-file "$TMP_ROOT/description.md")"
assert_eq 'the file form parses the same' "$from_file" "$out"

# A tick: box 2 checked with its Evidence line under it in the answered
# description, the box read checked, and nothing else of the text moved.
ticked="$("$LINEAR" done-when parse --description "$description" --met 2 --evidence 'v1.2 shipped')"
assert_eq 'the ticked box reads checked' "$(jq -c '[.ticked, .boxes[1].checked]' <<<"$ticked")" '[1,true]'
assert_eq 'the description carries the tick and its Evidence line' "$(jq -r '.description' <<<"$ticked")" \
  "${description/'- [ ] Post-merge'/'- [x] Post-merge'}  Evidence: v1.2 shipped"

# No section: no boxes, Done.
none="$("$LINEAR" done-when parse --description $'Just text\n')"
assert_eq 'a description with no section has no boxes' "$(jq -c '.boxes' <<<"$none")" '[]'

# Refusals: another action, neither input, both inputs, an unknown option,
# an unreadable file, a `--met` without its `--evidence`, and one with no
# box number.
for args in "render --description x" "parse" "parse --description x --description-file y" "parse --what" "parse --description-file $TMP_ROOT/absent" "parse --description x --met 1" "parse --description x --met 0 --evidence y"; do
  rc=0
  # shellcheck disable=SC2086
  "$LINEAR" done-when $args >/dev/null 2>"$TMP_ROOT/err" || rc=$?
  assert_eq "refused: done-when $args" "$rc" 1
  assert_contains "the refusal names the verb: $args" "$(cat "$TMP_ROOT/err")" 'linear: done-when'
done
