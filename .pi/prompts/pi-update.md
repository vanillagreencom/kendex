---
description: Audit vstack Pi extensions against every Pi package changelog since the last run, then apply needed fixes
---
Audit `pi-extensions/*` against **every Pi package changelog** for the releases published since this command last ran. Fetch the changelogs yourself — nothing is pasted. Compute the delta from the marker file, classify each new entry, apply the fixes that should ship, and leave the rest documented with reasoning.

## Intent
Pi ships all its packages in lockstep under one monorepo version (e.g. `0.82.0`). Each release adds entries across several package changelogs. This command finds every release newer than the last one we audited, unions the changelog entries across all packages plus the curated release notes, and decides — per entry — whether our extensions must change.

Do not invent work that isn't supported by a changelog entry; do not skip an entry that touches a surface we own. Earlier releases (at or below the marker version) are assumed already absorbed.

## Sources (fetch all — do not wait for a paste)
Authoritative per-package changelogs in `earendil-works/pi` on `main` (older links in the entries may say `pi-mono`; the live repo is `earendil-works/pi`):

| Key | Path |
|-----|------|
| `agent` | `packages/agent/CHANGELOG.md` |
| `ai` | `packages/ai/CHANGELOG.md` |
| `coding-agent` | `packages/coding-agent/CHANGELOG.md` |
| `server` | `packages/server/CHANGELOG.md` |
| `storage` | `packages/storage/sqlite-node/CHANGELOG.md` |
| `tui` | `packages/tui/CHANGELOG.md` |

Curated cross-package release notes (secondary cross-check, not authoritative for per-package detail): <https://pi.dev/news/releases>.

Fetch each changelog with `web_fetch` on its raw URL, e.g.
`https://raw.githubusercontent.com/earendil-works/pi/main/packages/coding-agent/CHANGELOG.md`
(fallback: `gh api repos/earendil-works/pi/contents/<path> -H "Accept: application/vnd.github.raw"`). All six share one version line — fetch all six; they will normally list the same new version headers.

Each changelog uses `## [x.y.z] - YYYY-MM-DD` headers with `### New Features / Added / Changed / Fixed / Removed` sub-sections. A leading `## [Unreleased]` block is not a release: scan it for a heads-up only, and never advance the marker to it.

## Delta since last run (marker file)
State lives in `pi-extensions/pi-update.state.json` (committed source; not a discovered extension — it has no `package.json`, and it sits beside the existing `pi-extensions/package-policy.test.mjs`). It is kept outside `.pi/` on purpose: `.pi/` is broadly gitignored and a marker there cannot be reliably re-included. Schema:
```json
{
  "lastVersion": "0.82.0",
  "lastDate": "2026-07-24",
  "lastRun": "2026-07-24T18:00:00Z",
  "lastRunHead": "<git sha at run start>",
  "sourcesCovered": ["agent", "ai", "coding-agent", "server", "storage", "tui", "releases"]
}
```

1. Read the marker. **In scope = every released version header `> lastVersion`** (semver) across all sources, newest processed last. If the top released version equals `lastVersion`, there is nothing to do — say so, still refresh the `lastRun`/`lastRunHead` timestamp, commit the marker, and stop.
2. **First run (marker absent):** do not silently process the entire history. Detect a candidate baseline (most recent Pi version referenced in `git log`, else the version bundled at `pi-extensions/pi-claude-bridge/node_modules/@earendil-works/pi-coding-agent/CHANGELOG.md`), then use the `question` tool to confirm the baseline version with the user before doing any work. Seed the marker at the confirmed baseline; only versions strictly greater are processed.
3. **Override:** if the user pastes a changelog or names an explicit version/range after the command, treat that as the authoritative item list, skip fetching, and still update the marker to the highest version covered.
4. **Update on success (even a no-op):** after the audit — whether or not any fix shipped — rewrite the marker with the newest processed version/date, a fresh `lastRun`, and the run-start `lastRunHead`, and commit it. The marker commit records "audited through vX.Y.Z" so the next run does not re-audit.

## Hard rules
- Do not bump any extension package version unless the user explicitly asks. `vstack refresh -g` ships behavior changes without a version bump.
- Do not bump the CLI version or cut a release; that is `/gh-release`.
- Do not npm-publish; that is `/npm-deploy`.
- Stage only intended files in each commit. Mention unrelated dirty files; stop and ask if anything looks unintentional.
- After every committed extension change, run `vstack refresh -g` and report which packages were updated. The Pi extension development workflow in `CLAUDE.md` is binding: commit first, then refresh.
- Do not claim "fixed" or "shipped" until commit + refresh both completed and reported.
- If you cannot live-test inside Pi, say so explicitly rather than asserting parity.

## Audit process
1. **Enumerate extensions.** `ls pi-extensions/` — every subdir with a `package.json` is in scope.
2. **Triage each new entry by package** (which of our extensions the source most likely touches):
   - `coding-agent` — tools, hooks, agent runtime, SDK fields, `settings.json`. Highest impact; touches nearly every extension (`pi-tool-renderer`, `pi-hooks`, `pi-agents-tmux`, `pi-task-panel`, `pi-questions`, `pi-qol`, `pi-output-policy`, `pi-skills-manager`, `pi-session-manager`, `pi-web-tools`, `pi-caveman`, `pi-claude-bridge`, `pi-codex-minimal-tools`, `pi-prompt-stash`, `pi-extension-manager`).
   - `ai` — provider/model SDK (constrained sampling, capability flags, catalogs). Mostly Non-impact unless we override a provider — grep the affected provider id first (see Notes).
   - `agent` — agent loop/primitives → `pi-agents-tmux`, `pi-session-bridge`.
   - `server` — RPC/server events → `pi-session-bridge` (RPC surface), `pi-web-tools`.
   - `storage` — session persistence → `pi-session-manager`, `pi-session-bridge`, `pi-prompt-stash`.
   - `tui` — terminal UI, rendering, popups → `pi-tool-renderer`, `pi-qol`, `pi-extension-manager`, `pi-skills-manager`.
3. **Classify each entry** into exactly one bucket:
   - **Required parity fix** — Pi core changed a behavior we override, mirror, or duplicate (e.g. a tool renderer we replace, a hook event shape, a `settings.json` field we read/write). Off-by-one bugs in helpers we copied count here.
   - **Optional improvement** — Pi exposed a new SDK field, helper, or event that could simplify our code, but our current code is still correct.
   - **Non-impact** — Pi core internals, provider/auth fixes, Windows/macOS platform fixes, theme picker UI, or other surfaces outside our extension code.
4. **For each Required and Optional item:**
   - Grep our extensions for the affected symbol/field/regex/file pattern. Cite the exact `path:line`.
   - If a referenced Pi-side field name is unclear, fetch the relevant Pi source file from <https://github.com/earendil-works/pi> to confirm before editing.
   - Decide: ship now, defer, or skip. Record reasoning.
5. **For Non-impact items:** one-line justification each — enough that re-reading the audit later confirms it was considered.

## Apply fixes
For every "ship now" item:
1. Edit the canonical extension files only — never touch `.pi/`, `.claude/`, `.opencode/`, `.codex/`, `.agents/`, `.cursor/` mirrors. (`pi-extensions/pi-update.state.json` is source state, not an extension — updating it is expected.)
2. If a fix touches a behavior covered by `hooks/*.sh`, mirror it in `pi-extensions/pi-hooks/extensions/hooks.ts` in the same commit (parity rule in `CLAUDE.md`).
3. If a fix changes user-visible behavior or settings, update the matching README/SKILL.md/`vstack.toml`/`.env.local.example` payload in the same commit.
4. Add or extend a unit test where the fix is testable in isolation (favor regression coverage on numeric helpers, parsers, off-by-one bugs).
5. Run any package-local test suite the fix touches. Document the result (pass/fail, count). If peer-dep imports prevent local execution, link the bundled Pi modules from `/usr/lib/node_modules/pi/node_modules/@earendil-works/*` into a temporary `node_modules/@earendil-works/` (symlinks only), run the tests, then remove the temp `node_modules/` and any generated lockfile so the working tree stays clean.
6. Group related fixes into one commit per logical change. Multi-package fixes for the same Pi changelog item belong in one commit with a subject listing the affected packages.
7. After commit(s), run `vstack refresh -g` and capture the "Pi package(s) updated" line.

## Final report
Produce a structured summary:
- **Releases covered:** `lastVersion` → newest processed version, with dates, and the source keys that carried new entries.
- **Classified entries:** count per bucket (Required / Optional / Non-impact).
- **Shipped:** commit hash + one-line subject for each commit; affected extensions; tests run with pass count.
- **Deferred / skipped (with reason):** Optional items not taken, plus the reasoning (e.g. "Pi exposes unified `details.patch` string; our renderer needs `StructuredDiff` tokens for split view, no net simplification").
- **Non-impact log:** bulleted list of entries with one-line justification.
- **Marker:** old → new `lastVersion`, and the commit that updated `pi-extensions/pi-update.state.json`.
- **Refresh result:** packages reported updated by `vstack refresh -g`.
- **Working tree:** confirm `git status --short` is clean.

## Notes
- All six package changelogs currently release in lockstep under one monorepo version, so `lastVersion` tracks the whole release. If a package ever diverges, split the marker to a per-source `{ key: version }` map and gate each source independently.
- Pi `pi update` only reconciles `git:` and `npm:` scheme entries in Pi's `settings.json`. Vstack-installed extensions live as path packages (`./packages/<name>`) so they are out of scope for Pi-side `pi update` git-ref reconcile changes; flag this explicitly when a changelog entry mentions `pi update`.
- Changes to model/provider config (Bedrock, Copilot, OpenCode Zen routing, `compat.*` flags) do not touch our extension surface unless we override a provider — confirm by grepping for the affected provider id before classifying as Non-impact.
- Read tool, bash tool, edit tool, write tool, and search/list tool renderers are owned by `pi-tool-renderer` and override Pi defaults. Pi core UX changes to these tools are a UX choice for us, not an automatic must-mirror; ask the user when default behavior diverges.
