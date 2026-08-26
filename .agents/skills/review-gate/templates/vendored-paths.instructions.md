---
applyTo: "[VENDORED_GLOB]"
---

<!-- Copy to .github/instructions/ as a *.instructions.md file, and fill:
     [VENDORED_GLOB] the vendored tree, whose root is per-repo — verify it
     against a real re-vendor PR's file list rather than assuming an install
     path; [UPSTREAM_REPO] the owning repository; [PIN_CHECK] the repo-owned
     control that fails on byte drift. Delete this comment.
     Verification protocol: review-gate references/vendored-paths.md. -->

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
