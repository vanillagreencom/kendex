# kendex

Desktop app + thin CLI (Rust + Tauri + React) for managing AI coding-harness customizations.

**Orientation.** Read `docs/ARCHITECTURE.md` before structural work; stale docs are bugs — amend them in the same change. Open work lives in Linear (team KEN); scratch goes to `tmp/` (gitignored), never `/tmp`. Review bots follow `review-bots.md` and `.github/instructions/*.instructions.md`. Engineering rules are the dev skill's § Engineering Rules; finding dispositions are orch's `references/finding-disposition.md`.

Repo-specific rules:

- `crates/core` is pure domain logic — no Tauri, no IPC, no UI concerns.
- `ui/` renders state and invokes commands; domain logic and types live in Rust, and TS bindings are generated, never hand-written.
- The CHANGELOG is for consumers (Keep a Changelog): document app, CLI, and package changes; keep engine-internal and maintainer-only details out. An entry runs at most 200 characters — the outcome, a **Breaking:** migration inline, `— thanks @name` for outside contributors — never an essay.
- An entry is a file, never a `CHANGELOG.md` line: write `changelog.d/<section>/<name>.md` holding the list item it becomes, per `changelog.d/README.md`. `tools/changelog-collate` folds them in at release.
- Where a skill has a rendered copy under `.agents/skills/`, a change to the source lands that copy in the same commit, because the render is committed and no check compares the two. A skill with no copy there has nothing to land. Where the project declares skill instructions for a skill, its render carries an injected block the source has no copy of, marked in the file by the renderer, and a comparison has to skip that block.
- `ui/` installs with `npm ci --prefix ui`, in the main checkout only.
- Some required checks run only in the merge queue, so a green PR does not prove them; the fast/full split in `.github/workflows/skill-tests.yml`'s header comment says which jobs and shards those are. A change under a surface whose job or shard is merge-queue-only runs that suite locally before the PR.

`tools/guard` enforces the rest — read the script; it is the list. It is the last lane of the package's commit chain, named by `GROWTH_GUARDS_PRE_COMMIT_LOCAL`; `tools/setup` arms that chain in a fresh clone, beside the package's own commit-msg gate. Neither judges a hook below its delegating line, so a `.git/hooks/commit-msg` calling a repo-local tools/commit-msg lane — which this repo does not have — blocks every commit until you delete that hook and run setup again. That gate holds the three rules only a commit message can carry: the header is `type(scope)!: subject`, the whole header line caps at 72 characters, and a change under `crates/` or `ui/` ships a changelog fragment or says `[no-changelog]` in the subject.

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
  `Tracked: KEN-<n>` / `#<n>`. A decline names the passing state or the
  false premise it disproves; a label is not a reason. The merge gate
  rejects tracking claims that name no issue, and declines whose reason is
  nothing but a label it knows.
