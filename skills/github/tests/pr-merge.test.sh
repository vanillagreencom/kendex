#!/usr/bin/env bash
# pr-merge: the --check readiness JSON and its stderr verdict, the
# review-thread gate, the terminal states (a merged or closed PR
# short-circuits every mode, before and after a state lookup that failed
# once), the guarded mutation and its post-call outcomes, the retired
# override flags, and the retired merge settings. The review gate's class
# policy over that thread gate is pr-merge-thread-waiver.test.sh's. The row
# format and the world words are lib/pr-merge-world.sh's.
set -euo pipefail

# shellcheck source=lib/pr-merge-world.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/pr-merge-world.sh"

run_table "the readiness check" "\
pending checks block, transiently, one issue naming each|checks:pending2 checks-exit:8|check|0|merge=false transient=true $OPEN runs=- issues=[ci_pending: Cross-Platform (PENDING), Linux Integration (IN_PROGRESS)] warnings=[]|blocked;head-run: none|calls=$CHECK auth=<unset>
a failed check blocks permanently|checks:failed|check|0|merge=false transient=false $OPEN runs=- issues=[ci_failed: Lint (FAILURE)] warnings=[]|blocked;head-run: none|calls=$CHECK auth=<unset>
a red check the base branch does not require blocks nothing and is named as a warning|checks:optional-red required:Lint|check|0|merge=true transient=false $OPEN runs=- issues=[] warnings=[ci_optional_failed: CodeQL (FAILURE)]|mergeable;head-run: none|calls=$CHECK auth=<unset>
a red required context still blocks|checks:optional-red required:CodeQL|check|0|merge=false transient=false $OPEN runs=- issues=[ci_failed: CodeQL (FAILURE)] warnings=[]|blocked;head-run: none|calls=$CHECK auth=<unset>
a base that requires no context counts every check|checks:optional-red repo:no-rule|check|0|merge=false transient=false $OPEN runs=- issues=[ci_failed: CodeQL (FAILURE)] warnings=[]|blocked;head-run: none|calls=$CHECK auth=<unset>
a classic protection context supplies the required set too|checks:optional-red classic:Lint|check|0|merge=true transient=false $OPEN runs=- issues=[] warnings=[ci_optional_failed: CodeQL (FAILURE)]|mergeable;head-run: none|calls=$CHECK auth=<unset>
the legacy classic contexts array supplies it as well as checks[]|checks:optional-red classic-contexts:Lint|check|0|merge=true transient=false $OPEN runs=- issues=[] warnings=[ci_optional_failed: CodeQL (FAILURE)]|mergeable;head-run: none|calls=$CHECK auth=<unset>
a ruleset rule that gates on no check keeps the required set readable|checks:optional-red rule-type:pull_request|check|0|merge=true transient=false $OPEN runs=- issues=[] warnings=[ci_optional_failed: CodeQL (FAILURE)]|mergeable;head-run: none|calls=$CHECK auth=<unset>
a required-workflows rule gates on a check it never names, so every check counts|checks:optional-red rule-type:workflows|check|0|merge=false transient=false $OPEN runs=- issues=[ci_failed: CodeQL (FAILURE)] warnings=[]|blocked;head-run: none|calls=$CHECK auth=<unset>
a code-scanning rule is the same unnameable gate|checks:optional-red rule-type:code_scanning|check|0|merge=false transient=false $OPEN runs=- issues=[ci_failed: CodeQL (FAILURE)] warnings=[]|blocked;head-run: none|calls=$CHECK auth=<unset>
a Copilot review rule demands a review, not a check, so the required set stands|checks:optional-red rule-type:copilot_code_review|check|0|merge=true transient=false $OPEN runs=- issues=[] warnings=[ci_optional_failed: CodeQL (FAILURE)]|mergeable;head-run: none|calls=$CHECK auth=<unset>
a ruleset read that errors discards the contexts classic protection did supply|checks:optional-red classic:Lint rules:fail|check|0|merge=false transient=false $OPEN runs=- issues=[ci_failed: CodeQL (FAILURE)] warnings=[]|blocked;head-run: none|calls=$CHECK auth=<unset>
a branch-protection read that errors discards the contexts the ruleset did supply|checks:optional-red required:Lint branch:fail|check|0|merge=false transient=false $OPEN runs=- issues=[ci_failed: CodeQL (FAILURE)] warnings=[]|blocked;head-run: none|calls=$CHECK auth=<unset>
a required context that registered no check is pending, never a pass|checks:unregistered required:Lint|check|0|merge=false transient=true $OPEN runs=- issues=[ci_pending: Lint (missing)] warnings=[ci_optional_failed: CodeQL (FAILURE)]|blocked;head-run: none|calls=$CHECK auth=<unset>
an empty rollup with a required context is pending, not unconfigured|checks:none required:Lint|check|0|merge=false transient=true $OPEN runs=- issues=[ci_pending: Lint (missing)] warnings=[]|blocked;head-run: none|calls=$CHECK auth=<unset>
an empty rollup on a base that requires nothing stays unconfigured|checks:none|check|0|merge=true transient=false $OPEN runs=- issues=[] warnings=[ci_unconfigured: No status checks configured]|mergeable;head-run: none|calls=$CHECK auth=<unset>
an optional check still running blocks nothing either|checks:optional-pending checks-exit:8 required:Lint|check|0|merge=true transient=false $OPEN runs=- issues=[] warnings=[]|mergeable;head-run: none|calls=$CHECK auth=<unset>
a branch answer carrying no protection object is unreadable, so every check counts|checks:optional-red required:Lint repo:no-protection|check|0|merge=false transient=false $OPEN runs=- issues=[ci_failed: CodeQL (FAILURE)] warnings=[]|blocked;head-run: none|calls=$CHECK auth=<unset>
pending and failed together are not transient, both named|checks:mixed checks-exit:8|check|0|merge=false transient=false $OPEN runs=- issues=[ci_pending: Unit Tests (IN_PROGRESS);ci_failed: Lint (FAILURE)] warnings=[]|blocked;head-run: none|calls=$CHECK auth=<unset>
success and skipped checks merge with no issue|checks:pass-skip|check|0|merge=true transient=false $OPEN runs=- issues=[] warnings=[]|mergeable;head-run: none|calls=$CHECK auth=<unset>
a superseded run's cancelled jobs are not failures: only the current run's pending check blocks, transiently|checks:superseded-pending checks-exit:8|check|0|merge=false transient=true $OPEN runs=29099680623 issues=[ci_pending: Changes (IN_PROGRESS)] warnings=[]|blocked;head-run: 29099680623|calls=$CHECK auth=<unset>
a job the current run re-created and passed is not blocked by the old run's cancelled copy|checks:superseded-replaced|check|0|merge=true transient=false $OPEN runs=29099680623 issues=[] warnings=[]|mergeable;head-run: 29099680623|calls=$CHECK auth=<unset>
the current run's own cancellation is a failure|checks:current-cancel checks-exit:8|check|0|merge=false transient=false $OPEN runs=29099680623 issues=[ci_failed: Integration (CANCELLED)] warnings=[]|blocked;head-run: 29099680623|calls=$CHECK auth=<unset>
a clean run: the verdict is mergeable and head-run names the scoped run|checks:clean-run|check|0|merge=true transient=false $OPEN runs=29099680623 issues=[] warnings=[]|mergeable;head-run: 29099680623|calls=$CHECK auth=<unset>
a commit status with no workflow supplies its own run id|checks:status-only checks-exit:8|check|0|merge=false transient=true $OPEN runs=29099700000 issues=[ci_pending: CI Required (PENDING)] warnings=[]|blocked;head-run: 29099700000|calls=$CHECK auth=<unset>
an actionable unresolved thread blocks permanently, never a warning|checks:ci-required threads:actionable|check|0|merge=false transient=false $OPEN runs=- issues=[unresolved_threads: 1 actionable thread(s) need attention] warnings=[]|blocked;head-run: none|calls=$CHECK auth=<unset>
an outdated unresolved thread is not actionable|checks:ci-required threads:outdated|check|0|merge=true transient=false $OPEN runs=- issues=[] warnings=[]|mergeable;head-run: none|calls=$CHECK auth=<unset>
a malformed thread state blocks at the trust boundary|checks:ci-required threads:malformed|check|0|merge=false transient=false $OPEN runs=- issues=[review_threads_fetch_failed: GitHub returned malformed review thread data] warnings=[]|blocked;head-run: none|calls=$CHECK auth=<unset>
a page past ARG_MAX is streamed, not passed as an argument|checks:ci-required threads:large|check|0|merge=true transient=false $OPEN runs=- issues=[] warnings=[]|mergeable;head-run: none|calls=$CHECK auth=<unset>
a changes-requested reviewDecision blocks permanently|checks:ci-required review:CHANGES_REQUESTED|check|0|merge=false transient=false $OPEN runs=- issues=[changes_requested: Reviewer requested changes] warnings=[]|blocked;head-run: none|calls=$CHECK auth=<unset>
a changes-requested latest review blocks when the decision does not say so|checks:ci-required review:REVIEW_REQUIRED review-latest:CHANGES_REQUESTED|check|0|merge=false transient=false $OPEN runs=- issues=[changes_requested: Reviewer requested changes] warnings=[]|blocked;head-run: none|calls=$CHECK auth=<unset>
a PR with no approval is named not_approved, a warning that blocks nothing here|checks:ci-required review:REVIEW_REQUIRED|check|0|merge=true transient=false $OPEN runs=- issues=[] warnings=[not_approved: Review status is 'REVIEW_REQUIRED']|mergeable;head-run: none|calls=$CHECK auth=<unset>
an approving latest review clears not_approved where the decision is empty|checks:ci-required review:none review-latest:APPROVED|check|0|merge=true transient=false $OPEN runs=- issues=[] warnings=[]|mergeable;head-run: none|calls=$CHECK auth=<unset>
an actionable thread on the second page blocks|checks:ci-required threads:resolved100 threads:page2:actionable|check|0|merge=false transient=false $OPEN runs=- issues=[unresolved_threads: 1 actionable thread(s) need attention] warnings=[]|blocked;head-run: none|calls=view:state,view:mergeable,checks,graphql:threads,graphql:threads,view:reviews auth=<unset>
a merged PR reports its state and timestamp, no issues, no check fetched|state:MERGED merged-at|check|0|merge=false transient=false state=MERGED mergeable=UNKNOWN at=2026-08-15T09:41:12Z runs=- issues=[] warnings=[]|merged;head-run: none|calls=view:state auth=<unset>
a closed PR reports its state, no issues|state:CLOSED|check|0|merge=false transient=false state=CLOSED mergeable=UNKNOWN at=- runs=- issues=[] warnings=[]|closed;head-run: none|calls=view:state auth=<unset>
a missing PR is not_found|pr:missing|check|0|merge=false transient=false state=UNKNOWN mergeable=UNKNOWN at=- runs=- issues=[not_found: PR #123 not found] warnings=[]|blocked;head-run: none|calls=view:state auth=<unset>
GitHub's own missing-PR wording is not_found too|state-err:graphql-notfound|check|0|merge=false transient=false state=UNKNOWN mergeable=UNKNOWN at=- runs=- issues=[not_found: PR #123 not found] warnings=[]|blocked;head-run: none|calls=view:state auth=<unset>
an auth failure is gh_error with its diagnostic, never not_found|state-err:401|check|0|merge=false transient=false state=UNKNOWN mergeable=UNKNOWN at=- runs=- issues=[gh_error: gh: Bad credentials (HTTP 401)] warnings=[]|blocked;head-run: none|calls=view:state auth=<unset>
a rate limit keeps its diagnostic|state-err:ratelimit|check|0|merge=false transient=false state=UNKNOWN mergeable=UNKNOWN at=- runs=- issues=[gh_error: API rate limit exceeded for user ID 1.] warnings=[]|blocked;head-run: none|calls=view:state auth=<unset>
a silent failure names gh and its exit code|state-err:silent4|check|0|merge=false transient=false state=UNKNOWN mergeable=UNKNOWN at=- runs=- issues=[gh_error: gh pr view exited 4 with no diagnostic] warnings=[]|blocked;head-run: none|calls=view:state auth=<unset>
a live PR is still gated on its open thread|checks:ci-required threads:bot|check|0|merge=false transient=false $OPEN runs=- issues=[unresolved_threads: 1 actionable thread(s) need attention] warnings=[]|blocked;head-run: none|calls=$CHECK auth=<unset>
"

run_table "the merge path" "\
--auto cannot bypass an actionable thread: no mutation, no queue query|checks:ci-required threads:actionable|auto|1|-|{blocked};{permanent};✗ {threads:1};{hint-threads}|calls=$CHECK auth=<unset>
the immediate merge fails closed on it too|checks:ci-required threads:actionable|immediate|1|-|{blocked};{permanent};✗ {threads:1};{hint-threads}|calls=$CHECK auth=<unset>
a malformed thread state blocks --auto|checks:ci-required threads:malformed|auto|1|-|{blocked};{permanent};✗ {malformed};{hint-threads}|calls=$CHECK auth=<unset>
a second-page fetch failure blocks --auto|checks:ci-required threads:resolved100 threads:page2-fail|auto|1|-|{blocked};{permanent};✗ {fetch-failed};{hint-threads}|calls=view:state,view:mergeable,checks,graphql:threads,graphql:threads,view:reviews auth=<unset>
a malformed second-page cursor blocks --auto|checks:ci-required threads:resolved100 threads:page2-malformed|auto|1|-|{blocked};{permanent};✗ {fetch-failed};{hint-threads}|calls=view:state,view:mergeable,checks,graphql:threads,graphql:threads,view:reviews auth=<unset>
a thread lookup failure blocks --auto|checks:ci-required threads:fetch-fail|auto|1|-|{blocked};{permanent};✗ {fetch-failed};{hint-threads}|calls=$CHECK auth=<unset>
a failed check without --auto is blocked with the auto hint|checks:failed|immediate|1|-|{blocked};{permanent};✗ ci_failed: Lint (FAILURE);{hint-auto}|calls=$CHECK auth=<unset>
a red optional check does not stop the merge, and is named on the way|checks:optional-red required:Lint post:MERGED merge-commit:merged-oid|immediate|0|-|Warnings:;⚠ ci_optional_failed: CodeQL (FAILURE);{no-token};MERGED PR #123|calls=$PRE,merge,graphql:queue auth=<unset>
the router promotes the bot token for the mutation and the snapshot|checks:ci-required require-token post:MERGED merge-commit:merged-oid env:GH_BOT_TOKEN=ghp_test_token|router:--squash|0|-|Using GH_BOT_TOKEN as stub-user;MERGED PR #123|calls=user,$PRE,user,merge,graphql:queue auth=ghp_test_token
a prepared head that drifted fails before arming|checks:ci-required head:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa|expected:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb|1|-|BLOCKED PR #123 — prepared head changed before merge attempt (expected=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb, actual=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa)|calls=$PRE auth=<unset>
an active queue entry after --auto is success-pending, exit 75, volatile|checks:ci-required head:28132e9b990a595417f79f4e213b4e984bf676fd post-entry require-token env:GH_BOT_TOKEN=ghp_test_token|auto|75|-|Using GH_BOT_TOKEN as stub-user;QUEUED IN MERGE QUEUE PR #123 — queueState=QUEUED;{volatile}|calls=$PRE,user,merge:auto,graphql:queue auth=<unset>+ghp_test_token
--auto refuses where auto-merge is off: nothing mutated|checks:ci-required repo:no-auto|auto|1|-|arm: no-merge-gate=allow_auto_merge repo=owner/repo;{arm-remedy}|calls=$CHECK auth=<unset>
--auto refuses where the base branch has no required check or review rule|checks:ci-required repo:no-rule|auto|1|-|arm: no-merge-gate=required_check repo=owner/repo;{arm-remedy}|calls=$CHECK auth=<unset>
the refusal is the first stderr line, ahead of the checks' warnings|checks:none repo:no-auto|auto|1|-|arm: no-merge-gate=allow_auto_merge repo=owner/repo;{arm-remedy}|calls=$CHECK auth=<unset>
a ruleset pull_request rule alone is a gate: it arms|checks:ci-required post-auto repo:pr-rule|auto|75|-|{no-token};AUTO-MERGE ENABLED PR #123 — will fire when CI + branch protection clear;{volatile}|calls=$PRE,merge:auto,graphql:queue auth=<unset>
a classic required check with no ruleset is a gate: it arms|checks:ci-required post-auto repo:classic|auto|75|-|{no-token};AUTO-MERGE ENABLED PR #123 — will fire when CI + branch protection clear;{volatile}|calls=$PRE,merge:auto,graphql:queue auth=<unset>
a classic required check stored under checks[] rather than contexts is a gate too|checks:ci-required post-auto classic:Lint|auto|75|-|{no-token};AUTO-MERGE ENABLED PR #123 — will fire when CI + branch protection clear;{volatile}|calls=$PRE,merge:auto,graphql:queue auth=<unset>
a base branch with slashes is URL-encoded in the gate reads and arms|checks:ci-required post-auto base:release/foo/bar|auto|75|-|{no-token};AUTO-MERGE ENABLED PR #123 — will fire when CI + branch protection clear;{volatile}|calls=$PRE,merge:auto,graphql:queue auth=<unset>
classic auto-merge is success-pending, exit 75, volatile|checks:ci-required post-auto|auto|75|-|{no-token};AUTO-MERGE ENABLED PR #123 — will fire when CI + branch protection clear;{volatile}|calls=$PRE,merge:auto,graphql:queue auth=<unset>
an immediate merge whose snapshot is MERGED exits 0|checks:ci-required post:MERGED merge-commit:merged-oid|auto|0|-|{no-token};MERGED PR #123|calls=$PRE,merge:auto,graphql:queue auth=<unset>
OPEN, unqueued and unarmed after a zero exit is blocked, naming the absent proof|checks:ci-required|auto|1|-|{no-token};BLOCKED PR #123 — gh reported success but state=OPEN, autoMerge=false, mergeQueue=false;merge command accepted|calls=$PRE,merge:auto,graphql:queue auth=<unset>
a snapshot on a newer head fails closed|checks:ci-required head:guarded-head post-head:newer-unreviewed-head post-queue|auto|1|-|{no-token};BLOCKED PR #123 — head changed during merge attempt (expected=guarded-head, actual=newer-unreviewed-head)|calls=$PRE,merge:auto,graphql:queue auth=<unset>
a merge whose both post-merge reads fail is blocked, never a success|checks:ci-required merge-commit:merged-oid graphql:fail post-view-fail|immediate|1|-|{no-token};BLOCKED PR #123 — gh reported success but state=UNKNOWN, autoMerge=false, mergeQueue=false;merge command accepted|calls=$PRE,merge,graphql:queue,view:post auth=<unset>
the REST fallback keeps classic auto-merge when the queue query fails|checks:ci-required graphql:fail post-auto|auto|75|-|{no-token};AUTO-MERGE ENABLED PR #123 — will fire when CI + branch protection clear;{volatile}|calls=$PRE,merge:auto,graphql:queue,view:post auth=<unset>
a second --auto on a queued PR: gh's already-queued failure, the snapshot's entry wins|checks:ci-required head:already-queued-head merge-fail:already-queued post-queue|auto|75|-|{no-token};QUEUED IN MERGE QUEUE PR #123 — queueState=QUEUED;{volatile}|calls=$PRE,merge:auto,graphql:queue auth=<unset>
a genuine merge failure with no proof stays blocked with gh's output|checks:ci-required merge-fail:policy|auto|1|-|{no-token};{merge-failed};failed to run merge: Pull request is not mergeable: the base branch policy prohibits the merge|calls=$PRE,merge:auto,graphql:queue auth=<unset>
a failed CLI is still a success when the exact-head snapshot is MERGED|checks:ci-required merge-fail:transport post:MERGED merge-commit:merged-oid|immediate|0|-|{no-token};MERGED PR #123|calls=$PRE,merge,graphql:queue auth=<unset>
"

run_table "the terminal states" "\
--auto on a merged PR exits 0 with the timestamp: no check, no thread, no mutation|state:MERGED merged-at threads:bot|auto|0|-|ALREADY MERGED PR #123 2026-08-15T09:41:12Z|calls=view:state auth=<unset>
the immediate merge on a merged PR|state:MERGED merged-at|immediate|0|-|ALREADY MERGED PR #123 2026-08-15T09:41:12Z|calls=view:state auth=<unset>
no mergedAt: the bare line|state:MERGED|auto|0|-|ALREADY MERGED PR #123|calls=view:state auth=<unset>
a closed PR is a distinct refusal, exit 1|state:CLOSED threads:bot|auto|1|-|{closed}|calls=view:state auth=<unset>
a failed state lookup blocks the merge with its real cause|state-err:401|immediate|1|-|{blocked};{permanent};✗ gh_error: gh: Bad credentials (HTTP 401);{hint-auto}|calls=view:state,view:state auth=<unset>
a state resolved only on the retry still short-circuits --auto, the lookup retried not cached|state:MERGED merged-at state-err:once|auto|0|-|ALREADY MERGED PR #123 2026-08-15T09:41:12Z|calls=view:state,view:state auth=<unset>
a closed PR found on the retry keeps its line|state:CLOSED state-err:once|auto|1|-|{closed}|calls=view:state,view:state auth=<unset>
the immediate mode on a retry-resolved state|state:MERGED merged-at state-err:once|immediate|0|-|ALREADY MERGED PR #123 2026-08-15T09:41:12Z|calls=view:state,view:state auth=<unset>
an open PR still merges, its state read once|checks:ci-required post:MERGED merge-commit:merged-oid|immediate|0|-|{no-token};MERGED PR #123|calls=$PRE,merge,graphql:queue auth=<unset>
GH_TOKEN alone is named with the installation it acts as, and no current-user warning|checks:ci-required post:MERGED merge-commit:merged-oid env:GH_TOKEN=ghs_INSTALL|immediate|0|-|Using GH_TOKEN as GitHub App installation;MERGED PR #123|calls=$PRE,user,merge,graphql:queue auth=ghs_INSTALL
a token whose user lookup fails any other way is named unverified, and the merge still runs|checks:ci-required post:MERGED merge-commit:merged-oid env:GH_TOKEN=ghp_REVOKED|immediate|0|-|Using GH_TOKEN as unverified;MERGED PR #123|calls=$PRE,user,merge,graphql:queue auth=ghp_REVOKED
"

# No path merges past the merge queue. On a base that requires one, the lane's
# routes pass no --admin and GitHub enrolls the PR, so the only merge they can
# cause is the queue's own. The must-fail inverse is an unconditional --admin
# on the command: each row's trace then names merge:admin and reds. The retired
# settings refuse every mode before the first GitHub call; the inverse is every
# other row in this file, which runs with all three keys unset and reaches gh.
run_table "the merge queue and the retired settings" "\
on a queue base the immediate merge enrolls the PR and passes no --admin|checks:ci-required post-queue|immediate|75|-|{no-token};QUEUED IN MERGE QUEUE PR #123 — queueState=QUEUED;{volatile}|calls=$PRE,merge,graphql:queue auth=<unset>
on a queue base --auto enrolls the PR and passes no --admin|checks:ci-required post-queue|auto|75|-|{no-token};QUEUED IN MERGE QUEUE PR #123 — queueState=QUEUED;{volatile}|calls=$PRE,merge:auto,graphql:queue auth=<unset>
a partial post-merge answer is no outcome: the pr-view fallback decides|checks:ci-required post-graphql:partial post-auto|auto|75|-|{no-token};AUTO-MERGE ENABLED PR #123 — will fire when CI + branch protection clear;{volatile}|calls=$PRE,merge:auto,graphql:queue,view:post auth=<unset>
the admin-credential verb is gone: an unknown option, refused before any call|-|admin-credential|1|-|Error: Unknown option: --admin-credential|calls=- auth=-
the admin override is gone: an unknown option, refused before any call|-|admin|1|-|Error: Unknown option: --admin|calls=- auth=-
the router passes --admin to the same refusal|-|router:--admin|1|-|Error: Unknown option: --admin|calls=- auth=-
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

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
