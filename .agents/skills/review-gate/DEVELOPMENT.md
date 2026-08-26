# review-gate — development notes

Internals, design, and maintenance for the review-gate skill. Consumer docs
live in [README.md](README.md); the agent-facing contract is
[SKILL.md](SKILL.md).

## Engine files

Paths are as installed in a consuming repo, under
`.agents/skills/review-gate/`.

| File | What it is |
|---|---|
| `scripts/review-predicate.sh` | Answers "is this head reviewed?" — verdict on stdout, exit 2 means no verdict, take no action. |
| `scripts/review-writer.sh` | Posts that answer as the commit status. The whole writer. |
| `scripts/pr-watch.sh` | The agent-side reducer: "does any open PR need attention right now?" Silence on stdout + exit 0 means nothing needs you, which makes it a one-line loop/cron predicate; `--heal` also dispatches the writer once on a stale gate. |
| `scripts/review-predicate-selftest.sh` | Offline proof of the decision table; runs ungated in CI so a broken predicate reds its own job instead of approving everything. |
| `tests/e2e-sandbox.sh` | Live replay against a throwaway repo — re-run it before changing the engine. |

## How the selftest pins the decision table

`.agents/skills/review-gate/scripts/review-predicate-selftest.sh` pins the
decision table offline: a `gh` shim answers from fixtures and applies `--jq`
through real jq, so the real predicate runs unmodified. Every case ending
`approved` is paired with a near-miss that must not. Two layers: a mechanism
layer with forced configurations, and a configured layer that re-derives the
battery from the invoking repo's own resolved settings — so a repo trusting a
different bot tests its own trust list.
