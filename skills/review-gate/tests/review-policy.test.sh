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

echo "=== the policy is active by default ==="

# No settings layer assigns the key: the fixture repository has no settings
# file and no .env.local, and the environment carries neither the key nor a
# settings-file override. The default policy answers.
DEFAULT_RC=0
DEFAULT_CONFIG="$(cd "$TMP/whole-repo" && env -u REVIEW_GATE_SETTINGS_FILE -u REVIEW_GATE_CLASS_POLICY \
  "$WHOLE/review-gate/scripts/review-policy" --check-config 2>"$TMP/err")" || DEFAULT_RC=$?
assert_eq "$DEFAULT_RC:$DEFAULT_CONFIG" "0:review-policy=active" "with no assignment anywhere the policy is active"
DEFAULT_RC=0
DEFAULT_RECORD="$(cd "$TMP/whole-repo" && env -u REVIEW_GATE_SETTINGS_FILE -u REVIEW_GATE_CLASS_POLICY \
  "$WHOLE/review-gate/scripts/review-policy" --event pull_request --base HEAD~1 --head HEAD --repo . 2>"$TMP/err")" || DEFAULT_RC=$?
assert_eq "$DEFAULT_RC:$DEFAULT_RECORD" "0:change_class=micro review_evidence=none policy=active" \
  "and a micro diff needs no review evidence under it"

# The inverse: an explicit empty assignment is the one way to turn it off.
EMPTY_RC=0
EMPTY_CONFIG="$(cd "$TMP/whole-repo" && env -u REVIEW_GATE_SETTINGS_FILE REVIEW_GATE_CLASS_POLICY= \
  "$WHOLE/review-gate/scripts/review-policy" --check-config 2>"$TMP/err")" || EMPTY_RC=$?
assert_eq "$EMPTY_RC:$EMPTY_CONFIG" "0:review-policy=inactive" "an explicit empty assignment turns the policy off"

echo "=== --check-choice says how the repository chose its policy ==="

# One row per choice. UNSET assigns nothing in any layer, EMPTY assigns the
# empty string, and every other value is assigned as written, in the
# environment. Rows compare normalized, so the reordered and
# spaced default still reads as the default assigned.
while IFS='|' read -r label value want; do
  CHOICE_RC=0
  [ "$value" != EMPTY ] || value=""
  if [ "$value" = UNSET ]; then
    CHOICE="$(cd "$TMP/whole-repo" && env -u REVIEW_GATE_SETTINGS_FILE -u REVIEW_GATE_CLASS_POLICY \
      "$WHOLE/review-gate/scripts/review-policy" --check-choice 2>"$TMP/err")" || CHOICE_RC=$?
  else
    CHOICE="$(cd "$TMP/whole-repo" && env -u REVIEW_GATE_SETTINGS_FILE REVIEW_GATE_CLASS_POLICY="$value" \
      "$WHOLE/review-gate/scripts/review-policy" --check-choice 2>"$TMP/err")" || CHOICE_RC=$?
  fi
  assert_eq "$CHOICE_RC:$CHOICE" "$want" "$label"
done <<'ROWS'
no assignment is the default|UNSET|0:review-policy-choice=default
the default assigned|render:none;trivial:none;micro:none;small:bot;standard:current|0:review-policy-choice=default-assigned
the default assigned in another order and spacing|standard:current; small:bot;micro:none ;trivial:none;render:none|0:review-policy-choice=default-assigned
other rows are custom|render:none;trivial:none;micro:none;small:none;standard:none|0:review-policy-choice=custom
an empty assignment is off|EMPTY|0:review-policy-choice=off
ROWS

echo "=== --lock-kendex says which kendex judges the install record ==="

# UNSET assigns nothing in any layer, EMPTY assigns the empty string, and
# every other value is assigned as written, in the environment. The class
# policy column is UNSET or a value assigned the same way. A refused row
# reads the diagnostic key.
while IFS='|' read -r label value policy want; do
  LOCK_RC=0
  lock_env=(-u REVIEW_GATE_LOCK_KENDEX)
  policy_env=(-u REVIEW_GATE_CLASS_POLICY)
  [ "$value" != EMPTY ] || value=""
  [ "$value" = UNSET ] || lock_env=(REVIEW_GATE_LOCK_KENDEX="$value")
  [ "$policy" = UNSET ] || policy_env=(REVIEW_GATE_CLASS_POLICY="$policy")
  LOCK="$(cd "$TMP/whole-repo" && env -u REVIEW_GATE_SETTINGS_FILE "${policy_env[@]}" "${lock_env[@]}" \
    "$WHOLE/review-gate/scripts/review-policy" --lock-kendex 2>"$TMP/err")" || LOCK_RC=$?
  [ "$LOCK_RC" -eq 0 ] || LOCK="$(diagnostic_key)"
  assert_eq "$LOCK_RC:$LOCK" "$want" "$label"
done <<'ROWS'
no assignment leaves the install record to the pinned release|UNSET|UNSET|0:review-policy-lock-kendex=off
an empty assignment is the same|EMPTY|UNSET|0:review-policy-lock-kendex=off
main asks for the rolling main build|main|UNSET|0:review-policy-lock-kendex=main
a malformed class policy does not stand in for the lock setting|main|render:none|0:review-policy-lock-kendex=main
any other value is refused|v1.2.0|UNSET|2:policy-lock-kendex
ROWS

# Must-fail control: the verb is answered before the class policy is read.
# The mutant moves the whole dispatch, unchanged, to just after the policy
# parse, and the malformed-policy row must then read the parse's refusal.
LATE="$TMP/late"
package "$LATE" review-gate harness-ci orch
LATE_POLICY="$LATE/review-gate/scripts/review-policy"
LATE_START='if [ "${1:-}" = "--lock-kendex" ]; then'
LATE_BEFORE='if [ "${1:-}" = "--review-bots" ]; then'
assert_eq "$(grep -Fxc -- "$LATE_START" "$LATE_POLICY" || true):$(grep -Fxc -- "$LATE_BEFORE" "$LATE_POLICY" || true)" \
  "1:1" "control: the --lock-kendex dispatch and the line after the parse are there once"
if [ -L "$LATE_POLICY" ]; then
  bad "control: the mutation source must not be a symlink"
else
  # Literal whole-line matches through the environment, as the marker mutant
  # below does. The block ends at its first column-one fi.
  LATE_RC=0
  MOVE_START="$LATE_START" MOVE_BEFORE="$LATE_BEFORE" awk '
    $0 == ENVIRON["MOVE_START"] { moving = 1 }
    moving { held = held $0 "\n"; if ($0 == "fi") { moving = 0; moved++ }; next }
    $0 == ENVIRON["MOVE_BEFORE"] { printf "%s", held; placed++ }
    { print }
    END { if (moved != 1 || placed != 1) exit 1 }' "$LATE_POLICY" >"$TMP/late-policy" || LATE_RC=$?
  assert_eq "$LATE_RC:$(( $(wc -c <"$TMP/late-policy") ))" "0:$(( $(wc -c <"$LATE_POLICY") ))" \
    "control: the mutant moves the dispatch once and adds no byte"
  if cmp -s "$TMP/late-policy" "$LATE_POLICY"; then
    bad "control: the mutant must move the dispatch"
  else
    cat "$TMP/late-policy" >"$LATE_POLICY"
    LATE_RC=0
    LATE_OUT="$(cd "$TMP/whole-repo" && env -u REVIEW_GATE_SETTINGS_FILE REVIEW_GATE_CLASS_POLICY=render:none \
      REVIEW_GATE_LOCK_KENDEX=main "$LATE_POLICY" --lock-kendex 2>"$TMP/err")" || LATE_RC=$?
    [ "$LATE_RC" -eq 0 ] || LATE_OUT="$(diagnostic_key)"
    assert_eq "$LATE_RC:$LATE_OUT" "2:policy-invalid" \
      "must-fail: a dispatch behind the parse lets a malformed class policy stand in for the lock setting"
  fi
fi

echo "=== every shipped statement of the default is the default ==="

# The default review-policy prints is the reference. The shipped settings
# example must resolve to it, and README.md and references/settings.md must
# state it. Each row names a file and what it must answer; the drift rows run
# the same reader over a copy carrying other rows, and must not match.
DEFAULT="$("$WHOLE/review-gate/scripts/review-policy" --help | sed -n '/the default is:/{n;n;p;}' | sed 's/^[[:space:]]*//')"
case "$DEFAULT" in
  render:*) ;;
  *) bad "control: the default extractor read no policy from review-policy --help" "got [$DEFAULT]" ;;
esac
CUSTOM="${DEFAULT/small:bot/small:none}"
assert_eq "$([ "$CUSTOM" != "$DEFAULT" ] && echo changed || echo same)" "changed" \
  "control: the drift fixtures carry other rows than the default"

stated() { # KIND FILE — what FILE says the default is
  case "$1" in
    readme) sed -n 's/.*built-in default of `REVIEW_GATE_CLASS_POLICY`, `\([^`]*\)`.*/\1/p' "$2" ;;
    settings) sed -n 's/^| `REVIEW_GATE_CLASS_POLICY` | `\([^`]*\)` |.*/\1/p' "$2" ;;
    example)
      (cd "$TMP/whole-repo" && env -u REVIEW_GATE_CLASS_POLICY REVIEW_GATE_SETTINGS_FILE="$2" \
        "$WHOLE/review-gate/scripts/review-policy" --check-choice 2>"$TMP/err") || printf 'exit=%s' "$?" ;;
    *) printf 'unknown-kind' ;;
  esac
}
# Literal, through the environment and index/substr, as the marker mutant
# below does: a quoted replacement word in ${var/pat/rep} keeps its quotes
# under Bash 3.2, so the copy would carry text no reader was asked about.
drift() { # FILE OUT — OUT is FILE with the default replaced by other rows
  DRIFT_OLD="$DEFAULT" DRIFT_NEW="$CUSTOM" awk '
    {
      old = ENVIRON["DRIFT_OLD"]
      at = index($0, old)
      if (at) { $0 = substr($0, 1, at - 1) ENVIRON["DRIFT_NEW"] substr($0, at + length(old)) }
      print
    }' "$1" >"$2"
}
while IFS='|' read -r label kind file mode want; do
  case "$want" in DEFAULT) want="$DEFAULT" ;; CUSTOM) want="$CUSTOM" ;; esac
  path="$SKILL_DIR/$file"
  if [ "$mode" != shipped ]; then
    out="$TMP/drift.${file##*/}"
    drift "$path" "$out"
    # The copy is the original with exactly the one string swapped: no
    # default left, one custom string, and no byte added around it.
    want_bytes=$(( $(wc -c <"$path") - ${#DEFAULT} + ${#CUSTOM} ))
    assert_eq "$(grep -cF -- "$DEFAULT" "$out" || true):$(grep -cF -- "$CUSTOM" "$out" || true):$(( $(wc -c <"$out") ))" \
      "0:1:$want_bytes" "control: the drift copy of $file swaps the default for other rows and nothing else"
    path="$out"
  fi
  assert_eq "$(stated "$kind" "$path")" "$want" "$label"
done <<'ROWS'
the shipped settings example assigns the default|example|kendex.settings.toml.example|shipped|review-policy-choice=default-assigned
README.md states the default|readme|README.md|shipped|DEFAULT
references/settings.md states the default|settings|references/settings.md|shipped|DEFAULT
must-fail: an example carrying other rows is custom|example|kendex.settings.toml.example|drift|review-policy-choice=custom
must-fail: a README carrying other rows states them|readme|README.md|drift|CUSTOM
must-fail: a settings reference carrying other rows states them|settings|references/settings.md|drift|CUSTOM
ROWS

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
