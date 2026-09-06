#!/usr/bin/env bash
# scripts/commit-msg over the header of one message: the conventional shape
# in both directions, the git-generated headers that stand aside from it, the
# line that IS the header, the argv the hook contract passes, the type list
# as configuration, and every quoted header reaching the reader scrubbed. One
# table per family: a row feeds one message under the built-in settings and
# reads back the exit status and every line printed. The cap is
# commit-msg-length.test.sh, the settings a hook lane reads are
# commit-msg-settings.test.sh, the changelog owed is
# commit-msg-changelog.test.sh.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
CM="$SKILL_DIR/scripts/commit-msg"
# shellcheck source=lib/harness.bash
. "$TEST_DIR/lib/harness.bash"
ROOT="$TMP"

unset COMMIT_GUARDS_COMMIT_TYPES COMMIT_GUARDS_SUBJECT_MAX \
  COMMIT_GUARDS_CHANGELOG_REQUIRED_PATHS COMMIT_GUARDS_CHANGELOG_PATHS \
  COMMIT_GUARDS_CHANGELOG_RECORD COMMIT_GUARDS_SETTINGS_FILE 2>/dev/null || true

PASS=0
FAIL=0
assert_eq() { # LABEL EXPECT ACTUAL
  if [ "$2" = "$3" ]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$1"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        want: %s\n        got:  %s\n' "$1" "$2" "$3"
  fi
}

# A neutral world: no rule here reads a commit, and the sentinel keeps every
# run on the built-in settings, so one repository serves every row.
R="$ROOT/repo"
mkdir -p "$R"
git -C "$R" -c init.defaultBranch=main init -q

# One line for a run of the gate inside $R: the exit status, then every
# printed line in order joined by ';' with the scratch root aliased. ENVS
# is a comma-separated list of assignments laid over the sentinel. ARGS is
# the argv, where @MSG@ stands for a file holding the message, the way the
# hook passes it, and <root> for the scratch root; an empty ARGS feeds the
# message on stdin. MSG carries %b escapes and gets the trailing newline git
# leaves on a message file.
judge() { # ENVS ARGS MSG
  local envs=() args=() argv rc=0 out
  [ -z "$1" ] || IFS=',' read -ra envs <<<"$1"
  if [ -n "$2" ]; then
    printf '%b\n' "$3" >"$ROOT/msg"
    argv="${2//@MSG@/$ROOT/msg}"
    IFS=' ' read -ra args <<<"${argv//<root>/$ROOT}"
  fi
  out="$(cd "$R" && printf '%b\n' "$3" |
    env COMMIT_GUARDS_SETTINGS_FILE=/dev/null ${envs[@]+"${envs[@]}"} "$CM" ${args[@]+"${args[@]}"} 2>&1)" || rc=$?
  out="${out//"$ROOT"/<root>}"
  printf 'rc=%s%s' "$rc" "${out:+ $(printf '%s\n' "$out" | LC_ALL=C paste -sd ';' -)}"
}

DEFAULT_TYPES="build chore ci docs feat fix perf refactor revert style test"
OK="commit-msg: OK — conventional header:"
GEN="commit-msg: git-generated header — shape and length not judged:"
shape_fail() { # HEADER-AS-SHOWN [TYPES] — the whole shape violation
  printf '%s' "commit-msg FAIL non-conventional header: $1;  expected: type(scope)!: subject — scope and '!' optional; types: ${2:-$DEFAULT_TYPES};  scope accepts uppercase issue keys and issue numbers, e.g. fix(ABC-123): tighten the gate / fix(#123): case-fold IDs;  git-generated headers (Merge/Revert/Reapply, fixup!/squash!/amend!) pass unchanged"
}
LEN_TAIL=";  move the detail into the body — the header is the one line every log shows"
ESC="$(printf '\033')"
BADBYTES="$(printf 'fix: \377\376 bad bytes')"

run_rows() { # label | env | args | message | expect
  local row label env args msg expect
  for row in "$@"; do
    IFS='|' read -r label env args msg expect <<<"$row"
    assert_eq "$label" "$expect" "$(judge "$env" "$args" "$msg")"
  done
}

echo "=== the conventional shape, and every header outside it ==="
run_rows \
  "a bare type|||feat: add the gate|rc=0 $OK feat: add the gate" \
  "a lowercase scope|||fix(cli): repair the trailing newline|rc=0 $OK fix(cli): repair the trailing newline" \
  "MUST: an uppercase issue key in the scope|||fix(ABC-123): tighten the gate|rc=0 $OK fix(ABC-123): tighten the gate" \
  "an issue-number scope|||fix(#123): case-fold open-terminal issue IDs|rc=0 $OK fix(#123): case-fold open-terminal issue IDs" \
  "the breaking-change marker|||feat(api)!: drop the legacy endpoint|rc=0 $OK feat(api)!: drop the legacy endpoint" \
  "a multi-part scope with a comma and a space|||chore(deps, ci): bump the runner image|rc=0 $OK chore(deps, ci): bump the runner image" \
  "a slashed scope|||refactor(tui/render): split the paint pass|rc=0 $OK refactor(tui/render): split the paint pass" \
  "a bare imperative subject fails, and the diagnostic names the shape, the types and the key example|||Add stuff|rc=1 $(shape_fail 'Add stuff')" \
  "an uppercase type|||Feat: uppercase type|rc=1 $(shape_fail 'Feat: uppercase type')" \
  "a missing colon|||feat add the gate|rc=1 $(shape_fail 'feat add the gate')" \
  "no space after the colon|||feat:no space after colon|rc=1 $(shape_fail 'feat:no space after colon')" \
  "an empty subject|||feat: |rc=1 $(shape_fail 'feat: ')" \
  "an unknown type|||wip: not a known type|rc=1 $(shape_fail 'wip: not a known type')" \
  "empty scope parentheses|||feat(): empty scope|rc=1 $(shape_fail 'feat(): empty scope')"

echo "=== git-generated headers pass unchanged (MUST) ==="
run_rows \
  "Merge|||Merge branch feature into main|rc=0 $GEN Merge branch feature into main" \
  "Revert|||Revert \"feat: add the gate\"|rc=0 $GEN Revert \"feat: add the gate\"" \
  "Reapply|||Reapply \"feat: add the gate\"|rc=0 $GEN Reapply \"feat: add the gate\"" \
  "fixup!|||fixup! fix(cli): repair the newline|rc=0 $GEN fixup! fix(cli): repair the newline" \
  "squash!|||squash! fix(cli): repair the newline|rc=0 $GEN squash! fix(cli): repair the newline" \
  "amend!|||amend! fix(cli): repair the newline|rc=0 $GEN amend! fix(cli): repair the newline"

echo "=== the header is the first line that is neither blank nor a comment ==="
run_rows \
  "only the header of a multi-line message is judged|||feat: subject line\n\nbody paragraph\nmore body|rc=0 $OK feat: subject line" \
  "comment and blank lines before the header are skipped|||# comment from the template\n\nfeat: subject after comments|rc=0 $OK feat: subject after comments" \
  "an empty message is its own violation||||rc=1 commit-msg FAIL empty commit message (no non-comment content)" \
  "a CRLF header is stripped before matching|||feat: crlf subject\r|rc=0 $OK feat: crlf subject"

echo "=== the argv the hook contract passes ==="
run_rows \
  "a message FILE is read the way the hook passes it||@MSG@|fix(VST-214): ship the check family|rc=0 $OK fix(VST-214): ship the check family" \
  "'-' names stdin||-|fix(cli): read from the dash|rc=0 $OK fix(cli): read from the dash" \
  "a missing message file is exit 2, never a pass||<root>/no-such-msg|fix: unread|rc=2 ::error::commit-msg: no such message file: <root>/no-such-msg" \
  "two positional arguments are exit 2||@MSG@ extra|fix: two files|rc=2 ::error::commit-msg: at most one message file (see --help)" \
  "an unknown flag is exit 2||--bogus|fix: flagged|rc=2 ::error::commit-msg: unknown argument --bogus (see --help)"

echo "=== the type list is configuration, and it is validated ==="
run_rows \
  "a custom list admits its types|COMMIT_GUARDS_COMMIT_TYPES=feat release||release: cut 2.6.6|rc=0 $OK release: cut 2.6.6" \
  "control: the custom list rejects everything else, and the diagnostic names that list|COMMIT_GUARDS_COMMIT_TYPES=feat release||fix: no longer a type|rc=1 $(shape_fail 'fix: no longer a type' 'feat release')" \
  "a non-lowercase entry is exit 2|COMMIT_GUARDS_COMMIT_TYPES=Feat||feat: x|rc=2 ::error::commit-msg: COMMIT_GUARDS_COMMIT_TYPES entry 'Feat' is not a lowercase type name" \
  "an empty list is exit 2|COMMIT_GUARDS_COMMIT_TYPES= ||feat: x|rc=2 ::error::commit-msg: COMMIT_GUARDS_COMMIT_TYPES resolved empty — at least one type is required"

# The scope class is ASCII in every surface that documents it, and a bracket
# range is a COLLATION range under a UTF-8 locale, which is the one thing
# that could admit an accented scope. C and C.UTF-8 are what the hosts this
# suite runs on carry: the rows prove the verdict does not vary across them.
# Bytes that are not UTF-8 at all sit in the subject, whose class is "not
# whitespace", which they are.
echo "=== the shape verdict is the same in every locale a hook inherits ==="
run_rows \
  "an accented scope is outside the documented class under C|LC_ALL=C||fix(café): tighten the gate|rc=1 $(shape_fail 'fix(café): tighten the gate')" \
  "an accented scope is outside the documented class under C.UTF-8|LC_ALL=C.UTF-8||fix(café): tighten the gate|rc=1 $(shape_fail 'fix(café): tighten the gate')" \
  "control: the same scope in ASCII passes under C|LC_ALL=C||fix(cafe): tighten the gate|rc=0 $OK fix(cafe): tighten the gate" \
  "control: the same scope in ASCII passes under C.UTF-8|LC_ALL=C.UTF-8||fix(cafe): tighten the gate|rc=0 $OK fix(cafe): tighten the gate" \
  "a subject carrying invalid UTF-8 passes under C|LC_ALL=C||$BADBYTES|rc=0 $OK $BADBYTES" \
  "a subject carrying invalid UTF-8 passes under C.UTF-8|LC_ALL=C.UTF-8||$BADBYTES|rc=0 $OK $BADBYTES"

# A commit object carries whatever bytes were written into it, and a
# generated revert or fixup header carries a subject copied out of history
# nobody here reviewed. An ESC handed on raw would repaint the reader's
# terminal or forge a second diagnostic line under this hook's own name, so
# every line that quotes the header shows the byte as a replacement in place.
echo "=== every quoted header reaches the reader scrubbed, never raw ==="
run_rows \
  "the OK line shows a control byte as a replacement, in place|||fix: a subject with ${ESC}[31m in it|rc=0 $OK fix: a subject with ?[31m in it" \
  "the shape violation quotes the header scrubbed|||no type here ${ESC}[31m at all|rc=1 $(shape_fail 'no type here ?[31m at all')" \
  "the length violation quotes it scrubbed|COMMIT_GUARDS_SUBJECT_MAX=5||fix: a subject with ${ESC}[31m in it|rc=1 $OK fix: a subject with ?[31m in it;commit-msg FAIL header is 31 characters (max 5): fix: a subject with ?[31m in it$LEN_TAIL" \
  "the generated-header notice quotes it scrubbed too|||Revert \"fix: a subject with ${ESC}[31m in it\"|rc=0 $GEN Revert \"fix: a subject with ?[31m in it\""

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
