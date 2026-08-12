# github skill development

## Structure

- `scripts/github.sh` — Entry point (command router)
- `scripts/git-https-auth` — Git wrapper for per-command GitHub SSH→HTTPS fallback through `gh` auth
- `scripts/git-diff-summary` — Standalone changed-file domain/scope and risk-flag summary helper
- `scripts/commands/` — Individual command scripts
- `scripts/lib/gh-auth.sh` — Shared GitHub token resolution and keyring fallback helpers
- `scripts/lib/github-api.sh` — Shared library (auth, GraphQL, REST, error handling)
- `SKILL.md` — Agent-facing skill definition

## Adding a Command

1. Create `scripts/commands/<command-name>.sh`
2. Source `../lib/github-api.sh` for shared functions
3. Add a `show_help()` function
4. Add the command to the case statement in `scripts/github.sh`
5. Update the Commands table in `SKILL.md`

## Declaration-site test scoping (`git-diff-summary`)

A `.rs` file with no file-local test marker can still be test-only when its
gate lives at the declaration site in the declaring module. Classification
therefore reads the modules that could declare the file, on the diff's new
side: `HEAD` for a `base...HEAD` diff, the index for `--staged`, the worktree
for `--head` — tracked files only, so an untracked file never reclassifies a
tracked change. Every `.rs` file in the candidate's own directory and its
ancestor directories is scanned once, emitting candidate-agnostic route
records that the per-candidate evaluator filters afterwards.

**Lexing.** Source is masked before matching: line-comment precedence, nested
block comments, and the contents of string, raw-string, byte/C-string and
char literals blanked, so quoted braces, `//` and `/*` cannot corrupt
structure. Item matching runs on the mask and values are read from the
original at the same offsets. A leading UTF-8 BOM and a crate shebang are
first-line preambles, dropped ahead of the first item.

**Routes.** A route is a `mod` declaration or an `include!` of the target,
each carrying its own attribute gate. Bare `mod name;` emits both legal forms
(`name.rs` and `name/mod.rs`) and resolves in the declaring file's module
directory — its own directory for `mod.rs`/`lib.rs`/`main.rs`, its directory
plus its file stem otherwise. `#[path]` values and `include!` literals
resolve in the containing file's directory, per the Rust reference. Targets
are lexically normalized so equivalent spellings compare equal. `include!` is
evaluated at the invocation site for every delimiter form, and only when its
argument IS a direct string literal.

**Skip regions.** Braced bodies — inline modules, `macro_rules!` definitions,
macro invocations, and fn/impl/struct bodies — emit no records at all, and
nested macro token trees are jumped over rather than scanned, so an
`include!` that Rust never expands fabricates nothing.

**Verdict.** A candidate whose every found route is `#[cfg(test)]`-gated is
test scope. Any ungated route, no route found, a `bin/` segment or
`lib.rs`/`main.rs` crate root, or a read failure keeps the file-local
classification: every shape the scanner cannot resolve fails toward no
record rather than a guessed one. The residual limits of this model are
enumerated in the `git-diff-summary` header.
