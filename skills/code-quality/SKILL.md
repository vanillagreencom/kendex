---
name: code-quality
description: "Load for any coding or development task in any repository: writing, changing, fixing, refactoring, or testing code or scripts in any language."
summary: "Code-authoring standards for dev agents: correctness over convenience, no fail-open branches, module structure, prove-your-guards, test architecture, comment rules, over-engineering limits."
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

- **One lifetime, one owner.** Resources that share a lifetime (connections, leases, sessions, caches) live in one object whose teardown does every cleanup. Adding a resource touches the owner, never the call sites.
- **A function that holds a subsystem's whole lifecycle is a module.** Split it at the phase seams (acquire, deliver, recover, tear down) before the next concern lands.
- **Exports serve the design, not the packaging.** An internal symbol re-exported so tests or vendors can reach it is API the next refactor owes compatibility to. Generate that entry in the build instead.
- **Compatibility probing carries a floor.** Runtime detection across upstream versions states the minimum version it serves and the version that removes it. An undated shim is a workaround under § Correctness.
- **Narrowing has one door.** A wire-format union read through repeated casts gets one guard module, and call sites match on the narrowed value. This applies in languages with sum types.
- **Classification is a table.** Detecting an upstream failure kind from its message text is one pattern table with real examples pinned under test, never a regex at each call site.

## Prove Your Guards

A new or modified production gate or guard ships with one must-fail control per rule it enforces: plant one defect the rule catches, and the control passes when the guard turns red once. The control keeps the matched text and removes the behavior; one that deletes the code under test only proves the assertion runs. Reject assertions loose enough to match a skip note, fixtures that never reach the guarded bound, and harness code that keeps alive what the implementation should.

- **A scripted text substitution asserts its match, or it is not an edit.** Assert the pattern's occurrence count and that the file changed, or use an edit tool that errors on no match. Neither assertion holds on a symlink, which `sed -i` replaces with a new file while its target stands: resolve the path first, or refuse a symlink.
- **A floor alone is not a control.** Derive the expected set from the artifact under test (the flag's own regex, the function's own body), never from a second list in a test file. Floor it, with a message naming the extractor as broken rather than the subject as sparse. Under-inclusion needs the floor plus a required member; over-inclusion needs a forbidden member. State which direction stays open.

### Instruments you did not write

- **A check narrower than the claim can only confirm it, never establish it.** Match the instrument's reach to the assertion's reach before running it, and prefer one that fails visibly on a planted counterexample. A grep over one directory supports no claim about the tree.
- **Behaviour measured at an interactive prompt is not what scripts get.** `type <cmd>` names the shadow, which differs per shell. Resolve the command in the script's own shell and PATH, and name the shell and implementation it resolves to.
- **A guard's failure message is an instrument.** It is what an author acts on. Unescaped backticks inside a double-quoted diagnostic execute their contents, so the intended text is altered or gone while the surrounding command still succeeds.

## Tests

- A surface is one script, function or command verb. Each changed surface with a test takes one must-fail control: one planted defect that turns its test red once. The control belongs to the instrument, never to a row, however many rows invoke it.
- Where no production edit can redden a surface's test, the test states that, why, and what it holds, in place of its control. A test of the mechanism that implements a guarantee moves with the mechanism: assert the guarantee.
- A test pins values a program parses: keys, codes, enums, exit status, flags, and a text protocol a named consumer reads, stated in the producer's header. A test that pins prose or the test harness's own configuration is deleted.
- A row pins what only its own guard emits: an expectation a neighbouring gate or a helper on both sides also produces is not a pin, and neither is a value read as a truthiness bit.
- A dependency is tested in its own suite; a consumer suite asserts only its own use of it.
- Shaped input (positions, settings keys, tamper classes) is one table: one loop, one assertion per row, the rows visible in the file, and no control beyond its surface's one.
- A test reads time through an injectable clock; a real wait names its reason beside it.
- A collection-driven check fails closed on an empty collection.
- A shared fixture is a neutral world (a seeded repository, a fake SDK); a fixture that carries a planted defect is private to its case.
- A test that spawns a real process passes the child's environment explicitly, never the developer's live environment.
- Tests live beside the code, one file per surface, named for it. Every suite in a tree sources that tree's one assertion library.
- A test file past about 64 KB holds more than one surface; split it at a surface seam.

## Language Discipline

- **Rust**: exhaustive matches (no `_ =>` over enums you own); enums over strings/sentinels/booleans-with-meaning. A test that hands a temporary path to code that may resolve symlinks binds its canonical root at creation and passes that binding, never the raw path; platform-only test APIs carry a `cfg` and, when the property is portable, a portable twin.
- **Bash**: check the result of every effectful substitution, in test position too; `--` before path arguments sourced from configuration, argv, or the environment (not paths the script built itself, e.g. `mktemp -d`); no `[A-Za-z]`-class assumptions under arbitrary locales.
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

## Over-Engineering

Build only what was asked. No speculative abstractions and no error handling for impossible scenarios. In production code, no generalization before a third caller exists, and no wrapper that only forwards; a decision re-derived at N sites already has N callers. Test helpers live in the tree's one assertion library (§ Tests), whatever their caller count. A new dependency needs a one-line justification in its commit message.

One judge per question: never re-implement a decision (classify, validate, parse, detect state) another component or language already owns; delegate. A decision re-derived at each use site in one file is the same defect: compute it once and let each site match on the result. A second spelling is a defect even when both copies agree.

## Cleanup

Remove unused code completely: no backwards-compatibility shims, no renamed `_vars`, no commented-out blocks, no `// removed` markers, no re-exports without callers. Breaking removals get a CHANGELOG note, not a compat layer.
