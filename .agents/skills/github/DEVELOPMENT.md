# github skill development

## Structure

- `scripts/github.sh` — Entry point (command router)
- `scripts/commands/` — One script per subcommand
- `scripts/git-https-auth` — Git wrapper for per-command GitHub SSH→HTTPS fallback through `gh` auth
- `scripts/git-diff-summary` — Standalone changed-file domain/scope and risk-flag summary helper
- `scripts/lib/github-api.sh` — Shared auth, GraphQL, REST, and error handling
- `scripts/lib/gh-auth.sh` — Token resolution and keyring fallback
- `scripts/lib/bounded.sh` — Portable wall-clock bound for GitHub subprocesses
- `scripts/lib/kendex-env.sh` — Project settings / `.env.local` loader
- `scripts/lib/ci-run-correlation.sh` — Check-rollup run scoping, shared with orch `ci-wait`
- `scripts/lib/verify-lib.sh` — Merge simulation and build/test detection for `pr-cross-check --verify`
- `SKILL.md` — Agent-facing skill definition
- `tests/` — Run any file directly; each is self-contained

## Adding a Command

1. Create `scripts/commands/<command-name>.sh`
2. Source `../lib/github-api.sh` for shared functions
3. Add a `show_help()` function
4. Add the command to the case statement in `scripts/github.sh`
5. Update the Commands table in `SKILL.md`

Parse arguments with an explicit `while`/`shift` loop that rejects unknown
flags and surplus positionals. Emit JSON with `jq -n`, never string
interpolation — API error text routinely contains quotes. A failed dependency
must exit nonzero rather than returning an empty result that reads as "none
found".

## Declaration-site test scoping (`git-diff-summary`)

A `.rs` file with no file-local test marker can still be test-only when its
gate lives at the declaration site in the declaring module. Classification
therefore reads the modules that could declare the file, on the diff's new
side: `HEAD` for a `base...HEAD` diff, the index for `--staged`, the worktree
for `--head` — tracked files only, so an untracked file never reclassifies a
tracked change. Every `.rs` file in the candidate's own directory and its
ancestor directories is scanned once, emitting candidate-agnostic route
records that the per-candidate evaluator filters afterwards.

**The form read.** The literal declaration, at column zero, `pub`/`pub(...)`
accepted and `#[path]` optional:

```rust
#[cfg(test)]
#[path = "scan_fixtures.rs"]
mod scan_fixtures;
```

An attribute binds to the next line and is dropped by anything else, so only
a contiguous block carries a gate. Bare `mod name;` emits both legal forms
(`name.rs` and `name/mod.rs`) and resolves in the declaring file's module
directory — its own directory for `mod.rs`/`lib.rs`/`main.rs`, its directory
plus its file stem otherwise. A `#[path]` value resolves in the containing
file's directory, per the Rust reference. Targets are lexically normalized so
equivalent spellings compare equal.

**Everything else emits nothing.** A declaration inside a body or a macro, an
`include!`, one spelled across lines, one inside a string or a comment: no
record for that shape, so the file keeps its file-local classification rather
than a guessed one. This is review-flag hygiene, not an adversarial control.

**Verdict.** A candidate whose every found route is `#[cfg(test)]`-gated is
test scope. Any ungated route, no route found, a `bin/` segment or
`lib.rs`/`main.rs` crate root, or a read failure — including a symlinked
declaring module, whose blob is link text rather than source — keeps the
file-local classification.
