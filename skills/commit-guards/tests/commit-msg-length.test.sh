#!/usr/bin/env bash
# scripts/commit-msg's subject cap: 72 characters by default, a setting
# validated like every other, waived for a git-generated header, and a count
# of CHARACTERS that reads the same in every locale a hook inherits — a
# multibyte sequence is one, a byte that belongs to no sequence is one each,
# so no malformed header walks past the cap. One table: a row feeds one
# message under the built-in settings and reads back the exit status and
# every line printed, so the shape verdict beside the length one is read too.
# The header shape itself is commit-msg.test.sh.
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

# One line for a run of the gate inside $R over a message on stdin: the exit
# status, then every printed line in order joined by ';'. ENVS is a
# comma-separated list of assignments laid over the sentinel.
judge() { # ENVS MSG
  local envs=() rc=0 out
  [ -z "$1" ] || IFS=',' read -ra envs <<<"$1"
  out="$(cd "$R" && printf '%s\n' "$2" |
    env COMMIT_GUARDS_SETTINGS_FILE=/dev/null ${envs[@]+"${envs[@]}"} "$CM" 2>&1)" || rc=$?
  printf 'rc=%s%s' "$rc" "${out:+ $(printf '%s\n' "$out" | LC_ALL=C paste -sd ';' -)}"
}

DEFAULT_TYPES="build chore ci docs feat fix perf refactor revert style test"
OK="commit-msg: OK — conventional header:"
GEN="commit-msg: git-generated header — shape and length not judged:"
shape_fail() { # HEADER-AS-SHOWN — the whole shape violation
  printf '%s' "commit-msg FAIL non-conventional header: $1;  expected: type(scope)!: subject — scope and '!' optional; types: $DEFAULT_TYPES;  scope accepts uppercase issue keys and issue numbers, e.g. fix(ABC-123): tighten the gate / fix(#123): case-fold IDs;  git-generated headers (Merge/Revert/Reapply, fixup!/squash!/amend!) pass unchanged"
}
too_long() { # HEADER COUNT MAX — the OK shape line, then the length violation
  printf '%s' "$OK $1;commit-msg FAIL header is $2 characters (max $3): $1;  move the detail into the body — the header is the one line every log shows"
}
# N copies of a string, so a fixture states the length it means instead of
# carrying a literal nobody can count.
rep() { # STRING N
  local s="$1" n="$2" i=0 out=""
  while [ "$i" -lt "$n" ]; do
    out="$out$s"
    i=$((i + 1))
  done
  printf '%s' "$out"
}

run_rows() { # label | env | message | expect
  local row label env msg expect
  for row in "$@"; do
    IFS='|' read -r label env msg expect <<<"$row"
    assert_eq "$label" "$expect" "$(judge "$env" "$msg")"
  done
}

# "fix(KEN-1): " is 12 characters, so the counts below are 12 plus the run.
H72="fix(KEN-1): $(rep x 60)"
H73="fix(KEN-1): $(rep x 61)"
H32="fix(KEN-1): $(rep x 20)"
echo "=== the cap: 72 by default, configurable, waived for a generated header ==="
run_rows \
  "a 72-character header passes||$H72|rc=0 $OK $H72" \
  "73 fails after the shape verdict, naming the count, the cap and the remedy||$H73|rc=1 $(too_long "$H73" 73 72)" \
  "a long Merge header is exempt from the cap||Merge $(rep x 90)|rc=0 $GEN Merge $(rep x 90)" \
  "a long fixup! header is exempt too||fixup! $H73 $(rep x 20)|rc=0 $GEN fixup! $H73 $(rep x 20)" \
  "a raised cap admits the 73|COMMIT_GUARDS_SUBJECT_MAX=100|$H73|rc=0 $OK $H73" \
  "a lowered cap refuses a header the default admits|COMMIT_GUARDS_SUBJECT_MAX=20|$H32|rc=1 $(too_long "$H32" 32 20)" \
  "a cap that is not a positive integer is exit 2|COMMIT_GUARDS_SUBJECT_MAX=0|fix: x|rc=2 ::error::commit-msg: COMMIT_GUARDS_SUBJECT_MAX must be a positive integer, got '0'" \
  "one run names both the shape and the length, never the first alone|COMMIT_GUARDS_SUBJECT_MAX=20|$(rep q 90)|rc=1 $(shape_fail "$(rep q 90)");commit-msg FAIL header is 90 characters (max 20): $(rep q 90);  move the detail into the body — the header is the one line every log shows"

# Characters, not bytes, whatever locale the committer's shell carries: a git
# hook inherits that environment, so a header measured in bytes would be
# accepted in one shell and refused in another. C and C.UTF-8 are what the
# hosts this suite runs on carry.
MULTI="fix(KEN-1): $(rep 'é' 55)"      # 67 characters, 122 bytes
MULTI_OVER="fix(KEN-1): $(rep 'é' 61)" # 73 characters
echo "=== the count is characters in every locale ==="
run_rows \
  "a 67-character multibyte header passes under C|LC_ALL=C|$MULTI|rc=0 $OK $MULTI" \
  "a 67-character multibyte header passes under C.UTF-8|LC_ALL=C.UTF-8|$MULTI|rc=0 $OK $MULTI" \
  "73 of them is 73 characters under C, not the byte count|LC_ALL=C|$MULTI_OVER|rc=1 $(too_long "$MULTI_OVER" 73 72)" \
  "73 of them is 73 characters under C.UTF-8|LC_ALL=C.UTF-8|$MULTI_OVER|rc=1 $(too_long "$MULTI_OVER" 73 72)"

# Bytes with no character count: a stray continuation byte, an overlong
# form, a surrogate encoding, a lead byte past the last code point. Each
# byte costs one, so a run of them can never read as almost nothing — the
# control is the same count of well-formed sequences, which is that count.
STRAY="fix: $(rep "$(printf '\277')" 200)"
OVERLONG="fix: $(rep "$(printf '\340\200\200')" 30)"
SURROGATE="fix: $(rep "$(printf '\355\240\200')" 30)"
OUT_OF_RANGE="fix: $(rep "$(printf '\364\220\200\200')" 30)"
DASHES="fix: $(rep "$(printf '\342\200\224')" 30)"
echo "=== a byte that belongs to no sequence costs one, never nothing ==="
run_rows \
  "200 stray continuation bytes are 205 characters||$STRAY|rc=1 $(too_long "$STRAY" 205 72)" \
  "30 overlong forms are 95 characters||$OVERLONG|rc=1 $(too_long "$OVERLONG" 95 72)" \
  "30 surrogate encodings are 95 characters||$SURROGATE|rc=1 $(too_long "$SURROGATE" 95 72)" \
  "30 out-of-range sequences are 125 characters||$OUT_OF_RANGE|rc=1 $(too_long "$OUT_OF_RANGE" 125 72)" \
  "control: 30 well-formed three-byte sequences are 35 characters and pass||$DASHES|rc=0 $OK $DASHES"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
