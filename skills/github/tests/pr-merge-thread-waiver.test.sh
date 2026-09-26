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


# The out field's fixed texts; the err field spells the same ones as macros.
WAIVED="unresolved_threads_waived: 1 review-bot thread(s) open, waived by the review gate's class policy for this change, and the merge route resolves them before it arms"
UNREADABLE="review_policy_unreadable: The review gate's class policy could not be resolved for this pull request"
PERSON="unresolved_threads: 1 actionable thread(s) need attention"
MERGE_PRE="$CHECK_POLICY,view:head"
# The reply trace names the class and the head it was measured at, shortened.
AT="@${RANGE_HEAD:0:7}"

# --check never mutates: a waiver is named in the readiness JSON and nothing
# else happens. The inverse of every waived row is the standard-class row
# beside it, whose threads keep the gate.
run_table "the readiness check" "\
a class the policy sends for review keeps the thread gate|checks:ci-required threads:actionable class-policy:standard|check-classified|0|merge=false transient=false $OPEN runs=- issues=[$PERSON] warnings=[] waiver=-|blocked;head-run: none|calls=$CHECK_POLICY auth=<unset>
a class the policy waives names a bot's thread in the waiver and gates nothing with it|checks:ci-required threads:bot class-policy:trivial|check-classified|0|merge=true transient=false $OPEN runs=- issues=[] warnings=[$WAIVED] waiver=trivial@${RANGE_HEAD}[PRRT_post_merge_bot]|mergeable;head-run: none|calls=$CHECK_POLICY auth=<unset>
a waived class still blocks on a thread a person opened|checks:ci-required threads:actionable class-policy:render|check-classified|0|merge=false transient=false $OPEN runs=- issues=[$PERSON] warnings=[] waiver=-|blocked;head-run: none|calls=$CHECK_POLICY auth=<unset>
a person's thread beside a bot's blocks, and only the bot's is waived|checks:ci-required threads:bot-and-person class-policy:render|check-classified|0|merge=false transient=false $OPEN runs=- issues=[$PERSON] warnings=[$WAIVED] waiver=render@${RANGE_HEAD}[PRRT_bot]|blocked;head-run: none|calls=$CHECK_POLICY auth=<unset>
a bot's thread on a class the policy sends for review keeps the gate|checks:ci-required threads:bot class-policy:standard|check-classified|0|merge=false transient=false $OPEN runs=- issues=[$PERSON] warnings=[] waiver=-|blocked;head-run: none|calls=$CHECK_POLICY auth=<unset>
a code-scanning alert on a waived class blocks: its app is not a review bot the gate reads|checks:ci-required threads:codeql class-policy:trivial|check-classified|0|merge=false transient=false $OPEN runs=- issues=[$PERSON] warnings=[] waiver=-|blocked;head-run: none|calls=$CHECK_POLICY auth=<unset>
a review bot's thread a person has replied in blocks on a waived class|checks:ci-required threads:bot-with-reply class-policy:trivial|check-classified|0|merge=false transient=false $OPEN runs=- issues=[$PERSON] warnings=[] waiver=-|blocked;head-run: none|calls=$CHECK_POLICY auth=<unset>
a review bot's thread not read in full blocks on a waived class|checks:ci-required threads:bot-partial class-policy:trivial|check-classified|0|merge=false transient=false $OPEN runs=- issues=[$PERSON] warnings=[] waiver=-|blocked;head-run: none|calls=$CHECK_POLICY auth=<unset>
an outdated thread a person opened blocks on a waived class, since GitHub's rule counts it|checks:ci-required threads:outdated class-policy:trivial|check-classified|0|merge=false transient=false $OPEN runs=- issues=[$PERSON] warnings=[] waiver=-|blocked;head-run: none|calls=$CHECK_POLICY auth=<unset>
a thread the merge route resolved stays resolved while the class is still waived|checks:ci-required threads:waived-resolved class-policy:trivial|check-classified|0|merge=true transient=false $OPEN runs=- issues=[] warnings=[] waiver=-|mergeable;head-run: none|calls=$CHECK_POLICY auth=<unset>
a thread the merge route resolved is reopened and blocks once the class is sent for review|checks:ci-required threads:waived-resolved class-policy:standard|check-classified|0|merge=false transient=false $OPEN runs=- issues=[$PERSON] warnings=[] waiver=-|{reopened:PRRT_waived};blocked;head-run: none|calls=$CHECK_POLICY,graphql:reopen(PRRT_waived) auth=<unset>
a reopen that fails is named, and the thread still blocks|checks:ci-required threads:waived-resolved class-policy:standard reopen:fail|check-classified|0|merge=false transient=false $OPEN runs=- issues=[$PERSON] warnings=[] waiver=-|pr-merge: thread-reopen-failed id=PRRT_waived;{\"error\":\"reopen refused\"};{\"success\":false,\"unresolved\":[],\"failed\":[\"PRRT_waived\"]};blocked;head-run: none|calls=$CHECK_POLICY,graphql:reopen(PRRT_waived) auth=<unset>
an outdated bot thread alone asks the policy and is waived, since GitHub's rule counts it|checks:ci-required threads:bot-outdated class-policy:trivial|check-classified|0|merge=true transient=false $OPEN runs=- issues=[] warnings=[$WAIVED] waiver=trivial@${RANGE_HEAD}[PRRT_bot_outdated]|mergeable;head-run: none|calls=$CHECK_POLICY auth=<unset>
a class policy the classifier cannot answer blocks a bot's thread rather than waive, and the owner's own diagnostic reaches stderr|checks:ci-required threads:bot class-policy:-|check-classified|0|merge=false transient=false $OPEN runs=- issues=[$UNREADABLE;$PERSON] warnings=[] waiver=-|review-gate-error=policy-classifier-call value=<tmp>/tree/skills/review-gate/scripts/../../harness-ci/scripts/change-class;review-policy: the harness-ci change classifier could not answer;blocked;head-run: none|calls=$CHECK_POLICY auth=<unset>
a class the classifier did not measure blocks rather than waive, whatever it named|checks:ci-required threads:actionable class-policy:unmeasured|check-classified|0|merge=false transient=false $OPEN runs=- issues=[$UNREADABLE;$PERSON] warnings=[] waiver=-|class: class=render measured=false cause=stub;review-gate-error=policy-unmeasured value=cause=stub;review-policy: the change classifier fell back to standard instead of measuring a class;blocked;head-run: none|calls=$CHECK_POLICY auth=<unset>
a range naming a commit this checkout lacks blocks rather than waive|checks:ci-required threads:actionable class-policy:range-absent|check-classified|0|merge=false transient=false $OPEN runs=- issues=[$UNREADABLE;$PERSON] warnings=[] waiver=-|{fetch-no-origin};blocked;head-run: none|calls=$CHECK_POLICY auth=<unset>
an unreadable pull request range blocks rather than waive|checks:ci-required threads:actionable class-policy:range-fail|check-classified|0|merge=false transient=false $OPEN runs=- issues=[$UNREADABLE;$PERSON] warnings=[] waiver=-|blocked;head-run: none|calls=$CHECK_POLICY auth=<unset>
"

# The merge modes resolve each waived thread, one reply naming the class and
# then one resolve, as the last step before the merge call. The inverse rows
# never reach a thread mutation: a person's thread, a class sent for review,
# an unreadable policy, and a head that moved after the class was measured.
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
a head that moved after the class was measured blocks before any thread is touched|checks:ci-required threads:bot class-policy:trivial head-moved:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb post-entry|auto-classified|1|-|Warnings:;⚠ {waived:1};BLOCKED PR #123 — the class policy waived its bot threads at $RANGE_HEAD, not at the head being merged (bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb)|calls=$MERGE_PRE auth=<unset>
a failed reply blocks with nothing armed, and names the thread|checks:ci-required threads:two-bots class-policy:trivial reply:fail post-entry|auto-classified|1|-|Warnings:;⚠ {waived:2};BLOCKED PR #123 — the reply on waived bot thread PRRT_bot_a failed;{\"error\":\"reply refused\"}|calls=$MERGE_PRE,graphql:reply(PRRT_bot_a:trivial$AT) auth=<unset>
a failed resolve blocks with nothing armed, and names the thread|checks:ci-required threads:bot class-policy:trivial resolve:fail post-entry|auto-classified|1|-|Warnings:;⚠ {waived:1};BLOCKED PR #123 — resolving waived bot thread PRRT_post_merge_bot failed;{\"error\":\"resolve refused\"};{\"success\":false,\"resolved\":[],\"failed\":[\"PRRT_post_merge_bot\"]}|calls=$MERGE_PRE,graphql:reply(PRRT_post_merge_bot:trivial$AT),graphql:resolve(PRRT_post_merge_bot) auth=<unset>
"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
