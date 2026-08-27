---
name: code-quality
description: "Generic code-authoring standards for dev agents: correctness over convenience, no fail-open branches, comment rules, over-engineering limits, prove-your-guards. Load before writing or modifying code."
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

# Code Quality

> **Problem with this skill?** Run `kendex report` — it files to the owning repo automatically. Do not hand-file.

Repo-specific standards live in each repo's `## Project Instructions` section below and add to these rules.

## Core Principle

A loud failure beats a silent wrong answer. Handle every error, check invariants, and never continue in a state the code does not understand.

## Correctness

- No workarounds or quick hacks. If the correct fix is larger than expected, say so.
- **Never fail open.** A dependency failure (command, file, network, parse) must not leave the caller in a passing or default state: no validator degrading to "no findings", no probe failure read as "not applicable", no unchecked `$(mktemp)`.
- A branch that "shouldn't happen" is never an empty or silently-ignored `else`: assert it, return an explicit internal error, or mark it unreachable — with a message naming the violated invariant. Use plain conditionals only when both branches are expected paths.
- An error path must name the actual cause, not a neighbouring dependency.
- Handle edge cases: empty input, boundary values, junk prefixes/suffixes, interrupted-then-retried flows.

## Prove Your Guards

A new or modified check, guard, assertion, or test ships with a must-fail control: plant the defect it catches (a red-first run or a temporary mutation) and see it go red before its green counts. A guard that pattern-matches source text also gets controls for shapes that satisfy the match without the property: comments, string and template-literal interiors, nested occurrences, alternate quoting, a braceless statement. Reject assertions loose enough to match a skip note, fixtures that never reach the guarded bound, and harness code that keeps alive what the implementation should.

## Language Discipline

- **Rust**: make illegal states unrepresentable; exhaustive matches (no `_ =>` over enums you own); enums over strings/sentinels/booleans-with-meaning.
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

Same rules for docs, READMEs, and skill/agent files: state the rule or behavior, never its provenance or justification. Their reader is an agent — write the shortest unambiguous rule and delete sentences nothing acts on.

## Over-Engineering

Build only what was asked. No speculative abstractions, no error handling for impossible scenarios, no generalization before a third caller exists. Delete wrappers that only forward.

One judge per question: never re-implement a decision (classify, validate, parse, detect state) another component or language already owns — delegate. A second spelling is a defect even when both copies agree. Package behavior lives in the package's shipped scripts; a host binary only locates, execs, and surfaces results.

## Cleanup

Remove unused code completely: no backwards-compatibility shims, no renamed `_vars`, no commented-out blocks, no `// removed` markers, no re-exports without callers. Breaking removals get a CHANGELOG note, not a compat layer.
