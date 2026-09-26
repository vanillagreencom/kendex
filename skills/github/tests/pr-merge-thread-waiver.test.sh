#!/usr/bin/env bash
# pr-merge under the review gate's class policy: the review-thread gate a
# waived class relaxes for the threads a bot opened and keeps for everyone
# else's, the policy answers that refuse rather than waive, and the merge
# route resolving each waived thread — one reply, one resolve, under the
# merge's token and on the head the class was measured at — before it arms.
# The row format and the world words are lib/pr-merge-world.sh's.
set -euo pipefail

# shellcheck source=lib/pr-merge-world.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/pr-merge-world.sh"

# The class policy is asked of review-gate's review-policy beside the scripts
# tree pr-merge runs from, and review-policy resolves the change classifier
# beside itself. So the class-policy rows run pr-merge.sh out of a mirror of
# the scripts tree: real directories holding a symlink per file, with the
# mirror's own harness-ci sibling written as the stub. Production resolution is
# untouched — a run from the real tree still reaches the shipped classifier.
MIRROR="$TMPDIR/tree"
mirror_tree() { # DEST SKILL
  local dest="$1" skill="$2" f d
  while IFS= read -r f; do
    d=""
    d=$(dirname -- "$f") || exit 2
    mkdir -p "$dest/skills/$skill/scripts/$d"
    ln -s "$REPO_ROOT/skills/$skill/scripts/$f" "$dest/skills/$skill/scripts/$f"
  done < <(cd "$REPO_ROOT/skills/$skill/scripts" && find . -type f | sed 's|^\./||')
}
for mirrored in github review-gate; do mirror_tree "$MIRROR" "$mirrored"; done

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
# from the caller is caught. With no STUB_CLASS it answers nothing at all,
# which is the unreadable-policy case.
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
# The class line, whose measured= marker says whether a rule earned this class
# or the classifier fell back to standard. review-policy reads it and refuses
# an answer marked unmeasured, so a row can turn a waiver into a refusal
# without changing the class on stdout.
if [[ "${STUB_MARKER:-yes}" == yes ]]; then
  printf 'class: class=%s measured=%s cause=stub\n' "$STUB_CLASS" "${STUB_MEASURED:-true}" >&2
fi
printf 'change_class=%s\n' "$STUB_CLASS"
EOF
chmod +x "$MIRROR/skills/harness-ci/scripts/change-class"

# A review gate installed at an older revision than this github skill: its
# owner stands with no waiver rule beside it.
NO_RULE="$TMPDIR/no-rule-tree"
for mirrored in github review-gate; do mirror_tree "$NO_RULE" "$mirrored"; done
rm -- "$NO_RULE/skills/review-gate/scripts/lib/waiver.sh"
mkdir -p "$NO_RULE/skills/harness-ci/scripts"
cp -- "$MIRROR/skills/harness-ci/scripts/change-class" "$NO_RULE/skills/harness-ci/scripts/change-class"
NO_RULE_PR_MERGE="$NO_RULE/skills/github/scripts/commands/pr-merge.sh"
[[ -f "$NO_RULE_PR_MERGE" && ! -e "$NO_RULE/skills/review-gate/scripts/lib/waiver.sh" ]] || { echo "the no-rule mirror is malformed" >&2; exit 2; }


# The out field's fixed texts; the err field spells the same ones as macros.
WAIVED="unresolved_threads_waived: 1 review-bot thread(s) open, waived by the review gate's class policy for this change, and the merge route resolves them before it arms"
UNREADABLE="review_policy_unreadable: The review gate's class policy could not be resolved for this pull request"
NO_RULE_ISSUE="review_policy_unreadable: The review gate's waiver rule could not be loaded beside its class policy"
PERSON="unresolved_threads: 1 actionable thread(s) need attention"
MERGE_PRE="$CHECK_POLICY,view:head"
# The reply trace names the class and the head it was measured at, shortened.
AT="@${RANGE_HEAD:0:7}"

# --check never mutates: a waiver, and a lapsed waiver resolution in
# thread_reopen, are named in the readiness JSON and nothing else happens. The
# inverse of every waived row is the standard-class row beside it, whose
# threads keep the gate.
run_table "the readiness check" "\
a class the policy sends for review keeps the thread gate|checks:ci-required threads:actionable class-policy:standard|check-classified|0|merge=false transient=false $OPEN runs=- issues=[$PERSON] warnings=[] waiver=- reopen=[]|blocked;head-run: none|calls=$CHECK_POLICY auth=<unset>
a class the policy waives names a bot's thread in the waiver and gates nothing with it|checks:ci-required threads:bot class-policy:trivial|check-classified|0|merge=true transient=false $OPEN runs=- issues=[] warnings=[$WAIVED] waiver=trivial@${RANGE_HEAD}[PRRT_post_merge_bot] reopen=[]|mergeable;head-run: none|calls=$CHECK_POLICY auth=<unset>
a waived class still blocks on a thread a person opened|checks:ci-required threads:actionable class-policy:render|check-classified|0|merge=false transient=false $OPEN runs=- issues=[$PERSON] warnings=[] waiver=- reopen=[]|blocked;head-run: none|calls=$CHECK_POLICY auth=<unset>
a person's thread beside a bot's blocks, and only the bot's is waived|checks:ci-required threads:bot-and-person class-policy:render|check-classified|0|merge=false transient=false $OPEN runs=- issues=[$PERSON] warnings=[$WAIVED] waiver=render@${RANGE_HEAD}[PRRT_bot] reopen=[]|blocked;head-run: none|calls=$CHECK_POLICY auth=<unset>
a bot's thread on a class the policy sends for review keeps the gate|checks:ci-required threads:bot class-policy:standard|check-classified|0|merge=false transient=false $OPEN runs=- issues=[$PERSON] warnings=[] waiver=- reopen=[]|blocked;head-run: none|calls=$CHECK_POLICY auth=<unset>
a code-scanning alert on a waived class blocks: its app is not a review bot the gate reads|checks:ci-required threads:codeql class-policy:trivial|check-classified|0|merge=false transient=false $OPEN runs=- issues=[$PERSON] warnings=[] waiver=- reopen=[]|blocked;head-run: none|calls=$CHECK_POLICY auth=<unset>
a review bot's thread a person has replied in blocks on a waived class|checks:ci-required threads:bot-with-reply class-policy:trivial|check-classified|0|merge=false transient=false $OPEN runs=- issues=[$PERSON] warnings=[] waiver=- reopen=[]|blocked;head-run: none|calls=$CHECK_POLICY auth=<unset>
a review bot's thread not read in full blocks on a waived class|checks:ci-required threads:bot-partial class-policy:trivial|check-classified|0|merge=false transient=false $OPEN runs=- issues=[$PERSON] warnings=[] waiver=- reopen=[]|blocked;head-run: none|calls=$CHECK_POLICY auth=<unset>
an outdated thread a person opened blocks on a waived class, since GitHub's rule counts it|checks:ci-required threads:outdated class-policy:trivial|check-classified|0|merge=false transient=false $OPEN runs=- issues=[$PERSON] warnings=[] waiver=- reopen=[]|blocked;head-run: none|calls=$CHECK_POLICY auth=<unset>
a waiver its resolver answered and resolved again counts zero on a waived class|checks:ci-required threads:waived-answered class-policy:trivial|check-classified|0|merge=true transient=false $OPEN runs=- issues=[] warnings=[] waiver=- reopen=[]|mergeable;head-run: none|calls=$CHECK auth=<unset>
a waiver its resolver answered and resolved again counts zero on a class sent for a bot round|checks:ci-required threads:waived-answered class-policy:small|check-classified|0|merge=true transient=false $OPEN runs=- issues=[] warnings=[] waiver=- reopen=[]|mergeable;head-run: none|calls=$CHECK auth=<unset>
a waiver a person replied after blocks on a waived class and is named to reopen|checks:ci-required threads:waived-person-reply class-policy:trivial|check-classified|0|merge=false transient=false $OPEN runs=- issues=[$PERSON] warnings=[] waiver=- reopen=[PRRT_waived_reply]|blocked;head-run: none|calls=$CHECK_POLICY auth=<unset>
a person's account spelling a review bot's login is no review bot|checks:ci-required threads:bot-login-user class-policy:trivial|check-classified|0|merge=false transient=false $OPEN runs=- issues=[$PERSON] warnings=[] waiver=- reopen=[]|blocked;head-run: none|calls=$CHECK_POLICY auth=<unset>
a thread the merge route resolved stays resolved while the class is still waived|checks:ci-required threads:waived-resolved class-policy:trivial|check-classified|0|merge=true transient=false $OPEN runs=- issues=[] warnings=[] waiver=- reopen=[]|mergeable;head-run: none|calls=$CHECK_POLICY auth=<unset>
a lapsed waiver blocks once the class is sent for review, and --check names it without reopening it|checks:ci-required threads:waived-resolved class-policy:standard|check-classified|0|merge=false transient=false $OPEN runs=- issues=[$PERSON] warnings=[] waiver=- reopen=[PRRT_waived]|blocked;head-run: none|calls=$CHECK_POLICY auth=<unset>
an outdated bot thread alone asks the policy and is waived, since GitHub's rule counts it|checks:ci-required threads:bot-outdated class-policy:trivial|check-classified|0|merge=true transient=false $OPEN runs=- issues=[] warnings=[$WAIVED] waiver=trivial@${RANGE_HEAD}[PRRT_bot_outdated] reopen=[]|mergeable;head-run: none|calls=$CHECK_POLICY auth=<unset>
a class policy the classifier cannot answer blocks a bot's thread rather than waive, and the owner's own diagnostic reaches stderr|checks:ci-required threads:bot class-policy:-|check-classified|0|merge=false transient=false $OPEN runs=- issues=[$UNREADABLE;$PERSON] warnings=[] waiver=- reopen=[]|review-gate-error=policy-classifier-call value=<tmp>/tree/skills/review-gate/scripts/../../harness-ci/scripts/change-class;review-policy: the harness-ci change classifier could not answer;blocked;head-run: none|calls=$CHECK_POLICY auth=<unset>
a class the classifier did not measure blocks rather than waive, whatever it named|checks:ci-required threads:actionable class-policy:unmeasured|check-classified|0|merge=false transient=false $OPEN runs=- issues=[$UNREADABLE;$PERSON] warnings=[] waiver=- reopen=[]|class: class=render measured=false cause=stub;review-gate-error=policy-unmeasured value=cause=stub;review-policy: the change classifier fell back to standard instead of measuring a class;blocked;head-run: none|calls=$CHECK_POLICY auth=<unset>
a range naming a commit this checkout lacks blocks rather than waive|checks:ci-required threads:actionable class-policy:range-absent|check-classified|0|merge=false transient=false $OPEN runs=- issues=[$UNREADABLE;$PERSON] warnings=[] waiver=- reopen=[]|{fetch-no-origin};blocked;head-run: none|calls=$CHECK_POLICY auth=<unset>
an unreadable pull request range blocks rather than waive|checks:ci-required threads:actionable class-policy:range-fail|check-classified|0|merge=false transient=false $OPEN runs=- issues=[$UNREADABLE;$PERSON] warnings=[] waiver=- reopen=[]|blocked;head-run: none|calls=$CHECK_POLICY auth=<unset>
with the thread term off a bot's thread on a waived class is no waiver and blocks|checks:ci-required threads:bot class-policy:trivial env:REVIEW_GATE_THREADS=off|check-classified|0|merge=false transient=false $OPEN runs=- issues=[$PERSON] warnings=[] waiver=- reopen=[]|blocked;head-run: none|calls=$CHECK_POLICY auth=<unset>
a review gate with no waiver rule and no thread needs no rule|checks:ci-required threads:-|check-no-rule|0|merge=true transient=false $OPEN runs=- issues=[] warnings=[] waiver=- reopen=[]|mergeable;head-run: none|calls=$CHECK auth=<unset>
a review gate with no waiver rule refuses an open thread the rule could waive|checks:ci-required threads:bot class-policy:trivial|check-no-rule|0|merge=false transient=false $OPEN runs=- issues=[$NO_RULE_ISSUE] warnings=[] waiver=- reopen=[]|blocked;head-run: none|calls=$CHECK auth=<unset>
a review gate with no waiver rule refuses a resolved thread carrying the merge route's reply|checks:ci-required threads:waived-resolved class-policy:standard|check-no-rule|0|merge=false transient=false $OPEN runs=- issues=[$NO_RULE_ISSUE] warnings=[] waiver=- reopen=[]|blocked;head-run: none|calls=$CHECK auth=<unset>
"

# The merge modes resolve each waived thread, one reply naming the class and
# then one resolve, as the last step before the merge call, and reopen each
# lapsed waiver resolution before they block. The inverse rows never reach a
# thread mutation: a person's thread, a class sent for review, an unreadable
# policy, a head that moved after the class was measured, and --dry-run.
run_table "the merge route" "\
a waived class resolves a bot's thread, then --auto arms with no override flag|checks:ci-required threads:bot class-policy:render post-entry|auto-classified|75|-|Warnings:;⚠ {waived:1};{resolved:PRRT_post_merge_bot:render};{no-token};QUEUED IN MERGE QUEUE PR #123 — queueState=QUEUED;{volatile}|calls=$MERGE_PRE,graphql:reply(PRRT_post_merge_bot:render$AT),graphql:resolve(PRRT_post_merge_bot),merge:auto,graphql:queue auth=<unset>
the immediate merge resolves every waived thread, an outdated one too, before it merges|checks:ci-required threads:two-bots class-policy:trivial post:MERGED merge-commit:merged-oid|immediate-classified|0|-|Warnings:;⚠ {waived:2};{resolved:PRRT_bot_a:trivial};{resolved:PRRT_bot_b:trivial};{no-token};MERGED PR #123|calls=$MERGE_PRE,graphql:reply(PRRT_bot_a:trivial$AT),graphql:resolve(PRRT_bot_a),graphql:reply(PRRT_bot_b:trivial$AT),graphql:resolve(PRRT_bot_b),merge,graphql:queue auth=<unset>
the replies and resolves run under the merge's own token|checks:ci-required threads:bot class-policy:trivial post-entry require-token env:GH_BOT_TOKEN=ghp_test_token|auto-classified|75|-|Warnings:;⚠ {waived:1};{resolved:PRRT_post_merge_bot:trivial};Using GH_BOT_TOKEN as stub-user;QUEUED IN MERGE QUEUE PR #123 — queueState=QUEUED;{volatile}|calls=$MERGE_PRE,graphql:reply(PRRT_post_merge_bot:trivial$AT),graphql:resolve(PRRT_post_merge_bot),user,merge:auto,graphql:queue auth=<unset>+ghp_test_token
a person's thread beside a bot's blocks --auto before any thread is touched|checks:ci-required threads:bot-and-person class-policy:trivial post-entry|auto-classified|1|-|{blocked};{permanent};✗ {threads:1};⚠ {waived:1};{hint-threads}|calls=$CHECK_POLICY auth=<unset>
a bot's thread on a class sent for review blocks --auto untouched|checks:ci-required threads:bot class-policy:standard post-entry|auto-classified|1|-|{blocked};{permanent};✗ {threads:1};{hint-threads}|calls=$CHECK_POLICY auth=<unset>
an unreadable class policy blocks --auto untouched|checks:ci-required threads:bot class-policy:- post-entry|auto-classified|1|-|review-gate-error=policy-classifier-call value=<tmp>/tree/skills/review-gate/scripts/../../harness-ci/scripts/change-class;review-policy: the harness-ci change classifier could not answer;{blocked};{permanent};✗ {unreadable};✗ {threads:1};{hint-threads}|calls=$CHECK_POLICY auth=<unset>
a code-scanning alert blocks --auto on a waived class, never replied to or resolved|checks:ci-required threads:codeql class-policy:trivial post-entry|auto-classified|1|-|{blocked};{permanent};✗ {threads:1};{hint-threads}|calls=$CHECK_POLICY auth=<unset>
an unreadable class policy blocks --auto on an outdated bot thread alone|checks:ci-required threads:bot-outdated class-policy:- post-entry|auto-classified|1|-|review-gate-error=policy-classifier-call value=<tmp>/tree/skills/review-gate/scripts/../../harness-ci/scripts/change-class;review-policy: the harness-ci change classifier could not answer;{blocked};{permanent};✗ {unreadable};{hint-threads}|calls=$CHECK_POLICY auth=<unset>
a thread the merge route resolved is reopened before --auto blocks on a class sent for review|checks:ci-required threads:waived-resolved class-policy:standard post-entry|auto-classified|1|-|{reopened:PRRT_waived};{blocked};{permanent};✗ {threads:1};{hint-threads}|calls=$CHECK_POLICY,graphql:reopen(PRRT_waived) auth=<unset>
a reopen that fails is named, and --auto still blocks|checks:ci-required threads:waived-resolved class-policy:standard reopen:fail post-entry|auto-classified|1|-|pr-merge: thread-reopen-failed id=PRRT_waived;{\"error\":\"reopen refused\"};{\"success\":false,\"unresolved\":[],\"failed\":[\"PRRT_waived\"]};{blocked};{permanent};✗ {threads:1};{hint-threads}|calls=$CHECK_POLICY,graphql:reopen(PRRT_waived) auth=<unset>
a waiver a person replied after is reopened before --auto blocks on a waived class|checks:ci-required threads:waived-person-reply class-policy:trivial post-entry|auto-classified|1|-|{reopened:PRRT_waived_reply};{blocked};{permanent};✗ {threads:1};{hint-threads}|calls=$CHECK_POLICY,graphql:reopen(PRRT_waived_reply) auth=<unset>
--dry-run on a lapsed waiver reopens nothing|checks:ci-required threads:waived-resolved class-policy:standard post-entry|dry-classified|1|-|{blocked};{permanent};✗ {threads:1};{hint-threads}|calls=$CHECK_POLICY auth=<unset>
the immediate merge runs beside a review gate with no waiver rule when no thread needs it|checks:ci-required threads:- post:MERGED merge-commit:merged-oid|immediate-no-rule|0|-|{no-token};MERGED PR #123|calls=$CHECK,view:head,merge,graphql:queue auth=<unset>
a head that moved after the class was measured blocks before any thread is touched|checks:ci-required threads:bot class-policy:trivial head-moved:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb post-entry|auto-classified|1|-|Warnings:;⚠ {waived:1};BLOCKED PR #123 — the class policy waived its bot threads at $RANGE_HEAD, not at the head being merged (bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb)|calls=$MERGE_PRE auth=<unset>
a failed reply blocks with nothing armed, and names the thread|checks:ci-required threads:two-bots class-policy:trivial reply:fail post-entry|auto-classified|1|-|Warnings:;⚠ {waived:2};BLOCKED PR #123 — the reply on waived bot thread PRRT_bot_a failed;{\"error\":\"reply refused\"}|calls=$MERGE_PRE,graphql:reply(PRRT_bot_a:trivial$AT) auth=<unset>
a failed resolve blocks with nothing armed, and names the thread|checks:ci-required threads:bot class-policy:trivial resolve:fail post-entry|auto-classified|1|-|Warnings:;⚠ {waived:1};BLOCKED PR #123 — resolving waived bot thread PRRT_post_merge_bot failed;{\"error\":\"resolve refused\"};{\"success\":false,\"resolved\":[],\"failed\":[\"PRRT_post_merge_bot\"]}|calls=$MERGE_PRE,graphql:reply(PRRT_post_merge_bot:trivial$AT),graphql:resolve(PRRT_post_merge_bot) auth=<unset>
"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
