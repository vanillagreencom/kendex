# kendex

Desktop app + thin CLI (Rust + Tauri + React) for managing AI coding-harness customizations.

**Orientation.** Read `docs/ARCHITECTURE.md` before structural work; stale docs are bugs — amend them in the same change. Open work lives in Linear (team KEN); scratch goes to `tmp/` (gitignored), never `/tmp`. Review bots follow `review-bots.md` and `.github/instructions/*.instructions.md`. Engineering rules are the code-quality skill; round scope is the dev skill's § Engineering Rules; finding dispositions are orch's `references/finding-disposition.md`.

Repo-specific rules:

- `crates/core` is pure domain logic — no Tauri, no IPC, no UI concerns.
- `ui/` renders state and invokes commands; domain logic and types live in Rust, and TS bindings are generated, never hand-written.
- Every CI job runs on GitHub-hosted runners; no workflow reads `vars.CI_RUNNER_*`.
- In a worktree, sync a skill's `.agents/` render by replaying the source diff, never by copying `SKILL.md`; renders may carry an injected instructions block.
- A new test that needs a host path reads it from `Env` (`host_rooted`, `drift_dir`), never composes the platform path.
- A new test that shells out to git clears `GIT_DIR`, `GIT_COMMON_DIR`, `GIT_WORK_TREE`, and `GIT_INDEX_FILE` together. Under `skills/orch/tests/` that clearing lives in `lib/git-env.sh`, which every suite sources on the line under its `set -...o pipefail`.
- The CHANGELOG is for consumers (Keep a Changelog): document app, CLI, and package changes; keep engine-internal and maintainer-only details out. An entry runs at most 200 characters — the outcome, a **Breaking:** migration inline, `— thanks @name` for outside contributors — never an essay.
- An entry is a file, never a `CHANGELOG.md` line: write `changelog.d/<section>/<name>.md` holding the list item it becomes, per `changelog.d/README.md`. `.agents/skills/growth-guards/scripts/changelog-entries --collate` folds them in at release.
- Where a skill has a rendered copy under `.agents/skills/`, a change to the source lands that copy in the same commit; the same holds for `agents/<n>.md` and its per-harness renders, and for a `hooks/<n>` change, which lands whichever harness hook copies already track it — judged per file, because the harness hook sets are deliberately not uniform and `hooks/tests/*` renders nowhere. `tools/guard` reds any such source change whose render does not move with it — presence, not byte equality, because where the project declares skill instructions for a skill, its render carries an injected block the source has no copy of, marked in the file by the renderer. A source with no tracked render has nothing to land.
- `ui/` installs with `npm ci --prefix ui`, in the main checkout only.
- Every suite and the aggregator over them run on the pull request as well as in the merge queue, so a green PR proves what the queue re-proves and a red shard blocks the PR itself — fix it there rather than requeuing. Anything in `.github/workflows/skill-tests.yml` that does not run on every event carries an `if:` saying why.

`tools/guard` enforces the rest — read the script; it is the list. It is the last lane of the package's commit chain, named by `GROWTH_GUARDS_PRE_COMMIT_LOCAL`; `tools/setup` arms that chain in a fresh clone, beside the package's own commit-msg gate. Neither judges a hook below its delegating line: a `.git/hooks/commit-msg` calling a repo-local tools/commit-msg lane — which this repo does not have — blocks every commit until you delete that hook and run setup again. That gate holds the three rules only a commit message can carry: the header is `type(scope)!: subject`, the whole header line caps at 72 characters, and a change under `crates/` or `ui/` ships a changelog fragment or says `[no-changelog]` in the subject.

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
- Do not re-raise a finding class already answered with a documented
  rationale — `Declined: <reason>` on this PR, a settings comment, an engine
  header comment, or a note in `skills/review-gate/references/` — unless the
  relevant code changed since.
- Author replies are `Fixed in <sha>`, `Declined: <reason>`, or
  `Tracked: KEN-<n>` / `#<n>`. A decline takes a reason form
  `skills/orch/references/finding-disposition.md` § Decision flow sets
  out; a label is not a reason. The merge gate rejects tracking claims
  that name no issue, and declines whose reason is nothing but a label
  it knows.
