# Adding a repo

Run when adding a repository to bot-instructions. Before the first pass, read [references/checklist.md § Before the first pass](../references/checklist.md#before-the-first-pass).

Two passes. The order is not a preference — three rules fix it, and a sequence that ignores them writes a TOML that does not validate or a render that stops.

**What those rules require, since everything below follows from them.**

*From `toml-schema`'s cross-flag clauses.* A `[[bot-instructions.surface]]` set needs at least one of `copilot`, `coderabbit`, `macroscope` or `qodo_best_practices` on, because those four are every route surface text has. `copilot` or `coderabbit` needs `codex`, because that flag writes the pointed `code-review.md` both of them read. `qodo_best_practices` and `qodo_review_md` need `qodo`.

*From `adopt`'s own rule.* It takes a file or region over only for a capability that is on.

Those two give **capability-dependent content lands with its capability**, and nothing that depends on a flag is written before the flag.

*From `agents-section`'s nested-`AGENTS.md` clause.* It rejects a nested `AGENTS.md` carrying a `## Code Review Rules` section, it is the one clause no flag gates, and it runs against the repo before every write. So it is invisible to the flag reasoning above and constrains the sequence anyway: a repo holding such a section cannot complete **any** render, including a pass-one render with every flag off. Clearing it is therefore a pass-one prerequisite rather than part of the `codex` capability's own pass.

**Pass one, the repo-wide TOML.** `[bot-instructions.repo]`, `[bot-instructions.exclusions]`, `[bot-instructions.cadence]`, `[bot-instructions.tone]`, `[bot-instructions.budgets]` and any `[bot-instructions.doctrine.*]` overrides, with every `[bot-instructions.bots]` flag false and no `[[bot-instructions.surface]]` entries.

1. Read the repo's existing hand-written bot files now and plan where their claims go: which become `[[bot-instructions.surface]]` entries, which become `[bot-instructions.doctrine.append]`, which will not fold and stay hand-written. Write the repo-wide tables; leave the surfaces for the pass that turns on a bot able to read them.
2. Clear any nested `AGENTS.md` carrying a `## Code Review Rules` section. Fold what it holds into `[bot-instructions.doctrine.append]` or a `[[bot-instructions.surface]]` and delete the section, or move the section out of an `AGENTS.md`. The generator writes only the root one, and `agents-section` rejects a nested one unconditionally, so this is what a pass-one render stops on if it is skipped. Its content is not lost: it lands in the TOML written in step 1.
3. Do not run `adopt` here. Nothing can be adopted for a capability that is off, so it would report nothing on exactly the repo this planning is for.
4. Run `render`. With step 2 done it writes nothing and says so, because every flag is off; that no-op is the staging point, not a finished install, and the existing bot files are still the repo's own and still what the bots read. With step 2 skipped it does not write nothing — it stops on the nested section before the write and names the file, which is the clause doing its job rather than a failure of the sequence.

**Pass two, per capability.** Enable `codex` first if this repo wants `copilot` or `coderabbit`, and `qodo` before its two sub-flags. Then, one capability at a time, finishing each before starting the next so a failure names the bot that caused it:

5. Work that capability's settings section in [references/checklist.md § The settings](../references/checklist.md#the-settings).
6. Do its prerequisite, where it has one. `codex` needs a `## Code Review Rules` heading added to `AGENTS.md` by hand, since the generator never adds it; the pointed `code-review.md` needs no prerequisite, because the generator creates that file. `coderabbit` needs CodeRabbit's published schema at `.bot-instructions/coderabbit-schema.json`; no verb writes it and `coderabbit-schema` fails without it, deliberately, because a validator that skipped on a missing schema would be silent for the life of the repo. `qodo_review_md` needs the portal toggle already on.
7. Set the flag. With the first of `copilot`, `coderabbit`, `macroscope` or `qodo_best_practices`, add the `[[bot-instructions.surface]]` entries planned in step 1 — they are legal from that moment and were not before.
8. Run `adopt`. It can now take over that capability's generated paths, the `AGENTS.md` region the heading opened included, and it names every file and region it takes plus every repo-root or `.github/` markdown file those files point at. That second list is where a repo-wide hand-written reviewer file shows up. Read both against the TOML: a claim in one of those files that the TOML does not carry is about to be deleted, or to go on steering reviews from outside the package. Adopting a hand-written region also reports it under `agents-region` and exits 1, because the managed region is one directive line; the marker is written either way, and step 9's render is the migration.
9. Run `render`, then read the diff. Doctrine text appearing for the first time is expected; a repo-specific claim disappearing means it never made it into the TOML.
10. Run `check`. Then repeat from step 5 for the next capability.

**Walked end to end, for a repo that arrives with hand-written bot files.** Pass one clears any nested `## Code Review Rules` section into the TOML, then commits a TOML that validates and a render that writes nothing, leaving those files untouched and still authoritative. The first capability's pass sets `codex`, opens the `AGENTS.md` region, adopts it, and renders the section. The next sets `copilot`, adds the surfaces, and adopts `.github/copilot-instructions.md` and the `.instructions.md` names those surfaces produce — a hand-written file in that directory under a name no surface produces is left alone, which is correct and stays the repo's own. Each later capability adopts and renders only its own paths. The install is finished when every capability the repo wants is on, `check` is clean, and the smoke test in § After the checklist has seen each enabled bot comment. A repo that stops after pass one has staged the work, not done it.

## After the checklist

Open one pull request that touches a file each bot should comment on, and confirm each enabled bot posts. A bot that stays silent on a deliberately imperfect diff has a settings problem, not an instructions problem, and no amount of re-rendering fixes it. This is the only step that tests [the settings](../references/checklist.md#the-settings) rather than trusting the record of them.
