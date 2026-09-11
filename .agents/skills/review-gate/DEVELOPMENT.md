# review-gate development

Internals and maintenance for the review-gate engine. Consumer docs: [README.md](README.md); the agent contract: [SKILL.md](SKILL.md).

## Engine files

Paths as installed in a consuming repo, under `.agents/skills/review-gate/`.

| File | What it is |
|------|------------|
| `scripts/review-predicate.sh` | Answers "is this head reviewed?": verdict on stdout, exit 2 means no verdict, take no action. `--check-config` runs its settings-validation phase alone. |
| `scripts/review-writer.sh` | Posts that answer as the commit status. The whole writer. |
| `scripts/validate.sh` | The consumer-facing tool: is this repo's install sound? Runtime, settings, carry-forward exclusions, then the workflow half below, whose verdicts it relays and counts. |
| `scripts/validate-workflow.sh` | Is the adopted copy still the shipped template? Equality, not re-derivation: see § Equality, not re-derivation. |
| `scripts/pr-watch.sh` | The agent-side reducer: does any open PR need attention right now? Silence on stdout plus exit 0 means nothing needs you; `--heal` also dispatches the writer once on a stale gate. |
| `scripts/lib/diagnostics.sh` | Formats stable diagnostic records and validator reports. Standalone settings consumers copy it with `scripts/lib/settings.sh`. |
| `scripts/review-predicate-selftest.sh` | Offline proof of the decision table. An engine proof: it runs here, in the catalog repo, on every change. |
| `tests/lib/gh-shim.sh` | The fake `gh` every offline proof puts on PATH: fixtures by endpoint, real jq for `--jq`, fail switches. |
| `tests/lib/selftest-fixtures.sh` | The fixture writers, one per endpoint shape, sourced by the selftest. |
| `tests/predicate-re2-engine.test.sh` | The predicate's thread jq, run through the engine that actually ships it: the real `gh --jq` (Go's RE2), pointed at a local HTTP stub. Every other proof reads that program through the local jq, whose Oniguruma accepts lookaround RE2 will not compile. Needs `gh`, `python3` and `jq`, and refuses rather than skipping without them. |

## Diagnostic records

Refusals and notices begin with `review-gate-error=CODE value=VALUE` or `review-gate-notice=CODE value=VALUE`. Values use Bash `printf %q` escaping. English explanation follows the record. Validators use `ok`, `FAIL`, or `note` records with `check=CODE value=VALUE` and indent all explanation lines. The consumer validator, `validate.sh`, ends with `review-gate-failed=COUNT passed=COUNT`; the standalone workflow validator exits after its individual records.

The predicate's verdict and detail lines and the watcher's tab-separated attention records are complete text protocols. Their script headers define those contracts. Diagnostic changes preserve those stdout protocols.

## Where each proof runs

- Engine proofs run here. The selftest and the suites under `tests/` prove that this package behaves. A consumer re-running them would be re-testing vendored content that already passed on the commit that shipped it.
- Repo-own checks run in the consumer. `validate.sh` asks only questions whose answer depends on the calling repository: its files, its committed settings, its tracked paths, its adopted workflow. It re-runs no engine behaviour and judges no value or pattern itself; its settings half calls `review-predicate.sh --check-config` and relays the answer.

One judge per rule, and the judge is whoever owns the mechanism. The exclusion matcher lives in `review-predicate.sh`, so exclusion-pattern spelling is refused there and nowhere else; a second grammar in the validator could only drift from the matcher. The grammar the engine judges by is closed, path characters plus `*`: `case` offers three more metacharacters, and each respells something the structural rules reject, so refusing the spelling outright leaves nothing to analyse. The check runs in the configuration phase, ahead of every evaluation.

`--check-config` stops at the last point before the predicate needs a PR to evaluate. Every configuration rule sits above that stop, the comment-reviewer grammar included. Moving a rule below the stop is a visible edit, not a silent hole in what the flag covers.

## How the selftest pins the decision table

`review-predicate-selftest.sh` pins the decision table offline: a `gh` shim answers from fixtures and applies `--jq` through real jq, so the real predicate runs unmodified. Every case ending `approved` is paired with a near-miss that must not. The runner sources private test tables under `tests/lib/predicate-selftest/` at the configuration, evidence, API-read and carry-forward boundaries. A configured layer derives its cases from the invoking repo's resolved settings.

## Equality, not re-derivation

`validate-workflow.sh` compares the adopted copy against the shipped template line by line. A YAML comment-only line is the one thing dropped, and only outside a block scalar. Inside a `run: |` the lines are shell payload, so nothing is normalized and the bytes are compared as they are: a `#` line there is a shell comment that can comment out a joined command, trailing whitespace after a backslash cancels the continuation, a blank line is script content, and a CRLF ending is a CRLF ending. Two deltas are allowed and nothing else; any other difference is one failure naming the first divergent line, and the remedy never varies: re-copy the template.

- The script path, which is not interchangeable: each repo kind has one correct spelling. Only the expected side is normalized, so the catalog requires `skills/` and a consumer requires the vendored `.agents/skills/`, and each rejects the other's.
- The `check_run` opt-in, which is two lines or none, in one place. The expected side is built by uncommenting the template's own two lines where they sit, so the pair is allowed exactly where the template documents it. A trigger without its `types:` child fires on every activity type or is refused outright, and the child without its trigger lands under whatever precedes it, so the two are required adjacent and in order.

It re-derives nothing by design. Deriving the contract (this job's permissions, that expression's terms, these activity types) is a YAML-and-expressions parser written in bash, and every new spelling is a new hole. Equality has no such gap, because the template carries no per-repo values: a copy that differs is a copy someone edited.

What it therefore never answers is what the template says. Both sides of the diff come from that one file, so an edit re-copied into every consumer is invisible here by construction. One instrument upstream reads the template's content: the relay battery in `tests/review-writer-template.test.sh`, which extracts the relay step from both copies, executes it against a gh stub once, and proves the two extracted steps byte-identical. Everything else the template says is unasserted, with one exception: this tool refuses to run at all when the template stops carrying the commented `check_run` opt-in pair, which is where it derives its one allowance from.

Checked: the single-writer contract is about the workflow set, not one file, so no other tracked workflow may name the engine outside a comment. That over-approximates on purpose, counting a reference and claiming only that.

Reported, not checked: with the `check_run` opt-in enabled, the reviewer's check name lives in a GitHub repository variable rather than in any file. A local, report-only tool cannot read it, so the note names the prerequisite and says it is unverified; a clean exit does not mean the variable is set.

Comments are compared out: a copy whose prose was reworded is still the template, and a comment gates nothing.

## Decline parsing

A thread's disposition reply fails as `unreasoned-decline` when it declines and its reason strips to nothing against the predicate's label vocabulary: an empty reason, or only labels such as `frozen`, `out of scope`, `pre-existing`, or a bare test count. Two positional name strips ride after that vocabulary and the filler words alike. A count takes the non-space run immediately in front of it, and a slash-joined token is a path, so `lifecycle 104/104 and the full tools/guard pass` strips to nothing too. A name standing anywhere else survives. The parser reads the reply by shape, so a decline written without the colon counts too; a label beside a real reason is fine. The reach and the shapes past it are pinned in `tests/corpus/declines-known-limit.txt`.

## Tracking-claim parsing

A thread's disposition reply fails as `untracked-claim` when it carries a track-word (`track`, `tracked`, `tracking`, `tracks`) and names no issue. The match is lexical and anywhere in the reply, never a judgement of intent, so ordinary prose springs it: `the file is tracked by git` is a tracking claim, and an author means `committed` there. Bot comments are exempt because they quote each other, so the reply that counts is the last non-bot one matching either a reply form or a track-word: a later `Fixed in <sha>` or `Declined:` clears the verdict, and resolving the thread does not.

## Suppressed-finding parsing

A review fails as `suppressed-findings` when its body carries a heading whose text is `Suppressed comments (N)`. Copilot writes that block instead of posting comments when it judges a finding to be in code the current diff did not change, so no review thread exists and the unresolved-thread term reads zero. The term runs over the rows the evidence select accepts, before the `REVIEW_GATE_REVIEW_OBJECT_MIN_STATE` reduction, so a COMMENTED row carrying findings is read under `approved` too. It reads them at the commit the gate relies on: the head, and `carry_base` as well once carry-forward decided the evidence — the carry candidate is the same trust chain at a different commit, so the row carrying the block is itself carry-eligible and head-only reading would let a carry approve over it.

The block ends at the next heading of any level or at `</details>`, and an entry inside it is a whole line of the form `**path:line**`. Lines inside a fenced snippet are skipped, because the offending code pasted under an entry carries `#` comment lines a heading rule would otherwise read as the end of the block. The fence records its opening delimiter's character and length and closes only on a run of the same character at that length or longer with nothing after it, so a three-backtick fence quoted inside a four-backtick one does not end it. The heading is the sentinel: both heading arms are read whatever the fence state says and close any fence they find open, so no run of fence-looking lines earlier in the body can leave the scan inside a fence and swallow the block that follows. That errs toward finding a block, never toward missing one — the same direction as the quoting limit below. The heading's `N` is the count reported; the entries are the file:line list. A disagreement between the two, a heading whose count is not a number, and a parse bash cannot read all refuse instead of reporting a smaller number, and all refuse to the verdict rather than to exit 2, which would tell the writer to take no action and leave an earlier success standing. The verdict detail carries a bounded list because a commit-status description holds about 140 characters; when it drops entries it counts them, and the full list goes to stderr under `review-gate-notice=predicate-suppressed`.

There is no dedicated settings key, and while enforcement is on nothing disables the term; the only switch that reaches it is `REVIEW_GATE_MODE = "off"`, which answers approved for the whole gate without reading any evidence. The known limit is the errored-attestation filter's mirror: a body quoting the heading at the start of a line counts as a real block.

An entry is subtracted when the PR author has answered it, because no thread exists to reply into. The reply is an issue comment by the author carrying a line that opens with the entry's own `file:line` token — bare as the status detail prints it, or bold as the review body prints it — and continues with the reply. Both spellings go through one test, equality with a token the scan extracted, so the scan holds the only definition of what an entry token is and a path it admits is a path the author can copy back, a space in it included. The bare form needs the character after the token to be no letter or digit, so `a/b.ts:1` cannot claim the line `a/b.ts:12`; the bold form needs no such test, its closing `**` being the terminator. The comment binds this head by naming a sha at or above `REVIEW_GATE_SHA_PREFIX_FLOOR` that the head starts with, so a reply written for an earlier head does not survive a push. The binding scan reads only the lines the line rule does not claim. A reply line disposes one finding and asserts no commit, while carrying runs shaped like a sha that are not one: the commit a `Fixed in <sha>` names, which the ordinary commit-reply-push order makes the head; a tracking claim's `#1234567`; the entry token itself where a path opens with hex. Binding on any of them lets a comment written for the earlier head bind itself to the new one and carry its other replies across a diff no reviewer re-read. That reply is read by the same `disposition`, `tracking`, `names_issue`, `declined` and `reason_left` definitions the thread terms read, spelled once in `REPLY_FORMS_DEF`: a reply that is neither a disposition nor a tracking claim, a tracking claim naming no issue, and a decline whose reason strips to nothing all leave the entry standing. The newest line naming an entry decides. Every finding stands when the disposition read produces no count, and the verdict says so; the term still clears whole when the commit the gate relies on carries no block.

## Predicate evidence and trust

Evidence for the current head is any of:

1. Review object at the exact head from a non-author, non-dismissed login. `REVIEW_GATE_REVIEW_OBJECT_TRUSTED_LOGINS` restricts accepted logins, and `REVIEW_GATE_REVIEW_OBJECT_MIN_STATE = "approved"` restricts accepted states. A later COMMENTED review does not supersede an approval; only a later CHANGES_REQUESTED withdraws it. A row whose body's first line, after leading whitespace and markdown quote markers, contains a `REVIEW_GATE_REVIEW_OBJECT_ERROR_PATTERNS` marker is not evidence, never a failure.
2. Trusted clean-analysis check-run or commit status named by `REVIEW_GATE_TRUSTED_STATUS_CONTEXTS`. A success matching `REVIEW_GATE_CHECKRUN_SKIP_PATTERNS` is not evidence because it does not prove analysis ran. On both surfaces the newest row or run per name decides; an older clean success never outlives its reviewer's newer pending, failed, or skip-marked round.
3. Comment-form clean pass from a `REVIEW_GATE_COMMENT_REVIEWERS` bot, never the PR author even if configured, binding the evidence to this head's SHA at or above `REVIEW_GATE_SHA_PREFIX_FLOOR`.
4. Operator override named by `REVIEW_GATE_OVERRIDE_CONTEXT`, posted by a trusted operator with a non-empty reason. It substitutes only for missing evidence; it never overrides changes requested or an unresolved thread. The gate detail surfaces the enforced reason.

With `REVIEW_GATE_CARRY_FORWARD`, evidence at an ancestor carries to head only when the delta is in a configured class: docs-only, comment-only, a committed kendex render tree, or an identical tree. Carry-forward never creates evidence, never carries over code changes outside those classes, and never bypasses a fail-closed term.

Changes requested and unresolved threads always fail closed. Every evidence read fails loud with exit 2 and no verdict.

Trust keys on names only GitHub controls: the author login of a review or comment, or the exact check or status context on repos where every publisher is trusted. A comment body establishes no trust; it only binds evidence to a commit. Where PR workflows hold `statuses:write`, `REVIEW_GATE_STATUS_PUBLISHER_REJECT` rejects statuses minted by a forgeable creator, typically `github-actions[bot]`, on both trusted-context and override reads.

## Writer mechanics

One workflow, defined on the default branch, is the only writer of the gate status. Its `workflow_dispatch` and `schedule` invocations enumerate every open PR, then each recursive single-head invocation evaluates the predicate and converges its result.

- The `merge_group` invocation posts unconditional success for one merge-group SHA without evaluating the predicate or enumerating open PRs.
- `WRITER_READ_ONLY=1` exits before settings resolution and reads or posts nothing.
- PR-attached legs (`pull_request_target`, `pull_request_review`, `status`, and an opted-in `check_run`) do not run the engine. They run a group-less relay that dispatches a converge pass. Only `workflow_dispatch` and `schedule` hold the single-writer group. The relay costs one non-evictable run per PR-attached event; size that before adoption on a capacity-limited runner pool ([Updating an already-adopted copy](references/adoption.md#updating-an-already-adopted-copy-relayconverge-split)).
- The relay never exits non-zero and holds no `statuses` scope. Every fault warns and exits 0, every wait is bounded, and a sustained dispatch outage surfaces as gate staleness, healed by the cron floor and `pr-watch --heal`.
- The `pull_request_target` job never executes PR-controlled code. Every checkout pins the default branch with credentials dropped and refuses an empty default-branch resolution rather than falling back.
- On the converge legs, a single-head evaluation no-ops when the current entry already matches and defers a `success` post to a newer run's entry. See § Write ordering.

## Evidence reads

Reads retry in-process up to `REVIEW_GATE_API_ATTEMPTS` (default 1) with `REVIEW_GATE_API_RETRY_DELAY_SECONDS` between attempts; a read that fails through every attempt is exit 2, and a zero-byte producer is a failed read, not an empty page set. Review threads are counted across pages (100 per page, bound 20 pages / 2000 threads); past the bound, or when pagination metadata cannot advance, the count reports overflow and fails closed to `threads-open`.

Statuses are read from the per-commit statuses list endpoint, where every real publisher (GitHub Apps included) carries a creator login. While `REVIEW_GATE_STATUS_PUBLISHER_REJECT` is configured, a status with no creator login is an anomaly and is not evidence; with the list empty, the default, the filter is off entirely.

## Write ordering

Before any `success` post the writer re-reads the status and defers when any gate entry was created at or after this run's evaluation instant: a newer run's state and description (which carries the audit detail) both stand, and a failed re-read defers too. Downward posts never defer. The single-writer concurrency group is a waste reducer on top of that, not the correctness mechanism: runs can still interleave on one head, and this rule is what orders them.
