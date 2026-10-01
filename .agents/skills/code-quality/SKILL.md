---
name: code-quality
description: "Load for any coding or development task in any repository: writing, changing, fixing, refactoring, or testing code or scripts in any language."
summary: "Code-authoring standards for dev agents: correctness over convenience, no fail-open branches, module structure, over-engineering limits, prove-your-guards, test architecture, comment rules."
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

<!-- kendex:project-instructions:start -->
## Project Instructions

<!-- kendex:shared-instructions:start -->
Problems with a kendex-owned skill go through `kendex report`; check ownership in the file first.
<!-- kendex:shared-instructions:end -->

### React

- A store selector returns a stable reference: never mint an array, object or Set inside one, since a fresh value re-renders forever and blanks the page.
- An effect that positions or measures rendered content takes what is drawn as its trigger, not a list of state names; the exhaustive-dependencies lint checks only what the effect reads.

### Platform rules

Enforce a rule on the platform where it can hold it (GitHub settings and rulesets, a harness's own settings). Keep a hook, script or instruction guard only where it cannot, and state why at the guard.

<!-- kendex:project-instructions:end -->

# Code Quality

Repo-specific standards live in each repo's `## Project Instructions` section and add to these rules.

## Core Principle

A loud failure beats a silent wrong answer. Handle every error, check invariants, and never continue in a state the code does not understand.

## Correctness

- No workarounds or quick hacks. If the correct fix is larger than expected, say so.
- **Never fail open.** A dependency failure (command, file, network, parse) must not leave the caller in a passing or default state: no validator degrading to "no findings", no probe failure read as "not applicable". An absent or unknown input is not a dependency failure: refusing on it disables a working path, which needs its own justification stated where the choice is made.
- Make illegal states unrepresentable: a state with several cases is one tagged value each site matches exhaustively, never independent flags each site conjoins. § Language Discipline holds each language's spelling.
- A gate, guard or scanner change adds no enumerated exemption list; a refusal is one rule at the point the code cannot judge.
- A branch that "shouldn't happen" is never an empty or silently-ignored `else`: assert it, return an explicit internal error, or mark it unreachable, with a message naming the violated invariant. Use plain conditionals only when both branches are expected paths.
- An error path must name the actual cause, not a neighbouring dependency.
- A refusal or notice a script prints starts with a stable first line: a short key and the value acted on (a path, a count, an exit code). The English explanation follows on later lines, and the message text lives in one place per script.
- Handle edge cases: empty input, boundary values, junk prefixes/suffixes, interrupted-then-retried flows.

## Structure

- **One lifetime, one owner.** Resources that share a lifetime (connections, leases, sessions, caches) live in one owner whose teardown releases them all. Adding a resource changes its owner, never the call sites.
- **Independent lifecycles split an owner; phases do not.** A component that holds resources with independent lifecycles gives each resource its own owner, and that owner keeps the resource's acquisition, recovery and release. Acquire, deliver, recover and tear-down phases alone never split an owner; private functions inside it may name them.
- **Members serve the design, not packaging or tests.** An internal symbol re-exported so tests or vendors can reach it is API the next refactor owes compatibility to; generate that entry in the build instead. Setup and readback that only tests use stay out of shipped components, exported or not: put them in fixtures or a disposable runtime copy. An operational diagnostic stays when a named production consumer uses it, documented where its API is declared.
- **Compatibility probing carries a floor.** Runtime detection across upstream versions states the minimum version it serves and the version that removes it. An undated shim is a workaround under § Correctness.
- **Narrowing has one door.** A wire-format union read through repeated casts gets one guard module, and call sites match on the narrowed value. This applies in languages with sum types.
- **Classification is a table.** Detecting an upstream failure kind from its message text is one pattern table with real examples pinned under test, never a regex at each call site.

## Over-Engineering

Build only what was asked. No speculative abstractions, no extension point for a caller that does not exist, no wrapper that only forwards, and no error handling for impossible scenarios. A new dependency needs a one-line justification in its commit message.

One judge per question: never re-implement a decision (classify, validate, parse, detect state) another component or language already owns; delegate. When real consumers would each make the same decision, one shared owner makes it; caller count neither justifies nor removes that owner. A decision re-derived at each use site in one file is the same defect: compute it once and let each site match on the result. A second spelling is a defect even when both copies agree. Before adding a script, watch, file, setting or rule, name the existing mechanism that owns the concern and extend it. Add a new mechanism only when no owner exists; state why in the commit message. Redo a fix that adds a second path beside an owner, or a rule beside another file's rule, as a change to that owner.

Integrate through the system's own interface. Before building on another system (a service, an API, a CLI, an agent harness), read its current documentation and use the interface it provides for the purpose. Check the system's documented extension points in this order: SDK, extension or plugin API, events or RPC, hooks, settings; name the one used and why. Deriving its state indirectly (reading a status line, parsing a file or screen text, scraping a pane, reading its internal files, or re-implementing a feature it already offers) is a last resort: the code names it as the fallback, the interface it stands in for, and why that interface cannot serve. Review holds the indirect-read case: the `reviewer-arch` agent and the `bot-instructions` review doctrine report as a blocking finding an indirect read of another system's state (a scraped screen or pane, a status line, output text the system does not document as an interface, or its internal files) that does not name the interface it stands in for and why that interface cannot serve. Reading a documented interface, text or JSON output included, is not this finding.

## Prove Your Guards

A new or modified production gate or guard ships with one must-fail control per independent rule it enforces: plant one defect that reaches that rule, and the control passes when the guard turns red once. Rows that exercise the same rule share its control; independent rules in one guard each take their own, and a defect planted for one rule never stands in for another. A script's mutant control edits a copy of the script, never the tracked file. A control keeps the matched text and removes the behavior; one that deletes the code under test only proves the assertion runs. Reject assertions loose enough to match a skip note, fixtures that never reach the guarded bound, and harness code that keeps alive what the implementation should.

- **A scripted text substitution asserts its match, or it is not an edit.** Assert the pattern's occurrence count and that the file changed, or use an edit tool that errors on no match. Neither assertion holds on a symlink, which `sed -i` replaces with a new file while its target stands: resolve the path first, or refuse a symlink.
- **A floor alone is not a control.** An inventory or coverage check derives the members it visits from the artifact under test (the flag's own regex, the function's own body), never from a second list in a test file. Floor it, with a message naming the extractor as broken rather than the subject as sparse. Under-inclusion needs the floor plus a required member; over-inclusion needs a forbidden member. State which direction stays open. A behavior or contract test keeps its expected values independent of the implementation: never derive an expected API set, parser result or accepted input from the code that produces it.

### Instruments you did not write

- **A check narrower than the claim can only confirm it, never establish it.** Match the instrument's reach to the assertion's reach before running it, and prefer one that fails visibly on a planted counterexample. A grep over one directory supports no claim about the tree.
- **Behaviour measured at an interactive prompt is not what scripts get.** `type <cmd>` names the shadow, which differs per shell. Resolve the command in the script's own shell and PATH, and name the shell and implementation it resolves to.
- **A guard's failure message is an instrument.** It is what an author acts on. Unescaped backticks inside a double-quoted diagnostic execute their contents, so the intended text is altered or gone while the surrounding command still succeeds.

## Tests

- A surface is one script, function or command verb: it names where controls live, not how many. Each changed surface with a test takes at least one must-fail control, one planted defect that turns its test red once. A control belongs to the instrument, never to a row, however many rows invoke it; a production guard takes one per rule under § Prove Your Guards.
- Where no production edit can redden a surface's test, the test states that, why, and what it holds, in place of its control. A test of the mechanism that implements a guarantee moves with the mechanism: assert the guarantee.
- A test pins values a program parses: keys, codes, enums, exit status, flags, and a text protocol a named consumer reads, stated in the producer's header. A test that pins prose or the test harness's own configuration is deleted.
- A row pins what only its own guard emits: an expectation a neighbouring gate or a helper on both sides also produces is not a pin, and neither is a value read as a truthiness bit.
- A dependency is tested in its own suite; a consumer suite asserts only its own use of it.
- A change selects its checks, locally and in CI, from each suite's direct and indirect inputs: its sources, the dependencies it consumes, fixtures, generated-code inputs, configuration and build settings. Select through the suite's existing entry point and the dependency metadata the build already holds; a suite both run goes through the same entry point in both. Missing or unreadable selection evidence runs every check in the requested area. Selection needs no custom selector, dependency table, cache, runner or workflow.
- Shaped input (positions, settings keys, tamper classes) is one table: one loop, one assertion per row, the rows visible in the file.
- A test reads time through an injectable clock; a real wait names its reason beside it.
- A collection-driven check states its coverage floor and proves its discovery completed. It rejects an empty result when the floor requires members, and a failed or incomplete discovery never reports a valid empty set. An empty application input the contract permits passes, and a test covers it.
- A shared fixture is a neutral world (a seeded repository, a fake SDK); a fixture that carries a planted defect is private to its case.
- A test that spawns a real process passes the child's environment explicitly, never the developer's live environment.
- Tests live beside the code where the runtime neither loads nor snapshots them, otherwise in a separate test tree; one file per surface, named for it. Every suite in a tree sources that tree's one assertion library, and a test helper lives in that library, never in a suite.
- A test file past about 64 KB holds more than one surface; split it at a surface seam.

## Language Discipline

- **Rust**: exhaustive matches (no `_ =>` over enums you own); enums over strings/sentinels/booleans-with-meaning. A test that hands a temporary path to code that may resolve symlinks binds its canonical root at creation and passes that binding, never the raw path; platform-only test APIs carry a `cfg` and, when the property is portable, a portable twin.
- **Bash**: check the result of every effectful substitution, in test position too; `--` before path arguments sourced from configuration, argv, or the environment (not paths the script built itself, e.g. `mktemp -d`); no `[A-Za-z]`-class assumptions under arbitrary locales. A test suite makes its `mktemp -d` root with these lines, `NAME` the suite's own name, and resolves it before any path derived from it is compared or printed: macOS answers `mktemp -d` under `/var`, a symlink to `/private/var`, so a path the code under test resolved never equals one built on the raw root.

  ```bash
  TMP_ROOT="$(mktemp -d)" || { echo "NAME: scratch=mktemp-failed" >&2; exit 1; }
  [[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "NAME: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
  TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "NAME: scratch=resolve-failed" >&2; exit 1; }
  trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
  ```

  `mktemp -d` is assigned and checked alone, never nested inside the `cd`: there its failure hands `cd` an empty argument, which bash before 5.3 accepts as the current directory, so the root names the caller's directory and the EXIT trap removes it.

- In any `pipefail` script, never pipe a shell writer into an early-closing reader (`head`, `grep -q`, `grep -m N`), which stops reading while its producer still writes: the 141 SIGPIPE status aborts the run where `errexit` fires, and in condition position reads as a plain false that drops the result with no error. Capture whole and window in-shell, or give the reader a here-string.
- **TypeScript/JS**: discriminated unions switched with a `never` default over strings and booleans-with-meaning; distinguish missing from present-but-falsy (`""`, `0`) at every guard; no `any` at module boundaries.

## Comments and Prose

Do:

- Document the constraint or invariant the code cannot show, not what the line does.
- Document public functions, structs, enums, and variants.

Don't:

- Comments that repeat the code.
- History: a temporal marker, a date, an issue id, a review round or a conversation. For an optional audit, see [commit-guards CHECKS.md § comments](../commit-guards/CHECKS.md#comments).
- Claims broader than what the adjacent code or assertion actually enforces.

Markdown is [`../docs-writing/SKILL.md`](../docs-writing/SKILL.md): the writing standard, and what each file type holds and excludes.

Commit bodies explain intent, never narrate the diff.

## Cleanup

Remove unused code completely: no backwards-compatibility shims, no renamed `_vars`, no commented-out blocks, no `// removed` markers, no re-exports without callers. Breaking removals get a CHANGELOG note, not a compat layer.
