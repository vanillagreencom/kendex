---
name: size-ratchet
description: "Load to add, tune, or debug the size ratchet, its baseline, or SIZE_RATCHET_* settings."
summary: "Tighten-only file-size gate: tracked files over their threshold are frozen in a baseline TSV that only moves down."
license: MIT
user-invocable: true
metadata:
  author: vanillagreen
  source: kendex
  repository: "https://github.com/vanillagreencom/kendex"
  bugs: "https://github.com/vanillagreencom/kendex/issues"
  version: "1.0.0"
tags: [automation]
---

# Size Ratchet

> **Problem with this skill?** Run `kendex report` — it files to the owning repo automatically. Do not hand-file.

**No tracked file gets bigger than its threshold, and files already over
it only shrink.** Existing offenders are frozen in a baseline at their
current line counts; everything else stays at or under its path class's
threshold. Baseline rows only go down or away; a number goes up only by a
human editing the row in a reviewed diff.

```bash
.agents/skills/size-ratchet/scripts/size-ratchet            # check (pre-PR / CI)
.agents/skills/size-ratchet/scripts/size-ratchet --staged   # check what a commit records (git hook)
.agents/skills/size-ratchet/scripts/size-ratchet --update   # tighten the baseline
.agents/skills/size-ratchet/scripts/size-ratchet --seed     # write the FIRST baseline
```

Flags, `SIZE_RATCHET_*` keys, and exit codes: `size-ratchet --help`.
Verdict classes, semantics, baseline/excludes formats, path classes, and
seeding: [README.md](README.md). Collection internals and the migration
note for repos already using this format: [DEVELOPMENT.md](DEVELOPMENT.md).

## Responding to a failure

Every diagnostic names the file, its count, the baseline row it violated,
the deciding threshold (class pattern or default), and the remedy: *split
at a concept seam*.

**The ratchet serves cohesion, never defeats it.** The goal is files an
agent can load and reason about whole: one concept per file, whole
concept in the file. A *concept seam* is a boundary where the extracted
file stands alone — its reader never needs the source file open beside
it. For a file offered as one, count the names it imports straight from
its parent (`use super::{...}`): a real seam sits near zero, and
`use super::*` is an automatic failure. Moving half a function, a helper
only one caller uses, or "part 2 of X" into a second file to duck the
count is worse than the long file: prefer the raise.

**Three Rust shapes are that move, whatever the seam is called.**
1. `#[path = "<sibling>.rs"]` on a private `mod` that exists to hold the
   parent's lines. `#[path]` chosen for any other reason, a test module,
   a `cfg`-selected alternative, names a real seam.
2. A hub declaring `mod child;` then `use child::*`, with every spoke
   opening `use super::*`. The split is invisible by construction, so no
   seam is load-bearing and every spoke reaches whatever its siblings
   widened for the hub's glob. A hub carries declarations, narrow
   orchestration, and stable exports. A spoke depends on the hub's shared
   types or on a lower shared module, never on a sibling's internals.
3. A file whose only top-level items are inherent `impl` blocks on a type
   its parent declares. That file is part 2 of the type by construction.

A file header that justifies the file's existence by a line threshold is
the author writing down that the seam is not real.

**Raising a row** (`RATCHET_RAISE=1`, reason in the commit body) is
correct in exactly two cases, both for hand-written files:
1. The added lines are the fix for the reported symptom and the file has
   no concept seam.
2. **Merging fragments**: files that are one concept read together —
   ping-pong calls, a helper file with one importer, "part 2" files —
   are combined back into one, and the merged file's row rises to its
   real size. Shrink or delete the emptied rows in the same diff.

Never raise for tests, docs, comments, or lines a review round asked
for — those either fit, split at a real seam, or do not belong. **The gate
enforces the test half itself**: a baseline row for a test-class path that
is absent from HEAD's baseline, or lower there, fails whatever the commit
declares. Rows already at HEAD are grandfathered. Generated
and vendored content is never raised either: it is excluded (the
exclusion list, `pattern<TAB>reason`) and leaves the counted set.

**A threshold change requires a fragment sweep.** In either direction it
strands the splits made under the previous number: a repo that loosens already
holds those fragments, a repo that tightens is about to create them. A seam
that fits only the old number is not evidence of a seam.
[references/threshold-change.md](references/threshold-change.md).
