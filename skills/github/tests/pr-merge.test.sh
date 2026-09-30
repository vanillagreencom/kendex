#!/usr/bin/env bash
# pr-merge: the --check readiness JSON and its stderr verdict, which read no
# review thread, the terminal states (a merged or closed PR short-circuits
# every mode, before and after a state lookup that failed once), the guarded
# mutation and its post-call outcomes, the --auto arm's approval gate, the
# retired override flags, the retired merge settings, and the admin request,
# refused on the queue-only class harness-ci's classifier prints for the pull
# request's range. The row format and the world words are
# lib/pr-merge-world.sh's.
set -euo pipefail

# shellcheck source=lib/pr-merge-world.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/pr-merge-world.sh"

run_table "the readiness check" "\
pending checks block, transiently, one issue naming each|checks:pending2 checks-exit:8|check|0|merge=false transient=true $OPEN runs=- issues=[ci_pending: Cross-Platform (PENDING), Linux Integration (IN_PROGRESS)] warnings=[] $KEYS|blocked;head-run: none|calls=$CHECK auth=<unset>
a failed check blocks permanently|checks:failed|check|0|merge=false transient=false $OPEN runs=- issues=[ci_failed: Lint (FAILURE)] warnings=[] $KEYS|blocked;head-run: none|calls=$CHECK auth=<unset>
a red check the base branch does not require blocks nothing and is named as a warning|checks:optional-red required:Lint|check|0|merge=true transient=false $OPEN runs=- issues=[] warnings=[ci_optional_failed: CodeQL (FAILURE)] $KEYS|mergeable;head-run: none|calls=$CHECK auth=<unset>
a red required context still blocks|checks:optional-red required:CodeQL|check|0|merge=false transient=false $OPEN runs=- issues=[ci_failed: CodeQL (FAILURE)] warnings=[] $KEYS|blocked;head-run: none|calls=$CHECK auth=<unset>
a base that requires no context counts every check|checks:optional-red repo:no-rule|check|0|merge=false transient=false $OPEN runs=- issues=[ci_failed: CodeQL (FAILURE)] warnings=[] $KEYS|blocked;head-run: none|calls=$CHECK auth=<unset>
a classic protection context supplies the required set too|checks:optional-red classic:Lint|check|0|merge=true transient=false $OPEN runs=- issues=[] warnings=[ci_optional_failed: CodeQL (FAILURE)] $KEYS|mergeable;head-run: none|calls=$CHECK auth=<unset>
the legacy classic contexts array supplies it as well as checks[]|checks:optional-red classic-contexts:Lint|check|0|merge=true transient=false $OPEN runs=- issues=[] warnings=[ci_optional_failed: CodeQL (FAILURE)] $KEYS|mergeable;head-run: none|calls=$CHECK auth=<unset>
a ruleset rule that gates on no check keeps the required set readable|checks:optional-red rule-type:pull_request|check|0|merge=true transient=false $OPEN runs=- issues=[] warnings=[ci_optional_failed: CodeQL (FAILURE)] $KEYS|mergeable;head-run: none|calls=$CHECK auth=<unset>
a required-workflows rule gates on a check it never names, so every check counts|checks:optional-red rule-type:workflows|check|0|merge=false transient=false $OPEN runs=- issues=[ci_failed: CodeQL (FAILURE)] warnings=[] $KEYS|blocked;head-run: none|calls=$CHECK auth=<unset>
a code-scanning rule is the same unnameable gate|checks:optional-red rule-type:code_scanning|check|0|merge=false transient=false $OPEN runs=- issues=[ci_failed: CodeQL (FAILURE)] warnings=[] $KEYS|blocked;head-run: none|calls=$CHECK auth=<unset>
a Copilot review rule demands a review, not a check, so the required set stands|checks:optional-red rule-type:copilot_code_review|check|0|merge=true transient=false $OPEN runs=- issues=[] warnings=[ci_optional_failed: CodeQL (FAILURE)] $KEYS|mergeable;head-run: none|calls=$CHECK auth=<unset>
a ruleset read that errors discards the contexts classic protection did supply|checks:optional-red classic:Lint rules:fail|check|0|merge=false transient=false $OPEN runs=- issues=[ci_failed: CodeQL (FAILURE)] warnings=[] $KEYS|blocked;head-run: none|calls=$CHECK auth=<unset>
a branch-protection read that errors discards the contexts the ruleset did supply|checks:optional-red required:Lint branch:fail|check|0|merge=false transient=false $OPEN runs=- issues=[ci_failed: CodeQL (FAILURE)] warnings=[] $KEYS|blocked;head-run: none|calls=$CHECK auth=<unset>
a required context that registered no check is pending, never a pass|checks:unregistered required:Lint|check|0|merge=false transient=true $OPEN runs=- issues=[ci_pending: Lint (missing)] warnings=[ci_optional_failed: CodeQL (FAILURE)] $KEYS|blocked;head-run: none|calls=$CHECK auth=<unset>
an empty rollup with a required context is pending, not unconfigured|checks:none required:Lint|check|0|merge=false transient=true $OPEN runs=- issues=[ci_pending: Lint (missing)] warnings=[] $KEYS|blocked;head-run: none|calls=$CHECK auth=<unset>
an empty rollup on a base that requires nothing stays unconfigured|checks:none|check|0|merge=true transient=false $OPEN runs=- issues=[] warnings=[ci_unconfigured: No status checks configured] $KEYS|mergeable;head-run: none|calls=$CHECK auth=<unset>
an optional check still running blocks nothing either|checks:optional-pending checks-exit:8 required:Lint|check|0|merge=true transient=false $OPEN runs=- issues=[] warnings=[] $KEYS|mergeable;head-run: none|calls=$CHECK auth=<unset>
a branch answer carrying no protection object is unreadable, so every check counts|checks:optional-red required:Lint repo:no-protection|check|0|merge=false transient=false $OPEN runs=- issues=[ci_failed: CodeQL (FAILURE)] warnings=[] $KEYS|blocked;head-run: none|calls=$CHECK auth=<unset>
pending and failed together are not transient, both named|checks:mixed checks-exit:8|check|0|merge=false transient=false $OPEN runs=- issues=[ci_pending: Unit Tests (IN_PROGRESS);ci_failed: Lint (FAILURE)] warnings=[] $KEYS|blocked;head-run: none|calls=$CHECK auth=<unset>
success and skipped checks merge with no issue|checks:pass-skip|check|0|merge=true transient=false $OPEN runs=- issues=[] warnings=[] $KEYS|mergeable;head-run: none|calls=$CHECK auth=<unset>
a superseded run's cancelled jobs are not failures: only the current run's pending check blocks, transiently|checks:superseded-pending checks-exit:8|check|0|merge=false transient=true $OPEN runs=29099680623 issues=[ci_pending: Changes (IN_PROGRESS)] warnings=[] $KEYS|blocked;head-run: 29099680623|calls=$CHECK auth=<unset>
a job the current run re-created and passed is not blocked by the old run's cancelled copy|checks:superseded-replaced|check|0|merge=true transient=false $OPEN runs=29099680623 issues=[] warnings=[] $KEYS|mergeable;head-run: 29099680623|calls=$CHECK auth=<unset>
the current run's own cancellation is a failure|checks:current-cancel checks-exit:8|check|0|merge=false transient=false $OPEN runs=29099680623 issues=[ci_failed: Integration (CANCELLED)] warnings=[] $KEYS|blocked;head-run: 29099680623|calls=$CHECK auth=<unset>
a clean run: the verdict is mergeable and head-run names the scoped run|checks:clean-run|check|0|merge=true transient=false $OPEN runs=29099680623 issues=[] warnings=[] $KEYS|mergeable;head-run: 29099680623|calls=$CHECK auth=<unset>
a commit status with no workflow supplies its own run id|checks:status-only checks-exit:8|check|0|merge=false transient=true $OPEN runs=29099700000 issues=[ci_pending: CI Required (PENDING)] warnings=[] $KEYS|blocked;head-run: 29099700000|calls=$CHECK auth=<unset>
a changes-requested reviewDecision blocks permanently|checks:ci-required review:CHANGES_REQUESTED|check|0|merge=false transient=false $OPEN runs=- issues=[changes_requested: Reviewer requested changes] warnings=[] $KEYS|blocked;head-run: none|calls=$CHECK auth=<unset>
a changes-requested latest review blocks when the decision does not say so|checks:ci-required review:REVIEW_REQUIRED review-latest:CHANGES_REQUESTED|check|0|merge=false transient=false $OPEN runs=- issues=[changes_requested: Reviewer requested changes] warnings=[] $KEYS|blocked;head-run: none|calls=$CHECK auth=<unset>
a PR with no approval is named not_approved, a warning that blocks nothing here|checks:ci-required review:REVIEW_REQUIRED|check|0|merge=true transient=false $OPEN runs=- issues=[] warnings=[not_approved: Review status is 'REVIEW_REQUIRED'] $KEYS|mergeable;head-run: none|calls=$CHECK auth=<unset>
an approving latest review clears not_approved where the decision is empty|checks:ci-required review:none review-latest:APPROVED|check|0|merge=true transient=false $OPEN runs=- issues=[] warnings=[] $KEYS|mergeable;head-run: none|calls=$CHECK auth=<unset>
a merged PR reports its state and timestamp, no issues, no check fetched|state:MERGED merged-at|check|0|merge=false transient=false state=MERGED mergeable=UNKNOWN at=2026-08-15T09:41:12Z runs=- issues=[] warnings=[] $KEYS|merged;head-run: none|calls=view:state auth=<unset>
a closed PR reports its state, no issues|state:CLOSED|check|0|merge=false transient=false state=CLOSED mergeable=UNKNOWN at=- runs=- issues=[] warnings=[] $KEYS|closed;head-run: none|calls=view:state auth=<unset>
a missing PR is not_found|pr:missing|check|0|merge=false transient=false state=UNKNOWN mergeable=UNKNOWN at=- runs=- issues=[not_found: PR #123 not found] warnings=[] $KEYS|blocked;head-run: none|calls=view:state auth=<unset>
GitHub's own missing-PR wording is not_found too|state-err:graphql-notfound|check|0|merge=false transient=false state=UNKNOWN mergeable=UNKNOWN at=- runs=- issues=[not_found: PR #123 not found] warnings=[] $KEYS|blocked;head-run: none|calls=view:state auth=<unset>
an auth failure is gh_error with its diagnostic, never not_found|state-err:401|check|0|merge=false transient=false state=UNKNOWN mergeable=UNKNOWN at=- runs=- issues=[gh_error: gh: Bad credentials (HTTP 401)] warnings=[] $KEYS|blocked;head-run: none|calls=view:state auth=<unset>
a rate limit keeps its diagnostic|state-err:ratelimit|check|0|merge=false transient=false state=UNKNOWN mergeable=UNKNOWN at=- runs=- issues=[gh_error: API rate limit exceeded for user ID 1.] warnings=[] $KEYS|blocked;head-run: none|calls=view:state auth=<unset>
a silent failure names gh and its exit code|state-err:silent4|check|0|merge=false transient=false state=UNKNOWN mergeable=UNKNOWN at=- runs=- issues=[gh_error: gh pr view exited 4 with no diagnostic] warnings=[] $KEYS|blocked;head-run: none|calls=view:state auth=<unset>
"

run_table "the merge path" "\
a failed check without --auto is blocked with the auto hint|checks:failed|immediate|1|-|{blocked};{permanent};✗ ci_failed: Lint (FAILURE);{hint-auto}|calls=$CHECK auth=<unset>
a red optional check does not stop the merge, and is named on the way|checks:optional-red required:Lint post:MERGED merge-commit:merged-oid|immediate|0|-|Warnings:;⚠ ci_optional_failed: CodeQL (FAILURE);{no-token};MERGED PR #123|calls=$PRE,merge:squash,graphql:queue auth=<unset>
the router promotes the bot token for the mutation and the snapshot|checks:ci-required require-token post:MERGED merge-commit:merged-oid env:GH_BOT_TOKEN=ghp_test_token|router:--squash|0|-|Using GH_BOT_TOKEN as stub-user;MERGED PR #123|calls=user,$PRE,user,merge:squash,graphql:queue auth=ghp_test_token
a prepared head that drifted fails before arming|checks:ci-required head:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa|expected:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb|1|-|BLOCKED PR #123 — prepared head changed before merge attempt (expected=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb, actual=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa)|calls=$PRE auth=<unset>
an active queue entry after --auto is success-pending, exit 75, volatile|checks:ci-required head:28132e9b990a595417f79f4e213b4e984bf676fd post-entry require-token env:GH_BOT_TOKEN=ghp_test_token|auto|75|-|Using GH_BOT_TOKEN as stub-user;QUEUED IN MERGE QUEUE PR #123 — queueState=QUEUED;{volatile}|calls=$PRE,user,merge:squash:auto,graphql:queue auth=<unset>+ghp_test_token
--auto refuses where auto-merge is off: nothing mutated|checks:ci-required repo:no-auto|auto|1|-|arm: no-merge-gate=allow_auto_merge repo=owner/repo;{auto-remedy}|calls=$CHECK auth=<unset>
the refusal is the first stderr line, ahead of the checks' warnings|checks:none repo:no-auto|auto|1|-|arm: no-merge-gate=allow_auto_merge repo=owner/repo;{auto-remedy}|calls=$CHECK auth=<unset>
a base branch with slashes is URL-encoded in the gate reads and arms|checks:ci-required post-auto base:release/foo/bar|auto|75|-|{no-token};AUTO-MERGE ENABLED PR #123 — will fire when CI + branch protection clear;{volatile}|calls=$PRE,merge:squash:auto,graphql:queue auth=<unset>
classic auto-merge is success-pending, exit 75, volatile|checks:ci-required post-auto|auto|75|-|{no-token};AUTO-MERGE ENABLED PR #123 — will fire when CI + branch protection clear;{volatile}|calls=$PRE,merge:squash:auto,graphql:queue auth=<unset>
an immediate merge whose snapshot is MERGED exits 0|checks:ci-required post:MERGED merge-commit:merged-oid|auto|0|-|{no-token};MERGED PR #123|calls=$PRE,merge:squash:auto,graphql:queue auth=<unset>
OPEN, unqueued and unarmed after a zero exit is blocked, naming the absent proof|checks:ci-required|auto|1|-|{no-token};BLOCKED PR #123 — gh reported success but state=OPEN, autoMerge=false, mergeQueue=false;merge command accepted|calls=$PRE,merge:squash:auto,graphql:queue auth=<unset>
a snapshot on a newer head fails closed|checks:ci-required head:guarded-head post-head:newer-unreviewed-head post-queue|auto|1|-|{no-token};BLOCKED PR #123 — head changed during merge attempt (expected=guarded-head, actual=newer-unreviewed-head)|calls=$PRE,merge:squash:auto,graphql:queue auth=<unset>
a merge whose both post-merge reads fail is blocked, never a success|checks:ci-required merge-commit:merged-oid graphql:fail post-view-fail|immediate|1|-|{no-token};BLOCKED PR #123 — gh reported success but state=UNKNOWN, autoMerge=false, mergeQueue=false;merge command accepted|calls=$PRE,merge:squash,graphql:queue,view:post auth=<unset>
the REST fallback keeps classic auto-merge when the queue query fails|checks:ci-required graphql:fail post-auto|auto|75|-|{no-token};AUTO-MERGE ENABLED PR #123 — will fire when CI + branch protection clear;{volatile}|calls=$PRE,merge:squash:auto,graphql:queue,view:post auth=<unset>
a second --auto on a queued PR: gh's already-queued failure, the snapshot's entry wins|checks:ci-required head:already-queued-head merge-fail:already-queued post-queue|auto|75|-|{no-token};QUEUED IN MERGE QUEUE PR #123 — queueState=QUEUED;{volatile}|calls=$PRE,merge:squash:auto,graphql:queue auth=<unset>
a genuine merge failure with no proof stays blocked with gh's output|checks:ci-required merge-fail:policy|auto|1|-|{no-token};{merge-failed};failed to run merge: Pull request is not mergeable: the base branch policy prohibits the merge|calls=$PRE,merge:squash:auto,graphql:queue auth=<unset>
a failed CLI is still a success when the exact-head snapshot is MERGED|checks:ci-required merge-fail:transport post:MERGED merge-commit:merged-oid|immediate|0|-|{no-token};MERGED PR #123|calls=$PRE,merge:squash,graphql:queue auth=<unset>
"

# The --auto arm's gate. GitHub merges an armed PR the moment its required
# checks pass unless a ruleset requires an approval, on that approval past
# open threads unless one requires thread resolution, and on an approval of
# an earlier head unless one dismisses stale approvals on push, so the arm is
# made only where the base's pull_request rules, one or several, meet every
# row of merge_gate_gap's rule shape. --auto defers every readiness blocker
# to that gate. Its must-fail controls, each a copy of the scripts tree with
# one whole line of pr-merge.sh replaced, the rest kept: each shape row cut,
# so a base missing that row's setting arms; the value-kind check answering
# true, so a missing count or flag is read as a setting rather than
# unverified; and --auto's deferral cut, so a PR with a pending required
# check is refused rather than armed.
mutant_copy no-refusal "        'required_approval required_approving_review_count count'" '' >/dev/null
mutant_copy no-thread-refusal "        'required_thread_resolution required_review_thread_resolution flag'" '' >/dev/null
mutant_copy no-stale-refusal "        'dismiss_stale_reviews dismiss_stale_reviews_on_push flag'" '' >/dev/null
mutant_copy no-kind-check '        def fits($kind): if $kind == "count" then type == "number" and . >= 0 and . == floor else type == "boolean" end;' '        def fits($kind): true;' >/dev/null
mutant_copy no-deferral '    if [ "$can_merge" != "true" ] && [ "$auto" != true ]; then' '    if [ "$can_merge" != "true" ]; then' >/dev/null

ARMED="{no-token};AUTO-MERGE ENABLED PR #123 — will fire when CI + branch protection clear;{volatile}|calls=$PRE,merge:squash:auto,graphql:queue auth=<unset>"
NO_APPROVAL="arm: no-merge-gate=required_approval repo=owner/repo;{approval-remedy}|calls=$CHECK auth=<unset>"
NO_THREADS="arm: no-merge-gate=required_thread_resolution repo=owner/repo;{thread-remedy}|calls=$CHECK auth=<unset>"
NO_STALE="arm: no-merge-gate=dismiss_stale_reviews repo=owner/repo;{stale-remedy}|calls=$CHECK auth=<unset>"
UNVERIFIED="arm: no-merge-gate=unverified repo=owner/repo;{unverified-remedy}|calls=$CHECK auth=<unset>"
run_table "the approval gate" "\
a base requiring 1 approval, thread resolution and stale dismissal arms|checks:ci-required post-auto approvals:1/true/true|auto|75|-|$ARMED
a base requiring 2 approvals, thread resolution and stale dismissal arms|checks:ci-required post-auto approvals:2/true/true|auto|75|-|$ARMED
a base requiring 0 approvals refuses, naming the repository: nothing mutated|checks:ci-required post-auto approvals:0/true/true|auto|1|-|$NO_APPROVAL
must-fail: with the approval row cut, the base requiring 0 approvals arms|checks:ci-required post-auto approvals:0/true/true|auto-mutant:no-refusal|75|-|$ARMED
a base with no pull_request rule refuses the same way|checks:ci-required post-auto repo:no-rule|auto|1|-|$NO_APPROVAL
a classic required check is no approval: it refuses|checks:ci-required post-auto repo:classic|auto|1|-|$NO_APPROVAL
two rules each requiring 0 approvals refuse, whatever their flags|checks:ci-required post-auto approvals:0/true/true,0/false/false|auto|1|-|$NO_APPROVAL
a base requiring an approval but not thread resolution refuses: nothing mutated|checks:ci-required post-auto approvals:1/false/true|auto|1|-|$NO_THREADS
must-fail: with the thread row cut, the base requiring no thread resolution arms|checks:ci-required post-auto approvals:1/false/true|auto-mutant:no-thread-refusal|75|-|$ARMED
a base keeping approvals past a push refuses: nothing mutated|checks:ci-required post-auto approvals:1/true/false|auto|1|-|$NO_STALE
must-fail: with the stale row cut, the base keeping approvals past a push arms|checks:ci-required post-auto approvals:1/true/false|auto-mutant:no-stale-refusal|75|-|$ARMED
the approval from one rule and thread resolution from another arm together|checks:ci-required post-auto approvals:1/false/true,0/true/true|auto|75|-|$ARMED
stale dismissal from another rule than the approval arms too|checks:ci-required post-auto approvals:1/true/false,0/false/true|auto|75|-|$ARMED
a pull_request rule whose count is missing is unverified, never a gate|checks:ci-required post-auto approvals:null/true/true|auto|1|-|$UNVERIFIED
a pull_request rule whose thread flag is missing is unverified, never a gate|checks:ci-required post-auto approvals:1/null/true|auto|1|-|$UNVERIFIED
a pull_request rule whose stale flag is missing is unverified, never a gate|checks:ci-required post-auto approvals:1/true/null|auto|1|-|$UNVERIFIED
a missing value in a rule beside a complete one is still unverified|checks:ci-required post-auto approvals:1/true/true,0/true/null|auto|1|-|$UNVERIFIED
must-fail: with the kind check answering true, the missing count reads as no approval|checks:ci-required post-auto approvals:null/true/true|auto-mutant:no-kind-check|1|-|$NO_APPROVAL
must-fail: with the kind check answering true, the missing flag beside a complete rule arms|checks:ci-required post-auto approvals:1/true/true,0/true/null|auto-mutant:no-kind-check|75|-|$ARMED
a ruleset read that fails is unverified|checks:ci-required post-auto rules:fail|auto|1|-|$UNVERIFIED
--auto arms a PR whose required check is still pending: GitHub holds it|checks:pending2 checks-exit:8 post-auto approvals:1/true/true|auto|75|-|$ARMED
must-fail: with --auto's deferral cut, the pending PR is refused and nothing arms|checks:pending2 checks-exit:8 post-auto approvals:1/true/true|auto-mutant:no-deferral|1|-|{blocked};{transient};✗ ci_pending: Cross-Platform (PENDING), Linux Integration (IN_PROGRESS);{hint-auto}|calls=$CHECK auth=<unset>
the same pending PR on a base requiring 0 approvals refuses before any mutation|checks:pending2 checks-exit:8 post-auto approvals:0/true/true|auto|1|-|$NO_APPROVAL
the immediate merge reads no approval rule: a base requiring 0 still merges|checks:ci-required post:MERGED merge-commit:merged-oid approvals:0/true/true|immediate|0|-|{no-token};MERGED PR #123|calls=$PRE,merge:squash,graphql:queue auth=<unset>
"

run_table "the terminal states" "\
--auto on a merged PR exits 0 with the timestamp: no check, no mutation|state:MERGED merged-at|auto|0|-|ALREADY MERGED PR #123 2026-08-15T09:41:12Z|calls=view:state auth=<unset>
the immediate merge on a merged PR|state:MERGED merged-at|immediate|0|-|ALREADY MERGED PR #123 2026-08-15T09:41:12Z|calls=view:state auth=<unset>
no mergedAt: the bare line|state:MERGED|auto|0|-|ALREADY MERGED PR #123|calls=view:state auth=<unset>
a closed PR is a distinct refusal, exit 1|state:CLOSED|auto|1|-|{closed}|calls=view:state auth=<unset>
a failed state lookup blocks the merge with its real cause|state-err:401|immediate|1|-|{blocked};{permanent};✗ gh_error: gh: Bad credentials (HTTP 401);{hint-auto}|calls=view:state,view:state auth=<unset>
a state resolved only on the retry still short-circuits --auto, the lookup retried not cached|state:MERGED merged-at state-err:once|auto|0|-|ALREADY MERGED PR #123 2026-08-15T09:41:12Z|calls=view:state,view:state auth=<unset>
a closed PR found on the retry keeps its line|state:CLOSED state-err:once|auto|1|-|{closed}|calls=view:state,view:state auth=<unset>
the immediate mode on a retry-resolved state|state:MERGED merged-at state-err:once|immediate|0|-|ALREADY MERGED PR #123 2026-08-15T09:41:12Z|calls=view:state,view:state auth=<unset>
an open PR still merges, its state read once|checks:ci-required post:MERGED merge-commit:merged-oid|immediate|0|-|{no-token};MERGED PR #123|calls=$PRE,merge:squash,graphql:queue auth=<unset>
GH_TOKEN alone is named with the installation it acts as, and no current-user warning|checks:ci-required post:MERGED merge-commit:merged-oid env:GH_TOKEN=ghs_INSTALL|immediate|0|-|Using GH_TOKEN as GitHub App installation;MERGED PR #123|calls=$PRE,user,merge:squash,graphql:queue auth=ghs_INSTALL
a token whose user lookup fails any other way is named unverified, and the merge still runs|checks:ci-required post:MERGED merge-commit:merged-oid env:GH_TOKEN=ghp_REVOKED|immediate|0|-|Using GH_TOKEN as unverified;MERGED PR #123|calls=$PRE,user,merge:squash,graphql:queue auth=ghp_REVOKED
"

# No path merges past the merge queue. On a base that requires one, the lane's
# routes pass no --admin and GitHub enrolls the PR, so the only merge they can
# cause is the queue's own. The must-fail inverse is an unconditional --admin
# on the command: each row's trace then names merge:admin and reds. The retired
# settings refuse every mode before the first GitHub call; the inverse is every
# other row in this file, which runs with all three keys unset and reaches gh.
run_table "the merge queue and the retired settings" "\
on a queue base the immediate merge enrolls the PR and passes no --admin|checks:ci-required post-queue|immediate|75|-|{no-token};QUEUED IN MERGE QUEUE PR #123 — queueState=QUEUED;{volatile}|calls=$PRE,merge:squash,graphql:queue auth=<unset>
on a queue base --auto enrolls the PR and passes no --admin|checks:ci-required post-queue|auto|75|-|{no-token};QUEUED IN MERGE QUEUE PR #123 — queueState=QUEUED;{volatile}|calls=$PRE,merge:squash:auto,graphql:queue auth=<unset>
a partial post-merge answer is no outcome: the pr-view fallback decides|checks:ci-required post-graphql:partial post-auto|auto|75|-|{no-token};AUTO-MERGE ENABLED PR #123 — will fire when CI + branch protection clear;{volatile}|calls=$PRE,merge:squash:auto,graphql:queue,view:post auth=<unset>
the admin-credential verb is gone: an unknown option, refused before any call|-|admin-credential|1|-|Error: Unknown option: --admin-credential|calls=- auth=-
--admin on a range this checkout lacks reads queue-only and refuses before any merge call|-|admin|1|-|pr-merge: admin-refused class=queue-only pr=123;cause=range-absent base=base-oid head=test-head;{fetch-no-origin};{admin-queue}|calls=view:range auth=<unset>
the router passes --admin to the same refusal|-|router:--admin|1|-|pr-merge: admin-refused class=queue-only pr=123;cause=range-absent base=base-oid head=test-head;{fetch-no-origin};{admin-queue}|calls=view:range auth=<unset>
the force override is gone: an unknown option, refused before any call|-|force|1|-|Error: Unknown option: --force|calls=- auth=-
the router passes --force to the same refusal|-|router:--force|1|-|Error: Unknown option: --force|calls=- auth=-
a set ORCH_ADMIN_MERGE_GH_CONFIG_DIR refuses before any call|checks:ci-required post:MERGED merge-commit:merged-oid env:ORCH_ADMIN_MERGE_GH_CONFIG_DIR=/home/dev/.config/gh-admin|immediate|1|-|pr-merge: retired-setting key=ORCH_ADMIN_MERGE_GH_CONFIG_DIR;{retired:ORCH_ADMIN_MERGE_GH_CONFIG_DIR}|calls=- auth=-
a set ORCH_ADMIN_MERGE_CLASSES refuses before any call|checks:ci-required post:MERGED merge-commit:merged-oid env:ORCH_ADMIN_MERGE_CLASSES=render|immediate|1|-|pr-merge: retired-setting key=ORCH_ADMIN_MERGE_CLASSES;{retired:ORCH_ADMIN_MERGE_CLASSES}|calls=- auth=-
a set ORCH_MERGE_BYPASS refuses --auto before any call|checks:ci-required post-queue env:ORCH_MERGE_BYPASS=fast-path|auto|1|-|pr-merge: retired-setting key=ORCH_MERGE_BYPASS;{retired:ORCH_MERGE_BYPASS}|calls=- auth=-
a key set to the empty string is still set, and --check refuses too|checks:ci-required env:ORCH_MERGE_BYPASS=|check|1|-|pr-merge: retired-setting key=ORCH_MERGE_BYPASS;{retired:ORCH_MERGE_BYPASS}|calls=- auth=-
two keys set name each on its own first line|checks:ci-required env:ORCH_ADMIN_MERGE_CLASSES= env:ORCH_MERGE_BYPASS=off|immediate|1|-|pr-merge: retired-setting key=ORCH_ADMIN_MERGE_CLASSES;pr-merge: retired-setting key=ORCH_MERGE_BYPASS;{retired:ORCH_ADMIN_MERGE_CLASSES+ORCH_MERGE_BYPASS}|calls=- auth=-
the router refuses a set key the same way|checks:ci-required post:MERGED merge-commit:merged-oid env:ORCH_MERGE_BYPASS=off|router:--auto|1|-|pr-merge: retired-setting key=ORCH_MERGE_BYPASS;{retired:ORCH_MERGE_BYPASS}|calls=- auth=-
a key in kendex.settings.toml [env] refuses the direct call|checks:ci-required post-queue cwd:toml|auto|1|-|pr-merge: retired-setting key=ORCH_MERGE_BYPASS;{retired:ORCH_MERGE_BYPASS}|calls=- auth=-
a key in .kendex/settings.toml [env] refuses the direct call|checks:ci-required post-queue cwd:dot-kendex|auto|1|-|pr-merge: retired-setting key=ORCH_ADMIN_MERGE_CLASSES;{retired:ORCH_ADMIN_MERGE_CLASSES}|calls=- auth=-
an unexported .env.local line refuses the direct call|checks:ci-required post-queue cwd:env-local|auto|1|-|pr-merge: retired-setting key=ORCH_ADMIN_MERGE_GH_CONFIG_DIR;{retired:ORCH_ADMIN_MERGE_GH_CONFIG_DIR}|calls=- auth=-
a key in kendex.settings.toml [env] refuses through the router|checks:ci-required post-queue|router-in:toml|1|-|pr-merge: retired-setting key=ORCH_MERGE_BYPASS;{retired:ORCH_MERGE_BYPASS}|calls=- auth=-
a key in .kendex/settings.toml [env] refuses through the router|checks:ci-required post-queue|router-in:dot-kendex|1|-|pr-merge: retired-setting key=ORCH_ADMIN_MERGE_CLASSES;{retired:ORCH_ADMIN_MERGE_CLASSES}|calls=- auth=-
an unexported .env.local line refuses through the router, which sources it without exporting it|checks:ci-required post-queue|router-in:env-local|1|-|pr-merge: retired-setting key=ORCH_ADMIN_MERGE_GH_CONFIG_DIR;{retired:ORCH_ADMIN_MERGE_GH_CONFIG_DIR}|calls=- auth=-
a settings file the loader rejects exits 1 on the loader's own lines before any call|checks:ci-required post-queue cwd:bad-settings|auto|1|-|kendex-env: duplicate-key file=<tmp>/settings-bad-settings/kendex.settings.toml key=ORCH_TMUX_VERIFY_SECS;::error::<tmp>/settings-bad-settings/kendex.settings.toml: ORCH_TMUX_VERIFY_SECS is assigned more than once in [env] (each key must be unique in the table)|calls=- auth=-
"

# --admin reads the queue-only class off harness-ci's change-class beside the
# scripts tree pr-merge runs from. So the route rows run pr-merge.sh out of a
# mirror of the scripts tree: real directories holding a symlink per file,
# with the mirror's own harness-ci sibling written as the stub. Production
# resolution is untouched: a run from the real tree still reaches the shipped
# classifier.
mirror_tree() { # DEST SKILL
  local dest="$1" skill="$2" f d
  while IFS= read -r f; do
    d=""
    d=$(dirname -- "$f") || exit 2
    mkdir -p "$dest/skills/$skill/scripts/$d"
    ln -s "$REPO_ROOT/skills/$skill/scripts/$f" "$dest/skills/$skill/scripts/$f"
  done < <(cd "$REPO_ROOT/skills/$skill/scripts" && find . -type f | sed 's|^\./||')
}
MIRROR="$TMPDIR/tree"
mirror_tree "$MIRROR" github
MIRROR_PR_MERGE="$MIRROR/skills/github/scripts/commands/pr-merge.sh"
[[ -f "$MIRROR_PR_MERGE" ]] || { echo "mirror is missing pr-merge.sh" >&2; exit 2; }
mkdir -p "$MIRROR/skills/harness-ci/scripts"
cat >"$MIRROR/skills/harness-ci/scripts/change-class" <<'EOF'
#!/usr/bin/env bash
# The shipped classifier's contract. A measured class needs
# --event pull_request, so a call without it is the wiring error the real
# classifier exits 2 on; stdout is one change_class=<class> line and nothing
# else. The caller must also pass --base and --head with the pull request's
# base and head, and --repo with the checkout it runs in: a call missing a
# flag or carrying the wrong value fails instead of answering, so dropping one
# from the caller is caught. With no STUB_CLASS it answers nothing at all.
[[ -n "${STUB_CLASS:-}" ]] || exit 1
event="" base="" head="" repo="" prev=""
for a in "$@"; do
  case "$prev" in
    --event) event="$a" ;; --base) base="$a" ;; --head) head="$a" ;; --repo) repo="$a" ;;
  esac
  prev="$a"
done
[[ "$event" == pull_request ]] || { echo "change-class: cause=missing-event option=--event" >&2; exit 2; }
[[ "$base" == "${STUB_EXPECT_BASE:-base-oid}" ]] || { echo "change-class: bad --base '$base'" >&2; exit 3; }
[[ "$head" == "${STUB_EXPECT_HEAD:?STUB_EXPECT_HEAD unset}" ]] || { echo "change-class: bad --head '$head'" >&2; exit 3; }
[[ "$repo" == "." ]] || { echo "change-class: bad --repo '$repo'" >&2; exit 3; }
# The queue-only line, where the row names one, then the class line.
[[ -z "${STUB_QUEUE_LINE:-}" ]] || printf 'queue-only: %s\n' "$STUB_QUEUE_LINE" >&2
printf 'class: class=%s measured=true cause=stub\n' "$STUB_CLASS" >&2
printf 'change_class=%s\n' "$STUB_CLASS"
EOF
chmod +x "$MIRROR/skills/harness-ci/scripts/change-class"

# A github skill installed without harness-ci, run on this PATH less every
# directory holding a change-class, with the world's stub bin ahead of it:
# no classifier is found beside the scripts tree or on PATH.
CLASSLESS="$TMPDIR/classless-tree"
mirror_tree "$CLASSLESS" github
CLASSLESS_PR_MERGE="$CLASSLESS/skills/github/scripts/commands/pr-merge.sh"
[[ -f "$CLASSLESS_PR_MERGE" && ! -e "$CLASSLESS/skills/harness-ci" ]] || { echo "the classless mirror is malformed" >&2; exit 2; }
CLASSLESS_PATH="$TMPDIR/bin"
IFS=: read -r -a path_dirs <<<"$PATH"
for path_dir in "${path_dirs[@]}"; do
  [[ -x "$path_dir/change-class" ]] || CLASSLESS_PATH+=":$path_dir"
done

# --admin reads the queue-only class off the classifier and refuses, naming
# it: a queue-only PR, and a class nothing could read, keep the queue; every
# other PR meets the retired admin route. The not-queue-only row is the
# inverse of the queue-only one. No row reaches a merge call.
run_table "the admin request" "\
a queue-only PR refuses --admin, naming the class and the path that made it|route:true|admin-classified|1|-|pr-merge: admin-refused class=queue-only pr=123;$QUEUE_TRUE;{admin-queue}|calls=view:range auth=<unset>
any other PR meets the retired admin route, its class named|route:false|admin-classified|1|-|pr-merge: admin-retired class=not-queue-only pr=123;$QUEUE_FALSE;{admin-retired}|calls=view:range auth=<unset>
a classifier that prints no queue-only line reads queue-only, its stderr replayed|route:-|admin-classified|1|-|pr-merge: admin-refused class=queue-only pr=123;cause=classifier-unreadable;class: class=standard measured=true cause=stub;{admin-queue}|calls=view:range auth=<unset>
a classifier that fails reads queue-only|route:fail|admin-classified|1|-|pr-merge: admin-refused class=queue-only pr=123;cause=classifier-exit-1;{admin-queue}|calls=view:range auth=<unset>
an unreadable pull request range reads queue-only, gh's words replayed|route:range-fail|admin-classified|1|-|pr-merge: admin-refused class=queue-only pr=123;cause=range-unreadable;could not read the pull request endpoints;{admin-queue}|calls=view:range auth=<unset>
no classifier beside the scripts tree or on PATH reads queue-only, before any gh call|-|admin-classless|1|-|pr-merge: admin-refused class=queue-only pr=123;cause=classifier-absent;{admin-queue}|calls=- auth=-
"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
