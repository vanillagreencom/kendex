# bot-instructions

Standardized instruction files for the GitHub review bots, generated from one
doctrine source plus a per-repo TOML rather than hand-written five times.

`scripts/bot-instructions` is the generator. It needs Python 3.11 or newer for
`tomllib` and nothing else.

Five bots read four incompatible surfaces. Codex reads `AGENTS.md` § Code
Review Rules and nothing else. Copilot code review reads
`.github/copilot-instructions.md`, path-scoped
`.github/instructions/*.instructions.md`, and `AGENTS.md`. CodeRabbit reads a
single `.coderabbit.yaml` that outranks its dashboard, plus `AGENTS.md` where
that file points it. Qodo reads `.pr_agent.toml` and `best_practices.md`.
Macroscope reads a `.macroscope/` tree.

Three of the five reach that `AGENTS.md` section, which is why it is the
doctrine root and why a TOML turning `codex` off with `copilot` or `coderabbit`
on is a schema error rather than a supported configuration. Written by hand,
one repo's review doctrine drifts from the next repo's, and an exclusion list
falls behind the tree it excludes without anything saying so.

```
doctrine (SKILL.md § Doctrine)  +  bot-instructions.toml
                    │
                    ▼ render
   AGENTS.md § Code Review Rules      .coderabbit.yaml
   .github/copilot-instructions.md    .pr_agent.toml + best_practices.md
   .github/instructions/*.md          .macroscope/
```

A `[[surface]]` in the TOML is written once and reaches Copilot, CodeRabbit and
Macroscope in each one's own dialect. An exclusion is written once and reaches
every bot that has an exclusion mechanism. Doctrine is written once, in this
package, for every repo, and one table in `schemas/renders.md` says which block
lands in which file, in what order, and why each omission is deliberate.

## Three verbs

`render` builds and validates in a scratch tree, then writes — and the checks
that judge repository state rather than emitted bytes read the repo before the
write, since a scratch tree is the one place they cannot fail. `check`
re-renders and reports any file that differs, plus anything carrying the
package's marker that the TOML no longer produces. `adopt` is the one-time verb
for a repo whose bot files were written by hand: `render` refuses to replace a
file that does not carry this package's marker, and `adopt` takes one over while
printing what it replaced.

Generated files are outputs. A hand edit is erased at the next render, and
`check` reds before that happens. There is no overwrite prompt and no merge of
hand edits back into the source.

## Why validators

Every bot in this set fails silently. An over-limit `.coderabbit.yaml` is
discarded whole and the review runs with defaults, saying nothing. A
`path_filters` entry missing its `!` turns the list into an allowlist and
un-reviews the repo. An `excludeAgent` typo loads reviewer doctrine into the
working agent. In each case the pull request looks reviewed.

Each validator names the silent failure it catches, and each rejection clause it
names ships a fixture carrying exactly that defect, asserted red on the
validator's own message — plus one canonical render asserted green, so a
validator that rejects everything fails the suite. What no validator can reach, because
it lives in a vendor's web UI, is the settings checklist instead.

## What this does not solve

Copilot, CodeRabbit and Macroscope read their instruction files from the pull
request's head, so a pull request can weaken the review it is about to get and
re-render until every check passes. No repo file closes that. SKILL.md § A pull
request changing its own review states what a repo whose merge gate consumes
bot output has to do about it.

## Reading order

| File | What it settles |
|------|-----------------|
| [SKILL.md](SKILL.md) | The doctrine text, which bot reads what, and the trust boundary |
| [schemas/repo-toml.md](schemas/repo-toml.md) | Every key of `bot-instructions.toml`, and the glob dialect |
| [schemas/renders.md](schemas/renders.md) | Per-surface render rules, ordering and escaping |
| [schemas/validators.md](schemas/validators.md) | Each validator's silent failure and what it rejects |
| [references/limits.md](references/limits.md) | Vendor caps, enums and read semantics, each with its source |
| [references/checklist.md](references/checklist.md) | How to add a repo, and the per-repo settings no file can configure |

## Adding a repo

The sequence is [references/checklist.md](references/checklist.md) § Adding a
repo, and it is not a preference: `toml-schema`'s cross-flag clauses, `adopt`'s
own rule, and `agents-section`'s ungated nested-`AGENTS.md` clause fix the
order, so that file derives it from them rather than asserting it. Two passes —
a repo-wide TOML with every bot off, then one pass per capability that enables
it, adopts its paths and renders them.

What a reader coming here for the shape needs: nothing that depends on a flag
is written before the flag, and a bot whose install or enablement step is
skipped reviews nothing while every file in the repo looks correct.
