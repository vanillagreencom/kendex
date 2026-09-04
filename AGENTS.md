# kendex

Desktop app and thin CLI (Rust + Tauri + React) for managing AI coding-harness customizations: agents, skills, hooks, commands, MCP servers, plugins and Pi extensions across a global scope and per-project scopes. This repository is also the default catalog every kendex install subscribes to (`agents/`, `skills/`, `hooks/`, `pi-extensions/`).

## Commands

- `tools/setup`: arms the commit chain in a fresh clone, beside the growth-guards commit-msg gate. A stray commit-msg hook in the git hooks directory calling a repo-local lane this repository lacks blocks every commit; delete it and run `tools/setup` again.
- `tools/guard`: the last lane of the pre-commit chain, named by `GROWTH_GUARDS_PRE_COMMIT_LOCAL`; read the script, it is the list of repo-specific rules.
- `npm ci --prefix ui`: installs the UI, in the main checkout only.
- `cargo build --release -p kendex-cli`: the self-install; copy the binary to `~/.cargo/bin/kendex` before running `kendex apply` or `kendex verify` on this tree.
- `cargo test -p kendex-app -- --ignored regenerate_bindings`: regenerates `ui/src/bindings.ts` after a command-surface change.

## Conventions

- Open work lives in Linear (team KEN); scratch goes to `tmp/` (gitignored), never `/tmp`.
- A commit header is `type(scope)!: subject`, the whole line at most 72 characters, and a change under `crates/` or `ui/` ships a changelog fragment or says `[no-changelog]` in the subject; the commit-msg gate holds these three.
- The changelog is for consumers (Keep a Changelog): app, CLI and package changes only, an entry at most 200 characters with a **Breaking:** migration inline and `— thanks @name` for an outside contributor.
- An entry is a file, `changelog.d/<section>/<name>.md`, per `changelog.d/README.md`; the growth-guards `changelog-entries --collate` script folds them in at release.
- Every CI job runs on GitHub-hosted runners; no workflow reads `vars.CI_RUNNER_*`.
- Every suite and the aggregator over them run on the pull request and in the merge queue, so a red shard is fixed on the PR, never requeued; anything in `.github/workflows/skill-tests.yml` that does not run on every event carries an `if:` saying why.
- A source with a tracked render (`skills/`, `agents/<n>.md`, `hooks/<n>`) lands the render in the same commit; the rule is in `skills/AGENTS.md`.
- Review bots follow `review-bots.md` and `.github/instructions/*.instructions.md`; engineering rules are the code-quality skill, round scope the dev skill, finding dispositions `skills/orch/references/finding-disposition.md`.

## Read next

- `docs/architecture/overview.md`: before structural work; its § Topics indexes the per-subsystem files.
- `crates/core/AGENTS.md`: when working under `crates/core/`.
- `crates/app/AGENTS.md`: when working under `crates/app/`.
- `crates/cli/AGENTS.md`: when working under `crates/cli/`.
- `ui/AGENTS.md`: when working under `ui/`.
- `skills/AGENTS.md`: when working under `skills/`, `agents/` or `hooks/`.
- `hooks/AGENTS.md`: when writing or changing a hook script.
- `pi-extensions/AGENTS.md`: when working under `pi-extensions/`.
- `docs/DEVELOPMENT.md`: building from source and where a debug build writes.
- `docs/RELEASING.md`: cutting a release.

## Code Review Rules

For automated reviewers (Codex code review, Copilot). Working agents: your reply contract is in the orch skill, not here.

- Raise only defects in the changed lines or directly broken by them: correctness, security, data loss, fail-open in gate/guard/CI code.
- One comment per root cause, naming every affected site. Everything you have about the diff goes in one round.
- No style, wording, or naming preferences. No speculative hardening on fail-closed paths. No test-coverage asks unless the diff changes behavior no test exercises. Formatting and lint belong to CI, not review.
- Do not re-raise a finding class already answered with a documented rationale — `Declined: <reason>` on this PR, a settings comment, an engine header comment, or a note in `skills/review-gate/references/` — unless the relevant code changed since.
- Author replies are `Fixed in <sha>`, `Declined: <reason>`, or `Tracked: KEN-<n>` / `#<n>`. A decline takes a reason form `skills/orch/references/finding-disposition.md` § Decision flow sets out; a label is not a reason. The merge gate rejects tracking claims that name no issue, and declines whose reason is nothing but a label it knows.
