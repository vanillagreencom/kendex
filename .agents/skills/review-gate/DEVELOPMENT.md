# review-gate — development notes

Internals, design, and maintenance for the review-gate skill. Consumer docs
live in [README.md](README.md); the agent-facing contract is
[SKILL.md](SKILL.md).

## Engine files

Paths are as installed in a consuming repo, under
`.agents/skills/review-gate/`.

| File | What it is |
|------|------------|
| `scripts/review-predicate.sh` | Answers "is this head reviewed?" — verdict on stdout, exit 2 means no verdict, take no action. `--check-config` runs its settings-validation phase alone. |
| `tests/lib/gh-shim.sh` | The fake `gh` every offline proof puts on PATH: fixtures by endpoint, real jq for `--jq`, fail switches. |
| `tests/lib/selftest-fixtures.sh` | The fixture writers, one per endpoint shape, sourced by the selftest. |
| `scripts/review-writer.sh` | Posts that answer as the commit status. The whole writer. |
| `scripts/validate.sh` | The consumer-facing tool: is this repo's install sound? Runtime, settings, carry-forward exclusions, then the workflow half below, whose verdicts it relays and counts. |
| `scripts/validate-workflow.sh` | Is the adopted copy still the shipped template? Equality, not re-derivation: see § Equality, not re-derivation. Usable on its own when only the workflow copy changed. |
| `scripts/pr-watch.sh` | The agent-side reducer: "does any open PR need attention right now?" Silence on stdout + exit 0 means nothing needs you, which makes it a one-line loop/cron predicate; `--heal` also dispatches the writer once on a stale gate. |
| `scripts/review-predicate-selftest.sh` | Offline proof of the decision table. An ENGINE proof: it runs here, in the catalog repo, on every change. |
| `tests/predicate-re2-engine.test.sh` | The predicate's thread jq, run through the engine that actually ships it: the real `gh --jq` (Go's RE2), pointed at a local HTTP stub. Every other proof reads that program through the local jq, whose Oniguruma accepts lookaround RE2 will not compile. Needs `gh`, `python3` and `jq`, and refuses rather than skipping without them. |

## Where each proof runs

The split is deliberate, and it is the line between a tool and a test suite.

- **Engine proofs run here.** The selftest and the suites under `tests/`
  prove that this package behaves. A consumer re-running them would be
  re-testing vendored content that already passed on the commit that shipped
  it.
- **Repo-own checks run in the consumer.** `validate.sh` asks only questions
  whose answer depends on the calling repository: its files, its committed
  settings, its tracked paths, its adopted workflow. It re-runs no engine
  behaviour, and it judges no value or pattern itself — its settings half
  calls `review-predicate.sh --check-config` and relays the answer.

ONE JUDGE per rule, and the judge is whoever owns the mechanism. The
exclusion matcher lives in `review-predicate.sh`, so exclusion-pattern
spelling is refused there and nowhere else; a second grammar in the validator
could only drift from the matcher, and did. What `validate.sh` keeps is what
the engine cannot answer: facts about the calling repository's tree.

The grammar the engine judges by is CLOSED — path characters plus `*` — and
that is what ends the equivalence hunt rather than another refusal. `case`
offers three more metacharacters, and each respells something the structural
rules reject: `[.]` and `\.` are the `.` component written differently, and
the next equivalence would be the next round. Refusing the spelling outright
leaves nothing to analyse. The check runs in the configuration phase, ahead
of every evaluation, so the grammar and what actually matches cannot diverge.

`--check-config` stops at the last point before the predicate needs a PR to
evaluate. Every configuration rule sits above that stop — the comment-reviewer
grammar included, which is validated in the configuration phase and only split
by the evidence loop. Moving a rule below the stop is a visible edit, not a
silent hole in what the flag covers.

## How the selftest pins the decision table

`review-predicate-selftest.sh` pins the decision table offline: a `gh` shim
answers from fixtures and applies `--jq` through real jq, so the real
predicate runs unmodified. Every case ending `approved` is paired with a
near-miss that must not. Two layers: a mechanism layer with forced
configurations, and a configured layer that re-derives the battery from the
invoking repo's own resolved settings.

## Equality, not re-derivation

`validate-workflow.sh` compares the adopted copy against the shipped template
line by line. A YAML comment-only line is the one thing dropped, and only
OUTSIDE a block scalar. Inside a `run: |` the lines are shell payload, so NOTHING
is normalized and the bytes are compared as they are: a `#` line there is a
shell comment that can comment out a joined command, trailing whitespace
after a backslash cancels the continuation, a blank line is script content,
and a CRLF ending is a CRLF ending. Normalization applies to YAML-structure
lines and nowhere else, which is what keeps a rule written for YAML from
erasing a shell-significant byte. Two deltas are
allowed and nothing else. Any other difference is one failure naming the
first divergent line, and the remedy never varies: re-copy the template.

- **The script path**, which is not interchangeable: each repo kind has ONE
  correct spelling. Only the EXPECTED side is normalized, so the catalog
  requires `skills/` and a consumer requires the vendored `.agents/skills/`,
  and each rejects the other's. Rewriting both sides would make either pass
  anywhere.
- **The `check_run` opt-in**, which is two lines or none, in one place. The
  expected side is built by uncommenting the template's own two lines where
  they sit, so the pair is allowed exactly where the template documents it —
  a pair appended under `jobs:` is not a trigger and is a divergence like any
  other edit. A trigger without its `types:` child fires on every activity
  type or is refused outright, and the child without its trigger lands under
  whatever precedes it, so the two are required adjacent and in order.

It re-derives nothing, and that is the design rather than an economy. Deriving
the contract — this job's permissions, that expression's terms, these activity
types — is a YAML-and-expressions parser written in bash, and it has an
asymptote: a flipped `&&`, an appended `|| true`, an activity type matched as
a substring, an inline flow mapping on the trigger key line, a foreign
`repository:` input on a checkout. Each is a new rule, and the next spelling
is a new hole. Equality has no such gap, because the template carries no
per-repo values: a copy that differs is a copy someone edited.

What it therefore never answers is what the TEMPLATE says. Both sides of the
diff come from that one file, so an edit re-copied into every consumer is
invisible here by construction. One instrument upstream reads the template's
content — the relay battery in `tests/review-writer-template.test.sh`, which
extracts the relay step and EXECUTES it against a gh stub, over both copies.
Everything else the template says is unasserted — an expression, a trigger, a
`permissions:` scope, a concurrency group — with one exception: this tool
refuses to run at all when the template stops carrying the COMMENTED
`check_run` opt-in pair, which is where it derives its one allowance from.
Read that as the coverage, not as a gap someone forgot to fill.

What equality cannot express is handled in one of two ways, and the
difference matters to anyone reading a clean run.

CHECKED: the single-writer contract is about the workflow SET, not one file,
so no other tracked workflow may name the engine outside a comment. That one
over-approximates on purpose — an invocation has no closed set of spellings,
so it counts a reference and claims only that.

REPORTED, NOT CHECKED: with the `check_run` opt-in enabled, the reviewer's
check name lives in a GitHub repository variable rather than in any file. A
local, report-only tool cannot read it, and reaching for the API to find out
would give this tool a network dependency it does not have. The note names
the prerequisite and says it is unverified; a clean exit does not mean the
variable is set.

The boundary, stated so it is not discovered: comments are compared out. A
copy whose prose was reworded is still the template — the catalog's own copy
reworded its header — and a comment gates nothing.

## Decline parsing

A thread's disposition reply fails as `unreasoned-decline` when it declines
and its reason strips to nothing against the predicate's label vocabulary: an
empty reason, or only labels such as `frozen`, `out of scope`, `pre-existing`,
or a bare test count. Two positional name strips ride after that vocabulary
and the filler words alike. A count takes the non-space run immediately in
front of it, and a slash-joined token is a path, so `lifecycle 104/104 and the full tools/guard pass`
strips to nothing too. A name standing anywhere else
survives. The parser reads the reply by shape, so a decline written without
the colon counts too; a label beside a real reason is fine. The reach and the
shapes past it are pinned in `tests/corpus/declines-known-limit.txt`.

## Tracking-claim parsing

A thread's disposition reply fails as `untracked-claim` when it carries a
track-word — `track`, `tracked`, `tracking`, `tracks` — and names no issue.
The match is lexical and anywhere in the reply, never a judgement of intent,
so ordinary prose springs it: `the file is tracked by git` is a tracking
claim, and an author means `committed` there. Bot comments are exempt because
they quote each other, so the reply that counts is the last NON-BOT one
matching either a reply form or a track-word: a later `Fixed in <sha>` or
`Declined:` clears the verdict, and resolving the thread does not.

## Predicate evidence and trust

Evidence for the current head is any of:

1. **Review object** at the exact head from a non-author, non-dismissed
   login. `REVIEW_GATE_REVIEW_OBJECT_TRUSTED_LOGINS` restricts accepted
   logins, and `REVIEW_GATE_REVIEW_OBJECT_MIN_STATE = "approved"` restricts
   accepted states. A later COMMENTED review does not supersede an approval;
   only a later CHANGES_REQUESTED withdraws it. A row whose body's first line,
   after leading whitespace and markdown quote markers, contains a
   `REVIEW_GATE_REVIEW_OBJECT_ERROR_PATTERNS` marker is not evidence, never a
   failure.
2. **Trusted clean-analysis check-run or commit status** named by
   `REVIEW_GATE_TRUSTED_STATUS_CONTEXTS`. A success matching
   `REVIEW_GATE_CHECKRUN_SKIP_PATTERNS` is not evidence because it does not
   prove analysis ran. On both surfaces the newest row or run per name decides;
   an older clean success never outlives its reviewer's newer pending, failed,
   or skip-marked round.
3. **Comment-form clean pass** from a `REVIEW_GATE_COMMENT_REVIEWERS` bot,
   never the PR author even if configured, binding the evidence to this head's
   SHA at or above `REVIEW_GATE_SHA_PREFIX_FLOOR`.
4. **Operator override** named by `REVIEW_GATE_OVERRIDE_CONTEXT`, posted by a
   trusted operator with a non-empty reason. It substitutes only for missing
   evidence; it never overrides changes requested or an unresolved thread.
   The gate detail surfaces the enforced reason. Fix findings and resolve
   threads first, then attest.

With `REVIEW_GATE_CARRY_FORWARD`, evidence at an ancestor carries to head only
when the delta is in a configured class: docs-only, comment-only, a committed
kendex render tree, or an identical tree. Carry-forward never creates evidence,
never carries over code changes outside those classes, and never bypasses a
fail-closed term.

Changes requested and unresolved threads always fail closed. Every evidence
read fails loud with exit 2 and no verdict.

Trust keys on names only GitHub controls: the author login of a review or
comment, or the exact check or status context on repos where every publisher is
trusted. A comment body establishes no trust; it only binds evidence to a
commit. Where PR workflows hold `statuses:write`,
`REVIEW_GATE_STATUS_PUBLISHER_REJECT` rejects statuses minted by a forgeable
creator, typically `github-actions[bot]`, on both trusted-context and override
reads.

## Writer mechanics (`.agents/skills/review-gate/scripts/review-writer.sh`)

One workflow, defined on the default branch, is the only writer of the gate
status. Its `workflow_dispatch` and `schedule` invocations enumerate every
open PR, then each recursive single-head invocation evaluates the predicate
and converges its result.

- The `merge_group` invocation posts unconditional success for one merge-group
  SHA without evaluating the predicate or enumerating open PRs.
- `WRITER_READ_ONLY=1` exits before settings resolution and reads or posts
  nothing.
- PR-attached legs (`pull_request_target`, `pull_request_review`, `status`, and
  an opted-in `check_run`) do not run the engine. They run a group-less relay
  that dispatches a converge pass. Only `workflow_dispatch` and `schedule`
  hold the single-writer group. The relay costs one non-evictable run per
  PR-attached event; size that before adoption on a capacity-limited runner
  pool ([references/adoption.md](references/adoption.md) § Updating an
  already-adopted copy).
- The relay never exits non-zero and holds no `statuses` scope. Every fault
  warns and exits 0, every wait is bounded, and a sustained dispatch outage
  surfaces as gate staleness, healed by the cron floor and `pr-watch --heal`.
- The `pull_request_target` job never executes PR-controlled code. Every
  checkout pins the default branch with credentials dropped and refuses an
  empty default-branch resolution rather than falling back.
- On the converge legs, a single-head evaluation no-ops when the current entry
  already matches and defers a `success` post to a newer run's entry. See
  § Write ordering.

## Evidence reads

Reads retry in-process up to `REVIEW_GATE_API_ATTEMPTS` (default 1) with
`REVIEW_GATE_API_RETRY_DELAY_SECONDS` between attempts; a read that fails
through every attempt is exit 2, and a zero-byte producer is a failed read,
not an empty page set. Review threads are counted across pages (100 per page,
bound 20 pages / 2000 threads); past the bound — or when pagination metadata
cannot advance — the count reports overflow and fails closed to
`threads-open`.

Statuses are read from the per-commit statuses LIST endpoint, where every
real publisher (GitHub Apps included) carries a creator login. While
`REVIEW_GATE_STATUS_PUBLISHER_REJECT` is configured, a status with no creator
login is an anomaly and is not evidence; with the list empty — the default —
the filter is off entirely.

## Write ordering

Before any `success` post the writer re-reads the status and defers when any
gate entry was created at or after this run's evaluation instant: a newer
run's state AND description (which carries the audit detail) both stand, and
a failed re-read defers too. Downward posts never defer. The single-writer
concurrency group is a waste reducer on top of that, not the correctness
mechanism — runs can still interleave on one head, and this rule is what
orders them.
