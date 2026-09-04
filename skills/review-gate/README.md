# review-gate

Blocks a merge until the PR head has actually been **reviewed** — by a bot, a human, or whatever mix your repo uses. One predicate answers "is this exact head reviewed?", one workflow posts that answer as a commit status your branch rules require.

A green gate is not always proof of a review: under `REVIEW_GATE_MODE = "off"` the predicate reads no evidence at all and posts success attesting that the gate is disabled, and merge-queue statuses post success unread as "merge-queue entry: post-approval by construction". Both say so in the status description — [references/settings.md](references/settings.md) § `REVIEW_GATE_MODE`.

It does **not** run or inspect your tests. That is branch protection's job.

## What you do

Three things, once.

**1. Vendor the skill and commit it.** `kendex refresh` writes `.agents/skills/review-gate/`. GitHub Actions checks out only tracked files, so a machine-local install — symlinked or untracked — does not exist in CI. If the engine is not in the commit, the gate is not in your CI.

**2. Copy the workflow.** `.agents/skills/review-gate/templates/review-gate-writer.yml` into `.github/workflows/`. Copy it **verbatim**: it carries no per-repo values. The file is yours after the copy — `kendex refresh` never syncs workflow YAML.

**3. Add one CI step that validates the install**, and require the gate context (your `REVIEW_GATE_CONTEXT` value) in the ruleset alongside your test aggregate.

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

`validate.sh` checks **your** repo: the engine is installed and runnable, your committed `REVIEW_GATE_*` values are legal, your carry-forward exclusions still match something in your tree, and your adopted workflow still meets the template's contract. One verdict line per check; exit 0 all clear, 1 findings, 2 could not run. It never re-runs the engine's own tests — those run in the kendex repo, on every change to the engine.

Wiring, rulesets, merge-queue settings, and what an adoption PR deletes: [references/adoption.md](references/adoption.md).

## Before you adopt it

Your repo must satisfy **one** of these, or untested code can reach main and this engine will not stop it:

- **a merge queue** whose required checks include your test suite (recommended — the suite runs once, on the merged result), or
- **no held-back jobs**: every required check runs on every push.

Held back with no queue, tests record as *skipped*, which GitHub counts as satisfied — a reviewed PR would merge untested.

## What counts as "reviewed"

A review approval at the exact head, a trusted clean-analysis check or status on that head, a trusted bot's comment bound to that head's sha, or an operator override carrying a written reason. A standing changes-requested or any unresolved review thread blocks whatever else is present, and a failed evidence read says so loudly and posts nothing rather than guessing.

Push a new commit and evidence resets — it is bound to the exact head. The one exception is opt-in **carry-forward**: a docs-only or comment-only change, or a `kendex refresh` under the render trees you list, can carry the previous head's review, so fixing a typo after review does not restart the cycle.

## Settings

Every per-repo value is a `REVIEW_GATE_*` key in your own `kendex.settings.toml` (environment wins over the file, which wins over the built-in default). Nothing repo-specific is hard-coded anywhere else. The keys most repos set are the gate's status context, the reviewer contexts and logins to trust, and whether carry-forward is on.

One name is not a settings key: `REVIEW_GATE_CHECK_RUN_NAME` is a **GitHub repository variable**, set under Settings → Secrets and variables → Actions. The relay reads it in a workflow expression, before any checkout exists, so the settings file cannot supply it — and `validate.sh` rejects it there, where it would resolve to nothing. It matters only with the opt-in `check_run` trigger ([references/adoption.md](references/adoption.md)).

Full key table and the security reasoning behind the trust keys: [references/settings.md](references/settings.md). Per-repo decision axes: [references/adoption.md](references/adoption.md).

Engine internals, file map, and maintenance: [DEVELOPMENT.md](DEVELOPMENT.md).
