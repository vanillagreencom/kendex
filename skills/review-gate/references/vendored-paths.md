# Reviewing byte-pinned vendored paths

For consumers that vendor an upstream tree byte-for-byte and merge re-vendor PRs. Suppressing duplicate upstream findings is a reviewer-instruction problem. Configuration answers break the gate.

A committed `kendex refresh` tree is the other case. Every section here covers it, with the two changes in § The harness-render variant at the foot.

## Review requirements

GitHub rulesets require approval at the current head and resolution of every inline review thread. A review body opens no thread.

Do not exclude a path that can hold an entire pull request's diff: a pure re-vendor change would receive no review.

## The rule: route by remedy locus, not by path

Classify each finding by where the fix would land, and pick the surface:

| Where the fix lands | Surface |
|---|---|
| A repo-owned file: the vendor pin or checksum manifest, settings, CI wiring, adoption glue | Inline comment |
| The vendored bytes themselves | Review body only |
| The vendored bytes, where the bump introduces a production-impacting regression that runs HERE | Inline comment, which may block |
| The upstream repo's own docs, config, or conventions | Review body only, or omit |

- A repo-owned finding is in scope. Keep it.
- A finding in the vendored bytes is upstream's call.
- The regression carve-out admits only a defect you would hold a release for: correctness, security, data loss. Style, naming, duplication, test layout and missing coverage stay in the review body.

An instruction that constrains only the REMEDY ("flag it, but do not ask for local edits") suppresses nothing: the thread still opens and still blocks. Constrain the surface.

### Reviewer classes — where a review body exists, and where it does not

Classify per reviewer, not per repo:

- **Summary-capable** — it authors its own review body. An upstream-remedy finding goes there and costs no thread.
- **Location-bound** — every finding is anchored to a file and line. Its review body, where it has one, is a fixed template.

For a location-bound reviewer the rule is a BOUND: at most ONE consolidated comment per PR carrying every upstream-remedy finding together, anchored anywhere in the vendored tree.

**Accepted residual.** A reviewer whose output schema binds one finding to one location will still emit one thread per finding.

- Read the thread count as an observable, not as compliance.
- Answer those threads like any others.
- **A location-bound reviewer exceeding one thread is not by itself a failed rollout.**

Do not build an adapter that collects such findings and republishes them as a summary.

Classify each of the repo's reviewers before wiring, by reading a review body it posted on a recent PR. A body identical across PRs is a template, and that reviewer is location-bound.

## The consumer session's half

Once per re-vendor train, on ONE consumer PR, collect upstream-remedy findings from BOTH surfaces: the review bodies, AND EVERY vendored-path thread a location-bound reviewer left.

Use the reporting route in this skill's injected `## Project Instructions`. If no route is injected, return the defect to the orchestrating agent and user without filing.

With a route, file through `kendex report`:

- Use the item and kind selectors in `kendex report --help`. With no selector, the CLI warns and reports against the local repo.
- Unresolved ownership or a third-party origin keeps the report local. Open the third-party issue by hand.
- A repo that vendored only a scripts subtree, with no item provenance to select, also reports upstream by hand.
- Confirm the destination with `--dry-run` before filing.

Do not fix it locally, and do not file the same finding from each consumer.

## Wiring a repo

1. Copy [`../templates/vendored-paths.instructions.md`](../templates/vendored-paths.instructions.md) into the repo's path-scoped reviewer instruction directory, `.github/instructions/`, as a `*.instructions.md` file. The copy is repo-owned.
2. Set `applyTo` to the repo's actual vendored glob.
3. Fill the placeholders.
4. Check the glob against the paths a real re-vendor PR touches.
5. **Replace any existing instruction scoped to the same tree — do not add alongside it.** Merge any repo-specific carve-outs the old clause held into the new body.
6. Classify each reviewer the repo runs as summary-capable or location-bound (above). A repo whose reviewers are ALL location-bound gets a bounded improvement, not silence. Decide whether that is worth the wiring.
7. Mirror the rule in the repo's reviewer-guidance file, for reviewers that do not read path-scoped instructions.
8. Keep the repository's GitHub approval and thread-resolution requirements unchanged.

## Verifying on a real re-vendor PR

- Read the current head, its reviews and every unresolved thread before resolving a finding.
- Confirm that reviewers considered the changed files.

A repository-owned finding or a production regression may hold the bump.

## The harness-render variant

For consumers that commit `kendex refresh` output and merge refresh PRs. No pin covers that tree. Interactive refresh holds a hand edit until someone forks it or discards it. The rolling refresh preserves hand edits and refuses publication under the [refresh publication contract](adoption.md#publication). Two things change; everything above holds.

**The rule is flat, with no carve-out.** Over a render, no finding goes on any surface, and a defect that would ship goes to the catalog repo and to the PR author out of band.

- The vendored rule routes upstream-remedy findings to the review summary body, and keeps one carve-out for a correctness, security, or data-loss regression the bump introduces. Over a render both go.
- One refresh lands in several repos at once, so a carve-out thread blocks the merge in each of them for a fix that can land in none.
- Under a flat rule there is no on-PR surface left, which also removes the consolidated-comment fallback the vendored template gives a location-bound reviewer.

**File against the catalog repo only when this skill's injected `## Project Instructions` supplies a reporting route.**

- Follow that route and the same filing steps as § The consumer session's half.
- With no injected route, return the defect to the orchestrating agent and user without filing.
- An item rendered from a third-party catalog reports locally instead, so open that catalog's issue by hand.

Wire it with the vendored template:

1. Copy it.
2. Set `applyTo` to the render trees.
3. Apply its RENDER VARIANT block, which carries the replacement text for every paragraph the flat rule changes. Deleting the carve-out alone is not enough: the byte-pin opening, the summary-body route, the repo-owned bullet's pin clause and the consolidated-comment fallback all survive that one deletion, and each contradicts the rule above.

Select paths from the actual refresh PR and its committed `.kendex-generated.json`, rather than assuming every file in a harness directory is rendered. The glob must not take four shapes:

- the rest of `.github`;
- the harness instruction files `CLAUDE.md`, `AGENTS.md` and `GEMINI.md`, which remain outside this render-review rule;
- every `.agents/skills/<name>` an item declares `source = "in-place"`, whose content of record is edited here;
- every path kendex merges its own entries into while the repo owns the rest, such as `.claude/settings.json`, `.codex/config.toml`, `.cursor/hooks.json`, `.mcp.json`, and the root `opencode.json`.

The instruction file the variant yields asserts that nothing under the glob is edited here. A glob that includes a merged path would suppress correctness and security findings over a settings file this repo owns and can fix.

Verify per § Verifying on a real re-vendor PR, reading the render trees rather than the vendored one. **Pass** is stricter in one term: no unresolved thread over the render from a summary-capable reviewer, including none raising a correctness, security, or data-loss defect, which the flat rule routes to the catalog repo and the vendored carve-out would have admitted.
