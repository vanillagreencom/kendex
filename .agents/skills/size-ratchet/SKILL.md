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

<!-- kendex:project-instructions:start -->
## Project Instructions

<!-- kendex:shared-instructions:start -->
Problems with a kendex-owned skill go through `kendex report`; check ownership in the file first.
<!-- kendex:shared-instructions:end -->
<!-- kendex:project-instructions:end -->

# Size Ratchet

**No tracked file gets bigger than its threshold, and files already over
it only shrink.** Existing offenders are frozen in a baseline at their
current sizes; everything else stays at or under its path class's
threshold. Markdown is measured in bytes and code in lines. Baseline rows
only go down or away while their unit stays the same. Reference and exception
rules are [README.md § Trusted HEAD baseline](README.md#trusted-head-baseline).

```bash
.agents/skills/size-ratchet/scripts/size-ratchet            # check (pre-PR / CI)
.agents/skills/size-ratchet/scripts/size-ratchet --staged   # check what a commit records (git hook)
.agents/skills/size-ratchet/scripts/size-ratchet --update   # tighten the baseline
.agents/skills/size-ratchet/scripts/size-ratchet --seed     # write the FIRST baseline
```

Flags, `SIZE_RATCHET_*` keys, and exit codes: `size-ratchet --help`.
Verdict classes, semantics, units, the shipped class list, baseline/excludes
formats, and seeding: [README.md](README.md). Collection and maintenance notes:
[DEVELOPMENT.md](DEVELOPMENT.md).

## Responding to a failure

Every size diagnostic names the file, its size, the baseline row it
violated, the deciding threshold (class pattern or default), and the remedy:
*split at a concept seam*.

Reference, repoint, raise, and unit-change behavior is one rule:
[README.md § Trusted HEAD baseline](README.md#trusted-head-baseline).
A shrunk row under `--staged` is already lowered and staged by the run itself.

**A NUL is refused, not measured.** Any tracked blob carrying a NUL in its
leading 8000 bytes is what git calls binary, whatever unit its class counts in
and whether or not the size exclusion list covers it. The gate exits 2 naming
the path and the byte's offset, in every mode, `--seed` and `--update`
included. Write the escape the language spells the byte with; a real binary
asset is declared `binary` or `-diff` in `.gitattributes`, the only exemption.

**Check composition before the seam.** A file over its cap whose bulk is
inline tests needs those tests moved to the language's separate-test
convention, not its concepts split; that move has no seam in it. In Rust
the measure is every line inside `#[cfg(test)]`, under any module name,
and past roughly 300 of them extraction comes first. Find a seam only if
what remains is still over.

**The ratchet serves cohesion, never defeats it.** The goal is files an
agent can load and reason about whole: one concept per file, whole
concept in the file. A *concept seam* is a boundary where the extracted
file stands alone: its reader never needs the source file open beside
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

**Raising a row** (`RATCHET_RAISE=1` on the invocation, reason in the
commit body) is correct in exactly two cases, both for hand-written files:
1. The added lines are the fix for the reported symptom and the file has
   no concept seam.
2. **Merging fragments**: files that are one concept read together are
   combined back into one, and the merged file's row rises to its real
   size. Read together means ping-pong calls, a helper file with one
   importer, "part 2" files. Shrink or delete the emptied rows in the
   same diff.

Which case applies is yours to judge and the gate's to ignore. The enforced
rule is [README.md § Trusted HEAD baseline](README.md#trusted-head-baseline).
Generated and vendored content is excluded from the counted set instead of
being raised.

The baseline is policy input, not a measured file. A self row is stale and
every rewrite removes it, so seed, update, and staged tightening converge in
one run.

**A threshold change requires a fragment sweep.** In either direction it
strands the splits made under the previous number: a repo that loosens already
holds those fragments, a repo that tightens is about to create them. A seam
that fits only the old number is not evidence of a seam. A change of UNIT is
a change of threshold too, since the number a path is judged against moves.
[references/threshold-change.md](references/threshold-change.md).
