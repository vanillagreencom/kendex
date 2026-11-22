# Adding a repo

Run when adding a repository to bot-instructions. Before the first pass, read [references/checklist.md § Before the first pass](../references/checklist.md#before-the-first-pass).

**Pass one, the repo-wide TOML.** `[bot-instructions.repo]`, `[bot-instructions.exclusions]`, `[bot-instructions.cadence]`, `[bot-instructions.tone]`, `[bot-instructions.budgets]` and any `[bot-instructions.doctrine.*]` overrides, with every `[bot-instructions.bots]` flag false and no `[[bot-instructions.surface]]` entries.

1. Read the repo's existing hand-written bot files now and plan where their claims go: which become `[[bot-instructions.surface]]` entries, which become `[bot-instructions.doctrine.append]`, which will not fold and stay hand-written.
   - Write the repo-wide tables.
   - Leave the surfaces for the pass that turns on a bot able to read them.
2. Clear any nested `AGENTS.md` carrying a `## Code Review Rules` section.
   - Fold what it holds into `[bot-instructions.doctrine.append]` or a `[[bot-instructions.surface]]` and delete the section, or move the section out of an `AGENTS.md`.
   - `agents-section` refuses every render while one remains.
3. Do not run `adopt` here. With every capability off it can take nothing over, so it reports nothing on exactly the repo this planning is for.
4. Run `render`.
   - It writes nothing and says so, because every flag is off.
   - That is the staging point, not a finished install: the existing bot files are still the repo's own and still what the bots read.

**Pass two, per capability.** Enable `codex` first if this repo wants `copilot` or `coderabbit`, and `qodo` before its two sub-flags.

One capability at a time, finishing each before starting the next so a failure names the bot that caused it:

5. Work that capability's settings section in [references/checklist.md § The settings](../references/checklist.md#the-settings).
6. Do its prerequisite, where it has one.
   - `codex` needs a `## Code Review Rules` heading added to `AGENTS.md` by hand, since the generator never adds it.
   - The generator creates the pointed `code-review.md` itself.
   - `coderabbit` needs CodeRabbit's published schema at `.bot-instructions/coderabbit-schema.json`, which no verb writes; [references/limits.md § CodeRabbit](../references/limits.md#coderabbit) names its URL.
   - `qodo_review_md` needs the portal toggle already on.
7. Set the flag.
   - With the first of `copilot`, `coderabbit`, `macroscope` or `qodo_best_practices`, add the `[[bot-instructions.surface]]` entries planned in step 1.
8. Run `adopt`.
   - It takes over that capability's generated paths, the `AGENTS.md` region the heading opened included.
   - It names every file and region it takes, plus every repo-root or `.github/` markdown file those files point at. That second list is where a repo-wide hand-written reviewer file shows up.
   - Read both lists against the TOML: a claim in one of those files that the TOML does not carry is about to be deleted, or to go on steering reviews from outside the package.
   - Adopting a hand-written region also reports it under `agents-region` and exits 1, because the managed region is one directive line. The marker is written either way, and step 9's render is the migration.
9. Run `render`, then read the diff.
   - Doctrine text appearing for the first time is expected.
   - A repo-specific claim disappearing means it never made it into the TOML.
10. Run `check`. Then repeat from step 5 for the next capability.

## After the checklist

- Open one pull request that touches a file each bot should comment on, and confirm each enabled bot posts.
- A bot that stays silent on a deliberately imperfect diff has a settings problem, not an instructions problem.
- This is the only step that tests [the settings](../references/checklist.md#the-settings) rather than trusting the record of them.
