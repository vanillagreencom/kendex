---
name: code-quality
description: "Load for any coding or development task in any repository: writing, changing, fixing, refactoring, or testing code or scripts in any language."
summary: "Code-authoring standards: failure semantics, resource ownership, shared decisions, evidence, test contracts, and stack-specific references."
license: MIT
user-invocable: true
dependencies:
  required: [docs-writing]
metadata:
  author: vanillagreen
  source: kendex
  repository: "https://github.com/vanillagreencom/kendex"
  bugs: "https://github.com/vanillagreencom/kendex/issues"
  version: "1.0.0"
tags: [review]
---

# Code Quality

Repo-specific standards live in each repo's `## Project Instructions` section and add to these rules. Before changing code, load the reference for each affected stack under § Language Discipline.

## Core Principle

Do not trade correctness for a smaller change. A failed check limits the evidence; it does not establish a product defect. Name the reachable failure before claiming user impact.

## Correctness

- Fix the cause in its existing owner. If the correct fix exceeds the scope, report that conflict instead of adding a workaround.
- A dependency failure must not become a passing result or a default value. A required gate refuses when it cannot read or evaluate its evidence. An advisory check reports unavailable with the cause. An absent or unknown application input is a separate contract choice; state why refusing it is necessary where that choice is made.
- When changing a state with mutually exclusive cases, use one tagged value with exhaustive handling. Do not start a refactor of untouched fields without a reachable invalid state.
- A gate, guard or scanner adds no enumerated exemption list. State the rule at the point where the code cannot judge.
- An unexpected branch asserts or returns the violated invariant. An error names the failed operation, not a neighbouring dependency.
- An automated tool's refusal or notice starts with a stable key and the value acted on. Put the human explanation on later lines. Keep each diagnostic in one place.

## Structure

- **One lifetime, one owner.** Resources with a shared lifetime have one owner whose teardown releases them. Resources with independent lifetimes have separate owners, each responsible for acquisition, recovery and release. Phases of one lifetime are private functions, not separate owners.
- Acquire ownership before registering cleanup. A pathname alone grants no right to replace or delete a file; acquire a scratch file by exclusive creation. A saved process number grants no right to signal a later process with that number. Keep a process handle or verify identity while the ownership mechanism prevents reuse.
- A child launch defines its environment explicitly, in production and in tests. The launch owner selects inherited values it needs instead of passing the caller's whole environment.
- Test access must not expand the shipped API or add fixture commands to a product executable. Keep fixtures in the stack's test boundary. A private readback alone is not a defect. Keep operational diagnostics with a named production consumer documented at their declaration.
- Compatibility probing states the minimum upstream version it serves and the version that removes it. An undated shim is a workaround under § Correctness.
- Narrow a wire-format union in one guard module. Call sites consume that result instead of repeating casts.
- Classify upstream failures from message text in one pattern table, with real examples under test.

## Over-Engineering

Build only what the current callers need. Add no speculative abstraction, extension point, forwarding wrapper or error path for an impossible state. Justify a new dependency in the commit message.

One owner makes each decision: classification, validation, parsing and state detection. Compute it once and let callers consume the result. Before adding a script, watch, file, setting or rule, find and extend the existing owner. If none exists, state that in the commit message. A check that compares a declaration with its implementation checks consistency; it is not a second implementation of the decision. Keep its expected contract independent of the implementation.

Integrate through the system's documented interface. Read its current documentation before building on it. Check its extension points in order: SDK, extension or plugin API, events or RPC, hooks, settings. Name the interface used and why. An indirect read of screen text, internal files or undocumented output must name the interface it replaces and why that interface cannot serve. The architecture reviewer and review doctrine treat a missing explanation as a blocker. Documented text output is an interface.

## Prove Your Guards

A new or modified production guard ships with one must-fail control per independent rule. Plant a defect that reaches that rule and observe the guard reject it. Rows for the same rule share a control; a defect for one rule cannot prove another. Mutate a disposable copy, never the tracked source. Keep the matched text when removing behavior: deleting the code under test only proves the assertion runs. Reject assertions that also match skip notes, fixtures that never reach the guarded bound or claimed workload, and harness code that keeps alive what the implementation should.

- An automated text edit asserts its match count and that the file changed, or uses an edit tool that refuses no match. Resolve or refuse symlinks before replacing a path.
- An inventory check discovers members from the artifact under test, not a second list. A coverage floor detects a broken extractor. Under-inclusion also needs a required member; over-inclusion needs a forbidden member. State which direction remains unproved. Behavior tests keep expected values independent of the implementation.
- Verify a benchmark's workload before timing. Bound or reset retained state outside the timed operation. A loop-cost estimate is not a latency percentile; a percentile requires a distribution of the events the claim names.

### Instruments you did not write

- Match the evidence to the claim: source consistency, construction, executed behavior, model, rendered output or performance. A source check can prove source shape. It cannot prove runtime behavior or rendered output.
- A copied model proves its own behavior. Exercise shared production operations when a small existing boundary permits it; otherwise label it a design demonstration or narrow the claim. Do not build a production abstraction solely to rescue a model's claim.
- Match the instrument's reach to the claim before running it. Prefer an instrument that visibly rejects a planted counterexample. A scan of one directory establishes nothing about unscanned files.

## Tests

- A surface is a coherent contract or state machine. The stack reference defines its test placement. Each changed surface with a test takes at least one must-fail control that turns that test red. The control belongs to the instrument, not to each row; production guards follow § Prove Your Guards. A control using input, a fixture or an uncompiled source copy stays in the test and runs with it. A control requiring a compiled-source edit is shown once and recorded in the commit message; its absence from the current test file proves no omission.
- If no production edit can redden the test, state why and what the test establishes. Assert the guarantee, not the mechanism used to provide it.
- No test asserts human-readable wording in messages, docs, help text or comments. Assert typed categories, error kinds or structured fields. The only exception is output another program parses: test its machine-read line or format and name that consumer. Delete pins on the test harness's own configuration.
- Each row asserts the result specific to its guard. A neighbouring gate's output, a helper used to produce both actual and expected values, or a truthiness check cannot establish that result.
- A dependency's own suite tests its behavior. The consumer tests its use of the dependency.
- Select local and CI checks through the same existing suite entry point from direct and indirect inputs: source, dependencies, fixtures, generated inputs, configuration and build settings. That entry point may map build metadata to checks; add no parallel selector, cache, runner, workflow or hand-kept dependency table. Missing or unreadable selection evidence runs every check in the requested area.
- With no build graph, an entry point, assertion library or shared-fixture change runs the whole suite. Otherwise select by the test's own path, its named surface and input notes in its file. This applies only when those identify every repository file the test or surface consumes. A test without that evidence runs on every change. No separate list or mandatory-note check is added. Full and release runs run every test.
- Read selected-run wall time from the existing test output and review recurring validation delays periodically, not as per-change limits or merge gates. Optimize demonstrated waste or feedback delays while preserving protection against real failures; do not narrow dependency inputs or split suites merely to meet a time target.
- Put variations of one input contract in one visible table and run the same assertions for each row.
- Inject time for clock-dependent logic. Use barriers or acknowledgements to prove concurrency order and producer progress. A sleep with a reason proves neither. Bound potentially blocking code with a parent-process deadline; an executor timeout cannot interrupt code that never yields. Real elapsed time is for timer-wiring or performance tests, with their limited claim stated.
- A collection-driven check proves discovery completed and enforces its coverage floor. Failed or partial discovery never reports a valid empty set. Cover empty application input when its contract permits it.
- Shared fixtures define a neutral world. Keep a planted defect private to its case.
- Place tests beside code only where the runtime neither loads nor snapshots them. Otherwise use a separate test tree. Name tests for their contract. Split large files at contract boundaries; size alone does not establish that a boundary exists.

## Language Discipline

Load only the references for the code being changed:

- Rust, Cargo or Rust benchmarks: [references/rust.md](references/rust.md).
- Bash or shell suites: [references/bash.md](references/bash.md).
- TypeScript or JavaScript: [references/typescript.md](references/typescript.md).

## Comments and Prose

A comment states why, or a constraint the code cannot show. No history, review notes, code restatements or change logs. Delete a comment that adds nothing. Keep claims within what the adjacent code establishes. The optional audit is [commit-guards CHECKS.md § comments](../commit-guards/CHECKS.md#comments).

Markdown follows [docs-writing](../docs-writing/SKILL.md). Commit bodies explain intent, not the diff.

## Cleanup

Remove unused code rather than leaving renamed variables, commented blocks, removal markers or re-exports without callers. A supported external API is a caller. Follow the repository's declared compatibility policy for removals; absent such a policy, remove the dead path and document a breaking change instead of inventing a compatibility layer.
