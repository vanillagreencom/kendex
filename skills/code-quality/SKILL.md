---
name: code-quality
description: "Generic code-authoring standards for dev agents: correctness over convenience, no fail-open branches, comment do's/don'ts, over-engineering and cleanup rules, prove-your-guards. Load before writing or modifying code. Per-repo specifics arrive via the project-instructions seam."
license: MIT
user-invocable: true
metadata:
  author: vanillagreen
  source: vstack
  repository: "https://github.com/vanillagreencom/vstack"
  bugs: "https://github.com/vanillagreencom/vstack/issues"
  version: "1.0.0"
---

# Code Quality

> **Problem with this skill?** Run `vstack report` — it files to the owning repo automatically. Do not hand-file.

Generic authoring rules, one copy upstream. Repo-specific standards (safety-critical invariants, domain rules, CI-pinned policies) ride each repo's `## Project Instructions` section below and override nothing here — they add to it.

## Core Principle

A loud failure beats a silent wrong answer. Handle every error, check invariants, and never continue in a state the code does not understand.

## Correctness

- No workarounds or quick hacks. If the correct fix is larger than expected, say so — do not ship the shortcut.
- **Never fail open.** A dependency failure (command, file, network, parse) must not leave the caller in a passing or default state — e.g. a validator that degrades to "no findings", a probe failure read as "not applicable", an unchecked `$(mktemp)` running on with an empty variable.
- A branch that "shouldn't happen" is never an empty or silently-ignored `else`: assert it, return an explicit internal error, or mark it unreachable — with a message naming the violated invariant. Use plain conditionals only when both branches are expected paths.
- When an error path fires, it must blame the actual cause. A loud failure naming the wrong dependency misdirects the operator as badly as silence.
- Edge cases are not optional: on a long enough timeline every possible input arrives. Empty input, boundary values, junk prefixes/suffixes, and interrupted-then-retried flows are the standard escapes.

## Prove Your Guards

A new or modified check, guard, assertion, or test ships with a must-fail control: plant the defect it exists to catch (a red-first run or a temporary mutation) and see it go red before its green counts as evidence. A guard that pattern-matches source text also gets controls for the shapes that satisfy the match without the property — comments, string and template-literal interiors, nested occurrences, alternate quoting, a braceless statement. Assertions loose enough to match a skip note, fixtures that never reach the guarded bound, and harness code that keeps alive what the implementation should, ship real bugs behind green suites.

## Language Discipline

- **Rust**: make illegal states unrepresentable; exhaustive matches (no `_ =>` over enums you own); enums over strings/sentinels/booleans-with-meaning.
- **Bash**: `set -euo pipefail` in every new script; check the result of every effectful substitution; `--` before variable path arguments whose value can come from configuration, argv, or the environment — not before a path the script built itself (`mktemp -d`, its own fixture directory); no `[A-Za-z]`-class assumptions under arbitrary locales.
- **TypeScript/JS**: distinguish missing from present-but-falsy (`""`, `0`) at every guard; no `any` at module boundaries.

## Comments and Prose

Do:

- Document WHY — the constraint or invariant the code cannot show — not what the line does.
- Document public functions, structs, enums, and variants.

Don't:

- Comments that repeat the code.
- Temporal markers ("added", "new", "existing code", "Phase 1") or revision narration — history lives in git.
- References to AI conversations, review rounds, or issue archaeology.
- Claims broader than what the adjacent code or assertion actually enforces.

The same rules govern docs, READMEs, and skill/agent files: state the rule or behavior, never its provenance, justification essay, or the analysis that produced it.

## Over-Engineering

Build only what was asked. No speculative abstractions, no error handling for impossible scenarios, no generalization before a third caller exists — three similar lines beat a premature abstraction. A wrapper that only forwards is a deletion candidate, not a pattern.

## Cleanup

Remove unused code completely: no backwards-compatibility shims, no renamed `_vars`, no commented-out blocks, no `// removed` markers, no re-exports for callers that no longer exist. Breaking removals get a CHANGELOG note, not a compat layer.
