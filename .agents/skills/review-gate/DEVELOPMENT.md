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
| `scripts/review-writer.sh` | Posts that answer as the commit status. The whole writer. |
| `scripts/validate.sh` | The consumer-facing tool: is this repo's install sound? Runtime, settings, carry-forward exclusions, then the workflow half below, whose verdicts it relays and counts. |
| `scripts/validate-workflow.sh` | Is the adopted copy still the shipped template? Equality, not re-derivation: see § Equality, not re-derivation. Usable on its own when only the workflow copy changed. |
| `scripts/pr-watch.sh` | The agent-side reducer: "does any open PR need attention right now?" Silence on stdout + exit 0 means nothing needs you, which makes it a one-line loop/cron predicate; `--heal` also dispatches the writer once on a stale gate. |
| `scripts/review-predicate-selftest.sh` | Offline proof of the decision table. An ENGINE proof: it runs here, in the catalog repo, on every change. |
| `tests/e2e-sandbox.sh` | Live replay against a throwaway repo — re-run it before changing the engine. |

## Where each proof runs

The split is deliberate, and it is the line between a tool and a test suite.

- **Engine proofs run here.** The selftest, the wrapper suites under
  `tests/`, and the sandbox replay all prove that this package behaves. A
  consumer re-running them would be re-testing vendored content that already
  passed on the commit that shipped it.
- **Repo-own checks run in the consumer.** `validate.sh` asks only questions
  whose answer depends on the calling repository: its files, its committed
  settings, its tracked paths, its adopted workflow. It re-runs no engine
  behaviour, and its settings half calls `review-predicate.sh --check-config`
  rather than restating any value rule.

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
OUTSIDE a block scalar. Inside a `run: |` the lines are shell payload, so the
bytes are compared as they are: a `#` line there is a shell comment that can
comment out a joined command, trailing whitespace after a backslash cancels
the continuation, and a blank line is script content. Two deltas are
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

What equality cannot express is checked on its own, and there are two such
things. With the `check_run` opt-in enabled, the reviewer's check name lives
in a GitHub repository variable rather than in the file. And the single-writer
contract is about the workflow SET, not one file: no other tracked workflow
may name the engine outside a comment. That second one over-approximates on
purpose — an invocation has no closed set of spellings, so it counts a
reference and claims only that.

The boundary, stated so it is not discovered: comments are compared out. A
copy whose prose was reworded is still the template — the catalog's own copy
reworded its header — and a comment gates nothing.

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

## The workflow template

`templates/review-gate-writer.yml` is copied verbatim: it carries no per-repo
values. The two per-repo knobs it once held are gone —

- the default branch is `${{ github.event.repository.default_branch }}`, and
  each engine-running job refuses an empty resolution in a guard step ahead
  of its checkout rather than falling back to a branch name someone has to
  keep correct;
- the `check_run` opt-in's reviewer check name is the repository variable
  `REVIEW_GATE_CHECK_RUN_NAME`, read by a term the relay's `if:` already
  carries, so opting in is uncommenting the trigger and setting a variable.

`tests/review-writer-template.test.sh` pins both, against the template and
against this repo's own adopted copy — that suite is where the workflow's
MEANING is asserted, and it runs here, upstream, on every change. A consumer
asserts nothing about meaning: `validate-workflow.sh` asks only whether its
copy is still this file. The two questions live in the two places that can
answer them.
