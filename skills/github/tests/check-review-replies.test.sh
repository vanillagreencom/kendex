#!/usr/bin/env bash
# check-review-replies end to end, against the staged gh fake: the verdict
# lines and exit status, the suppressed-finding scan of review bodies at the
# head, the head-bound disposition comments that answer it, the live read a
# reply edit changes without a push, the read failures that reach no verdict,
# whose words count, the router's project credentials, and a copy of the
# github skill with no review-gate beside it. The thread grammar's own cases
# and probes are check-review-replies-threads.test.sh's.
#
# Each must-fail control runs a copy of the scripts tree with one whole line
# of one file replaced, the rest kept (lib/mutant-copy.sh), and the case that
# line's rule decides flips. The file is check-review-replies.sh unless the
# control names the lib or router the rule lives in.
# shellcheck disable=SC2034 # the row tables read their fixtures through eval
set -euo pipefail

# A suite running from inside a git hook inherits GIT_DIR, GIT_COMMON_DIR,
# GIT_WORK_TREE and GIT_INDEX_FILE, which take precedence over `git -C` and
# would configure the real repository.
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
CHECKER="$REPO_ROOT/skills/github/scripts/commands/check-review-replies.sh"
GITHUB_SH="$REPO_ROOT/skills/github/scripts/github.sh"

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
# shellcheck source=lib/mutant-copy.sh
. "$TEST_DIR/lib/mutant-copy.sh"

HEAD=1a2b3c4d5e6f7a8b9c0d1a2b3c4d5e6f7a8b9c0d
OTHER=9f8e7d6c5b4a39281706f5e4d3c2b1a098765432
PR_PATH=api-repos/owner/repo/pulls/7
REVIEWS_PATH='api-repos/owner/repo/pulls/7/reviews?per_page=100'
COMMENTS_PATH='api-repos/owner/repo/issues/7/comments?per_page=100'

# --- the world ---------------------------------------------------------------
# The accounts a world holds, as `login type association id` the way REST
# spells them; the live shapes are the lanes app authoring a PR (Bot,
# CONTRIBUTOR) and Copilot reviewing it (Bot, NONE). GraphQL writes a bot's
# login without the [bot] suffix and its id as databaseId. The impostor is a
# separate User account registered under the app's slug.
account() { # NAME
  case "$1" in
    author) printf 'pr-author User NONE 1001' ;;
    app) printf 'lanes-app[bot] Bot CONTRIBUTOR 2002' ;;
    copilot) printf 'copilot-pull-request-reviewer[bot] Bot NONE 3003' ;;
    maintainer) printf 'maintainer User MEMBER 4004' ;;
    stranger) printf 'stranger User NONE 5005' ;;
    impostor) printf 'lanes-app User NONE 6006' ;;
    *) echo "UNKNOWN-ACCOUNT: $1" >&2; exit 2 ;;
  esac
}
rest_actor() { # ACCOUNT -> the user and author_association fields
  local login type assoc id
  read -r login type assoc id <<<"$(account "$1")"
  jq -cn --arg l "$login" --arg t "$type" --arg a "$assoc" --argjson i "$id" '{user: {login: $l, type: $t, id: $i}, author_association: $a}'
}
review() { # ACCOUNT STATE COMMIT BODY
  jq -cn --argjson u "$(rest_actor "$1")" --arg s "$2" --arg c "$3" --arg b "$4" '$u + {state: $s, commit_id: $c, body: $b}'
}
comment() { # ACCOUNT BODY
  jq -cn --argjson u "$(rest_actor "$1")" --arg b "$2" '$u + {body: $b}'
}
# A thread's first comment is the finding it opens. rooted_node takes it as its
# first pair; thread_node puts its replies under a review bot's finding that
# says nothing the thread rules read.
thread_node() { rooted_node copilot 'The caller can pass an empty list here.' "$@"; }
rooted_node() { # ACCOUNT BODY [ACCOUNT BODY]... — one thread, oldest comment first
  local nodes="" login type assoc id
  while [ "$#" -gt 0 ]; do
    read -r login type assoc id <<<"$(account "$1")"
    nodes="$nodes${nodes:+,}$(jq -cn --arg l "${login%\[bot\]}" --arg t "$type" --arg a "$assoc" --argjson i "$id" --arg b "$2" \
      '{author: {login: $l, __typename: $t, databaseId: $i}, authorAssociation: $a, body: $b}')"
    shift 2
  done
  printf '{"comments":{"totalCount":%s,"nodes":[%s]}}' "$(jq 'length' <<<"[$nodes]")" "$nodes"
}
# The thread and viewer answers are staged under their queries' account-id
# selections, so a query that drops one gets no answer and reaches no verdict:
# GitHub would answer it with no id for that actor type.
THREADS_QUERY='api-graphql:... on User { databaseId } ... on Bot { databaseId }'
VIEWER_QUERY='api-graphql:viewer { login databaseId }'
threads_set() { # NODE_JSON...
  local IFS=,
  gh_stub_answer "$THREADS_QUERY" "{\"data\":{\"repository\":{\"pullRequest\":{\"reviewThreads\":{\"pageInfo\":{\"hasNextPage\":false,\"endCursor\":null},\"nodes\":[$*]}}}}}"
}
reviews_set() { local IFS=,; gh_stub_answer "$REVIEWS_PATH" "[$*]"; }
comments_set() { local IFS=,; gh_stub_answer "$COMMENTS_PATH" "[$*]"; }

# The identity the check reads as, its token's GraphQL viewer, which spells
# an app's login with the [bot] suffix and its id as databaseId, the app's
# own account id. The live shape is a lane answering under the lanes app on
# a PR a person opened.
viewer_set() { # VIEWER_JSON
  gh_stub_answer "$VIEWER_QUERY" "{\"data\":{\"viewer\":$1}}"
}
VIEWER_APP='{"login":"lanes-app[bot]","databaseId":2002}'

# A clean pull request: head HEAD by ACCOUNT (default author), read as the
# app, no thread, no review, no comment. A case restages what it is about.
world() { # [ACCOUNT]
  gh_stub_reset
  gh_stub_answer "$PR_PATH" "$(jq -cn --argjson u "$(rest_actor "${1:-author}")" --arg h "$HEAD" '{user: $u.user, head: {sha: $h}}')"
  viewer_set "$VIEWER_APP"
  threads_set
  reviews_set
  comments_set
}

# SUBJECT is the command under test, so a control can point at a mutated
# copy and a case at the router; the PR number follows it. The child's
# environment is explicit: no token and no GH_REPO from the developer's shell
# decides which repository the fake answers for.
run() { # [SUBJECT...]
  local rc=0
  [ "$#" -gt 0 ] || set -- "$CHECKER"
  (cd "$TMP_ROOT/repo" && env -u GH_TOKEN -u GITHUB_TOKEN -u GH_BOT_TOKEN -u GH_REPO -u GH_CONFIG_DIR -u KENDEX_ENV_FILE \
    PATH="$TMP_ROOT/bin:$PATH" "$@" 7 >"$TMP_ROOT/stdout" 2>"$TMP_ROOT/stderr") || rc=$?
  # `rc=<n> <stdout lines joined by ` | `>`, the head written as {head} so a
  # row pins which head the verdict was for without spelling the sha.
  printf 'rc=%s %s' "$rc" "$(sed "s/$HEAD/{head}/g" "$TMP_ROOT/stdout" | paste -s -d '|' - | sed 's/|/ | /g')"
}
first_err() { sed -n 1p "$TMP_ROOT/stderr"; }

PASSED='rc=0 review-replies: pass head={head}'
FAILED='rc=1 review-replies: fail head={head}'

assert_eq "$(jq -Rrs 'contains("\u200b")' "$CHECKER")" false \
  "the source contains no literal zero-width space"

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
# A section declaring one finding more than it parses, and one declaring one
# fewer: summed, the two counts agree and the unparsed finding goes unnamed.
SUPP_THIRD='src/ui/lanes.tsx:12'
SUPP_UNDER="$(printf '### Suppressed comments (2)\n\n**%s**\n* Blocking: a generated name can collide.\nsrc/model/lanes.ts line 9: a finding with no token.\n' "$SUPP_FIRST")"
SUPP_OVER="$(printf '### Previously missed (1)\n\n**%s**\n* Blocking: selected can exceed the list length.\n**%s**\n* Blocking: a lane can exit twice.\n' "$SUPP_SECOND" "$SUPP_THIRD")"
# The live Copilot shape whose only finding sits in the body: COMMENTED,
# `Findings: None` and no thread, the entry only under `Previously missed
# (1)`, its summary carrying a severity image.
COPILOT_ENTRY='skills/orch/references/merge-attempt.md:25'
body_of() {
  case "$1" in
    heading) supp_body '### Suppressed comments (2)' "$SUPP_ENTRIES" ;;
    other-title) supp_body '### Review notes' "$SUPP_ENTRIES" ;;
    no-count) supp_body '### Suppressed comments (several)' "$SUPP_ENTRIES" ;;
    no-count-prose) printf '%s' "$SUPP_UNPARSED_PROSE" ;;
    over-count) supp_body '### Suppressed comments (3)' "$SUPP_ENTRIES" ;;
    count-prose) printf '%s' "$SUPP_MISMATCH_PROSE" ;;
    cancel-sections) printf '%s\n\n%s' "$SUPP_UNDER" "$SUPP_OVER" ;;
    trailer) supp_body '### Suppressed comments (1)' "$SUPP_HEADING_TRAILER" ;;
    fenced) supp_body '### Suppressed comments (2)' "$SUPP_FENCED_ENTRIES" ;;
    fence-first) printf '%s' "$SUPP_FENCE_FIRST" ;;
    renamed) supp_body '### Previously missed (2)' "$SUPP_ENTRIES" ;;
    v2) supp_v2_body 'Previously missed (2)' ;;
    v2-no-count) supp_v2_body 'Previously missed' ;;
    v2-other-title) supp_v2_body 'Reviewer notes (2)' ;;
    copilot) printf '<!-- ccr-overview-v2 -->\n\n## Copilot review overview\n\n### Needs a closer look\n\nThe recording workflow assumes a lane status file.\n\n**Findings:** None\n\n<details>\n<summary><strong>Previously missed (1)</strong></summary>\n\nIn code that has not changed since last review\n\n<details>\n<summary><picture><img alt="Medium severity"></picture> Unconditional lane-status write breaks standalone merge-pr runs</summary>\n\n`%s`\n\n**Blocking:** This status write is unconditional.\n</details>\n</details>\n' \
      "$(supp_zwsp "$COPILOT_ENTRY")" ;;
    crlf) supp_body '### Suppressed comments (2)' "$SUPP_ENTRIES" | awk '{ printf "%s\r\n", $0 }' ;;
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
a count disagreeing with the entries under it fails as a mismatch|over-count|$FAILED | suppressed-findings state=mismatch sections=1
a count over entries the scan cannot read fails as a mismatch|count-prose|$FAILED | suppressed-findings state=mismatch sections=1
two sections of one body whose counts cancel each fail as a mismatch|cancel-sections|$FAILED | suppressed-findings state=mismatch sections=2
a heading after the entries ends the block|trailer|$FIRST_STANDING
a fenced snippet between two entries hides neither of them|fenced|$BOTH_STANDING
a fence run before the heading cannot hide the block|fence-first|$FIRST_STANDING
a markdown heading carrying the newer name is the same block|renamed|$BOTH_STANDING
a summary-titled section counts entries past a nested </details>, display spaces stripped|v2|$BOTH_STANDING
a summary-titled section with no count fails as unparsed|v2-no-count|$FAILED | suppressed-findings state=unparsed
the same section under another title passes|v2-other-title|$PASSED
a body whose overview reads Findings: None still fails on its one entry|copilot|$FAILED | suppressed-findings count=1 | suppressed-entry $COPILOT_ENTRY
a body written with CRLF line ends reads as the same block|crlf|$BOTH_STANDING
ROWS

echo "=== which reviews the scan reads ==="
# A row is `label|pr author|reviewer|state|commit|body|want`. The scan reads
# the head's submitted reviews by a finding source: a bot or a repository
# member who is not the PR author. A review of an earlier head is not this
# head's, a dismissed one no longer stands, a pending one was never
# submitted, the author's own body is not a reviewer's finding, and an
# account with no standing on the repository blocks nothing.
while IFS='|' read -r label author reviewer state commit body want; do
  [ -n "$label" ] || continue
  world "$author"
  reviews_set "$(review "$reviewer" "$state" "$(eval "printf '%s' \"$commit\"")" "$(body_of "$body")")"
  assert_eq "$(run)" "$(eval "printf '%s' \"$want\"")" "$label"
done <<'ROWS'
an APPROVED review at head carrying the block still fails|author|copilot|APPROVED|$HEAD|heading|$BOTH_STANDING
a review of an earlier head is not read|author|copilot|COMMENTED|$OTHER|heading|$PASSED
a dismissed review at head is not read|author|copilot|DISMISSED|$HEAD|heading|$PASSED
a pending review at head is not read|author|copilot|PENDING|$HEAD|heading|$PASSED
the author's own review body is not read|author|author|COMMENTED|$HEAD|heading|$PASSED
an app author's own review body is not read|app|app|COMMENTED|$HEAD|heading|$PASSED
a maintainer's review body is read|author|maintainer|COMMENTED|$HEAD|heading|$BOTH_STANDING
a NONE-association reviewer's block is not read|author|stranger|COMMENTED|$HEAD|heading|$PASSED
a NONE-association reviewer's unparsed section leaves the verdict at pass|author|stranger|COMMENTED|$HEAD|no-count-prose|$PASSED
ROWS

echo "=== the head-bound disposition comments ==="
# A row is `label|body|pr author|commenter|bound|reply|want`: the review
# body, then one PR comment by the commenter opening `Dispositions at BOUND`
# over the reply lines (`\n` between them). A reply counts from the PR
# author, an app author included, the identity the check reads as, or a
# repository member, each matched by account id, never by login.
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
H6="${HEAD:0:6}"
H7="${HEAD:0:7}"
O7="${OTHER:0:7}"
while IFS='|' read -r label body author commenter bound reply want; do
  [ -n "$label" ] || continue
  world "$author"
  at_head "$(reply_body_of "$body")"
  comments_set "$(comment "$commenter" "$(eval "printf 'Dispositions at %s:\n%b' \"$bound\" \"$reply\"")")"
  assert_eq "$(run)" "$(eval "printf '%s' \"$want\"")" "$label"
done <<'ROWS'
a bound reasoned decline and a tracked entry clear the block|heading|author|author|$H7|**$SUPP_FIRST** - $SUPP_REASON\n**$SUPP_SECOND** - Tracked: KEN-1400|$PASSED
entries named bare, as this output prints them, clear the block|heading|author|author|$H7|$SUPP_FIRST - $SUPP_REASON\n$SUPP_SECOND - Tracked: KEN-1400|$PASSED
entries backticked, as the newer body prints them, clear the block|v2|author|author|$H7|\`$SUPP_FIRST\` - $SUPP_REASON\n\`$SUPP_SECOND\` - Tracked: KEN-1400|$PASSED
entries carrying the body's zero-width spaces clear the block|v2|author|author|$H7|\`$(supp_zwsp "$SUPP_FIRST")\` - $SUPP_REASON\n\`$(supp_zwsp "$SUPP_SECOND")\` - Tracked: KEN-1400|$PASSED
a head prefix shorter than 7 characters binds nothing|heading|author|author|$H6|**$SUPP_FIRST** - $SUPP_REASON\n**$SUPP_SECOND** - Tracked: KEN-1400|$BOTH_STANDING
the full head sha binds as its prefix does|heading|author|author|$HEAD|**$SUPP_FIRST** - $SUPP_REASON\n**$SUPP_SECOND** - Tracked: KEN-1400|$PASSED
a comment naming the head still answers a Fixed-in entry|heading|author|author|$H7|**$SUPP_FIRST** - Fixed in $HEAD\n**$SUPP_SECOND** - $SUPP_REASON|$PASSED
a comment tied to the head only by its own Fixed-in sha answers nothing|heading|author|author|$O7|**$SUPP_FIRST** - Fixed in $HEAD\n**$SUPP_SECOND** - $SUPP_REASON|$BOTH_STANDING
a label-only decline answers nothing|heading|author|author|$H7|**$SUPP_FIRST** - Declined: out of scope\n**$SUPP_SECOND** - Declined: pre-existing|$BOTH_STANDING
a reply naming an issue that is neither a disposition nor a tracking claim answers nothing|heading|author|author|$H7|**$SUPP_FIRST** - see KEN-12\n**$SUPP_SECOND** - see KEN-12|$BOTH_STANDING
a tracking claim naming no issue answers nothing|heading|author|author|$H7|**$SUPP_FIRST** - Tracking this separately.\n**$SUPP_SECOND** - Tracking this separately.|$BOTH_STANDING
a reply bound to another head answers nothing|heading|author|author|$O7|**$SUPP_FIRST** - $SUPP_REASON\n**$SUPP_SECOND** - Tracked: KEN-1400|$BOTH_STANDING
a reply by a NONE-association login answers nothing|heading|author|stranger|$H7|**$SUPP_FIRST** - $SUPP_REASON\n**$SUPP_SECOND** - Tracked: KEN-1400|$BOTH_STANDING
an answered entry leaves the count and the unanswered one stands|heading|author|author|$H7|**$SUPP_FIRST** - $SUPP_REASON|$SECOND_STANDING
the newest line naming an entry decides|heading|author|author|$H7|**$SUPP_FIRST** - $SUPP_REASON\n**$SUPP_SECOND** - Tracked: KEN-1400\n**$SUPP_FIRST** - Declined: frozen|$FIRST_STANDING
a bare entry whose path carries a space is answered|spaced|author|author|$H7|$SUPP_SPACED - $SUPP_REASON|$PASSED
a shorter entry does not claim a longer entry's line|short-long|author|author|$H7|$SUPP_LONGER - Tracked: KEN-1400|$FAILED | suppressed-findings count=1 | suppressed-entry $SUPP_SHORT
a line names one entry, the longest it opens with|stem|author|author|$H7|$SUPP_EXTENDS - Tracked: KEN-1400|$FAILED | suppressed-findings count=1 | suppressed-entry $SUPP_STEM
a maintainer's comment answers for the author|heading|author|maintainer|$H7|**$SUPP_FIRST** - $SUPP_REASON\n**$SUPP_SECOND** - Tracked: KEN-1400|$PASSED
an app author's own comment answers|heading|app|app|$H7|**$SUPP_FIRST** - $SUPP_REASON\n**$SUPP_SECOND** - Tracked: KEN-1400|$PASSED
the reading identity's comment answers on a person's PR|heading|author|app|$H7|**$SUPP_FIRST** - $SUPP_REASON\n**$SUPP_SECOND** - Tracked: KEN-1400|$PASSED
the reading identity's label-only decline answers nothing|heading|author|app|$H7|**$SUPP_FIRST** - Declined: frozen\n**$SUPP_SECOND** - Tracked separately|$BOTH_STANDING
a User named like the app answers nothing for the app author|heading|app|impostor|$H7|**$SUPP_FIRST** - $SUPP_REASON\n**$SUPP_SECOND** - Tracked: KEN-1400|$BOTH_STANDING
a User named like the app answers nothing for the reading identity|heading|author|impostor|$H7|**$SUPP_FIRST** - $SUPP_REASON\n**$SUPP_SECOND** - Tracked: KEN-1400|$BOTH_STANDING
ROWS

# Two reviews whose section counts cancel, every parsed entry answered: the
# finding the under-counted section never parsed still fails the check.
CANCEL_ANSWERED='reviews_set "$(review copilot COMMENTED "$HEAD" "$SUPP_UNDER")" "$(review copilot COMMENTED "$HEAD" "$SUPP_OVER")"; comments_set "$(comment author "$(printf "Dispositions at %s:\n**%s** - Tracked: KEN-1400\n**%s** - Tracked: KEN-1400\n**%s** - Tracked: KEN-1400" "$H7" "$SUPP_FIRST" "$SUPP_SECOND" "$SUPP_THIRD")")"'
world
eval "$CANCEL_ANSWERED"
assert_eq "$(run)" "$FAILED | suppressed-findings state=mismatch sections=2" \
  "two reviews whose counts cancel each fail as a mismatch, answers or not"

# An answer whose author does not count is named, so the author can see why
# it answered nothing. An app login carries a bracket expression.
world
at_head "$(body_of heading)"
comments_set "$(comment stranger "$(printf 'Dispositions at %s:\n**%s** - %s' "$H7" "$SUPP_FIRST" "$SUPP_REASON")")" \
  "$(comment copilot "$(printf 'Dispositions at %s:\n**%s** - %s' "$H7" "$SUPP_SECOND" "$SUPP_REASON")")"
run >/dev/null
assert_eq "$(grep '^suppressed-findings: ignored-author ' "$TMP_ROOT/stderr" | paste -s -d '|' -)" \
  'suppressed-findings: ignored-author login=copilot-pull-request-reviewer[bot]|suppressed-findings: ignored-author login=stranger' \
  "each head-bound answer by an author who does not count is named on stderr"

# The marker is the comment's first non-blank line and its only one, and
# nothing else binds. Each body below carries the head prefix somewhere
# other than a lone marker on the first non-blank line, but the last.
SUPP_HEXPATH="${HEAD:0:8}.ts:1"
# Each body answers both entries once it binds, so a rule binding a marker
# on any line passes all three; the must-fail controls below run that rule.
MARKER_BELOW="Thanks for the review.\nDispositions at $H7:\n**$SUPP_FIRST** - $SUPP_REASON\n**$SUPP_SECOND** - Tracked: KEN-1400"
MARKER_FENCED="The answers below take this shape:\n\`\`\`\nDispositions at $H7:\n\`\`\`\n**$SUPP_FIRST** - $SUPP_REASON\n**$SUPP_SECOND** - Tracked: KEN-1400"
MARKER_TWO_HEADS="Dispositions at $H7:\n**$SUPP_FIRST** - $SUPP_REASON\n\nDispositions at $O7:\n**$SUPP_SECOND** - Tracked: KEN-1400"
while IFS='|' read -r label body reply want; do
  [ -n "$label" ] || continue
  world
  at_head "$(eval "$body")"
  comments_set "$(comment author "$(eval "printf '%b' \"$reply\"")")"
  assert_eq "$(run)" "$(eval "printf '%s' \"$want\"")" "$label"
done <<'ROWS'
a head prefix in a path with no marker binds nothing|one_entry "$SUPP_HEXPATH"|Dispositions:\n$SUPP_HEXPATH - $SUPP_REASON|$FAILED | suppressed-findings count=1 | suppressed-entry $SUPP_HEXPATH
a marker quoted mid-line binds nothing|body_of heading|The other PR says Dispositions at $H7, which is this head.\n**$SUPP_FIRST** - $SUPP_REASON\n**$SUPP_SECOND** - Tracked: KEN-1400|$BOTH_STANDING
a comment marked for an older head answers nothing at this one|body_of heading|Dispositions at $O7:\nsrc/model/lanes.ts:9 - Fixed in $HEAD\n**$SUPP_FIRST** - $SUPP_REASON\n**$SUPP_SECOND** - Tracked: KEN-1400|$BOTH_STANDING
a current marker below the first line binds nothing|body_of heading|$MARKER_BELOW|$BOTH_STANDING
a current marker inside a fenced example binds nothing|body_of heading|$MARKER_FENCED|$BOTH_STANDING
a first-line current marker beside an older head's section binds nothing|body_of heading|$MARKER_TWO_HEADS|$BOTH_STANDING
a marker after leading blank lines binds|body_of heading|\n  \nDispositions at $H7:\n**$SUPP_FIRST** - $SUPP_REASON\n**$SUPP_SECOND** - Tracked: KEN-1400|$PASSED
ROWS

echo "=== the thread rules, wired to the verdict ==="
# A row is `label|pr author|thread|want`. A reply counts from the PR author,
# whatever its actor type, from the identity the check reads as, or from a
# repository member, each matched by account id; nobody else moves a
# thread's standing reply.
while IFS='|' read -r label author node want; do
  [ -n "$label" ] || continue
  world "$author"
  threads_set "$(eval "$node")"
  assert_eq "$(run)" "$(eval "printf '%s' \"$want\"")" "$label"
done <<'ROWS'
a reasoned decline and a tracked reply pass|author|thread_node author 'Declined: the caller rejects the empty case first.'|$PASSED
a tracking claim naming no issue fails|author|thread_node author 'Out of scope, tracked.'|$FAILED | untracked-claim count=1
a decline naming no mechanism fails|author|thread_node author 'Declined: frozen'|$FAILED | unreasoned-decline count=1
a review bot's label-only decline is exempt|author|thread_node copilot 'Declined: frozen'|$PASSED
an app author's label-only decline fails|app|thread_node app 'Declined: frozen'|$FAILED | unreasoned-decline count=1
an app author's tracking claim naming no issue fails|app|thread_node app 'Tracked separately'|$FAILED | untracked-claim count=1
a NONE-association Fixed in does not replace the author's untracked claim|author|thread_node author 'Out of scope, tracked.' stranger 'Fixed in 1a2b3c4'|$FAILED | untracked-claim count=1
a NONE-association tracking claim raises nothing|author|thread_node stranger 'Tracking this separately.'|$PASSED
a maintainer's reasoned decline replaces the author's untracked claim|author|thread_node author 'Out of scope, tracked.' maintainer 'Declined: the caller rejects the empty case first.'|$PASSED
the reading identity's label-only decline fails on a person's PR|author|thread_node app 'Declined: frozen'|$FAILED | unreasoned-decline count=1
the reading identity's lone tracking claim fails on a person's PR|author|thread_node app 'Tracked separately'|$FAILED | untracked-claim count=1
the reading identity's reasoned decline replaces the author's untracked claim|author|thread_node author 'Out of scope, tracked.' app 'Declined: the caller rejects the empty case first.'|$PASSED
a User named like the app does not replace the app author's untracked claim|app|thread_node app 'Out of scope, tracked.' impostor 'Fixed in 1a2b3c4'|$FAILED | untracked-claim count=1
a User named like the app does not replace the author's claim as the reading identity|author|thread_node author 'Out of scope, tracked.' impostor 'Fixed in 1a2b3c4'|$FAILED | untracked-claim count=1
a maintainer's finding saying tracked is no reply and passes|author|rooted_node maintainer 'Is this tracked anywhere? The caller can pass an empty list.'|$PASSED
a reply under a maintainer's finding is judged|author|rooted_node maintainer 'Is this tracked anywhere?' author 'Out of scope, tracked.'|$FAILED | untracked-claim count=1
a thread holding more comments than one read returns fails|author|jq -cn '{comments: {totalCount: 101, nodes: [{author: {login: "pr-author", __typename: "User"}, body: "Tracked: KEN-1"}]}}'|$FAILED | thread-replies state=truncated threads=1
ROWS

# Every failing rule reports, each on its own line, in a fixed order.
world
threads_set "$(thread_node author 'Out of scope, tracked.')" "$(thread_node author 'Declined: frozen')"
at_head "$(body_of heading)"
assert_eq "$(run)" "$FAILED | untracked-claim count=1 | unreasoned-decline count=1 | suppressed-findings count=2 | suppressed-entry $SUPP_FIRST | suppressed-entry $SUPP_SECOND" \
  "every failing rule reports, the head named on the first line"
assert_eq "$(sed -n 1p "$TMP_ROOT/stdout")" "review-replies: fail head=$HEAD" "the first line names the whole head sha"

echo "=== a live read: a reply edit without a push changes the verdict ==="
# The same head throughout; only what the replies say changes between reads.
world
threads_set "$(thread_node author 'Declined: frozen')"
assert_eq "$(run)" "$FAILED | unreasoned-decline count=1" "the label-only decline fails at this head"
threads_set "$(thread_node author 'Declined: the caller rejects the empty case first.')"
assert_eq "$(run)" "$PASSED" "the edited reply passes at the same head"
at_head "$(body_of heading)"
assert_eq "$(run)" "$BOTH_STANDING" "a review body's findings fail at the same head"
comments_set "$(comment author "$(printf 'Dispositions at %s:\n**%s** - %s\n**%s** - Tracked: KEN-1400' "$H7" "$SUPP_FIRST" "$SUPP_REASON" "$SUPP_SECOND")")"
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
a pull request naming no head|gh_stub_answer "$PR_PATH" '{"user":{"login":"pr-author","id":1001},"head":{}}'|check-review-replies: read-malformed pr=7
a pull request whose author carries no account id|gh_stub_answer "$PR_PATH" "{\"user\":{\"login\":\"pr-author\"},\"head\":{\"sha\":\"$HEAD\"}}"|check-review-replies: read-malformed pr=7
a viewer identity read that fails|gh_stub_answer "$VIEWER_QUERY" '{"errors":[{"type":"FORBIDDEN","message":"no"}]}'|check-review-replies: read-failed pr=7
a viewer identity read naming no account id|viewer_set '{"login":"lanes-app[bot]"}'|check-review-replies: read-malformed pr=7
a viewer identity read naming a login for an id|viewer_set '{"login":"lanes-app[bot]","databaseId":"lanes-app"}'|check-review-replies: read-malformed pr=7
a thread read that fails|gh_stub_answer "$THREADS_QUERY" '{"errors":[{"type":"FORBIDDEN","message":"no"}]}'|check-review-replies: read-failed pr=7
a reviews read that fails|gh_stub_fail "$REVIEWS_PATH" 1 'gh: Not Found (HTTP 404)'|check-review-replies: read-failed pr=7
a reviews read producing zero bytes|gh_stub_answer "$REVIEWS_PATH" ''|check-review-replies: read-malformed pr=7
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
threads_set "$(thread_node author 'Declined: frozen')"
assert_eq "$(run "$TMP_ROOT/alone/skills/github/scripts/commands/check-review-replies.sh")" "$FAILED | unreasoned-decline count=1" \
  "a copy of the github skill with no review-gate beside it judges the replies"

echo "=== through the router, with project credentials and no saved gh login ==="
# A caller runs github.sh check-review-replies, which loads the project env
# and selects its token before the first read. This gh answers only the
# project's bot token, as a host with no saved login does.
mkdir -p "$TMP_ROOT/authbin" "$TMP_ROOT/project"
git -C "$TMP_ROOT/project" init -q
git -C "$TMP_ROOT/project" config gc.auto 0
git -C "$TMP_ROOT/project" config maintenance.auto false
printf 'GH_BOT_TOKEN=ghs_PROJECTBOT\n' >"$TMP_ROOT/project/.env.local"
printf '#!/usr/bin/env bash\n[ "${GH_TOKEN:-}" = ghs_PROJECTBOT ] || { echo "To get started with GitHub CLI, please run:  gh auth login" >&2; exit 4; }\nexec %q "$@"\n' \
  "$TMP_ROOT/bin/gh" >"$TMP_ROOT/authbin/gh"
chmod +x "$TMP_ROOT/authbin/gh"
routed() { # SUBJECT... — run in a project whose only credential is its .env.local
  local rc=0
  (cd "$TMP_ROOT/project" && env -u GH_TOKEN -u GITHUB_TOKEN -u GH_BOT_TOKEN -u GH_REPO -u GH_CONFIG_DIR -u KENDEX_ENV_FILE \
    PATH="$TMP_ROOT/authbin:$PATH" "$@" 7 >"$TMP_ROOT/stdout" 2>"$TMP_ROOT/stderr") || rc=$?
  printf 'rc=%s %s' "$rc" "$(sed "s/$HEAD/{head}/g" "$TMP_ROOT/stdout" | paste -s -d '|' - | sed 's/|/ | /g')"
}
world
threads_set "$(thread_node author 'Declined: frozen')"
assert_eq "$(routed "$GITHUB_SH" check-review-replies)" "$FAILED | unreasoned-decline count=1" \
  "the router reads with the project's bot token"
assert_eq "$(routed "$CHECKER"; printf ' %s' "$(first_err)")" "rc=2  check-review-replies: repo-unresolved pr=7" \
  "the command file alone, with no token selected, reaches no verdict"
script=$(mutant_copy_edit "$TMP_ROOT/router-tokenless" '    kendex_github_apply_selected_auth_token router || true' '    true' github.sh)
assert_eq "$(routed "$script" check-review-replies; printf ' %s' "$(first_err)")" "rc=2  check-review-replies: repo-unresolved pr=7" \
  "must-fail: with the router's token selection cut, no read succeeds"

echo "=== must-fail controls ==="
# A row is `label|name|from line|to line|setup|want with the mutant`. The
# setup's live verdict is pinned in a section above; with its rule's line
# replaced, the same setup answers what the row names instead. A refusal
# prints nothing on stdout, so its first stderr line joins what it answered.
# FILE names a lib the rule lives in instead of the checker.
mutant_row() { # LABEL NAME FROM TO SETUP WANT [PR_AUTHOR [FILE]]
  local script got
  mutant_copy_edit "$TMP_ROOT/$2" "$3" "$4" "${8:-commands/check-review-replies.sh}" >/dev/null
  script="$TMP_ROOT/$2/skills/github/scripts/commands/check-review-replies.sh"
  world "${7:-author}"
  eval "$5"
  got=$(run "$script")
  [ "$got" != "rc=2 " ] || got="$got $(first_err)"
  assert_eq "$got" "$6" "must-fail: $1"
}
READ_FAILED='rc=2  check-review-replies: read-failed pr=7'
mutant_row "with the untracked-claim line cut, the claim passes" untracked \
  '[ "$untracked" = 0 ] || {' '[ true ] || {' \
  'threads_set "$(thread_node author "Out of scope, tracked.")"' "$PASSED"
mutant_row "with the unreasoned-decline line cut, the label passes" unreasoned \
  '[ "$unreasoned" = 0 ] || {' '[ true ] || {' \
  'threads_set "$(thread_node author "Declined: frozen")"' "$PASSED"
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
  'elif [ "$supp_mismatched" != 0 ]; then' 'elif false; then' \
  'at_head "$(body_of count-prose)"' "$PASSED"
mutant_row "with section counts summed, two reviews whose counts cancel pass" section-sum \
  '      if .section != null and .section.declared != .section.parsed then .mismatched += 1 else . end' '      if .section != null then .mismatched += (.section.declared - .section.parsed) else . end' \
  "$CANCEL_ANSWERED" "$PASSED"
mutant_row "with the head filter cut, an earlier head's review fails this one" head-review \
  '      | select(.commit_id == $sha and .state != "DISMISSED" and .state != "PENDING")' '      | select(.state != "DISMISSED" and .state != "PENDING")' \
  'reviews_set "$(review copilot COMMENTED "$OTHER" "$(body_of heading)")"' "$BOTH_STANDING"
MARKER_RULE='        | $marks[0] != null and ($sha | ascii_downcase | startswith($marks[0])) and ([$marks[] | values] | length == 1);'
mutant_row "with the head binding cut, a comment for an older head answers" head-bound \
  "$MARKER_RULE" '        | $marks[0] != null and ([$marks[] | values] | length == 1);' \
  'at_head "$(body_of heading)"; comments_set "$(comment author "$(printf "Dispositions at %s:\n**%s** - %s\n**%s** - Tracked: KEN-1400" "$O7" "$SUPP_FIRST" "$SUPP_REASON" "$SUPP_SECOND")")"' "$PASSED"
# A marker on any line binding the comment is the rule the first-line
# marker replaced; each body it would bind answers both entries.
ANY_LINE_CUT=("$MARKER_RULE" '        | [$marks[] | values | . as $c | select($sha | ascii_downcase | startswith($c))] | length > 0;')
mutant_row "with a marker on any line binding, a marker below the first line answers" any-line-below \
  "${ANY_LINE_CUT[@]}" \
  'at_head "$(body_of heading)"; comments_set "$(comment author "$(printf "%b" "$MARKER_BELOW")")"' "$PASSED"
mutant_row "with a marker on any line binding, a fenced marker answers" any-line-fenced \
  "${ANY_LINE_CUT[@]}" \
  'at_head "$(body_of heading)"; comments_set "$(comment author "$(printf "%b" "$MARKER_FENCED")")"' "$PASSED"
mutant_row "with a marker on any line binding, an older head's section answers" any-line-two-heads \
  "${ANY_LINE_CUT[@]}" \
  'at_head "$(body_of heading)"; comments_set "$(comment author "$(printf "%b" "$MARKER_TWO_HEADS")")"' "$PASSED"
mutant_row "with blank lines kept, a marker after a leading blank line binds nothing" blank-lines \
  '        [ split("\n")[] | select(test("\\S")) | marker_sha($floor) ] as $marks' '        [ split("\n")[] | marker_sha($floor) ] as $marks' \
  'at_head "$(body_of heading)"; comments_set "$(comment author "$(printf "\n  \nDispositions at %s:\n**%s** - %s\n**%s** - Tracked: KEN-1400" "$H7" "$SUPP_FIRST" "$SUPP_REASON" "$SUPP_SECOND")")"' "$BOTH_STANDING"
mutant_row "with the comment author filter cut, another login answers" comment-author \
  '      | [ .[] | select(rest_actor | reply_source($author; $viewer)) | answers($by_length) ] as $said' '      | [ .[] | answers($by_length) ] as $said' \
  'at_head "$(body_of heading)"; comments_set "$(comment stranger "$(printf "Dispositions at %s:\n**%s** - %s\n**%s** - Tracked: KEN-1400" "$H7" "$SUPP_FIRST" "$SUPP_REASON" "$SUPP_SECOND")")"' "$PASSED"
# The login compare the account id replaced, case and [bot] suffix folded:
# under it a User registered under the app's slug is the app.
LOGIN_COMPARE=('  def same_account($account): .id != null and .id == $account.id;' '  def same_account($account): .login != "" and (.login | ascii_downcase | sub("\\[bot\\]$"; "")) == ($account.login | ascii_downcase | sub("\\[bot\\]$"; ""));')
mutant_row "with logins compared, a User named like the app clears the app author's claim" login-thread \
  "${LOGIN_COMPARE[@]}" \
  'threads_set "$(thread_node app "Out of scope, tracked." impostor "Fixed in 1a2b3c4")"' "$PASSED" app
mutant_row "with logins compared, a User named like the app answers as the reading identity" login-disposition \
  "${LOGIN_COMPARE[@]}" \
  'at_head "$(body_of heading)"; comments_set "$(comment impostor "$(printf "Dispositions at %s:\n**%s** - %s\n**%s** - Tracked: KEN-1400" "$H7" "$SUPP_FIRST" "$SUPP_REASON" "$SUPP_SECOND")")"' "$PASSED"
mutant_row "with the finding-source test cut to the author, a NONE-association section fails" finding-source \
  '  def finding_source($author): (same_account($author) | not) and (.bot or member);' '  def finding_source($author): same_account($author) | not;' \
  'reviews_set "$(review stranger COMMENTED "$HEAD" "$(body_of no-count-prose)")"' "$FAILED | suppressed-findings state=unparsed"
# One definition holds the reading identity for every reader, so one cut of
# it reaches the thread rules and the disposition read alike.
VIEWER_CUT=('  def reply_source($author; $viewer): same_account($author) or same_account($viewer) or member;' '  def reply_source($author; $viewer): same_account($author) or member;')
mutant_row "with the reading identity cut, its label-only decline passes" viewer-decline \
  "${VIEWER_CUT[@]}" \
  'threads_set "$(thread_node app "Declined: frozen")"' "$PASSED"
mutant_row "with the reading identity cut, its lone tracking claim passes" viewer-claim \
  "${VIEWER_CUT[@]}" \
  'threads_set "$(thread_node app "Tracked separately")"' "$PASSED"
mutant_row "with the reading identity cut, its disposition comment answers nothing" viewer-answer \
  "${VIEWER_CUT[@]}" \
  'at_head "$(body_of heading)"; comments_set "$(comment app "$(printf "Dispositions at %s:\n**%s** - %s\n**%s** - Tracked: KEN-1400" "$H7" "$SUPP_FIRST" "$SUPP_REASON" "$SUPP_SECOND")")"' "$BOTH_STANDING"
mutant_row "with the account id test cut, a viewer read naming no id reaches a verdict" account-id \
  '    | if (.id | type) == "number" and .id > 0 and .id == (.id | floor)' '    | if true' \
  "viewer_set '{\"login\":\"lanes-app[bot]\"}'" "$PASSED"
# GraphQL's Actor interface carries no databaseId; the User and Bot
# fragments read it, and the viewer selects its own.
mutant_row "with the Bot id fragment cut, the thread read reaches no verdict" thread-bot-id \
  "                          comments(first: 100) { totalCount nodes { author { login __typename ... on User { databaseId } ... on Bot { databaseId } } authorAssociation body } }' 2>\"\$READ_ERR\") ||" \
  "                          comments(first: 100) { totalCount nodes { author { login __typename ... on User { databaseId } } authorAssociation body } }' 2>\"\$READ_ERR\") ||" \
  'threads_set "$(thread_node app "Declined: frozen")"' "$READ_FAILED"
mutant_row "with the viewer id selection cut, the viewer read reaches no verdict" viewer-id \
  "    data=\$(gh_graphql 'query { viewer { login databaseId } }') || return 1" \
  "    data=\$(gh_graphql 'query { viewer { login } }') || return 1" \
  'threads_set "$(thread_node app "Declined: frozen")"' "$READ_FAILED" author lib/github-api.sh
mutant_row "with every association a member, a NONE-association Fixed in clears the claim" member-open \
  '  def member: .association == "OWNER" or .association == "MEMBER" or .association == "COLLABORATOR";' '  def member: true;' \
  'threads_set "$(thread_node author "Out of scope, tracked." stranger "Fixed in 1a2b3c4")"' "$PASSED"
mutant_row "with no association a member, a maintainer's answer answers nothing" member-closed \
  '  def member: .association == "OWNER" or .association == "MEMBER" or .association == "COLLABORATOR";' '  def member: false;' \
  'at_head "$(body_of heading)"; comments_set "$(comment maintainer "$(printf "Dispositions at %s:\n**%s** - %s\n**%s** - Tracked: KEN-1400" "$H7" "$SUPP_FIRST" "$SUPP_REASON" "$SUPP_SECOND")")"' "$BOTH_STANDING"
mutant_row "with the reply reason test cut, a label-only decline answers" reply-reason \
  '      def unanswered: ((disposition or tracking) | not) or untracked_claim or unreasoned_decline;' '      def unanswered: ((disposition or tracking) | not) or untracked_claim;' \
  'at_head "$(body_of heading)"; comments_set "$(comment author "$(printf "Dispositions at %s:\n**%s** - Declined: out of scope\n**%s** - Declined: pre-existing" "$H7" "$SUPP_FIRST" "$SUPP_SECOND")")"' "$PASSED"
mutant_row "with the reply form test cut, a reply naming only an issue answers" reply-form \
  '      def unanswered: ((disposition or tracking) | not) or untracked_claim or unreasoned_decline;' '      def unanswered: false or untracked_claim or unreasoned_decline;' \
  'at_head "$(body_of heading)"; comments_set "$(comment author "$(printf "Dispositions at %s:\n**%s** - see KEN-12\n**%s** - see KEN-12" "$H7" "$SUPP_FIRST" "$SUPP_SECOND")")"' "$PASSED"
mutant_row "with the head prefix floor lowered to 6, a 6-character prefix binds" sha-floor \
  'SHA_FLOOR=7' 'SHA_FLOOR=6' \
  'at_head "$(body_of heading)"; comments_set "$(comment author "$(printf "Dispositions at %s:\n**%s** - %s\n**%s** - Tracked: KEN-1400" "$H6" "$SUPP_FIRST" "$SUPP_REASON" "$SUPP_SECOND")")"' "$PASSED"
mutant_row "with the CR strip cut, a CRLF body no longer reads as the block" crlf \
  "SUPP_NORMALIZE_DEF='def display_strip: gsub(\"\\r\"; \"\") | gsub(\"\\u200b\"; \"\");" "SUPP_NORMALIZE_DEF='def display_strip: gsub(\"\\u200b\"; \"\");" \
  'at_head "$(body_of crlf)"' "$FAILED | suppressed-findings state=unparsed"
mutant_row "with the zero-width strip cut, a Copilot path retains display spaces" zwsp \
  "SUPP_NORMALIZE_DEF='def display_strip: gsub(\"\\r\"; \"\") | gsub(\"\\u200b\"; \"\");" "SUPP_NORMALIZE_DEF='def display_strip: gsub(\"\\r\"; \"\");" \
  'at_head "$(body_of copilot)"' "$FAILED | suppressed-findings count=1 | suppressed-entry $(supp_zwsp "$COPILOT_ENTRY")"
mutant_row "with the page-shape test cut, a non-array reviews page reads as no review" page-shape \
  "    jq -s 'if (length > 0) and all(type == \"array\") then add else error(\"pages are not arrays\") end' <<<\"\$raw\" 2>/dev/null || {" \
  "    jq -s '[.[] | arrays] | add // []' <<<\"\$raw\" 2>/dev/null || {" \
  "at_head \"\$(body_of heading)\"; gh_stub_answer \"\$REVIEWS_PATH\" '{\"message\":\"Server Error\"}'" "$PASSED" author lib/github-api.sh
mutant_row "with the body scan cut, only thread state is read and a body-only finding passes" body-scan \
  '      | (.body // "") | suppressed_scan' '      | "" | suppressed_scan' \
  'at_head "$(body_of copilot)"' "$PASSED"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
