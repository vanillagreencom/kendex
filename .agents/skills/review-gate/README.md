# review-gate

Blocks a merge until the PR head has actually been reviewed, by a bot, a person, or whatever mix your repository uses. One predicate answers "is this exact head reviewed?", one workflow posts that answer as a commit status your branch rules require. For a repository that wants review to be a precondition of merging rather than a convention.

It does not run or inspect your tests; that is branch protection's job.

## Install

Your repository must first satisfy one of these, or untested code can reach main and this engine will not stop it: a merge queue whose required checks include your test suite, or no held-back jobs, so every required check runs on every push. Held back with no queue, tests record as skipped, which GitHub counts as satisfied.

Then, once:

1. Vendor the skill and commit it: `kendex add vanillagreencom/kendex --skill review-gate`, then `kendex refresh` writes `.agents/skills/review-gate/`. GitHub Actions checks out only tracked files, so an uncommitted install does not exist in CI.
2. Copy `.agents/skills/review-gate/templates/review-gate-writer.yml` into `.github/workflows/` verbatim. It carries no per-repo values, and `kendex refresh` never syncs workflow YAML.
3. Add one CI step that runs `.agents/skills/review-gate/scripts/validate.sh`, and require the gate context (your `REVIEW_GATE_CONTEXT` value) in the ruleset beside your test aggregate.

```yaml
  review-gate-validate:
    runs-on: ubuntu-latest
    permissions:
      contents: read
    steps:
      - uses: actions/checkout@<pinned-sha>
        with:
          persist-credentials: false
      - run: .agents/skills/review-gate/scripts/validate.sh
```

Wiring, rulesets, merge-queue settings, and what an adoption PR deletes: [references/adoption.md](references/adoption.md).

## What it does

- Counts as evidence a review approval at the exact head, a trusted clean-analysis check or status on that head, a trusted bot's comment bound to that head's sha, or an operator override carrying a written reason.
- Fails closed on a standing changes-requested review or any unresolved thread, and on a failed evidence read, which posts nothing rather than guessing.
- Resets evidence on every new commit, with opt-in carry-forward for a docs-only or comment-only change or a `kendex refresh` under listed render trees.
- `validate.sh` checks your repository's install: engine present and runnable, committed `REVIEW_GATE_*` values legal, carry-forward exclusions still matching, adopted workflow still the template.
- `pr-watch.sh` reduces every open PR to attention lines, silent when nothing needs you.

## How it works

The workflow you copied is the only writer of the gate status. Its dispatch and schedule runs enumerate every open PR and converge each head's status to the predicate's verdict; PR events relay into that converge pass. A green gate is not always proof of a review: under `REVIEW_GATE_MODE = "off"` the predicate reads no evidence and posts success attesting that the gate is disabled, and a merge-queue entry posts success unread. Both say so in the status description.

The verdict table and the agent-facing contract: [SKILL.md](SKILL.md). Engine internals: [DEVELOPMENT.md](DEVELOPMENT.md).

## Customise

Every per-repo value is a `REVIEW_GATE_*` key in your `kendex.settings.toml`; environment wins over the file, which wins over the built-in default. The keys most repositories set are the gate's status context, the reviewer contexts and logins to trust, and whether carry-forward is on. The full key table with the security reasoning behind the trust keys: [references/settings.md](references/settings.md). Per-repo decision axes: [references/adoption.md](references/adoption.md) § Keys a repo decides.

One name is not a settings key: `REVIEW_GATE_CHECK_RUN_NAME` is a GitHub repository variable, set under Settings, Secrets and variables, Actions. The relay reads it in a workflow expression before any checkout exists, so the settings file cannot supply it, and `validate.sh` rejects it there. It matters only with the opt-in `check_run` trigger.
