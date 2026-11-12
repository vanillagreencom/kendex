#!/usr/bin/env bash
# scripts/commit-msg reading one message: the line that IS the header, where
# [no-changelog] is read, and the argv the hook contract passes. Every row
# stages a change that owes a changelog entry, so the waiver is the proof of
# which text the gate read. One table per family: a row feeds one message and
# reads back the exit status and every line printed. The settings a hook lane
# reads are commit-msg-settings.test.sh, the changelog owed is
# commit-msg-changelog.test.sh.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
CM="$SKILL_DIR/scripts/commit-msg"
# shellcheck source=lib/harness.bash
. "$TEST_DIR/lib/harness.bash"
ROOT="$TMP"

unset COMMIT_GUARDS_CHANGELOG_REQUIRED_PATHS COMMIT_GUARDS_CHANGELOG_PATHS \
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

# One staged change under the required path and no fragment, so every row's
# verdict turns on the header alone; the sentinel keeps every other setting
# built in, and one repository serves every row.
R="$ROOT/repo"
mkdir -p "$R/src"
git -C "$R" -c init.defaultBranch=main init -q
printf 'fn a() {}\n' >"$R/src/a.rs"
git -C "$R" add src/a.rs
mkdir -p "$ROOT/cat-shim"
printf '#!/usr/bin/env bash\nif [ "${1:-}" = -- ] && [ "${2:-}" = %q ]; then echo "dependency-order-control: message-read" >&2; exit 9; fi\nexec %q "$@"\n' "$ROOT/msg" "$(command -v cat)" >"$ROOT/cat-shim/cat"
chmod +x "$ROOT/cat-shim/cat"

# One line for a run of the gate inside $R: the exit status, then every
# printed line in order joined by ';' with the scratch root aliased. ENVS
# is a comma-separated list of assignments laid over the sentinel, <root>
# and <path> in one standing for the scratch root and the caller's PATH.
# ARGS is the argv, where @MSG@ stands for a file holding the message, the
# way the hook passes it, and <root> for the scratch root; an empty ARGS or
# a '-' feeds the message on stdin, and any other ARGS gets a different
# message there, so a gate reading stdin instead of the file reddens the
# row. MSG carries %b escapes and gets the trailing newline git leaves on a
# message file.
judge() { # ENVS ARGS MSG
  local envs=() args=() argv rc=0 out i stdin="$3"
  [ -z "$1" ] || IFS=',' read -ra envs <<<"${1//<root>/$ROOT}"
  for i in "${!envs[@]}"; do envs[i]="${envs[i]//<path>/$PATH}"; done
  if [ -n "$2" ]; then
    printf '%b\n' "$3" >"$ROOT/msg"
    [ "$2" = "-" ] || stdin='feat: the stdin message, not the file'
    argv="${2//@MSG@/$ROOT/msg}"
    IFS=' ' read -ra args <<<"${argv//<root>/$ROOT}"
  fi
  out="$(cd "$R" && printf '%b\n' "$stdin" |
    env COMMIT_GUARDS_SETTINGS_FILE=/dev/null COMMIT_GUARDS_CHANGELOG_REQUIRED_PATHS='src/*' ${envs[@]+"${envs[@]}"} "$CM" ${args[@]+"${args[@]}"} 2>&1)" || rc=$?
  out="${out//"$ROOT"/<root>}"
  out="$(printf '%s\n' "$out" | LC_ALL=C awk '
    /^commit-msg: [a-z-]+=/ { print; next }
    /^[[:space:]]*dependency-order-control:/ { sub(/^[[:space:]]*/, ""); print }
  ')"
  printf 'rc=%s%s' "$rc" "${out:+ $(printf '%s\n' "$out" | LC_ALL=C paste -sd ';' -)}"
}

WAIVED="commit-msg: changelog-waived=src/a.rs"
MISSING="commit-msg: changelog-missing=src/a.rs:changelog.d/*/*.md"

run_rows() { # label | env | args | message | expect
  local row label env args msg expect
  for row in "$@"; do
    IFS='|' read -r label env args msg expect <<<"$row"
    assert_eq "$label" "$expect" "$(judge "$env" "$args" "$msg")"
  done
}

echo "=== the header is the first line that is neither blank nor a comment ==="
run_rows \
  "the header of a multi-line message carries the waiver|||feat: subject line [no-changelog]\n\nbody paragraph|rc=0 $WAIVED" \
  "a waiver in the body is not the header's|||feat: subject line\n\nbody [no-changelog]|rc=1 $MISSING" \
  "comment and blank lines before the header are skipped|||# comment from the template\n\nfeat: subject after comments [no-changelog]|rc=0 $WAIVED" \
  "control: a waiver in a comment line is not the header's|||# [no-changelog] from the template\n\nfeat: subject after comments|rc=1 $MISSING" \
  "a CRLF message's blank line is blank, so the header follows it|||\r\nfeat: crlf subject [no-changelog]\r|rc=0 $WAIVED" \
  "an empty message waives nothing||||rc=1 $MISSING"

echo "=== the argv the hook contract passes ==="
run_rows \
  "a message FILE is read whole, the way the hook passes it||@MSG@|# from the template\n\nfix(VST-214): ship the check family [no-changelog]|rc=0 $WAIVED" \
  "'-' names stdin||-|fix(cli): read from the dash [no-changelog]|rc=0 $WAIVED" \
  "a message read failure puts the stable record before cat's cause|PATH=<root>/cat-shim:<path>|@MSG@|fix: unread|rc=2 commit-msg: message-read=<root>/msg;dependency-order-control: message-read" \
  "a missing message file is exit 2, never a pass||<root>/no-such-msg|fix: unread|rc=2 commit-msg: message-missing=<root>/no-such-msg" \
  "two positional arguments are exit 2||@MSG@ extra|fix: two files|rc=2 commit-msg: message-extra=extra" \
  "an unknown flag is exit 2||--bogus|fix: flagged|rc=2 commit-msg: argument-unknown=--bogus"
usage="$(judge "" --help 'fix: x')"
assert_eq "--help emits its usage record and exits 0" "rc=0 commit-msg: usage=commit-msg" "${usage%%;*}"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
