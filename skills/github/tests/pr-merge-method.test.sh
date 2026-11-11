#!/usr/bin/env bash
# pr-merge's merge method and branch deletion, both read from GitHub: the
# method the base branch allows (its merge queue's, else the repository's
# allowed methods narrowed by its pull_request rules) chosen in the order the
# caller accepts, the one-line refusal where none is allowed or the read
# fails, --dry-run naming the method and --check reading none, and the head
# branch deleted only on --delete-branch where the repository's
# delete_branch_on_merge is off and the head is not a fork's. The row format and the world words are
# lib/pr-merge-world.sh's.
set -euo pipefail

# shellcheck source=lib/pr-merge-world.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/pr-merge-world.sh"

MERGED="MERGED PR #123"
# The method-only fixture has no ruleset ids. A live arm reads that
# fixture as a mixed queue ruleset; it still selects the queue's method.
QUEUE_ROUTE="merge-route: queue cause=queue-ruleset-mixed ruleset=null rule=required_status_checks"
QUEUED="$QUEUE_ROUTE;QUEUED IN MERGE QUEUE PR #123 — queueState=QUEUED;volatile-note"
DONE="checks:ci-required post:MERGED merge-commit:merged-oid"

run_table "the merge method" "\
a repository that allows merge commits alone merges with --merge|$DONE methods:merge|immediate|0|-|$MERGED|calls=$PRE,merge:merge,graphql:queue auth=<unset>
one that allows squash keeps squash|$DONE methods:squash+merge+rebase|immediate|0|-|$MERGED|calls=$PRE,merge:squash,graphql:queue auth=<unset>
one that allows rebase alone merges with --rebase|$DONE methods:rebase|immediate|0|-|$MERGED|calls=$PRE,merge:rebase,graphql:queue auth=<unset>
a pull_request rule narrows the repository's set|$DONE methods:squash+merge+rebase rule-methods:rebase+merge|immediate|0|-|$MERGED|calls=$PRE,merge:merge,graphql:queue auth=<unset>
a merge queue's method wins over the repository's|checks:ci-required post-queue methods:squash queue:MERGE|auto|75|-|$QUEUED|calls=$PRE,merge:merge:auto,graphql:queue auth=<unset>
the caller's order decides among the allowed methods|$DONE methods:squash+merge+rebase|with:--rebase+--merge|0|-|$MERGED|calls=$PRE,merge:rebase,graphql:queue auth=<unset>
a base allowing none of the accepted methods refuses on one line, nothing mutated|$DONE methods:merge|with:--squash|1|-|pr-merge: merge-method allowed=merge accepted=squash|calls=$PRE auth=<unset>
a queue method the caller does not accept refuses the same way|checks:ci-required post-queue queue:MERGE|with:--squash+--rebase+--auto|1|-|$QUEUE_ROUTE;pr-merge: merge-method allowed=merge accepted=squash,rebase|calls=$PRE auth=<unset>
a repository allowing no method names none|$DONE methods:-|immediate|1|-|pr-merge: merge-method allowed=none accepted=squash,merge,rebase|calls=$PRE auth=<unset>
settings GitHub withholds from a token without push access refuse as unreadable|$DONE repo:pushless|immediate|1|-|pr-merge: merge-method-unreadable cause=settings|calls=$PRE auth=<unset>
a base whose rules cannot be read refuses as unreadable|$DONE rules:fail|immediate|1|-|pr-merge: merge-method-unreadable cause=rules|calls=$PRE auth=<unset>
a pull request into develop takes develop's queue method|checks:ci-required post-queue base:develop queue-on:develop queue:MERGE methods:squash|auto|75|-|$QUEUED|calls=$PRE,merge:merge:auto,graphql:queue auth=<unset>
a pull request into main does not take develop's queue|$DONE base:main queue-on:develop queue:MERGE methods:squash|immediate|0|-|$MERGED|calls=$PRE,merge:squash,graphql:queue auth=<unset>
"

run_table "what --dry-run and --check read" "\
--dry-run names the method a merge-only repository allows|$DONE methods:merge|with:--dry-run|0|Would merge PR #123 (--merge, mode=immediate, delete_branch=false, token=not configured)|-|calls=$CHECK auth=<unset>
--check never reads the method, so a repository allowing none still reports readiness|$DONE methods:-|check|0|merge=true transient=false $OPEN runs=- issues=[] warnings=[] $KEYS|mergeable;head-run: none|calls=$CHECK auth=<unset>
"

run_table "the head branch after a merge" "\
--delete-branch deletes it where the repository does not|$DONE deletes-on-merge:false|with:--delete-branch|0|-|$MERGED|calls=$PRE,merge:squash,graphql:queue,delete:issue-123 auth=<unset>
where delete_branch_on_merge is on GitHub deletes it, and pr-merge does not|$DONE deletes-on-merge:true|with:--delete-branch|0|-|$MERGED|calls=$PRE,merge:squash,graphql:queue auth=<unset>
no --delete-branch keeps it|$DONE deletes-on-merge:false|with:--squash|0|-|$MERGED|calls=$PRE,merge:squash,graphql:queue auth=<unset>
a delete_branch_on_merge read that fails keeps it and says so|$DONE deletes-on-merge:null|with:--delete-branch|0|-|$MERGED;pr-merge: branch-kept branch=issue-123 cause=setting-unreadable|calls=$PRE,merge:squash,graphql:queue auth=<unset>
a fork's head is kept, and the same name in this repository is not deleted|$DONE deletes-on-merge:false cross-repository|with:--delete-branch|0|-|$MERGED;pr-merge: branch-kept branch=issue-123 cause=cross-repository|calls=$PRE,merge:squash,graphql:queue auth=<unset>
the fork answer holds when the post-merge read falls back to gh pr view|$DONE deletes-on-merge:false cross-repository graphql:fail|with:--delete-branch|0|-|$MERGED;pr-merge: branch-kept branch=issue-123 cause=cross-repository|calls=$PRE,merge:squash,graphql:queue,view:post auth=<unset>
"

# The suite's one must-fail control: a copy of the scripts tree with one
# whole line replaced (lib/pr-merge-world.sh mutant_copy), the method the
# merge passes pinned to squash, run in the world of the merge-only row,
# where it gives that row's wrong answer.
mutant_copy fixed '    local -a cmd=(pr merge "$pr_num" "--$method" --match-head-commit "$expected_head")' '    local -a cmd=(pr merge "$pr_num" --squash --match-head-commit "$expected_head")' >/dev/null || exit 2

run_table "the must-fail control" "\
must-fail: with the method pinned, a merge-only repository is squashed|$DONE methods:merge|mutant:fixed:--keep-branch|0|-|$MERGED|calls=$PRE,merge:squash,graphql:queue auth=<unset>
"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
