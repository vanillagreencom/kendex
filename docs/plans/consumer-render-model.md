# Consumer render model

A kendex consumer commits the files kendex renders into it: the harness trees, the review-bot files and a full copy of every skill it installs. The owner asked whether a consumer should commit only its lock, as a package manager would, and install the rest on each clone. That model breaks a fresh clone and five CI jobs, and it costs an install step on every clone, lane and CI run, a network dependency on the catalog, a new change class and a superseding decision record. Most of the churn it would remove comes from files no consumer reads: in a measured consumer refresh, rendered skill tests were the largest single share of the changed files. The recommendation, adopted by owner decision 1790634126 item 5, is route 2 below: consumer renders skip `tests/`, `evals/` and `DEVELOPMENT.md` (KEN-2038). Route 1, the package-manager install step, is dropped. The doc checks that were section B of the draft, with when each should run (KEN-2039), are in [ci-targets.md § Doc checks](ci-targets.md#doc-checks).

Design note, 2026-09-28. Read: [D001](../decisions/D001-portable-lock.md), [engine.md](../architecture/engine.md), [generated-paths.md](../architecture/generated-paths.md), [merge-rail.md](../architecture/merge-rail.md), the `change-class` header, the review-gate refresh template, one consumer's CI and trees, the fleet install scripts, the commit chain and `.github/workflows/skill-tests.yml`.

Per-repository records were removed from this public repository (KEN-2602).

## What a harness or bot reads from the tree before kendex can run

- Claude Code: `.claude/settings.json` (hook registrations, each naming a script by path under `.claude/hooks/`), `.claude/agents/*.md`, `.claude/skills/<n>` (symlinks into `.agents/skills/`), `CLAUDE.md` then `AGENTS.md`.
- Codex: `.codex/config.toml`, `.codex/hooks.json` (each command walks up to `.codex/hooks/<n>.sh` and prints `kendex-hook-missing ... Run kendex refresh` when absent), `.codex/agents/`, `AGENTS.md`.
- Pi: `.pi/settings.json`, `.pi/kendex/hooks.json`, `.pi/kendex/hooks/`, `.pi/agents/`.
- Review bots, at PR time from the tree: `.github/instructions/*.md`, `.github/copilot-instructions.md`, `.coderabbit.yaml`, `.macroscope/`, the owned region of `AGENTS.md`. These are package outputs of bot-instructions (`skills/bot-instructions/SKILL.md` repo-effects), not renders, and are outside `.kendex-generated.json`.
- GitHub: `.github/workflows/*.yml`, adopted verbatim copies recorded with a template hash ([generated-paths.md](../architecture/generated-paths.md) § Boundaries).
- A consumer commits far more files under `.agents/skills` than under `.claude`, `.codex` and `.pi`, and about a third of the skill files sit under a `tests/` segment. Most of a refresh PR's changed files are rendered skill copies, and about half of those are tests.

## What breaks under the pure package-manager model

The model: the lock is committed and the renders are ignored.

- Fresh clone, no kendex: every hook registration points at a missing script, so each tool call errors until apply runs, and the hook that tells the user to install kendex (`hooks/session-drift-check.sh`) is itself a render, so nothing says why.
- Review bots: unaffected as long as the bot files stay committed. Their checker (`.agents/skills/bot-instructions/scripts/bot-instructions`) is a render, which a consumer's CI can read from a default-branch sparse checkout.
- CI jobs running rendered scripts in a consumer: preflight, review-gate `validate.sh`, the bot-instructions check, `harness-only`, and `review-writer.sh` from the default branch in `review-gate-writer.yml` under an elevated token. Each needs an install step from the lock before it runs.
- `kendex verify` and the render class: `change-class` proves `render` by comparing the changed committed files to a fresh render (the `render` class in its header), and `harness-only` reads `.kendex-generated.json` at both endpoints. With nothing committed, a refresh PR is lock plus inventory plus bot files, and the class rule has nothing to compare. The proof needs a new `lock-only` rule.
- D001: its Summary says the lock is committed with the renders it records. The package model is the mirror image of that: a record with no renders, which the engine already handles as apply from the lock. The managed ignore block rule in [engine.md](../architecture/engine.md) § Decisions, "never repository documents and never the lock", must change to ignore the render roots. D001 needs a superseding record for this model, not for route 2.
- Worktree symlinks: a consumer links only its private env file and cache. An ignored render is absent in every new worktree, so each lane create runs apply. Linking the render roots to the main checkout is wrong: two branches with different locks would share one render, and `hooks/block-worktree-refresh.sh` already exists to stop a worktree writing the main checkout's renders.
- Skill tests: no consumer runs rendered skill tests. Only in-place project skills run their own.

## What the package-manager model costs

- An install step on every clone, lane create and CI run: the pinned installer (`skills/review-gate/templates/kendex-refresh.yml`, step "Install pinned kendex": `curl install.sh` at an immutable commit with `--version`), then `kendex source refresh` (fetches the catalog mirror into kendex's cache), then apply (plan, render from the mirror, scope lock, journal, lock write). kendex's own CI already pays the first two on the render-class path (`skill-tests.yml` job `changes`, the kendex install and `kendex source refresh` steps). Hosted lanes are prepared with kendex on the host before launch (`skills/orch/scripts/lane-host-ssh --help`); orch's post-merge already runs `kendex refresh --scope project --yes --leave` (`skills/orch/scripts/post-merge`).
- A network dependency on the catalog at CI time and at lane create: a GitHub outage or a rate limit blocks every job that needs a rendered script. Mitigation: cache the mirror keyed on the lock's source commits, as the render proof warns and degrades today (the `render proof may be unavailable` warning step in job `changes`).
- A pinned-revision fetch: each lock entry carries `sourceCommit`; the mirror must hold it, and verify renders at the recorded commit (`change-class` `--at-record`). A force-pushed or garbage-collected catalog commit breaks apply for every clone at that lock.
- A second copy of the trust question: a workflow with an elevated token (`review-gate-writer.yml`) would run scripts kendex just fetched instead of scripts on the default branch. The pinned installer commit plus the lock's source commit give the same guarantee, but that argument has to be written down in [D003](../decisions/D003-one-merge-path.md)'s terms.

## Middle routes

1. Commit only what a harness or bot must find before kendex runs (the `.claude`, `.codex` and `.pi` trees, the bot files, the workflows, the lock and inventory) and ignore `.agents/skills/<n>` renders. In-place project skills stay real directories. This removes most of a consumer's committed render files and keeps every hook and agent working in a fresh clone. It still needs the install step in CI for the five rendered scripts above, the `lock-only` class rule, the ignore block change, and a D001 supersession.
2. Drop `tests/` and other non-runtime trees from consumer renders. `collect_skill_tree` (`crates/core/src/source_read.rs`) skips only tool state. Skipping `tests/`, `evals/` and `DEVELOPMENT.md` removes about half of a refresh PR's rendered skill files and about a third of a consumer's committed skill files, changes nothing a harness, bot, CI job or worktree reads, and needs no decision record. Every skill's `renderedHash` moves once, which `lock-record.yml` re-records on main ([D007](../decisions/D007-lock-record-on-main.md)). The render-mirror rule in `tools/guard` (key `missing-render`, "each source there owes a render") must stop demanding a render for `tests/`, and the same-commit render rule, the first bullet of [skills/AGENTS.md](../../skills/AGENTS.md), says the same.

## Recommendation

Route 2 is adopted, carried by KEN-2038 (owner decision 1790634126 item 5). It deletes tests, evals and `DEVELOPMENT.md` from consumer renders and keeps `SKILL.md`, scripts, references, templates, schemas, workflows and examples, which agents read at run time. It keeps the committed lock, inventory, harness trees and bot files exactly as D001 and [generated-paths.md](../architecture/generated-paths.md) describe, and D001 needs no superseding record for it. The owner's decision adds two things to KEN-2038's scope: exempt `tests/` in the `tools/guard` render-mirror rule and in the first bullet of [skills/AGENTS.md](../../skills/AGENTS.md), and first check that no rendered script reads its own `tests/` fixtures at run time, naming each one found and how it is handled.

KEN-2038 is done when `kendex refresh` in a consumer writes no `<skill>/tests/`, `evals/` or `DEVELOPMENT.md` path, `.kendex-generated.json` lists none, `kendex verify` passes at the re-recorded lock, and change-class classes the refresh PR that removes them as `render`.

Route 1 is dropped by the same decision. Its reason, in the owner's terms: an install step per CI job, a network dependency, a `lock-only` change class and a D001 supersession, for the comparatively few harness files it would still leave committed.
