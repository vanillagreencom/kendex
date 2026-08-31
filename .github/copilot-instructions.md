# kendex

kendex is a distribution of agent-stack assets: skills (`skills/`, Bash
scripts plus markdown), agent definitions (`agents/`), hooks (`hooks/`),
Pi extensions (`pi-extensions/`, TypeScript with committed bundles), a
Rust engine and CLI (`crates/`), and a Tauri + React app (`crates/app`,
`ui/`). Consumers vendor the skills and extensions and re-vendor in
deliberate batches. Path-scoped review rules live in
`.github/instructions/*.instructions.md`; fleet review economics and
accepted residual classes in `review-bots.md` — follow both.

# Code review calibration

PRs here are authored and shepherded by AI agents and re-reviewed on
every push. Rounds are the scarce resource. Calibrate:

## What to raise
- Blocking: correctness bugs, security holes, data loss, fail-open paths in
  gate/CI/guard code — in the changed lines or directly broken by them.
- One comment per root cause. Name every affected site in that comment
  instead of one comment per site.
- Surface everything you have about the current diff in one round; a
  finding held for the next round costs a full re-review cycle.

## What not to raise
- Style, wording, naming, and comment-phrasing preferences.
- Speculative hardening on paths that already fail closed.
- Test-coverage asks, unless the diff changes behavior that no test now
  exercises — then say which behavior, in one comment.
- Scope observations ("this also touches X") when X is listed in the PR
  body as deliberate.
- Anything outside the diff and its direct blast radius.
- A finding class already answered on this PR with `Declined: <reason>` —
  do not re-raise it unless the relevant code changed since.

## Reply contract (context for reading threads)
`AGENTS.md` § Code Review Rules is the contract. Read it there.

## Severity honesty
Mark a finding blocking only if you would stop a human colleague's merge
for it. Everything else is a suggestion — batch suggestions, and omit them
entirely on re-review rounds whose diff is a one-line fix.
