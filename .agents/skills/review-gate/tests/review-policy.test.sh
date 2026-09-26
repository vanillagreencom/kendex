#!/usr/bin/env bash
# review-policy reads the classifier's measured marker and keeps no list of
# causes of its own. The catalog each case runs against is the subject: what
# the classifier can and cannot reach decides whether it measured a class or
# fell back to standard, and this suite asserts the record or the refusal that
# follows.
set -euo pipefail
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
CATALOG="$(cd "$SKILL_DIR/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf -- "${TMP:?}"' EXIT

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() {
  FAIL=$((FAIL + 1))
  printf '  FAIL  %s\n' "$1"
  [ -z "${2:-}" ] || printf '%s\n' "$2" | sed 's/^/        /'
  return 0
}
assert_eq() {
  if [ "$1" = "$2" ]; then ok "$3"; else bad "$3" "expected [$2], got [$1]"; fi
}

POLICY='render:none;trivial:none;micro:none;small:bot;standard:current'

# package TREE SKILL... — a catalog holding only the named skills, so a case
# says which of them the classifier may find. review-policy resolves the
# classifier beside itself and the classifier resolves the orch skill the same
# way, so a skill left out is a real absence rather than a stub.
package() {
  local tree="$1" skill
  shift
  mkdir -p "$tree"
  for skill in "$@"; do cp -R -- "$CATALOG/$skill" "$tree/$skill"; done
}

# repo DIR — two commits over a product file, with the generated-file
# inventory committed at both ends so the classifier gets past its first read.
repo() {
  local dir="$1"
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" config maintenance.auto false
  git -C "$dir" config user.email tests@example.invalid
  git -C "$dir" config user.name "review-policy tests"
  printf '[]\n' >"$dir/.kendex-generated.json"
  printf 'one\n' >"$dir/app.ts"
  git -C "$dir" add -A
  git -C "$dir" commit -q -m base
  printf 'two\n' >>"$dir/app.ts"
  git -C "$dir" add app.ts
  git -C "$dir" commit -q -m head
}

# run OWNER REPO — the live form, from inside REPO, under settings of this
# case's own rather than whatever the host carries. Sets OUT and RC.
run() {
  RC=0
  OUT="$(cd "$2" && REVIEW_GATE_SETTINGS_FILE=/dev/null \
    REVIEW_GATE_CLASS_POLICY="$POLICY" "$1" \
    --event pull_request --base HEAD~1 --head HEAD --repo . 2>"$TMP/err")" || RC=$?
}

diagnostic_key() { sed -n 's/^review-gate-error=\([a-z-]*\) .*/\1/p' "$TMP/err" | tail -1; }

echo "=== review-policy reads the classifier's marker ==="

# A catalog the classifier can measure in: harness-ci reaches the orch skill's
# narrow-change list and its branch measurer, so a rule earns the class.
WHOLE="$TMP/whole"
package "$WHOLE" review-gate harness-ci orch
repo "$TMP/whole-repo"
run "$WHOLE/review-gate/scripts/review-policy" "$TMP/whole-repo"
assert_eq "$RC" "0" "a measurable tree answers"
assert_eq "${OUT%% *}" "change_class=micro" "and the record names the class the rules earned"

# The same repository, judged by a catalog with no orch skill beside
# harness-ci. The classifier cannot read the narrow-change list, so its
# `standard` is the fallback. The harness-note on the way there carries a
# cause the classifier treats as measurable, which is why a consumer that read
# causes instead of this marker let the fallback through as a class.
LONE="$TMP/lone"
package "$LONE" review-gate harness-ci
repo "$TMP/lone-repo"
run "$LONE/review-gate/scripts/review-policy" "$TMP/lone-repo"
assert_eq "$RC" "2" "a tree the classifier cannot measure in refuses"
assert_eq "$([ -z "$OUT" ] && echo empty || echo lines)" "empty" "and prints no policy record"
assert_eq "$(diagnostic_key)" "policy-unmeasured" "naming the refusal under its own key"
assert_eq "$(grep -c 'cause=narrow-change-list-unreadable' "$TMP/err")" "2" \
  "and repeating the classifier's own cause, in its log and in the diagnostic"

# Must-fail control: the marker is the whole of what this script reads. A
# class line without one is an answer it cannot read, never one it may assume.
BLIND="$TMP/blind"
package "$BLIND" review-gate harness-ci orch
BLIND_CC="$BLIND/harness-ci/scripts/change-class"
MARKER_LINE="printf 'class: class=%s measured=%s %s\\n' \"\$1\" \"\$measured\" \"\$2\" >&2"
MARKER_MUTANT="printf 'class: class=%s %s\\n' \"\$1\" \"\$2\" >&2"
marker_count="$(grep -Fc -- "$MARKER_LINE" "$BLIND_CC" || true)"
assert_eq "$marker_count" "1" "control: the class line has one marker to remove"
if [ -L "$BLIND_CC" ]; then
  bad "control: the mutation source must not be a symlink"
else
  # Literal, through the environment and index/substr: awk expands escapes in
  # a -v assignment and reads a sub() pattern as a regex, and this line is
  # made of backslashes, dollars and percent signs.
  MUT_OLD="$MARKER_LINE" MUT_NEW="$MARKER_MUTANT" awk '
    {
      old = ENVIRON["MUT_OLD"]
      at = index($0, old)
      if (at) { $0 = substr($0, 1, at - 1) ENVIRON["MUT_NEW"] substr($0, at + length(old)) }
      print
    }' "$BLIND_CC" >"$TMP/blind-cc"
  if cmp -s "$TMP/blind-cc" "$BLIND_CC"; then
    bad "control: the mutant must remove the marker"
  else
    cat "$TMP/blind-cc" >"$BLIND_CC"
    repo "$TMP/blind-repo"
    run "$BLIND/review-gate/scripts/review-policy" "$TMP/blind-repo"
    assert_eq "$RC" "2" "must-fail: a class line carrying no marker refuses"
    assert_eq "$(diagnostic_key)" "policy-classifier-protocol" \
      "must-fail: and says the classifier's answer could not be read"
  fi
fi

# Must-fail control: the settings library refuses with its own keyed line when
# it cannot initialize, and this script loads it with no stderr redirect so
# that line reaches the operator. Under a redirect the same removal leaves an
# exit 2 naming nothing.
MUTE="$TMP/mute"
package "$MUTE" review-gate harness-ci orch
MUTE_DIAGNOSTICS="$MUTE/review-gate/scripts/lib/diagnostics.sh"
assert_eq "$([ -r "$MUTE_DIAGNOSTICS" ] && echo present || echo absent)" "present" \
  "control: the diagnostics library is there to remove"
rm -f -- "${MUTE_DIAGNOSTICS:?}"
repo "$TMP/mute-repo"
run "$MUTE/review-gate/scripts/review-policy" "$TMP/mute-repo"
assert_eq "$RC" "2" "a settings library that cannot initialize refuses"
assert_eq "$(diagnostic_key)" "diagnostics-load" \
  "must-fail: and the library's own diagnostic reaches stderr"

echo "=== review-policy names the review bots a none row waives threads from ==="

# `threads|trusted-logins|want`: REVIEW_GATE_THREADS (`-` leaves it unset),
# the trusted list as a repository sets it, and the first line
# --review-bots prints, after `exit N` when it refuses. Only a `[bot]` entry
# is a bot, both separators split, and the suffix is dropped because
# GitHub's GraphQL login lacks it. With the thread term off nothing can count
# a lapsed waiver, so no bot is named and nothing is waived.
bot_rows=0
while IFS='|' read -r threads trusted want; do
  bot_rows=$((bot_rows + 1))
  threads_env=(REVIEW_GATE_THREADS="$threads")
  [ "$threads" != - ] || threads_env=(-u REVIEW_GATE_THREADS)
  rc=0
  got="$(cd "$TMP" && env "${threads_env[@]}" REVIEW_GATE_SETTINGS_FILE=/dev/null \
    REVIEW_GATE_REVIEW_OBJECT_TRUSTED_LOGINS="$trusted" \
    "$SKILL_DIR/scripts/review-policy" --review-bots 2>&1)" || rc=$?
  got="${got%%$'\n'*}"
  [ "$rc" -eq 0 ] || got="exit $rc $got"
  assert_eq "$got" "$want" "review bots of [$trusted] with threads $threads"
done <<'ROWS'
-|copilot-pull-request-reviewer[bot]; coderabbitai[bot],bmethod|review-bots=copilot-pull-request-reviewer,coderabbitai
enforce|copilot-pull-request-reviewer[bot]|review-bots=copilot-pull-request-reviewer
off|copilot-pull-request-reviewer[bot]|review-bots=
sometimes|copilot-pull-request-reviewer[bot]|exit 2 review-gate-error=policy-threads-mode value=sometimes
-|bmethod|review-bots=
-||review-bots=
ROWS
assert_eq "$bot_rows" "6" "the review-bot table ran every row"

printf '\npass: %d   fail: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
