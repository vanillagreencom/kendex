# github skill development

Maintainer notes. Consumer docs: [README.md](README.md); the agent contract: [SKILL.md](SKILL.md).

## Adding a command

1. Create `scripts/commands/<command-name>.sh`, sourcing `../lib/github-api.sh` for auth, GraphQL, REST and error handling.
2. Give it a `show_help()`.
3. Add the command to the case statement in `scripts/github.sh` and to the Commands table in `SKILL.md`.

Parse arguments with an explicit `while`/`shift` loop that rejects unknown flags and surplus positionals. Emit JSON with `jq -n`, never string interpolation: API error text routinely contains quotes. A failed dependency exits nonzero rather than returning an empty result that reads as "none found".

Subprocess time bounds go through `scripts/lib/bounded.sh`, the one portable wall-clock bound. Token resolution and the keyring fallback are `scripts/lib/gh-auth.sh`, shared with the orch waiters. Check-rollup run scoping is `scripts/lib/ci-run-correlation.sh`, shared with orch `ci-wait`.

## Tests

`tests/` holds one self-contained suite per file; CI runs each as `bash <file>`.

## Declaration-site test scoping (`git-diff-summary`)

A `.rs` file with no file-local test marker can still be test-only when its gate lives at the declaration site in the declaring module. Classification therefore reads the modules that could declare the file, on the diff's new side: `HEAD` for a `base...HEAD` diff, the index for `--staged`, the worktree for `--head`, tracked files only, so an untracked file never reclassifies a tracked change. Every `.rs` file in the candidate's own directory and its ancestor directories is scanned once, emitting candidate-agnostic declaration records that the per-candidate evaluator filters afterwards.

The form read is a run of column-zero outer attributes followed by a column-zero `mod name;`, `pub`/`pub(...)` accepted, `#[path]` optional, `#[cfg(test)]` anywhere in the run:

```rust
#[cfg(test)]
#[allow(clippy::unwrap_used)]
#[path = "scan_fixtures.rs"]
mod scan_fixtures;
```

Any other line ends the run and drops the pending gate. Bare `mod name;` emits both legal forms (`name.rs` and `name/mod.rs`) and resolves in the declaring file's module directory: its own directory for `mod.rs`, `lib.rs` and `main.rs`, its directory plus its file stem otherwise. A `#[path]` value resolves in the containing file's directory, per the Rust reference. Targets are lexically normalized so equivalent spellings compare equal.

The scan is line-based, with no comment or literal masking and no nesting state. Column-zero text that is not a top-level item is read as one anyway, so the pair written flush left inside a block comment, a raw string, a macro body or an inline `mod` block emits a record. A declaration the scan cannot see (an `include!`, one indented inside a body, one spelled across lines) emits nothing, so a file production-reachable only through one of those while also carrying a `#[cfg(test)]`-gated declaration classifies as test. This is review-flag hygiene, not an adversarial control.

Verdict: a candidate whose every found declaration is `#[cfg(test)]`-gated is test scope. Any ungated declaration, none found, a `bin/` segment or `lib.rs`/`main.rs` crate root, or a read failure, including a symlinked declaring module whose blob is link text rather than source, keeps the file-local classification.
