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
tags: [review]
---

# Code Quality

Repo-specific standards live in each repo's `## Project Instructions` section and add to these rules, winning where they conflict. Before changing code, load the reference for each affected stack under § Language Discipline.

## Core Principle

Do not trade correctness for a smaller change. A failed check limits the evidence; it does not establish a product defect. Name the reachable failure before claiming user impact.

Every rule here serves an outcome: correct results for the user, reliability under change, low cost to carry. Before adding or removing a guard, check, abstraction, test or dependency, state what it protects and for whom, what it costs to carry and what is lost without it, and act on that reading. When two rules pull apart, the one that better serves those outcomes for this change wins, and the deviation is written where the decision lives. A finding that no shipped producer, supported external caller or untrusted input reaches, or that only new code written to bypass the guard reaches, is a note on the model, not a defect to fix.

## Correctness

- Fix the cause in its existing owner. When the correct fix exceeds the scope, report that conflict instead of adding a workaround.
- A defect has a class: the rule the code broke, not the line that broke it. Name the class and fix it once in its owner, so code that goes through the owner cannot repeat it, and never widen that fix to a route § Core Principle calls unreached. An instance that recurs after the fix is a design finding, not a bug to patch: restate what the fix serves and who it is against before widening it.
- Unreadable evidence is not evidence. A dependency failure, an unreadable input or an unevaluated check never becomes a passing result, a default value or a zero. A required gate refuses with the cause; an advisory check reports unavailable with the cause. A decision over a set of candidates stands only when every candidate was read. An absent or unknown application input is a separate contract choice; state why refusing it is necessary where that choice is made.
- A relation to an external system that code or its tests rely on, such as how a tool builds a row, what an API field means or which identifier is unique, is cited to that system's source, its documentation or a recorded run of it, never modeled from memory. A relation with none of these is not relied on.
- A state with mutually exclusive cases is one tagged value with exhaustive handling. Convert an untouched field only when it has a reachable invalid state.
- A gate or guard that needs an exemption list is wrong at the exempted sites: narrow the rule, or state it at the point where the code cannot judge. Keep an exemption only with its reason beside it.
- An unexpected branch asserts or returns the violated invariant. An error names the failed operation, not a neighbouring dependency, and the value it acted on unless that value is a secret; each diagnostic is emitted in one place. Where a program reads the diagnostic, lead with a stable key and put the human explanation after it.

## Structure

- **One lifetime, one owner.** Resources with a shared lifetime have one owner whose teardown releases them. Resources with independent lifetimes have separate owners, each responsible for acquisition, recovery and release. Phases of one lifetime are private functions, not separate owners.
- Acquire ownership before registering cleanup. A pathname alone grants no right to replace or delete a file, and a saved process number grants no right to signal: hold what the ownership mechanism keeps unique, an exclusively created file or a process handle, or verify identity while the ownership mechanism still prevents reuse.
- A child launch that changes identity, credentials or home directory selects the inherited values it needs, in production and in tests. A transparent launcher passes the caller's environment and states that contract.
- Test access expands no shipped API and adds no fixture command to a product executable; fixtures live in the stack's test boundary. A diagnostic command or output surface that ships names its production consumer at its declaration. A private readback with no production effect is not a defect.

## Over-Engineering

Build only what the current callers need. Add no speculative abstraction, extension point, forwarding wrapper or error path for an impossible state. Add an interface or injection point only when two implementations exist; production plus a test fake counts as two. Justify a new dependency in the commit message. A plan or brief is a route, not a contract: take a discovered path that serves the stated goals better and adds no machinery, and record the change where the plan lives. A planned approach is no reason to keep a worse one; a better path is no reason to widen the goals.

One owner makes each decision: classification, validation, parsing of external input and state detection. Compute it once, in one module, and let callers consume the typed result instead of repeating casts or matches; a classification of upstream text lives in one table, tested on real examples. Before adding a script, background watcher, setting or rule, find and extend the existing owner; if none exists, state that in the commit message. A check that compares a declaration with its implementation checks consistency; it is not a second implementation of the decision, and its expected contract stays independent of the implementation.

A new gate, check or guard names the failure it prevents, a run that failed or a shipped producer that reaches it, and who it is against: ordinary code calling by accident, untrusted input crossing a trust boundary, or a developer bypassing it on purpose, which review holds, not the guard. Weigh its upkeep against that harm; with no failure to name, it is not added. A guard over source code claims only what the platform's own enforcement holds, such as the type system, the compiler or a lint on resolved calls; past that line, review holds the rule. A guard over source that needs a second enumerator, a parser of its own source or a second build to prove itself complete has left its goal: narrow the claim.

Integrate through the system's documented interface: read its current documentation before building on it, and among its documented extension points, an SDK or plugin API, events or RPC, hooks or settings, use the one that holds the need with the least code to carry. Documented text output is an interface. Name the interface used and why. An indirect read of screen text, internal files or undocumented output names the interface it replaces and why that interface cannot serve.

## Prove Your Guards

A must-fail control ([§ Tests](#tests)) proves that an instrument detects the defect it claims to. Run only the rows under proof, by name, through the suite's case filter or a disposable wrapper. Mutate a disposable copy of the source outside the worktree, never the tracked source; keep a compiled control's build output under that copy, set per command and never in the session's environment, and remove the copy when the control is done. Keep the matched text when removing behavior: deleting the code under test only proves the assertion runs. Reject an assertion that also matches a skip note, a fixture that never reaches the guarded bound or claimed workload, and harness code that keeps alive what the implementation should.

- Before changing behavior, name the invariants the change must hold and the probe that would falsify each: an input, a crash point, a reused identity, an unreadable read. Those probes are the candidate test rows, each admitted under § Tests, and one of them is the must-fail control. A falsifying probe a review finds that the change did not name is a missing row; it is a design finding when the same class recurs.
- An automated text edit asserts its match count and that the file changed, or uses an edit tool that refuses a missed match. Resolve or refuse a symlink before replacing a path.
- An inventory or collection-driven check discovers its members from the artifact under test, not from a second list, proves discovery completed and enforces a coverage floor that catches a broken extractor; failed or partial discovery never reports a valid empty set. Under-inclusion needs a required member and over-inclusion a forbidden member; state which direction stays unproved.
- Verify a benchmark's workload before timing it, and bound or reset retained state outside the timed operation. A loop-cost estimate is not a latency percentile; a percentile needs a distribution of the events the claim names.
- Match the evidence to the claim. A source check proves source shape, not runtime behavior or rendered output; a scan of one directory establishes nothing about unscanned files; a copied model proves its own behavior. Prefer an instrument that visibly rejects a planted counterexample.
- Exercise the shared production operation where a small existing boundary permits it; otherwise label the result a design demonstration or narrow the claim. Build no production abstraction to rescue a model's claim.

## Tests

- A test is kept for the protection it gives, judged against its cost: its run on every CI pass and its upkeep. No test is admitted or required by its name or label. Delete a row that re-tests a rule another layer's test holds, duplicates a sibling row, pins the test harness's own configuration or tests a dependency's own behavior; the consumer tests its use of the dependency.
- A must-fail control proves a new or changed instrument once, in its first commit, and a bug fix ships the test that failed before the fix. The control is not owed per surface, per rule or per row. A control that runs from input, a fixture or an uncompiled source copy stays in the suite; one that needs a compiled-source edit is shown once and recorded in the commit message, and its absence from the suite is no omission. [§ Prove Your Guards](#prove-your-guards) holds the mechanics. When no production edit can redden a test, state why and what it establishes.
- A port keeps the original's answers on the inputs that matter: its fixtures, its incidents and the edges you name, recorded by running the original once. Keep a generated differential against the executing original only for an input domain too wide to enumerate, and remove it with the original.
- A row asserts the guarantee, not the mechanism that provides it, with expected values independent of the implementation and the result specific to its guard: a neighbouring gate's output, a helper that produces both actual and expected values, or a truthiness check establishes nothing.
- No test asserts human-readable wording in messages, docs, help text or comments; assert typed categories, error kinds or structured fields. The exceptions are output another program parses and text the product delivers as its result: test it and name that consumer or contract.
- No test pins a fixed count of data that grows, such as a dictionary's size, a table's row count or a catalog's member total. Assert the members the contract names, or the floor the contract fixes.
- Put variations of one input contract in one visible table and run the same assertions for each row, covering empty input where the contract permits it. Shared fixtures define a neutral world; keep a planted defect private to its case.
- A surface is a coherent contract or state machine; the stack reference places its tests. Name tests for their contract and split files at contract boundaries, never on size alone. Place tests beside code only where the runtime neither loads nor snapshots them; otherwise use a separate test tree. When modules merge or an interface moves, tests at the new interface replace the old tests of the parts in the same change.
- Where checks are selected by what changed, select them through the one existing suite entry point, from direct and indirect inputs: source, dependencies, fixtures, generated inputs, configuration and build settings. Add no parallel selector, cache, runner, workflow or hand-kept dependency table. Missing or unreadable selection evidence, a test whose inputs cannot be identified, and, with no build graph, a change to the entry point, the assertion library or a shared fixture each run every check in the requested area. A full or release run runs every test. An aggregate entry point runs every member and, on any failure, exits non-zero naming each failed member. Review validation time periodically, never as a per-change limit or merge gate: optimize demonstrated waste while keeping protection against real failures, and narrow no inputs and split no suite to meet a time target.
- Inject time for clock-dependent logic. Prove concurrency order and producer progress with barriers or acknowledgements; a sleep with a reason proves neither. Bound potentially blocking code with a parent-process deadline, since an executor timeout cannot interrupt code that never yields. Real elapsed time belongs to timer-wiring or performance tests, with their limited claim stated.
- Pin a fixture's bytes against checkout conversion: under git, `text eol=lf` for text a test parses or compares byte for byte, `binary` for an image or archive, `-text` where CRLF bytes are the input under test. A parser of checked-out text normalizes CRLF or refuses it by name.
- Test process-id parsing and mapping as pure functions with synthetic ids. Test liveness only against a process the test started and still holds, never an invented id or a reaped child's id.
- A delete or replace of a file another process may hold open accepts only success or the platform's held-file error, such as a Windows sharing violation, asserts the guarantee of the branch it took and fails on any other error. Reap owned processes before removing their scratch root.

## Language Discipline

Load only the references for the code being changed:

- Rust, Cargo or Rust benchmarks: [references/rust.md](references/rust.md).
- Bash or shell suites: [references/bash.md](references/bash.md).
- TypeScript or JavaScript: [references/typescript.md](references/typescript.md).
- A view, layout, styling or UI copy, in any stack: [references/ui.md](references/ui.md).

## Comments and Prose

A comment states why, or a constraint the code cannot show: no history, review notes, code restatements or change logs. Header help a script prints is CLI documentation, not narration. Delete a comment that adds nothing, and keep a claim within what the adjacent code establishes.

Markdown follows [docs-writing](../docs-writing/SKILL.md). Commit bodies explain intent, not the diff.

## Cleanup

Remove unused code rather than leaving renamed variables, commented blocks, removal markers or re-exports without callers; a supported external API is a caller. Follow the repository's declared compatibility policy for removals; absent such a policy, remove the dead path and document a breaking change instead of inventing a compatibility layer. A compatibility probe or shim states the minimum upstream version it serves and the condition that removes it; one with no exit is a workaround under § Correctness.
