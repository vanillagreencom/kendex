---
applyTo: "[VENDORED_GLOB]"
---

<!-- Copy to .github/instructions/ as a *.instructions.md file, and fill:
     [VENDORED_GLOB] the vendored tree, whose root is per-repo — verify it
     against a real re-vendor PR's file list rather than assuming an install
     path; [UPSTREAM_REPO] the owning repository; [PIN_CHECK] the repo-owned
     control that fails on byte drift. Delete this comment.
     Verification protocol: review-gate references/vendored-paths.md.
     Over a committed `kendex refresh` tree, take the RENDER VARIANT at the
     foot of this file first: eight edits, and the result is the whole
     instruction file. Delete the variant with this comment either way. -->

This tree is vendored BYTE-PINNED from [UPSTREAM_REPO]; [PIN_CHECK] fails if
the bytes drift. The same reviewers see this content upstream before it
arrives.

**Route every finding by where its fix would land, and pick the surface from
that.**

- **The fix lands in a repo-owned file** — the vendor pin or checksum manifest,
  settings, CI wiring, adoption glue: comment inline as normal. A re-vendor
  that moves these bytes without updating the repo-owned pin is a real defect.
- **The fix lands in these vendored bytes**: put it in the REVIEW SUMMARY BODY,
  not an inline comment. Name the file and what is wrong; do not propose a
  diff. The remedy is upstream-then-re-vendor and cannot happen in this PR.
- **The fix lands in [UPSTREAM_REPO]'s own docs, config, or conventions** (its
  README, its settings tables, its test layout): summary body, or omit.

**Carve-out — a production-impacting regression these bytes introduce.** If
this bump brings in a correctness, security, or data-loss defect that will run
here, comment inline and say it blocks. The bar is a defect you would hold a
release for. Style, naming, duplication, test layout, missing coverage, and
"this could be cleaner" never qualify — those are the summary-body case above.

**If every finding you emit is anchored to a file location** — you have no
review body you author, only a fixed template — do not drop the finding and do
not spread it. Post ONE consolidated comment for this PR carrying every
upstream-remedy finding together, anchored anywhere in this tree. One thread
per reviewer per PR is the bound.

If your output contract binds one finding to one comment and consolidation is
genuinely unavailable to you, every comment you post must still state plainly
that the remedy is upstream and must not ask for a local edit.

**Do not stay silent instead.** Review the PR and submit a review: the merge
gate needs a review object at this head.

Also out of scope here, on any surface: local restructuring of this tree
(splitting files, style or naming changes, line-count limits, test
reorganization), requests for repo-local test suites over it, and cross-repo
sync timing — an upstream fix not yet re-vendored is a coordination note, never
a merge blocker.

<!-- ===================== RENDER VARIANT — DELETE THIS BLOCK =====================

For a committed `kendex refresh` tree rather than a byte-pinned vendored one.
No pin covers a render, an edit under it does not land, and one refresh reaches
several repos at once, so the rule is flat: no finding over the render on any
surface of this PR. reference: review-gate references/vendored-paths.md
§ The harness-render variant.

Apply all eight edits. A partial application leaves a file that contradicts
itself — the carve-out and the consolidated-comment paragraphs are the two
that most often survive and they are the two the flat rule forbids.

1. REPLACE the opening paragraph ("This tree is vendored BYTE-PINNED …") with:

   This tree is `kendex refresh` OUTPUT, rendered from the catalogs
   `kendex.toml` names. The same reviewers see this content in the catalog
   repo before it arrives here. Nothing under this glob is edited in this
   repo, and an edit here does not land: the next refresh reads the disk,
   finds bytes no apply wrote, and holds that item as a conflict, planning no
   write until someone forks it or discards the edit. A local fix does not
   reach the repos that share this render; it wedges this one's next refresh.

   [UPSTREAM_REPO] and [PIN_CHECK] do not apply and are not filled: a render
   has no pin, and its upstream is whichever catalog `kendex.toml` names.

2. REPLACE the first routing bullet ("The fix lands in a repo-owned file …")
   with:

   - **The fix lands in a repo-owned file** — settings
     (`kendex.settings.toml`), `kendex.toml`, the workflow that runs the
     refresh, CI wiring, adoption glue, and any config or settings file
     kendex merges its own entries into while the repo owns the rest
     (`.claude/settings.json`, `.codex/config.toml`, `.codex/hooks.json`,
     `.cursor/hooks.json`, `.cursor/mcp.json` and their kind): comment inline
     as normal, correctness and security defects included. On a refresh PR
     that is the most valuable finding there is, and it is why a glob one
     shape too wide is a real cost: it would suppress exactly these.

3. REPLACE the second routing bullet ("The fix lands in these vendored bytes":
   REVIEW SUMMARY BODY) with:

   - **The fix lands in these rendered bytes**: do not raise it on this PR, on
     any surface. The session that runs the refresh follows the reporting route
     in the review-gate skill's injected `## Project Instructions`. With no
     injected route, it returns the defect to the orchestrating agent and user
     without filing. The fix arrives here as a later render.

4. REPLACE the third routing bullet ("[UPSTREAM_REPO]'s own docs …") with:

   - **The fix lands in the catalog repo's own docs, config, or conventions**
     (its README, its settings tables, its test layout): same route.

5. REPLACE the carve-out paragraph ("**Carve-out — a production-impacting
   regression …**") with:

   **No carve-out.** Not inline, not in a review summary body, and not for a
   correctness, security, or data-loss defect the render would ship here —
   that one goes to the catalog repo too, and to the PR author out of band.
   The rule is flat so the route is the same in every consuming repo, and a
   defect in a render is fixable only where the render is written. A finding
   whose fix lands in a repo-owned file is a different thing and stays an
   ordinary inline comment.

6. REPLACE both location-bound paragraphs ("**If every finding you emit is
   anchored to a file location**…" and "If your output contract binds one
   finding to one comment…") with:

   **If every finding you emit is anchored to a file location** — you have no
   review body you author, only a fixed template — the rule does not soften.
   A finding over this tree is not yours to place anywhere on this PR; it goes
   to the catalog repo, and the review you submit carries no finding over the
   render.

7. In the last paragraph, replace "and cross-repo" with "and", and replace
   "sync timing — an upstream fix not yet re-vendored" with "refresh timing —
   an upstream fix not yet rendered". The phrase wraps in the body, so it is
   two edits on two lines rather than one search for the joined sentence.

8. REPLACE the silence paragraph ("**Do not stay silent instead.**") with:

   **Do not stay silent instead.** Review whatever else the PR touches and
   submit a review: the merge gate needs a review object at this head, so a
   skipped review blocks the merge as hard as an unanswered thread does. A PR
   touching only this tree gets a review with no findings.

The glob is the other half. § The harness-render variant in
references/vendored-paths.md names the four shapes it must not take; the
merged-path shape is the one edit 2 above depends on, since this file asserts
that nothing under the glob is edited here and over a merged path that is
false.

============================================================================ -->
