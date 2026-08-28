---
applyTo: "[RENDERED_GLOB]"
---

<!-- Copy to .github/instructions/ as a *.instructions.md file, and fill:
     [RENDERED_GLOB] — the harness trees this repo commits as `kendex refresh`
     output. Start from the project trees kendex writes: `.agents/**`,
     `.claude/**`, `.codex/**`, `.cursor/**`, `.gemini/**`, `.opencode/**`,
     `.pi/**`, and for Copilot `.github/agents/**`, `.github/hooks/**`,
     `.github/skills/**`. Drop what this repo does not commit, then check the
     rest against a real refresh PR's file list. Two things this glob must NOT
     cover: `.github/**` past those three subtrees, and the `.agents` subtree
     of any item `kendex.toml` marks `source = "in-place"` — that content is
     this repo's own. Delete this comment.
     Wiring protocol: review-gate references/rendered-paths.md. -->

This tree is `kendex refresh` OUTPUT, rendered from the catalogs `kendex.toml`
names. The same reviewers see this content in the catalog repo before it
arrives here.

Nothing here is edited in this repo. The next refresh overwrites the tree
wholesale, so a local fix reads as closed while the bytes go back. No pin
covers it and nothing turns red on drift.

**Route every finding by where its fix would land, and pick the surface from
that.**

- **The fix lands in a repo-owned file** — settings (`kendex.settings.toml`),
  `kendex.toml`, the workflow that runs the refresh, CI wiring, adoption glue:
  comment inline as normal. On a refresh PR that is the most valuable finding
  there is.
- **The fix lands in these rendered bytes**: do not raise it on this PR. The
  remedy is `kendex report`, which files it against the repo that owns the
  item, and the fix arrives here as a later render.
- **The fix lands in the catalog repo's own docs, config, or conventions**
  (its README, its settings tables, its test layout): same route.

**No carve-out.** Not inline, not in a review summary body, and not for a
correctness, security, or data-loss defect the render would ship here — report
that one upstream and tell the PR author out of band. The rule is flat so the
route is the same in every consuming repo, and a defect in a render is fixable
only where the render is written. A finding whose fix lands in a repo-owned
file is a different thing and stays an ordinary inline comment.

One refresh lands in several repos at once. Every inline comment opens a
thread that blocks the merge until someone answers it, so one finding over
these bytes costs one blocking thread per reviewer per repo, over content
nobody here can change.

**If every finding you emit is anchored to a file location** — you have no
review body you author, only a fixed template — do not drop the finding and do
not spread it. Post ONE consolidated comment for this PR carrying every such
finding together, anchored anywhere in this tree, and say in it that the
remedy is upstream and that no local edit is wanted. One thread per reviewer
per PR is the bound.

**Do not stay silent instead.** Review whatever else the PR touches and submit
a review: the merge gate needs a review object at this head, so a skipped
review blocks the merge as hard as an unanswered thread does. A PR touching
only this tree gets a review with no findings.

Also out of scope here, on any surface: local restructuring of this tree
(splitting files, style or naming changes, line-count limits, test
reorganization), requests for repo-local test suites over it, and refresh
timing — an upstream fix not yet rendered is a coordination note, never a
merge blocker.
