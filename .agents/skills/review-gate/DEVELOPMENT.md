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
| `scripts/validate-workflow.sh` | The adopted-workflow contract alone. Split at the one seam the check has — everything here reads `.github/workflows/` and nothing else does — and usable on its own when only the workflow copy changed. Built on a block spine: see § Blocks, not the file. |
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

## Blocks, not the file

`validate-workflow.sh` asks every question of an EXTRACTED BLOCK — the `on:`
mapping, one job's mapping, one step — never of the workflow file. Four
primitives do the extraction and every check is built on them:

| Primitive | Answers |
|---|---|
| `block_under FILE KEY-ERE` | the lines nested under the first matching key, by indentation |
| `split_children BLOCK DEST PREFIX` | one file per immediate child of a mapping — `jobs:` gives a file per job, `on:` a file per trigger |
| `key_value BLOCK KEY` | the scalar after `KEY:` among a block's immediate children |
| `split_steps JOB DEST` | one file per step, with the `- ` marker rewritten to two spaces so the three primitives above work on a step unchanged |

The distinction is between "does the workflow do this?" and "does this text
appear somewhere?". The second question is answered yes by a comment naming
a variable, by a job renamed after the trigger it replaced, and by a second
copy of a role that nothing then inspects. Roles are counted for the same
reason: a duplicate is an uninspected job holding the same powers, not a
harmless copy of the one that was checked.

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
against this repo's own adopted copy. `validate.sh` asserts the same contract
in a consumer, phrased as a verdict a repo owner can act on.
