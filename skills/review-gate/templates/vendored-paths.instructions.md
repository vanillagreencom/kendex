---
applyTo: "[VENDORED_GLOB]"
---

<!-- Copy to .github/instructions/ as a *.instructions.md file, and fill:
     [VENDORED_GLOB] the vendored tree, whose root is per-repo — verify it
     against a real re-vendor PR's file list rather than assuming an install
     path; [UPSTREAM_REPO] the owning repository; [PIN_CHECK] the repo-owned
     control that fails on byte drift. Delete this comment.
     Rationale and the verification protocol: review-gate
     references/vendored-paths.md. -->

This tree is vendored BYTE-PINNED from [UPSTREAM_REPO] — the bytes reviewed
upstream are the bytes that run here, and [PIN_CHECK] fails if they drift. The
same reviewers see this content upstream before it ever arrives.

**Route every finding by where its fix would land, and pick the surface from
that.**

- **The fix lands in a repo-owned file** — the vendor pin or checksum manifest,
  settings, CI wiring, adoption glue: comment inline as normal. A re-vendor
  that moves these bytes without updating the repo-owned pin is a real defect,
  and the most valuable finding on this PR class.
- **The fix lands in these vendored bytes**: put it in the REVIEW SUMMARY BODY,
  not an inline comment. Name the file and what is wrong; do not propose a
  diff. A local edit here forks the pinned surface, which is what the pin check
  exists to prevent — the remedy is upstream-then-re-vendor and cannot happen
  in this PR.
- **The fix lands in [UPSTREAM_REPO]'s own docs, config, or conventions** (its
  README, its settings tables, its test layout): summary body, or omit. This
  repo cannot act on it.

Every inline comment opens a review thread that blocks the merge until someone
answers it, and this PR class lands in several consuming repos at once — one
upstream finding costs one blocking thread per reviewer per repo. The summary
body carries the same finding at no such cost and is harvested upstream once
per re-vendor train.

**If every finding you emit is anchored to a file location** — you have no
review body you author, only a fixed template — then do not drop the finding
and do not spread it. Post ONE consolidated comment for this PR carrying every
upstream-remedy finding together, anchored anywhere in this tree. One thread
per reviewer per PR is the bound; one thread per finding is what this
instruction exists to prevent.

**Do not stay silent instead.** Review the PR and submit a review: the merge
gate needs a review object at this head, so a skipped review blocks the merge
as hard as an unanswered thread does.

Also out of scope here, on any surface: local restructuring of this tree
(splitting files, style or naming changes, line-count limits, test
reorganization), requests for repo-local test suites over it, and cross-repo
sync timing — an upstream fix not yet re-vendored is a coordination note, never
a merge blocker.
