# Two advisory scores, never averaged

Read before changing a safety or quality rule, or anything that prints a score.

## The approach

Every item is scored twice over its own bytes: safety answers "is this dangerous", quality answers "is this well made". `quality::AuditResult` in `crates/core/src/quality/` is the one shape every scored surface embeds. Both scores are advisory everywhere: install, update and apply proceed regardless, and severity is named in words.

## Why

A catalog is someone else's repository, so a person deserves to see what a package would run before it runs. Two numbers stay honest where one average hides a critical finding behind good formatting; an advisory score keeps kendex from refusing what the person already decided to install, while a mention that is not a finding keeps the score from crying wolf at a guard's own refusal text.

## Rules

- Do score an item on its own bytes and nothing else: a repository-root skill's `.git`, `node_modules` and build directories are not its bytes, and a rule whose bytes are not in the input reports itself not applicable.
- Do keep the scores advisory: nothing holds a plan back, and a run that scored something closes on `safety: clean` only when nothing was flagged and every rule read every item.
- Do name severity in words, never colour alone.
- Do report a matched secret as a fingerprint only; the token never appears in a message, log or record.
- Do tell a mention from a finding by rule precision, at `quality::text::shell` and `quality::Quotation`: a switch or a destructive command a file only names, in a comment, a printed string or a test fixture, is a mention that costs the score nothing and prints only under `--verbose`.
- Do answer a rule that fires on a guard's own comment or refusal with precision, never with a per-package allowance; the one allowance, `crates/core/src/quality/allowance.toml`, accepts a finding a kendex package really runs or emits, for kendex's own item alone, by the hash of that line, and no catalog can carry one.
- Never let a score gate anything, never average the two, and never read the harness inside a rule.

## The canonical example

`crates/core/src/quality/rules/` holds one rule per file, each reading typed per-kind input and saying when it cannot read; `crates/core/tests/quality/mentions.rs` plants each quotation shape and watches it stay a mention. A new rule copies a rule file and adds its mention and finding rows there.
