#!/usr/bin/env bash
# json-error: every command refusal that carries a caller's value prints its
# stderr through `github_error` (scripts/lib/json-error.sh), so the line stays
# one JSON object whatever the value holds. A wrapper reads that stderr with
# jq; a refusal built by interpolating the value into the JSON text turns a
# double quote or a backslash into a parse failure that hides the refusal.
#
# A row is `label^script^want^argv...`, fields separated by `^`:
#   script  the command under scripts/commands/, without `.sh`
#   want    the refusal's `.error`, exactly
#   argv    the command's arguments, one per field
# Each row's value carries a double quote, and the --body-file rows a
# backslash too. The row passes when the command exits 1 and its stderr is
# exactly one `{"error": want}` object.
set -euo pipefail

# A suite running from inside a git hook inherits GIT_DIR, GIT_COMMON_DIR,
# GIT_WORK_TREE and GIT_INDEX_FILE, which take precedence over `git -C` and
# would configure the real repository.
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
COMMANDS="$REPO_ROOT/skills/github/scripts/commands"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT
PASS=0
FAIL=0

assert_eq() {
  local got="$1" want="$2" label="$3"
  if [[ "$got" == "$want" ]]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$label"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        want: %s\n        got:  %s\n' "$label" "$want" "$got"
  fi
}

# The lib derives PROJECT_ROOT through git at source time, so the working
# directory is a repository; gh is the staged fake.
mkdir -p "$TMP_ROOT/repo" "$TMP_ROOT/bin"
git -C "$TMP_ROOT/repo" init -q
# The EXIT trap removes this tree, so git's background writer is disabled at
# creation rather than left to race the removal.
git -C "$TMP_ROOT/repo" config gc.auto 0
git -C "$TMP_ROOT/repo" config maintenance.auto false
# shellcheck source=lib/gh-stub.sh
. "$TEST_DIR/lib/gh-stub.sh"
GH_STUB_DIR="$TMP_ROOT/gh-stub" gh_stub_install "$TMP_ROOT/bin"

# A PR lookup that finds nothing: the answer both the branch-name resolver and
# await-mergeable's existence check refuse on.
gh_stub_fail pr-view 1 'no pull requests found'

MISSING="$TMP_ROOT/no\"such\\file"

# Each surplus-positional row fills the positionals its command accepts before
# the one it refuses.
ROWS="\
post-reply surplus positional^post-reply^Unexpected argument: no\"^PRRT_abc^body^no\"
post-reply unreadable body file^post-reply^--body-file path not readable: $MISSING^PRRT_abc^--body-file^$MISSING
post-comment surplus positional^post-comment^Unexpected argument: no\"^23^body^no\"
post-comment unreadable body file^post-comment^--body-file path not readable: $MISSING^23^--body-file^$MISSING
find-comment surplus positional^find-comment^Unexpected argument: no\"^23^no\"
resolve-thread malformed thread id^resolve-thread^Invalid thread ID: no\" (must start with PRRT_)^no\"
unresolve-thread malformed thread id^unresolve-thread^Invalid thread ID: no\" (must start with PRRT_)^no\"
dismiss-review unknown argument^dismiss-review^Unknown argument: no\"^no\"
await-mergeable missing PR^await-mergeable^PR #1\" not found^1\"
pr-data unknown option^pr-data^Unknown option: --no\"^--no\"
pr-data surplus positional^pr-data^Unexpected argument: no\"^23^no\"
pr-data unknown format^pr-data^Invalid format: no\". Use: safe, raw^--format^no\"
pr-threads unknown option^pr-threads^Unknown option: --no\"^--no\"
pr-threads surplus positional^pr-threads^Unexpected argument: no\"^23^no\"
pr-threads unknown format^pr-threads^Invalid format: no\". Use: safe, raw^--format^no\"
pr-threads branch with no PR^pr-threads^No PR found for: no\"^no\"
"

echo "=== a refusal carrying a quoted value stays one JSON object ==="
before=$((PASS + FAIL))
while IFS= read -r row; do
  [[ "$row" != "" ]] || continue
  IFS='^' read -r -a fields <<<"$row"
  [[ "${#fields[@]}" -ge 4 ]] || {
    printf 'a row with no argv asserts nothing: %s\n' "$row" >&2
    exit 1
  }
  label="${fields[0]}" script="${fields[1]}" want="${fields[2]}"
  rc=0
  (cd "$TMP_ROOT/repo" && PATH="$TMP_ROOT/bin:$PATH" env -u GH_TOKEN -u GITHUB_TOKEN -u GH_BOT_TOKEN -u GH_REPO \
    "$COMMANDS/$script.sh" "${fields[@]:3}" >/dev/null 2>"$TMP_ROOT/stderr") || rc=$?
  # Slurped, so a second line or a second object fails the row as surely as
  # an unparseable one.
  got="rc=$rc $(jq -sc '.' <"$TMP_ROOT/stderr" 2>/dev/null ||
    printf 'unparseable: %s' "$(paste -s -d ';' - <"$TMP_ROOT/stderr")")"
  assert_eq "$got" "rc=1 $(jq -nc --arg e "$want" '[{error: $e}]')" "$label"
done <<<"$ROWS"
[[ "$((PASS + FAIL))" -gt "$before" ]] || {
  echo "no row was asserted" >&2
  exit 2
}

echo
echo "json-error: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
