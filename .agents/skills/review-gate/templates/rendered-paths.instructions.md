---
applyTo: "[RENDERED_GLOB]"
---

<!-- Copy to .github/instructions/ as a *.instructions.md file, and fill:
     [RENDERED_GLOB] — the harness trees this repo commits as `kendex refresh`
     output. Start from the project trees kendex writes into:
     `.agents/skills/**`, `.claude/**`, `.codex/**`, `.cursor/**`,
     `.gemini/**`, `.opencode/**`, `.pi/**`, and for Copilot
     `.github/agents/**`, `.github/hooks/**`, `.github/skills/**`. The shared
     tree is scoped to `skills` on purpose: `.agents/hooks` holds the repo's
     own adopted hook scripts. Those trees still hold files kendex never
     writes, and a glob covering one tells this repo's reviewers to skip its
     own content. Keep OUT: `.github/**` past those three subtrees; the
     harness memory files CLAUDE.md, AGENTS.md, GEMINI.md; every
     `.agents/skills/<name>` an item declares in-place; and every structured
     config or settings file kendex merges into rather than owns.
     § Deriving the glob in review-gate references/rendered-paths.md names
     each one and how to derive it here. Delete this comment. -->

This tree is `kendex refresh` OUTPUT, rendered from the catalogs `kendex.toml`
names. The same reviewers see this content in the catalog repo before it
arrives here.

Nothing under this glob is edited in this repo. The next refresh overwrites
these files wholesale, so a local fix reads as closed while the bytes go back.
No pin covers them and nothing turns red on drift. Both statements are about
the files this glob names and nothing else — a settings or config file kendex
merges its own entries into is repo-owned, and the rules below never apply to
one.

**Route every finding by where its fix would land, and pick the surface from
that.**

- **The fix lands in a repo-owned file** — settings (`kendex.settings.toml`),
  `kendex.toml`, the workflow that runs the refresh, CI wiring, adoption glue,
  and any config or settings file kendex merges entries into while the repo
  owns the rest (`.claude/settings.json`, `.codex/config.toml`,
  `.codex/hooks.json`, `.cursor/hooks.json`, `.cursor/mcp.json` and their
  kind): comment inline as normal, correctness and security defects included.
  On a refresh PR that is the most valuable finding there is.
- **The fix lands in these rendered bytes**: do not raise it on this PR, on
  any surface. It is filed against the catalog repo by the session that runs
  the refresh, and the fix arrives here as a later render.
- **The fix lands in the catalog repo's own docs, config, or conventions**
  (its README, its settings tables, its test layout): same route.

**No carve-out.** Not inline, not in a review summary body, and not for a
correctness, security, or data-loss defect the render would ship here — that
one goes to the catalog repo too, and to the PR author out of band. The rule
is flat so the route is the same in every consuming repo, and a defect in a
render is fixable only where the render is written. A finding whose fix lands
in a repo-owned file is a different thing and stays an ordinary inline
comment.

One refresh lands in several repos at once. Every inline comment opens a
thread that blocks the merge until someone answers it, so one finding over
these bytes costs one blocking thread per reviewer per repo, over content
nobody here can change.

**If every finding you emit is anchored to a file location** — you have no
review body you author, only a fixed template — the rule does not soften. A
finding over this tree is not yours to place anywhere on this PR; it goes to
the catalog repo, and the review you submit carries no finding over the
render.

**Do not stay silent instead.** Review whatever else the PR touches and submit
a review: the merge gate needs a review object at this head, so a skipped
review blocks the merge as hard as an unanswered thread does. A PR touching
only this tree gets a review with no findings.

Also out of scope here, on any surface: local restructuring of this tree
(splitting files, style or naming changes, line-count limits, test
reorganization), requests for repo-local test suites over it, and refresh
timing — an upstream fix not yet rendered is a coordination note, never a
merge blocker.
