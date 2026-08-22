# kendex

Desktop app + thin CLI (Rust + Tauri + React) for managing AI coding-harness customizations. Read `docs/ARCHITECTURE.md` before structural work; amend it in the same change that reshapes the code.

Rules the tooling cannot enforce:

- `crates/core` is pure domain logic — no Tauri, no IPC, no UI concerns.
- `ui/` renders state and invokes commands; domain logic and types live in Rust, and TS bindings are generated, never hand-written.
- Scope is the reported symptom. Every surface a change touches must trace to a line in the report — if you cannot name that line, keep it out of this change, however true the finding is.
- Prefer deleting code to abstracting it. Three similar lines beat a premature abstraction. A new dependency needs a one-line justification in its commit message.
- Every behavior change ships with a test that fails without it.
- An `else` that "shouldn't happen" is a bug: assert or return an error, never continue silently.
- Plain words over jargon: name things by what they do. Comments say why, never what or when — no temporal markers, no references to the change that wrote them. Commit bodies explain intent, never narrate the diff.
- Delete unused code completely — no compat shims, no `_renamed` vars, no "removed" comments.
- The CHANGELOG is for consumers (Keep a Changelog): document app, CLI, and package changes; keep engine-internal and maintainer-only details out.

`tools/guard` (the pre-commit hook) enforces the rest — read the script; it is the list.
