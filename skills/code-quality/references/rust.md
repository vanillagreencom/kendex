# Rust

## State and ownership

- Match owned enums exhaustively, with no wildcard arm. Use enums instead of strings, sentinels or booleans that encode cases.
- Acquire an owned scratch file with `OpenOptions::create_new(true)` before assigning cleanup responsibility. A prior existence check does not make a later create-and-truncate exclusive.

## Modules

- Give each file one concept, and the whole of it. A file split off at a concept seam stands alone: its reader never needs the source file open beside it.
- Test a proposed seam by counting the names the new file imports straight from its parent (`use super::{...}`). A real seam sits near zero, and `use super::*` fails the test. Moving half a function, a helper only one caller uses, or "part 2 of X" into a second file is worse than the long file.
- Three Rust shapes are that move, whatever the seam is called:
  1. `#[path = "<sibling>.rs"]` on a private `mod` that exists to hold the parent's lines. `#[path]` chosen for another reason, such as a test module or a `cfg`-selected alternative, names a real seam.
  2. A hub that declares `mod child;` then `use child::*`, with every spoke opening `use super::*`. A hub carries declarations, narrow orchestration and stable exports. A spoke depends on the hub's shared types or on a lower shared module, never on a sibling's internals.
  3. A file whose only top-level items are inherent `impl` blocks on a type its parent declares. That file is part 2 of the type by construction.
- A file header that justifies the file by a line count records that the seam is not real.
- Merge files that are one concept read together: calls that ping-pong between them, a helper file with one importer, a "part 2" file.

## Tests

- Group a coherent contract or state machine in a test module. Private helpers and native assertion macros belong there; do not split every function into a file or export helpers to meet a shared-library rule.
- Prefer private unit tests and `cfg(test)` fixtures for access within a crate. An integration test compiles the library without `cfg(test)`. Cross-crate support belongs in a dev-only support crate or a test-support feature absent from the product's dependency graph. Keep real serialization shared; put fake inputs and measurements behind that test boundary.
- Use a dedicated test executable for process protocols. Tests run in the release profile must not depend on debug-only commands in the product executable.
- A crate-private readback with no production effect is not a reason for a standalone refactor. When changing it, use `cfg(test)` instead of suppressing dead-code warnings.
- A test never calls `std::env::set_var` or `std::env::remove_var`. A fixture mutex does not protect other environment readers. Pass configuration as input; test environment parsing in a child with an explicit environment.
- Bind a temporary directory's canonical root at creation before passing it to code that resolves symlinks. Gate platform-only test APIs with `cfg`; give a portable property a portable test too.
- Build a must-fail control with `CARGO_TARGET_DIR` set on the control's own build and test commands, never exported into the session's environment: a later build in the session would point at the directory the control removed.

## Selection and measurement

- The existing validation entry point derives affected workspace consumers from `cargo metadata`. Account for resolved dependencies, features, target platforms and build settings when mapping that graph to suites. Include excluded packages through their own manifests when the requested area contains them; workspace metadata cannot select tests it does not describe.
- Criterion loop-cost estimates are not event latency percentiles. Apply [the evidence rules](../SKILL.md#prove-your-guards) to the measured workload and retained state.
