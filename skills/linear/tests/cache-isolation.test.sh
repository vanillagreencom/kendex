#!/usr/bin/env bash
# Regression for kendex#799: a test suite could not point the scripts at a
# cache of its own, so every suite that created a comment or completed an issue
# wrote its fixture identifiers into the developer's real .cache/linear.
# Entering a throwaway repo was the only isolation that worked, and PROJECT_ROOT
# cannot substitute for one — common.sh assigns it from `git rev-parse` on every
# source, so a caller's value never survives. LINEAR_CACHE_ROOT is the redirect,
# read before anything derived from where the process is standing.
#
# Locks in:
#   A. LINEAR_CACHE_ROOT outranks the repository the process is standing in;
#   B. with it unset the git root still decides, so the redirect adds a channel
#      rather than replacing one;
#   C. a value naming no directory is refused, not quietly ignored — falling
#      back would put the caller's fixtures in the real cache, the exact
#      failure the redirect exists to prevent;
#   D. a comment write leaves no lock file beside the issue it wrote, so a
#      cache stops accruing one permanent .lock per issue ever commented on;
#   E. lib/assert.sh redirects every suite that sources it, and its verdict
#      refuses a suite that ends with the redirect pointing anywhere else.
#
# Fully offline: curl is stubbed on PATH, no network.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/assert.sh
source "$SCRIPT_DIR/lib/assert.sh"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
assert_tmpdir TMP_ROOT

# Two project roots, each a git repo with its own cache holding one issue the
# other does not. Which issue a read finds is therefore the whole answer to
# "which root did the scripts resolve".
PROJ="$TMP_ROOT/proj"
ELSEWHERE="$TMP_ROOT/elsewhere"

seed_root() { # seed_root <root> <identifier>
  local root="$1" id="$2"
  mkdir -p "$root/.cache/linear/comments"
  git -C "$root" init -q -b main
  printf '{"synced_at":"2026-08-29T00:00:00+00:00"}\n' >"$root/.cache/linear/meta.json"
  jq -n --arg id "$id" '[{
    id: ("uuid-" + $id), identifier: $id, title: $id, description: "",
    state: {name: "Todo", type: "unstarted"}, labels: {nodes: []},
    project: null, parent: null, projectMilestone: null, cycle: null,
    relations: {nodes: []}, inverseRelations: {nodes: []},
    archivedAt: null, trashed: false
  }]' >"$root/.cache/linear/issues.json"
}

mkdir -p "$PROJ" "$ELSEWHERE" "$TMP_ROOT/bin"
seed_root "$PROJ" CC-1
seed_root "$ELSEWHERE" CC-2

LINEAR="$SKILL_DIR/scripts/linear.sh"

# read_from <cache-root-or-empty> <identifier> — read one issue while standing
# in $PROJ. An empty first argument runs with LINEAR_CACHE_ROOT unset.
read_from() {
  local root="$1" id="$2"
  if [[ -z "$root" ]]; then
    (cd "$PROJ" && env -u LINEAR_CACHE_ROOT bash "$LINEAR" cache issues get "$id" --format=safe)
  else
    (cd "$PROJ" && LINEAR_CACHE_ROOT="$root" bash "$LINEAR" cache issues get "$id" --format=safe)
  fi
}

# --- A. the redirect outranks the repository the process stands in ----------

run_output OUT rc read_from "$ELSEWHERE" CC-2
assert_eq "a read redirected by LINEAR_CACHE_ROOT exits zero" "$rc" 0
assert_jq "LINEAR_CACHE_ROOT outranks the repository the process is standing in" \
  "$OUT" '.identifier == "CC-2"'

run_output OUT rc read_from "$ELSEWHERE" CC-1 2>/dev/null
assert_eq "the standing repository's own cache is not consulted as well" "$OUT" ""

# --- B. unset, the git root still decides -----------------------------------

run_output OUT rc read_from "" CC-1
assert_eq "an unredirected read exits zero" "$rc" 0
assert_jq "with LINEAR_CACHE_ROOT unset the cache still comes from the git root" \
  "$OUT" '.identifier == "CC-1"'

# --- C. a root that names no directory is refused ---------------------------

MISSING="$TMP_ROOT/no-such-root"
ERR_FILE="$TMP_ROOT/err"
refuse() { (cd "$PROJ" && LINEAR_CACHE_ROOT="$1" bash "$LINEAR" cache issues get CC-1 --format=safe); }
run_output OUT rc refuse "$MISSING" 2>"$ERR_FILE"

assert_ne "a LINEAR_CACHE_ROOT naming no directory fails the command" "$rc" 0
assert_file_contains "the refusal names the variable and the path it was given" \
  "$ERR_FILE" "LINEAR_CACHE_ROOT is not an existing directory: $MISSING"
assert_eq "a refused read serves nothing from the standing repository's cache" "$OUT" ""

# Set but empty is the same answer. It reads as absent to a `-n` test, which
# would drop through to the git root and write the caller's fixtures into the
# real cache, and the exit verdict below already treats it as a suite that let
# the redirect go — the two sides of the contract have to agree.
run_output OUT rc refuse "" 2>"$ERR_FILE"

assert_ne "an empty LINEAR_CACHE_ROOT fails the command rather than reading as unset" "$rc" 0
assert_file_contains "the refusal names the empty path it was given" \
  "$ERR_FILE" "LINEAR_CACHE_ROOT is not an existing directory: "
assert_eq "an empty root serves nothing from the standing repository's cache" "$OUT" ""

# --- D. a comment write leaves no lock file beside the issue ----------------

# All three single-comment write-through helpers take the shared lock, so all
# three are driven: cache_append_comment, cache_update_comment and
# cache_delete_comment. Reverting any one of them to a per-issue lock file has
# to redden here, or the accumulating .lock files come back through whichever
# path was left uncovered. Each create is answered with a comment id naming its
# issue, so the update and the delete below address a known one.
cat >"$TMP_ROOT/bin/curl" <<'SH'
#!/usr/bin/env bash
payload="$(sed -n 's/^data = //p' <(cat) | jq -r)"
query="$(jq -r '.query' <<<"$payload")"
emit() { printf '%s___HTTP_CODE___200' "$1"; }
comment() { # comment <id> <issue-identifier> <body>
  printf '{"id":"%s","body":"%s","createdAt":"2026-08-29T00:00:00Z","updatedAt":"2026-08-29T00:00:00Z","user":{"name":"Test"},"issue":{"identifier":"%s","updatedAt":"2026-08-29T00:00:00Z"}}' \
    "$1" "$3" "$2"
}
case "$query" in
*CreateComment*)
  issue="$(jq -r '.variables.input.issueId' <<<"$payload")"
  emit "{\"data\":{\"commentCreate\":{\"success\":true,\"comment\":$(comment "c-$issue" "$issue" written)}}}" ;;
*UpdateComment*)
  id="$(jq -r '.variables.id' <<<"$payload")"
  emit "{\"data\":{\"commentUpdate\":{\"success\":true,\"comment\":$(comment "$id" "${id#c-}" edited)}}}" ;;
*DeleteComment*)
  emit '{"data":{"commentDelete":{"success":true}}}' ;;
*)
  emit '{"errors":[{"message":"unexpected query"}]}' ;;
esac
SH
chmod +x "$TMP_ROOT/bin/curl"

run_comments() { # run_comments <args...>
  (cd "$PROJ" && PATH="$TMP_ROOT/bin:$PATH" LINEAR_CACHE_ROOT="$PROJ" \
    LINEAR_API_KEY_OVERRIDE=test-token LINEAR_TEAM=TestTeam \
    bash "$LINEAR" comments "$@")
}

COMMENTS_DIR="$PROJ/.cache/linear/comments"
assert_no_issue_locks() { # assert_no_issue_locks <what-just-ran>
  assert_eq "no lock file is left beside an issue's comment file after $1" \
    "$(find "$COMMENTS_DIR" -name '*.lock' | LC_ALL=C sort | tr '\n' ' ')" ""
}

run_output OUT rc run_comments create CC-1 --body "written by the isolation suite"
assert_eq "a mocked comment create exits zero" "$rc" 0
run_output OUT rc run_comments create CC-2 --body "written by the isolation suite"
assert_eq "a second comment create, on another issue, exits zero" "$rc" 0
assert "the comment reached the redirected cache" test -f "$COMMENTS_DIR/CC-1.json"
assert_no_issue_locks "comments create"

run_output OUT rc run_comments update c-CC-1 --body edited
assert_eq "a mocked comment update exits zero" "$rc" 0
assert_eq "the update reached the cached comment" \
  "$(jq -r '.[0].body' "$COMMENTS_DIR/CC-1.json")" "edited"
assert_no_issue_locks "comments update"

run_output OUT rc run_comments delete c-CC-2
assert_eq "a mocked comment delete exits zero" "$rc" 0
assert_eq "the delete reached the cached comment" \
  "$(jq -r 'length' "$COMMENTS_DIR/CC-2.json")" "0"
assert_no_issue_locks "comments delete"

assert "the one shared comment lock lives above the per-issue files" \
  test -f "$PROJ/.cache/linear/.comments.lock"

# --- E. the assert lib redirects every suite, and refuses one that leaves ---

# Three child suites, each a suite in its own right. One does nothing but
# assert and must land in scratch it did not have to ask for; one throws the
# redirect away and one aims it at a root it does not own, and both must fail
# the verdict.
write_child() { # write_child <path> <body>
  cat >"$1" <<CHILD
#!/usr/bin/env bash
set -euo pipefail
source "$SCRIPT_DIR/lib/assert.sh"
$2
CHILD
}

# Each child records the root it was given and drops a file in it, so the
# parent can check afterwards that the root was scratch and that it went away —
# the lock files a cache write leaves behind go with it.
child_body='printf "%s\n" "${LINEAR_CACHE_ROOT:-<unset>}" >"CHILD_ROOT_FILE"
: >"${LINEAR_CACHE_ROOT:-.}/.cache/linear/comments/.probe.lock"'

write_child "$TMP_ROOT/child-default.test.sh" \
  "assert_eq \"the child asserts something\" 1 1
${child_body//CHILD_ROOT_FILE/$TMP_ROOT/child-root}"

run_status rc bash "$TMP_ROOT/child-default.test.sh" >/dev/null 2>&1
CHILD_ROOT="$(cat "$TMP_ROOT/child-root" 2>/dev/null || true)"

assert_eq "a suite that asks for nothing still passes" "$rc" 0
assert_ne "a suite that asks for nothing is redirected somewhere" "$CHILD_ROOT" "<unset>"
assert_not "the redirected root, and the lock file left in it, are gone at exit" \
  test -e "$CHILD_ROOT"

# Same again, but the child fails an assertion: cleanup must not be something
# only a passing suite gets.
write_child "$TMP_ROOT/child-failing.test.sh" \
  "assert_eq \"the child fails on purpose\" 1 2
${child_body//CHILD_ROOT_FILE/$TMP_ROOT/failing-root}"

run_status rc bash "$TMP_ROOT/child-failing.test.sh" >/dev/null 2>&1
FAILING_ROOT="$(cat "$TMP_ROOT/failing-root" 2>/dev/null || true)"

assert_ne "the failing child fails" "$rc" 0
assert_ne "the failing child recorded the root it was given" "$FAILING_ROOT" ""
assert_not "a failing suite's cache root is removed too" test -e "$FAILING_ROOT"

write_child "$TMP_ROOT/child-escaped.test.sh" \
  'assert_eq "the child asserts something" 1 1
unset LINEAR_CACHE_ROOT'

run_output OUT rc bash "$TMP_ROOT/child-escaped.test.sh" 2>"$ERR_FILE"
assert_ne "a suite that ends with the redirect thrown away fails its verdict" "$rc" 0
assert_file_contains "the verdict says the redirect was unset" \
  "$ERR_FILE" "LINEAR_CACHE_ROOT was unset by the suite"

write_child "$TMP_ROOT/child-outside.test.sh" \
  'assert_eq "the child asserts something" 1 1
export LINEAR_CACHE_ROOT="'"$PROJ"'"'

run_output OUT rc bash "$TMP_ROOT/child-outside.test.sh" 2>"$ERR_FILE"
assert_ne "a suite aiming the redirect outside its own scratch fails its verdict" "$rc" 0
assert_file_contains "the verdict names the root that escaped" \
  "$ERR_FILE" "points outside every scratch directory this suite registered: $PROJ"
