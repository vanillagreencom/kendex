# kendex

Desktop app + thin CLI (Rust + Tauri + React) for managing AI coding-harness customizations. Read `docs/ARCHITECTURE.md` before structural work; amend it in the same change that reshapes the code.

Rules the tooling cannot enforce:

- `crates/core` is pure domain logic — no Tauri, no IPC, no UI concerns.
- `ui/` renders state and invokes commands; domain logic and types live in Rust, and TS bindings are generated, never hand-written.
- Scope is the reported symptom. Every behavioral surface a change touches must trace to a line in the report — if you cannot name that line, keep it out of this change. Two exceptions: mechanical enablers of landing it (locks, changelog, baselines, dismissal renewals) ride without a line, and a defect the change introduces or arms is in scope by definition.
- Prefer deleting code to abstracting it. Three similar lines beat a premature abstraction. A new dependency needs a one-line justification in its commit message.
- Every behavior change ships with a test that fails without it.
- An `else` that "shouldn't happen" is a bug: assert or return an error, never continue silently.
- Plain words over jargon: name things by what they do. Comments say why, never what or when — no temporal markers, no references to the change that wrote them. Commit bodies explain intent, never narrate the diff.
- Delete unused code completely — no compat shims, no `_renamed` vars, no "removed" comments.
- The CHANGELOG is for consumers (Keep a Changelog): document app, CLI, and package changes; keep engine-internal and maintainer-only details out.

`tools/guard` (the pre-commit hook) enforces the rest — read the script; it is the list.

## Code Review Rules

For automated reviewers (Codex code review, Copilot). Working agents: your
reply contract is in the orch skill, not here.

- Raise only defects in the changed lines or directly broken by them:
  correctness, security, data loss, fail-open in gate/guard/CI code.
- One comment per root cause, naming every affected site. Everything you
  have about the diff goes in one round.
- No style, wording, or naming preferences. No speculative hardening on
  fail-closed paths. No test-coverage asks unless the diff changes behavior
  no test exercises. Formatting and lint belong to CI, not review.
- Do not re-raise a finding class answered `Declined: <reason>` on this PR
  unless the relevant code changed since.
- Author replies are `Fixed in <sha>`, `Declined: <reason>`, or
  `Tracked: KEN-<n>` / `#<n>`; the merge gate rejects tracking claims that
  name no issue.
