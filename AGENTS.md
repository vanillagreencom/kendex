# kendex

Desktop app and thin CLI (Rust + Tauri + React) for managing AI coding-harness customizations: agents, skills, hooks, commands, MCP servers, plugins and Pi extensions across a global scope and per-project scopes. This repository is also the default catalog every kendex install subscribes to (`agents/`, `skills/`, `hooks/`, `commands/`, `pi-extensions/`).

## Commands

- `tools/setup`: arms the commit chain in a fresh clone, beside the commit-guards commit-msg gate. A stray commit-msg hook in the git hooks directory calling a repo-local lane this repository lacks blocks every commit; delete it and run `tools/setup` again.
- `tools/guard`: the last lane of the pre-commit chain, named by `COMMIT_GUARDS_PRE_COMMIT_LOCAL`; read the script, it is the list of repo-specific rules.
- `npm ci --prefix ui`: installs the UI, in the main checkout only.
- `KENDEX_SOURCE_COMMIT=$(git rev-parse HEAD) cargo build --release -p kendex-cli`: the self-install; copy the binary to `~/.cargo/bin/kendex` before running `kendex apply` or `kendex verify` on this tree.
- `cargo test -p kendex-app -- --ignored regenerate_bindings`: regenerates `ui/src/bindings.ts` after a command-surface change.

## Conventions

- Before writing or changing code, load the code-quality skill.
- Open work lives in Linear (team KEN); scratch goes to `tmp/` (gitignored), never `/tmp`. A plan, a research report or a measurement is an attachment on its Linear issue or a file under `tmp/`, never a tracked file under `docs/`.
- A lane or research run that records another repository's data writes it to that repository's own tracker, never into the kendex tree.
- A change under `crates/` or `ui/` ships a changelog fragment, one consumer-facing list item in `changelog.d/<section>/<name>.md` per `changelog.d/README.md`, or says `[no-changelog]` in the subject; the commit-guards commit-msg gate holds it, and `changelog-entries --collate` folds the fragments in at release. A catalog package's entry goes in `changelog.d/<package>/<section>/<name>.md` and moves only that package's version: a change under `skills/<name>/` raises its `metadata.version` in the same commit.
- A source with a tracked render (`skills/`, `agents/<n>.md`, `hooks/<n>`) lands the render in the same commit; the rule is in `skills/AGENTS.md`.
- `kendex-local.toml` is this repository's own manifest. A rule for kendex alone, not for every install of a catalog skill, goes in its `[skill-instructions]`, which the render writes into `.agents/skills/<name>/SKILL.md`; `skills/` ships to every install.
- Review bots follow `.github/instructions/code-review.md`, which Code Review Rules below points them at, and `.github/instructions/*.instructions.md`; engineering rules are the code-quality skill, round scope the dev skill, finding dispositions `skills/orch/references/finding-disposition.md`.
- A doc under `docs/architecture/` is one principle; update it when a change makes a claim in it false, never beside a code change that falsifies nothing. A decision record exists only under the decider skill's bar.

## Read when

- Before changing planning, apply, the manifest, the lock, ownership, take-over, forks, the generated-file inventory, verification, workflow adoption, tracked outputs, or the commit, push or pull-request offer: `docs/architecture/engine.md`.
- Before changing an adapter, the capability table, rendering, hook delivery or the Pi carrier: `docs/architecture/harnesses.md`; the per-harness on-disk facts are `docs/adapters/README.md`.
- Before changing the source store, discovery, browsing, subscriptions, bundles, the drift snapshot, the community directory, sign-in or the skills.sh lead: `docs/architecture/sources.md`.
- Before changing project resolution, the worktree guard or in-place packages: `docs/architecture/in-place.md`.
- Before removing or replacing files kendex wrote, or changing the trash: `docs/architecture/trash.md`.
- Before changing a safety or quality rule: `docs/architecture/scoring.md`.
- Before changing the release feed, signing, digests or self-replace: `docs/architecture/updates.md`.
- Before changing CI, the review gate, the merge route or consumer refresh: `docs/architecture/merge-rail.md`.
- Before changing repository effects, the arming record or a package's declared checks: `docs/architecture/repo-effects.md`.
- Before adding an event, notice, badge, toast or dialog to the desktop app: `docs/architecture/attention.md`.
- Before reversing a choice a principle doc cites: `docs/decisions/INDEX.md`, found by keyword with the decider skill's `decisions search`.
- When changing what a catalog may declare: `docs/authoring/README.md`, the product reference the app shows.
- When working under `crates/`: `crates/AGENTS.md`, then `crates/core/AGENTS.md`, `crates/app/AGENTS.md` or `crates/cli/AGENTS.md`.
- When working under `ui/`: `ui/AGENTS.md`.
- When working under `skills/`, `agents/` or `hooks/`: `skills/AGENTS.md`, and `hooks/AGENTS.md` for a hook script.
- When working under `pi-extensions/`: `pi-extensions/AGENTS.md`.
- When working under `tools/`: `tools/AGENTS.md`.
- When changing a workflow or a review-bot instruction file: `.github/AGENTS.md`.
- Building from source, the debug sandbox and the commit chain: `DEVELOPMENT.md`.
- Cutting a release: the app-deploy skill, `.agents/skills/app-deploy/SKILL.md`.

## Code Review Rules

<!-- generated by bot-instructions 2.6.0 from kendex.toml, kendex-local.toml, .kendex-generated.json, SKILL.md, schemas/renders.md, AGENTS.md. Edit [bot-instructions] in the effective manifest or the spec copy, then re-render. -->

If you are a review agent reviewing code, read .github/instructions/code-review.md before you comment.
