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
drift() { # FILE OUT — OUT is a copy of FILE with the default replaced by other rows
  local content
  content="$(cat -- "$1")"
  printf '%s\n' "${content/"$DEFAULT"/"$CUSTOM"}" >"$2"
}
while IFS='|' read -r label kind file mode want; do
  case "$want" in DEFAULT) want="$DEFAULT" ;; CUSTOM) want="$CUSTOM" ;; esac
  path="$SKILL_DIR/$file"
  if [ "$mode" != shipped ]; then
    drift "$path" "$TMP/drift.${file##*/}"
    if cmp -s -- "$path" "$TMP/drift.${file##*/}"; then
      bad "control: the drift copy of $file kept the default"
    fi
    path="$TMP/drift.${file##*/}"
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

printf '\npass: %d   fail: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
