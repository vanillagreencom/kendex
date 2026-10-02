#!/usr/bin/env bash
# check-review-replies end to end, against the staged gh fake: the verdict
# lines and exit status, the suppressed-finding scan of review bodies at the
# head, the head-bound disposition comments that answer it, the live read a
# reply edit changes without a push, the read failures that reach no verdict,
# and a copy of the github skill with no review-gate beside it. The thread
# grammar's own cases and probes are check-review-replies-threads.test.sh's.
#
# Each must-fail control runs a copy of the scripts tree with one whole line
# of check-review-replies replaced, the rest kept, and the case that line's
# rule decides flips.
# shellcheck disable=SC2034 # the row tables read their fixtures through eval
set -euo pipefail

# A suite running from inside a git hook inherits GIT_DIR, GIT_COMMON_DIR,
# GIT_WORK_TREE and GIT_INDEX_FILE, which take precedence over `git -C` and
# would configure the real repository.
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
CHECKER="$REPO_ROOT/skills/github/scripts/check-review-replies"

TMP_ROOT="$(mktemp -d)" || { echo "check-review-replies.test: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "check-review-replies.test: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "check-review-replies.test: scratch=resolve-failed" >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT

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
git -C "$TMP_ROOT/repo" config gc.auto 0
git -C "$TMP_ROOT/repo" config maintenance.auto false
# shellcheck source=lib/gh-stub.sh
. "$TEST_DIR/lib/gh-stub.sh"
GH_STUB_DIR="$TMP_ROOT/gh-stub" gh_stub_install "$TMP_ROOT/bin"

HEAD=1a2b3c4d5e6f7a8b9c0d1a2b3c4d5e6f7a8b9c0d
OTHER=9f8e7d6c5b4a39281706f5e4d3c2b1a098765432
AUTHOR=pr-author
PR_PATH=api-repos/owner/repo/pulls/7
REVIEWS_PATH='api-repos/owner/repo/pulls/7/reviews?per_page=100'
COMMENTS_PATH='api-repos/owner/repo/issues/7/comments?per_page=100'

# --- the world ---------------------------------------------------------------
review() { # LOGIN STATE COMMIT BODY
  jq -cn --arg l "$1" --arg s "$2" --arg c "$3" --arg b "$4" '{user: {login: $l}, state: $s, commit_id: $c, body: $b}'
}
comment() { # LOGIN BODY
  jq -cn --arg l "$1" --arg b "$2" '{user: {login: $l}, body: $b}'
}
thread_node() { # LOGIN TYPENAME BODY
  jq -cn --arg l "$1" --arg t "$2" --arg b "$3" '{comments: {totalCount: 1, nodes: [{author: {login: $l, __typename: $t}, body: $b}]}}'
}
threads_set() { # NODE_JSON...
  local IFS=,
  gh_stub_answer api-graphql:reviewThreads "{\"data\":{\"repository\":{\"pullRequest\":{\"reviewThreads\":{\"pageInfo\":{\"hasNextPage\":false,\"endCursor\":null},\"nodes\":[$*]}}}}}"
}
reviews_set() { local IFS=,; gh_stub_answer "$REVIEWS_PATH" "[$*]"; }
comments_set() { local IFS=,; gh_stub_answer "$COMMENTS_PATH" "[$*]"; }

# A clean pull request: head HEAD by AUTHOR, no thread, no review, no
# comment. A case restages what it is about.
world() {
  gh_stub_reset
  gh_stub_answer "$PR_PATH" "{\"user\":{\"login\":\"$AUTHOR\"},\"head\":{\"sha\":\"$HEAD\"}}"
  threads_set
  reviews_set
  comments_set
}

# SUBJECT is the script under test, so a control can point at a mutated copy.
# The child's environment is explicit: no token and no GH_REPO from the
# developer's shell decides which repository the fake answers for.
run() { # [SUBJECT]
  local subject="${1:-$CHECKER}" rc=0
  (cd "$TMP_ROOT/repo" && env -u GH_TOKEN -u GITHUB_TOKEN -u GH_BOT_TOKEN -u GH_REPO -u GH_CONFIG_DIR -u KENDEX_ENV_FILE \
    PATH="$TMP_ROOT/bin:$PATH" "$subject" 7 >"$TMP_ROOT/stdout" 2>"$TMP_ROOT/stderr") || rc=$?
  # `rc=<n> <stdout lines joined by ` | `>`, the head written as {head} so a
  # row pins which head the verdict was for without spelling the sha.
  printf 'rc=%s %s' "$rc" "$(sed "s/$HEAD/{head}/g" "$TMP_ROOT/stdout" | paste -s -d '|' - | sed 's/|/ | /g')"
}
first_err() { sed -n 1p "$TMP_ROOT/stderr"; }

PASSED='rc=0 review-replies: pass head={head}'
FAILED='rc=1 review-replies: fail head={head}'

# A copy of the scripts tree under $TMP_ROOT/NAME with one whole line of
# check-review-replies replaced by TO. Prints the copy's script.
mutant_copy() { # NAME FROM TO
  local dest="$TMP_ROOT/$1" script
  mkdir -p "$dest/skills/github"
  cp -R "$REPO_ROOT/skills/github/scripts" "$dest/skills/github/scripts"
  script="$dest/skills/github/scripts/check-review-replies"
  [[ "$(grep -cxF -- "$2" "$script")" == 1 ]] || {
    echo "FIXTURE: the $1 line was not unique in $script" >&2
    exit 2
  }
  F="$2" T="$3" awk 'BEGIN { f = ENVIRON["F"]; t = ENVIRON["T"] } $0 == f { $0 = t } { print }' "$script" >"$script.edit"
  cat -- "$script.edit" >"$script"
  rm -f -- "${script:?}.edit"
  ! grep -qxF -- "$2" "$script" || {
    echo "FIXTURE: the $1 edit matched nothing in $script" >&2
    exit 2
  }
  printf '%s\n' "$script"
}

# --- the review bodies -----------------------------------------------------------
# Both bodies are live Copilot shapes. supp_body is the heading-titled one,
# trailer and all: the block sits inside <details>, a bold "Previously missed
# (N)" line separates the groups without being an entry, and a
# "- **Files reviewed:**" list item follows the entries without joining them.
# supp_v2_body is the summary-titled one, where that string is the section
# title, each entry sits in its own nested <details>, and each entry path is
# broken for display with a zero-width space after every slash.
SUPP_FIRST='src/model/naming.ts:106'
SUPP_SECOND='src/ui/agents.tsx:257'
SUPP_ENTRIES="**$SUPP_FIRST**
* Blocking: a generated name can equal a row already carrying it.
**$SUPP_SECOND**
* Blocking: selected can exceed the list length after a lane exits."
supp_body() { # HEADING [ENTRIES]
  printf '### Needs a closer look\n\nUnresolved selection and naming defects.\n\n<details>\n<summary>Review details</summary>\n\n%s\n\n**Previously missed (2)** — in code that has not changed since the last review.\n\n%s\n\n- **Files reviewed:** 26/26 changed files\n- **Comments generated:** 0 new\n</details>\n' "$1" "${2-}"
}
SUPP_ZWSP="$(printf '\342\200\213')"
supp_zwsp() { printf '%s' "$1" | sed "s|/|/$SUPP_ZWSP|g"; }
supp_v2_body() { # TITLE
  printf '<!-- ccr-overview-v2 -->\n\n## Copilot review overview\n\n### Needs a closer look\n\nUnresolved selection and naming defects.\n\n<details open>\n<summary><strong>Open (1)</strong></summary>\n\n- [A finding that did become a thread](#discussion_r1)\n</details>\n\n<details>\n<summary><strong>%s</strong></summary>\n\nIn code that has not changed since last review\n\n<details>\n<summary>Guard the generated name</summary>\n\n`%s`\n\nBlocking: a generated name can equal a row already carrying it.\n</details>\n\n<details>\n<summary>Bound the selection</summary>\n\n`%s`\n\nBlocking: selected can exceed the list length after a lane exits.\n</details>\n</details>\n' \
    "$1" "$(supp_zwsp "$SUPP_FIRST")" "$(supp_zwsp "$SUPP_SECOND")"
}
# A block of the given title and entries in one review at the head.
at_head() { # BODY
  reviews_set "$(review copilot COMMENTED "$HEAD" "$1")"
}
BOTH_STANDING="$FAILED | suppressed-findings count=2 | suppressed-entry $SUPP_FIRST | suppressed-entry $SUPP_SECOND"
FIRST_STANDING="$FAILED | suppressed-findings count=1 | suppressed-entry $SUPP_FIRST"
SECOND_STANDING="$FAILED | suppressed-findings count=1 | suppressed-entry $SUPP_SECOND"

echo "=== the review-body scan ==="
# A row is `label|body|want`, the body one of the shapes below, the whole
# stdout and exit status pinned.
SUPP_HEADING_TRAILER="**$SUPP_FIRST**
* Blocking: a generated name can equal a row already carrying it.

### Files reviewed

**$SUPP_SECOND**"
SUPP_FENCED_ENTRIES="**$SUPP_FIRST**
* Blocking: a generated name can equal a row already carrying it.
\`\`\`sh
# harness-smoke names the lane it could not reach
run_lane \"\$name\"
\`\`\`
**$SUPP_SECOND**
* Blocking: selected can exceed the list length after a lane exits."
SUPP_FENCE_FIRST="$(printf 'Review prose quoting a markdown file.\n\n````markdown\n```\n````\n\n### Suppressed comments (1)\n\n**%s**\n* Blocking: a real finding.\n' "$SUPP_FIRST")"
# A title with no count over entries the scan cannot read, and a count over
# entries the scan cannot read: each is its rule's alone, since neither
# leaves an entry for the count rule to report.
SUPP_UNPARSED_PROSE="$(supp_body '### Suppressed comments (several)' 'src/model/naming.ts line 106: a generated name can collide.')"
SUPP_MISMATCH_PROSE="$(supp_body '### Suppressed comments (1)' 'src/model/naming.ts line 106: a generated name can collide.')"
body_of() {
  case "$1" in
    heading) supp_body '### Suppressed comments (2)' "$SUPP_ENTRIES" ;;
    other-title) supp_body '### Review notes' "$SUPP_ENTRIES" ;;
    no-count) supp_body '### Suppressed comments (several)' "$SUPP_ENTRIES" ;;
    no-count-prose) printf '%s' "$SUPP_UNPARSED_PROSE" ;;
    over-count) supp_body '### Suppressed comments (3)' "$SUPP_ENTRIES" ;;
    count-prose) printf '%s' "$SUPP_MISMATCH_PROSE" ;;
    trailer) supp_body '### Suppressed comments (1)' "$SUPP_HEADING_TRAILER" ;;
    fenced) supp_body '### Suppressed comments (2)' "$SUPP_FENCED_ENTRIES" ;;
    fence-first) printf '%s' "$SUPP_FENCE_FIRST" ;;
    renamed) supp_body '### Previously missed (2)' "$SUPP_ENTRIES" ;;
    v2) supp_v2_body 'Previously missed (2)' ;;
    v2-no-count) supp_v2_body 'Previously missed' ;;
    v2-other-title) supp_v2_body 'Reviewer notes (2)' ;;
    *) echo "UNKNOWN-BODY: $1" >&2; exit 2 ;;
  esac
}
while IFS='|' read -r label body want; do
  [ -n "$label" ] || continue
  world
  at_head "$(body_of "$body")"
  assert_eq "$(run)" "$(eval "printf '%s' \"$want\"")" "$label"
done <<'ROWS'
a counted block at head fails, naming each file:line|heading|$BOTH_STANDING
the same review with no block passes|other-title|$PASSED
a title whose count is not a number fails as unparsed|no-count|$FAILED | suppressed-findings state=unparsed
a title with no count fails even when no entry under it reads|no-count-prose|$FAILED | suppressed-findings state=unparsed
a count disagreeing with the entries under it fails as a mismatch|over-count|$FAILED | suppressed-findings state=mismatch declared=3 entries=2
a count over entries the scan cannot read fails as a mismatch|count-prose|$FAILED | suppressed-findings state=mismatch declared=1 entries=0
a heading after the entries ends the block|trailer|$FIRST_STANDING
a fenced snippet between two entries hides neither of them|fenced|$BOTH_STANDING
a fence run before the heading cannot hide the block|fence-first|$FIRST_STANDING
a markdown heading carrying the newer name is the same block|renamed|$BOTH_STANDING
a summary-titled section counts entries past a nested </details>, display spaces stripped|v2|$BOTH_STANDING
a summary-titled section with no count fails as unparsed|v2-no-count|$FAILED | suppressed-findings state=unparsed
the same section under another title passes|v2-other-title|$PASSED
ROWS

echo "=== which reviews the scan reads ==="
# The head's submitted reviews by anyone but the author. A review of an
# earlier head is not this head's, a dismissed one no longer stands, a
# pending one was never submitted, and the author's own body is not a
# reviewer's finding.
while IFS='|' read -r label login state commit want; do
  [ -n "$label" ] || continue
  world
  reviews_set "$(review "$(eval "printf '%s' \"$login\"")" "$state" "$(eval "printf '%s' \"$commit\"")" "$(body_of heading)")"
  assert_eq "$(run)" "$(eval "printf '%s' \"$want\"")" "$label"
done <<'ROWS'
an APPROVED review at head carrying the block still fails|copilot|APPROVED|$HEAD|$BOTH_STANDING
a review of an earlier head is not read|copilot|COMMENTED|$OTHER|$PASSED
a dismissed review at head is not read|copilot|DISMISSED|$HEAD|$PASSED
a pending review at head is not read|copilot|PENDING|$HEAD|$PASSED
the author's own review body is not read|$AUTHOR|COMMENTED|$HEAD|$PASSED
ROWS

echo "=== the head-bound disposition comments ==="
# A row is `label|body|login|bound|reply|want`: the review body, then one PR
# comment by LOGIN opening `Dispositions at BOUND` over the reply lines
# (`\n` between them).
SUPP_REASON='Declined: the generator draws its name from the row set, so a collision is unreachable.'
SUPP_SPACED='docs/release notes.md:12'
SUPP_SHORT='src/lane.ts:1'
SUPP_LONGER='src/lane.ts:12'
SUPP_STEM='src/foo:1'
SUPP_EXTENDS='src/foo:1.ts:2'
two_entries() { supp_body '### Suppressed comments (2)' "**$1**
* Blocking: the first finding.
**$2**
* Blocking: the second finding."; }
one_entry() { supp_body '### Suppressed comments (1)' "**$1**
* Blocking: the only finding."; }
reply_body_of() {
  case "$1" in
    heading | v2) body_of "$1" ;;
    spaced) one_entry "$SUPP_SPACED" ;;
    short-long) two_entries "$SUPP_SHORT" "$SUPP_LONGER" ;;
    stem) two_entries "$SUPP_STEM" "$SUPP_EXTENDS" ;;
    *) echo "UNKNOWN-REPLY-BODY: $1" >&2; exit 2 ;;
  esac
}
H7="${HEAD:0:7}"
O7="${OTHER:0:7}"
while IFS='|' read -r label body login bound reply want; do
  [ -n "$label" ] || continue
  world
  at_head "$(reply_body_of "$body")"
  comments_set "$(comment "$(eval "printf '%s' \"$login\"")" "$(eval "printf 'Dispositions at %s:\n%b' \"$bound\" \"$reply\"")")"
  assert_eq "$(run)" "$(eval "printf '%s' \"$want\"")" "$label"
done <<'ROWS'
a bound reasoned decline and a tracked entry clear the block|heading|$AUTHOR|$H7|**$SUPP_FIRST** - $SUPP_REASON\n**$SUPP_SECOND** - Tracked: KEN-1400|$PASSED
entries named bare, as this output prints them, clear the block|heading|$AUTHOR|$H7|$SUPP_FIRST - $SUPP_REASON\n$SUPP_SECOND - Tracked: KEN-1400|$PASSED
entries backticked, as the newer body prints them, clear the block|v2|$AUTHOR|$H7|\`$SUPP_FIRST\` - $SUPP_REASON\n\`$SUPP_SECOND\` - Tracked: KEN-1400|$PASSED
entries carrying the body's zero-width spaces clear the block|v2|$AUTHOR|$H7|\`$(supp_zwsp "$SUPP_FIRST")\` - $SUPP_REASON\n\`$(supp_zwsp "$SUPP_SECOND")\` - Tracked: KEN-1400|$PASSED
the full head sha binds as its prefix does|heading|$AUTHOR|$HEAD|**$SUPP_FIRST** - $SUPP_REASON\n**$SUPP_SECOND** - Tracked: KEN-1400|$PASSED
a comment naming the head still answers a Fixed-in entry|heading|$AUTHOR|$H7|**$SUPP_FIRST** - Fixed in $HEAD\n**$SUPP_SECOND** - $SUPP_REASON|$PASSED
a comment tied to the head only by its own Fixed-in sha answers nothing|heading|$AUTHOR|$O7|**$SUPP_FIRST** - Fixed in $HEAD\n**$SUPP_SECOND** - $SUPP_REASON|$BOTH_STANDING
a label-only decline answers nothing|heading|$AUTHOR|$H7|**$SUPP_FIRST** - Declined: out of scope\n**$SUPP_SECOND** - Declined: pre-existing|$BOTH_STANDING
a tracking claim naming no issue answers nothing|heading|$AUTHOR|$H7|**$SUPP_FIRST** - Tracking this separately.\n**$SUPP_SECOND** - Tracking this separately.|$BOTH_STANDING
a reply bound to another head answers nothing|heading|$AUTHOR|$O7|**$SUPP_FIRST** - $SUPP_REASON\n**$SUPP_SECOND** - Tracked: KEN-1400|$BOTH_STANDING
a reply by another login answers nothing|heading|other-user|$H7|**$SUPP_FIRST** - $SUPP_REASON\n**$SUPP_SECOND** - Tracked: KEN-1400|$BOTH_STANDING
an answered entry leaves the count and the unanswered one stands|heading|$AUTHOR|$H7|**$SUPP_FIRST** - $SUPP_REASON|$SECOND_STANDING
the newest line naming an entry decides|heading|$AUTHOR|$H7|**$SUPP_FIRST** - $SUPP_REASON\n**$SUPP_SECOND** - Tracked: KEN-1400\n**$SUPP_FIRST** - Declined: frozen|$FIRST_STANDING
a bare entry whose path carries a space is answered|spaced|$AUTHOR|$H7|$SUPP_SPACED - $SUPP_REASON|$PASSED
a shorter entry does not claim a longer entry's line|short-long|$AUTHOR|$H7|$SUPP_LONGER - Tracked: KEN-1400|$FAILED | suppressed-findings count=1 | suppressed-entry $SUPP_SHORT
a line names one entry, the longest it opens with|stem|$AUTHOR|$H7|$SUPP_EXTENDS - Tracked: KEN-1400|$FAILED | suppressed-findings count=1 | suppressed-entry $SUPP_STEM
ROWS

# The marker opens a line, and nothing else binds. Each body below carries
# the head prefix somewhere other than a `Dispositions at` line opening.
SUPP_HEXPATH="${HEAD:0:8}.ts:1"
while IFS='|' read -r label body reply want; do
  [ -n "$label" ] || continue
  world
  at_head "$(eval "$body")"
  comments_set "$(comment "$AUTHOR" "$(eval "printf '%b' \"$reply\"")")"
  assert_eq "$(run)" "$(eval "printf '%s' \"$want\"")" "$label"
done <<'ROWS'
a head prefix in a path with no marker binds nothing|one_entry "$SUPP_HEXPATH"|Dispositions:\n$SUPP_HEXPATH - $SUPP_REASON|$FAILED | suppressed-findings count=1 | suppressed-entry $SUPP_HEXPATH
a marker quoted mid-line binds nothing|body_of heading|The other PR says Dispositions at $H7, which is this head.\n**$SUPP_FIRST** - $SUPP_REASON\n**$SUPP_SECOND** - Tracked: KEN-1400|$BOTH_STANDING
a comment marked for an older head answers nothing at this one|body_of heading|Dispositions at $O7:\nsrc/model/lanes.ts:9 - Fixed in $HEAD\n**$SUPP_FIRST** - $SUPP_REASON\n**$SUPP_SECOND** - Tracked: KEN-1400|$BOTH_STANDING
ROWS

echo "=== the thread rules, wired to the verdict ==="
while IFS='|' read -r label node want; do
  [ -n "$label" ] || continue
  world
  threads_set "$(eval "$node")"
  assert_eq "$(run)" "$(eval "printf '%s' \"$want\"")" "$label"
done <<'ROWS'
a reasoned decline and a tracked reply pass|thread_node "$AUTHOR" User 'Declined: the caller rejects the empty case first.'|$PASSED
a tracking claim naming no issue fails|thread_node "$AUTHOR" User 'Out of scope, tracked.'|$FAILED | untracked-claim count=1
a decline naming no mechanism fails|thread_node "$AUTHOR" User 'Declined: frozen'|$FAILED | unreasoned-decline count=1
a bot's label-only decline is exempt|thread_node copilot Bot 'Declined: frozen'|$PASSED
a thread holding more comments than one read returns fails|jq -cn '{comments: {totalCount: 101, nodes: [{author: {login: "pr-author", __typename: "User"}, body: "Tracked: KEN-1"}]}}'|$FAILED | thread-replies state=truncated threads=1
ROWS

# Every failing rule reports, each on its own line, in a fixed order.
world
threads_set "$(thread_node "$AUTHOR" User 'Out of scope, tracked.')" "$(thread_node "$AUTHOR" User 'Declined: frozen')"
at_head "$(body_of heading)"
assert_eq "$(run)" "$FAILED | untracked-claim count=1 | unreasoned-decline count=1 | suppressed-findings count=2 | suppressed-entry $SUPP_FIRST | suppressed-entry $SUPP_SECOND" \
  "every failing rule reports, the head named on the first line"
assert_eq "$(sed -n 1p "$TMP_ROOT/stdout")" "review-replies: fail head=$HEAD" "the first line names the whole head sha"

echo "=== a live read: a reply edit without a push changes the verdict ==="
# The same head throughout; only what the replies say changes between reads.
world
threads_set "$(thread_node "$AUTHOR" User 'Declined: frozen')"
assert_eq "$(run)" "$FAILED | unreasoned-decline count=1" "the label-only decline fails at this head"
threads_set "$(thread_node "$AUTHOR" User 'Declined: the caller rejects the empty case first.')"
assert_eq "$(run)" "$PASSED" "the edited reply passes at the same head"
at_head "$(body_of heading)"
assert_eq "$(run)" "$BOTH_STANDING" "a review body's findings fail at the same head"
comments_set "$(comment "$AUTHOR" "$(printf 'Dispositions at %s:\n**%s** - %s\n**%s** - Tracked: KEN-1400' "$H7" "$SUPP_FIRST" "$SUPP_REASON" "$SUPP_SECOND")")"
assert_eq "$(run)" "$PASSED" "an author comment added without a push answers them"

echo "=== reads that reach no verdict ==="
# A row is `label|stage|first stderr line`; each exits 2 with nothing on
# stdout. A dependency failure is never a pass and never a finding count.
while IFS='|' read -r label stage want; do
  [ -n "$label" ] || continue
  world
  at_head "$(body_of heading)"
  eval "$stage"
  out=$(run)
  assert_eq "$out $(first_err)" "rc=2  $want" "$label"
done <<'ROWS'
a pull request read that fails|gh_stub_fail "$PR_PATH" 1 'gh: Not Found (HTTP 404)'|check-review-replies: read-failed pr=7
a pull request naming no head|gh_stub_answer "$PR_PATH" '{"user":{"login":"pr-author"},"head":{}}'|check-review-replies: read-malformed pr=7
a thread read that fails|gh_stub_answer api-graphql:reviewThreads '{"errors":[{"type":"FORBIDDEN","message":"no"}]}'|check-review-replies: read-failed pr=7
a reviews read that fails|gh_stub_fail "$REVIEWS_PATH" 1 'gh: Not Found (HTTP 404)'|check-review-replies: read-failed pr=7
a reviews read producing zero bytes|gh_stub_answer "$REVIEWS_PATH" ''|check-review-replies: read-empty pr=7
a reviews page that is not an array|gh_stub_answer "$REVIEWS_PATH" '{"message":"Server Error"}'|check-review-replies: read-malformed pr=7
a comments read that fails while findings stand|gh_stub_fail "$COMMENTS_PATH" 1 'gh: Not Found (HTTP 404)'|check-review-replies: read-failed pr=7
ROWS

echo "=== arguments ==="
while IFS='|' read -r label args want; do
  [ -n "$label" ] || continue
  [ "$args" != - ] || args=""
  # shellcheck disable=SC2086 # the row's arguments split on purpose
  out=$(cd "$TMP_ROOT/repo" && PATH="$TMP_ROOT/bin:$PATH" "$CHECKER" $args 2>&1 >/dev/null | sed -n 1p) || true
  assert_eq "$out" "$want" "$label"
done <<'ROWS'
no argument is a usage error|-|check-review-replies: usage pr=
a branch name is a usage error|feature-branch|check-review-replies: usage pr=feature-branch
two numbers are a usage error|7 8|check-review-replies: usage pr=7
ROWS
assert_eq "$(PATH="$TMP_ROOT/bin:$PATH" "$CHECKER" --help | sed -n 1p)" "Usage: check-review-replies <PR_NUMBER>" "--help prints the usage"

echo "=== without review-gate ==="
# The github skill alone, as a project without review-gate installs it.
mkdir -p "$TMP_ROOT/alone/skills"
cp -R "$REPO_ROOT/skills/github" "$TMP_ROOT/alone/skills/github"
world
threads_set "$(thread_node "$AUTHOR" User 'Declined: frozen')"
assert_eq "$(run "$TMP_ROOT/alone/skills/github/scripts/check-review-replies")" "$FAILED | unreasoned-decline count=1" \
  "a copy of the github skill with no review-gate beside it judges the replies"

echo "=== must-fail controls ==="
# A row is `label|name|from line|to line|setup|want with the mutant`. The
# setup's live verdict is pinned in a section above; with its rule's line
# replaced, the same setup answers what the row names instead.
mutant_row() { # LABEL NAME FROM TO SETUP WANT
  local script
  script=$(mutant_copy "$2" "$3" "$4")
  world
  eval "$5"
  assert_eq "$(run "$script")" "$6" "must-fail: $1"
}
mutant_row "with the untracked-claim line cut, the claim passes" untracked \
  '[ "$untracked" = 0 ] || {' '[ true ] || {' \
  'threads_set "$(thread_node "$AUTHOR" User "Out of scope, tracked.")"' "$PASSED"
mutant_row "with the unreasoned-decline line cut, the label passes" unreasoned \
  '[ "$unreasoned" = 0 ] || {' '[ true ] || {' \
  'threads_set "$(thread_node "$AUTHOR" User "Declined: frozen")"' "$PASSED"
mutant_row "with the truncation line cut, a truncated thread passes" truncated \
  '[ "$truncated" = 0 ] || {' '[ true ] || {' \
  "threads_set \"\$(jq -cn '{comments: {totalCount: 101, nodes: []}}')\"" "$PASSED"
mutant_row "with the heading arm cut, a heading-titled block passes" heading \
  '      if test("^#{1,6}[ \t]+") then sub("^#{1,6}[ \t]+"; "")' '      if false then ""' \
  'at_head "$(body_of heading)"' "$PASSED"
mutant_row "with the summary arm cut, a summary-titled block passes" summary \
  '      elif test("^<summary[^>]*>.*</summary>[ \t]*$")' '      elif false' \
  'at_head "$(body_of v2)"' "$PASSED"
mutant_row "with the unparsed test cut, a title with no count passes" unparsed \
  'if [ "$supp_unparsed" != 0 ]; then' 'if false; then' \
  'at_head "$(body_of no-count-prose)"' "$PASSED"
mutant_row "with the mismatch test cut, a count over unreadable entries passes" mismatch \
  'elif [ "$supp_declared" != "$supp_entries" ]; then' 'elif false; then' \
  'at_head "$(body_of count-prose)"' "$PASSED"
mutant_row "with the head filter cut, an earlier head's review fails this one" head-review \
  '      | select(.commit_id == $sha and .state != "DISMISSED" and .state != "PENDING"' '      | select(.state != "DISMISSED" and .state != "PENDING"' \
  'reviews_set "$(review copilot COMMENTED "$OTHER" "$(body_of heading)")"' "$BOTH_STANDING"
mutant_row "with the head binding cut, a comment for an older head answers" head-bound \
  '          | select(($sha | ascii_downcase) | startswith($claimed)) ] | length > 0;' '          | select(true) ] | length > 0;' \
  'at_head "$(body_of heading)"; comments_set "$(comment "$AUTHOR" "$(printf "Dispositions at %s:\n**%s** - %s\n**%s** - Tracked: KEN-1400" "$O7" "$SUPP_FIRST" "$SUPP_REASON" "$SUPP_SECOND")")"' "$PASSED"
mutant_row "with the comment author filter cut, another login answers" comment-author \
  '          | select((.user.login // "") == $author)' '          | select(true)' \
  'at_head "$(body_of heading)"; comments_set "$(comment other-user "$(printf "Dispositions at %s:\n**%s** - %s\n**%s** - Tracked: KEN-1400" "$H7" "$SUPP_FIRST" "$SUPP_REASON" "$SUPP_SECOND")")"' "$PASSED"
mutant_row "with the reply reason test cut, a label-only decline answers" reply-reason \
  '        or (($r | declined) and (($r | reason_left) == ""));' '        or false;' \
  'at_head "$(body_of heading)"; comments_set "$(comment "$AUTHOR" "$(printf "Dispositions at %s:\n**%s** - Declined: out of scope\n**%s** - Declined: pre-existing" "$H7" "$SUPP_FIRST" "$SUPP_SECOND")")"' "$PASSED"
mutant_row "with the page-shape test cut, a non-array reviews page reads as no review" page-shape \
  "  pages=\$(jq -s 'if (length > 0) and all(type == \"array\") then add else error(\"pages are not arrays\") end' <<<\"\$raw\" 2>/dev/null) ||" \
  "  pages=\$(jq -s '[.[] | arrays] | add // []' <<<\"\$raw\" 2>/dev/null) ||" \
  "at_head \"\$(body_of heading)\"; gh_stub_answer \"\$REVIEWS_PATH\" '{\"message\":\"Server Error\"}'" "$PASSED"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
