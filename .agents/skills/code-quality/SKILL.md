---
name: code-quality
description: "Load before writing or modifying code."
summary: "Code-authoring standards for dev agents: correctness over convenience, no fail-open branches, comment rules, over-engineering limits, prove-your-guards."
license: MIT
user-invocable: true
metadata:
  author: vanillagreen
  source: kendex
  repository: "https://github.com/vanillagreencom/kendex"
  bugs: "https://github.com/vanillagreencom/kendex/issues"
  version: "1.0.0"
tags: [review]
---

<!-- kendex:project-instructions:start -->
## Project Instructions

Problems with a kendex-owned skill go through `kendex report`; check ownership in the file first.
<!-- kendex:project-instructions:end -->

# Code Quality

Repo-specific standards live in each repo's `## Project Instructions` section and add to these rules.

## Core Principle

A loud failure beats a silent wrong answer. Handle every error, check invariants, and never continue in a state the code does not understand.

## Correctness

- No workarounds or quick hacks. If the correct fix is larger than expected, say so.
- **Never fail open.** A dependency failure (command, file, network, parse) must not leave the caller in a passing or default state: no validator degrading to "no findings", no probe failure read as "not applicable", no unchecked `$(mktemp)`.
- A branch that "shouldn't happen" is never an empty or silently-ignored `else`: assert it, return an explicit internal error, or mark it unreachable — with a message naming the violated invariant. Use plain conditionals only when both branches are expected paths.
- An error path must name the actual cause, not a neighbouring dependency.
- Handle edge cases: empty input, boundary values, junk prefixes/suffixes, interrupted-then-retried flows.

## Prove Your Guards

A new or modified check, guard, assertion, or test ships with a must-fail control: plant the defect it catches (a red-first run or a temporary mutation) and see it go red before its green counts. A guard that pattern-matches source text also gets controls for shapes that satisfy the match without the property: comments, string and template-literal interiors, nested occurrences, alternate quoting, a braceless statement, a dead branch, a discarded result, and a textually earlier but unrelated conditional. The control that counts keeps the matched text and removes the behavior; one that deletes the code under test only proves the assertion runs. Reject assertions loose enough to match a skip note, fixtures that never reach the guarded bound, and harness code that keeps alive what the implementation should.

- **A scripted text substitution asserts its match, or it is not an edit.** Assert the pattern's occurrence count and that the file changed, or use an edit tool that errors on no match. Neither assertion holds on a symlink, which `sed -i` replaces with a new file while its target stands: resolve the path first, or refuse a symlink.
- **A floor alone is not a control.** Derive the expected set from the artifact under test (the flag's own regex, the function's own body), never from a second list in a test file. Floor it, with a message naming the extractor as broken rather than the subject as sparse. Under-inclusion needs the floor plus a required member; over-inclusion needs a forbidden member. State which direction stays open.

### Instruments you did not write

- **A check narrower than the claim can only confirm it, never establish it.** Match the instrument's reach to the assertion's reach before running it, and prefer one that fails visibly on a planted counterexample. A grep over one directory supports no claim about the tree.
- **Behaviour measured at an interactive prompt is not what scripts get.** `type <cmd>` names the shadow, which differs per shell. Resolve the command in the script's own shell and PATH, and name the shell and implementation it resolves to.
- **A guard's failure message is an instrument.** It is what an author acts on. Unescaped backticks inside a double-quoted diagnostic execute their contents, so the intended text is altered or gone while the surrounding command still succeeds.

## Language Discipline

- **Rust**: make illegal states unrepresentable; exhaustive matches (no `_ =>` over enums you own); enums over strings/sentinels/booleans-with-meaning. A test that hands a temporary path to code that may resolve symlinks binds its canonical root at creation and passes that binding, never the raw path; platform-only test APIs carry a `cfg` and, when the property is portable, a portable twin.
- **Bash**: `set -euo pipefail` in every new script; check the result of every effectful substitution; `--` before path arguments sourced from configuration, argv, or the environment (not paths the script built itself, e.g. `mktemp -d`); no `[A-Za-z]`-class assumptions under arbitrary locales.
- **TypeScript/JS**: distinguish missing from present-but-falsy (`""`, `0`) at every guard; no `any` at module boundaries.

## Comments and Prose

Do:

- Document the constraint or invariant the code cannot show, not what the line does.
- Document public functions, structs, enums, and variants.

Don't:

- Comments that repeat the code.
- Temporal markers ("added", "new", "existing code", "Phase 1") or revision narration.
- References to AI conversations, review rounds, or issue archaeology.
- Claims broader than what the adjacent code or assertion actually enforces.
- A numeral counting things outside the sentence. State the property and the command that enumerates it. A numeral bound to something adjacent — a list in the same paragraph, a constant a check compares against, one a ratchet owns — stays.

Markdown placement rules:

- Never state a rule twice within or across package files; make later statements point to the first.
- Never put mechanics, rationale, or history in `SKILL.md` or agent files; keep rules and commands there.
- Never put internal explanations, rationale, invariant details, or test mechanics outside `DEVELOPMENT.md`; keep actionable rules and commands loaded.
- Never put anything but purpose, high-level behavior, features, user settings, and installation in a package `README.md`.
- Never keep content in `references/*.md` unless a named workflow loads it on demand.

Write the shortest unambiguous rule and delete sentences nothing acts on. Use plain words over jargon. Commit bodies explain intent, never narrate the diff.

## Over-Engineering

Build only what was asked. No speculative abstractions, no error handling for impossible scenarios, no generalization before a third caller exists. Delete wrappers that only forward. A new dependency needs a one-line justification in its commit message.

One judge per question: never re-implement a decision (classify, validate, parse, detect state) another component or language already owns — delegate. A second spelling is a defect even when both copies agree. Package behavior lives in the package's shipped scripts; a host binary only locates, execs, and surfaces results.

## Cleanup

Remove unused code completely: no backwards-compatibility shims, no renamed `_vars`, no commented-out blocks, no `// removed` markers, no re-exports without callers. Breaking removals get a CHANGELOG note, not a compat layer.
