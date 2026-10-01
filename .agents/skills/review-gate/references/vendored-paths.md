# Reviewing byte-pinned vendored paths

For consumers that vendor an upstream tree byte-for-byte and merge re-vendor PRs. Suppressing duplicate upstream findings is a reviewer-instruction problem; configuration answers break the gate.

A committed `kendex refresh` tree is the other case, and every section here covers it with the two changes in § The harness-render variant at the foot.

## Review requirements

GitHub rulesets require approval at the current head and resolution of every inline review thread. A review body opens no thread. Do not exclude a path that can hold an entire pull request's diff: a pure re-vendor change would receive no review.

## The rule: route by remedy locus, not by path

Classify each finding by where the fix would land, and pick the surface:

| Where the fix lands | Surface |
|---|---|
| A repo-owned file — the vendor pin or checksum manifest, settings, CI wiring, adoption glue | Inline comment. In scope, keep it. |
| The vendored bytes themselves | Review body only. Upstream's call. |
| The vendored bytes, where the bump introduces a production-impacting regression that runs HERE — correctness, security, data loss | Inline comment, and it may block. See the carve-out below. |
| The upstream repo's own docs, config, or conventions | Review body only, or omit. |

The regression carve-out admits only a defect you would hold a release for — correctness, security, data loss. Style, naming, duplication, test layout, missing coverage stay in the review body.

An instruction that constrains only the REMEDY ("flag it, but do not ask for local edits") suppresses nothing: the thread still opens and still blocks. Constrain the surface.

### Reviewer classes — where a review body exists, and where it does not

Classify per reviewer, not per repo:

- **Summary-capable** — it authors its own review body. An upstream-remedy finding goes there and costs no thread.
- **Location-bound** — every finding is anchored to a file and line; its review body, where it has one, is a fixed template.

For a location-bound reviewer the rule is a BOUND: at most ONE consolidated comment per PR carrying every upstream-remedy finding together, anchored anywhere in the vendored tree.

**Accepted residual.** A reviewer whose output schema binds one finding to one location will still emit one thread per finding. Read the thread count as an observable, not as compliance, and answer those threads like any others: **a location-bound reviewer exceeding one thread is not by itself a failed rollout.**

Do not build an adapter that collects such findings and republishes them as a summary.

Classify each of the repo's reviewers before wiring, by reading a review body it posted on a recent PR: a body identical across PRs is a template, and that reviewer is location-bound.

## The consumer session's half

Once per re-vendor train, on ONE consumer PR, collect upstream-remedy findings from BOTH surfaces: the review bodies, AND EVERY vendored-path thread a location-bound reviewer left.

Use the reporting route in this skill's injected `## Project Instructions`. If no route is injected, return the defect to the orchestrating agent and user without filing.

The lock is the one judge, and it records provenance for every kind — skills, agents, hooks and Pi extensions alike. A name routes upstream when the lock holds at least one entry for it, narrowed to the kind the selector names, and EVERY matching entry's `source_repo` is kendex's own repo, the one candidate the comparison holds — an item vendored from anywhere else files against the LOCAL repo, and its issue is opened by hand. One entry recorded from somewhere else makes the name ambiguous and keeps the report local, which is also what an unlocked name gets. How the manifest spelled the repo does not decide it: a shorthand, an https URL and a `git@` reference fold to one identity. `--skill`, `--agent`, `--hook` and `--asset` are the selectors; with none of them the CLI warns once that ownership could not be determined and files against the LOCAL repo.

A repo that vendored only a scripts subtree, with no lock entry over it, has no name to select — open the upstream issue by hand. Confirm with `--dry-run` before relying on any of it.

Do not fix it locally, and do not file the same finding from each consumer.

## Wiring a repo

1. Copy [`../templates/vendored-paths.instructions.md`](../templates/vendored-paths.instructions.md) into the repo's path-scoped reviewer instruction directory — `.github/instructions/`, as a `*.instructions.md` file — set `applyTo` to the repo's actual vendored glob, and fill the placeholders. Repo-owned after the copy.
2. Check the glob against the paths a real re-vendor PR touches.
3. **Replace any existing instruction scoped to the same tree — do not add alongside it.** Merge any repo-specific carve-outs the old clause held into the new body.
4. Classify each reviewer the repo runs as summary-capable or location-bound (above). A repo whose reviewers are ALL location-bound gets a bounded improvement, not silence — decide whether that is worth the wiring.
5. Mirror the rule in the repo's reviewer-guidance file, for reviewers that do not read path-scoped instructions.
6. Keep the repository's GitHub approval and thread-resolution requirements unchanged.

## Verifying on a real re-vendor PR

Read the current head, its reviews and every unresolved thread before resolving a finding. Confirm that reviewers considered the changed files. A repository-owned finding or a production regression may hold the bump. A location-bound reviewer's thread count alone does not prove instruction failure.

## The harness-render variant

For consumers that commit `kendex refresh` output and merge refresh PRs. No pin covers that tree. Interactive refresh holds a hand edit until someone forks it or discards it. The rolling refresh preserves hand edits and refuses publication under the [SKILL.md refresh contract](../SKILL.md#scripts). Two things change; everything above holds.

**The rule is flat, with no carve-out.** The vendored rule routes upstream-remedy findings to the review summary body and keeps one carve-out for a correctness, security, or data-loss regression the bump introduces. One refresh lands in several repos at once, so that thread blocks the merge in each of them for a fix that can land in none. Over a render both go: no finding over the render on any surface, and a defect that would ship goes to the catalog repo and to the PR author out of band. Under a flat rule there is no on-PR surface left, which also removes the consolidated-comment fallback the vendored template gives a location-bound reviewer.

**File against the catalog repo only when this skill's injected `## Project Instructions` supplies a reporting route.** Follow that route and the same lock ownership rule as § The consumer session's half. With no injected route, return the defect to the orchestrating agent and user without filing. An item rendered from a third-party catalog carries that catalog in its lock entries and reports here instead, so open that issue by hand.

Wire it with the vendored template: copy it, set `applyTo` to the render trees, and apply its RENDER VARIANT block, which carries the replacement text for every paragraph the flat rule changes. Deleting the carve-out alone is not enough — the byte-pin opening, the summary-body route, the repo-owned bullet's pin clause and the consolidated-comment fallback all survive that one deletion and each contradicts the rule above. The trees kendex writes are `.agents/skills`, `.claude`, `.codex`, `.cursor`, `.gemini`, `.opencode`, `.pi`, and for Copilot the `agents`, `hooks`, and `skills` subtrees of `.github`. Each can also hold files kendex never writes, so the file list of a real refresh PR is the authority on the glob. Four shapes it must not take: the rest of `.github`; the harness memory files `CLAUDE.md`, `AGENTS.md` and `GEMINI.md`, which kendex writes none of; every `.agents/skills/<name>` an item declares `source = "in-place"`, whose content of record is edited here; and every path kendex merges its own entries into while the repo owns the rest, such as `.claude/settings.json`, `.codex/config.toml`, `.cursor/hooks.json`, `.mcp.json`, and the root `opencode.json`. That last shape is the one most worth keeping out: the instruction file the variant yields asserts that nothing under the glob is edited here, and over a merged path that is false — a glob one shape too wide silently suppresses correctness and security findings over a settings file this repo owns and can fix.

Verify per § Verifying on a real re-vendor PR, reading the render trees rather than the vendored one. **Pass** is stricter in one term: no unresolved thread over the render from a summary-capable reviewer, including none raising a correctness, security, or data-loss defect, which the flat rule routes to the catalog repo and the vendored carve-out would have admitted.
