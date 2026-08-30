# Threshold change sweep

Run this before a changed `SIZE_RATCHET_THRESHOLD`, `SIZE_RATCHET_CLASSES`,
`SIZE_RATCHET_DEFAULT_CLASSES` or `SIZE_RATCHET_FROZEN_CLASSES` entry lands, in
either direction, and when an entry changes UNIT — the number a path is judged
against moves either way. The frozen list moves it too, through the class
inversion in [README.md § Path
classes](../README.md#path-classes): a glob added or removed there moves
matching paths between a repo class and a shipped one. Run it at `--seed` too when
the repo already had a prose size rule: seeding records no row for an
under-threshold fragment, so the repo inherits that rule's fragments and
nothing else points at them.

Sweep the tracked files whose deciding threshold, or its unit, differs
between the old configuration and the new (`git ls-files`, minus the
exclusion list).

## Predicates

Each one names a candidate, not a verdict. Read the file before acting.

1. **One real importer.** A non-barrel source file whose exported names are
   imported by exactly one other file. Separate re-exports from imports before
   counting, or a package index masks every candidate behind itself.
2. **Mutual imports.** Two files that import each other. Read the pair as one
   file before judging either half.
3. **`<parent>-<qualifier>` names.** A file named for another file plus a
   suffix (`-shared`, `-helpers`, `-reads`, `-run`, `part2`) with one consumer.

Predicate 1 alone is too noisy to act on. A large tree yields hundreds of
single-importer files that are real modules. Predicates 2 and 3 are what
separate a line move from a seam.

## Parsing caveats

Two shapes defeat the obvious import regex.

- **A multi-line import whose closing brace sits at column 0** escapes a
  line-anchored pattern. Match the whole statement.
- **A path inside a comment** (`{@link import("./x.ts")}`) reads as a real
  edge. Strip comments before the cycle pass.

## Disposition

Open the candidate beside its importer. If its reader needs that file open to
follow it, it is a fragment: merge it back and take every baseline-row
consequence from [SKILL.md](../SKILL.md) § Responding to a failure. If it
stands alone, it is a module. Leave it.
