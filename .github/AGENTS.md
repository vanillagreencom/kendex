# .github/

This repository's own continuous integration and the instruction files its review bots read. Nothing here is catalog content.

- `copilot-instructions.md` and `instructions/*.instructions.md` are rendered by the bot-instructions package and each names its generator in a comment: line 1 of `copilot-instructions.md`, and below the `applyTo` frontmatter in an `instructions/*.instructions.md`. Change `[bot-instructions]` in the effective manifest and re-render, never the file.
- Every job runs on a GitHub-hosted runner. This repository is public and declares no self-hosted runner; the two publish workflows read `vars.CI_RUNNER_2V` for the fleet's runner and fall back to `ubuntu-latest`, which is what runs here since the variable is unset.
- `own-catalog.yml` holds this repository to the same check a consumer gets by calling `catalog-check.yml`, which is the reusable workflow consumers call; keep the caller's content out of the reusable one.
- `skill-tests.yml` is the suite runner [`../skills/AGENTS.md`](../skills/AGENTS.md) names; it carries the `tools/` and `hooks/` suites and the Bash 3.2 legs as well.
- `review-gate-writer.yml` is a relay whose body must equal the review-gate package's template, which [`../skills/review-gate/scripts/validate-workflow.sh`](../skills/review-gate/scripts/validate-workflow.sh) checks.
- `release.yml` is [`../docs/RELEASING.md`](../docs/RELEASING.md).
- `publish-aur.yml` and `publish-homebrew.yml` carry `packaging/` to the AUR and the Homebrew tap; triggers, the dry-run dispatch and the secrets each needs are [`../packaging/README.md`](../packaging/README.md) § Publishing. Neither is called by `release.yml`: a release is published as a draft and the recipe bump follows it.
