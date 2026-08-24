---
name: size-ratchet
description: "Tighten-only file-size gate: tracked files over their threshold (default 400, per-class via SIZE_RATCHET_CLASSES) are frozen in a baseline TSV that only moves down. Load to add, tune, or debug the ratchet, its baseline, or SIZE_RATCHET_* settings."
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

`--staged` judges the commit's snapshot: index blobs, and index policy.
Details in [DEVELOPMENT.md](DEVELOPMENT.md).

## Verdicts

`check` scans every tracked file (`git ls-files`) minus the exclusion list
and fails (exit 1) on any of:

| Failure | Meaning |
|---|---|
| **new offender** | Over its threshold with no baseline row. |
| **baselined file grew** | Actual lines exceed the file's baseline row. |
| **baseline looser than reality** | A row higher than the file's actual count, for a file now at/under its threshold, or for a file that is untracked or excluded. |

Every diagnostic names the file, its count, the baseline row it violated,
the deciding threshold (class pattern or default), and the remedy: *split
at a concept seam*.

**The ratchet serves cohesion, never defeats it.** The goal is files an
agent can load and reason about whole: one concept per file, whole
concept in the file. A *concept seam* is a boundary where the extracted
file stands alone — its reader never needs the source file open beside
it. Moving half a function, a helper only one caller uses, or "part 2 of
X" into a second file to duck the count is worse than the long file:
prefer the raise.

**Raising a row** (`RATCHET_RAISE=1`, reason in the commit body) is
correct in exactly two cases, both for hand-written files:
1. The added lines are the fix for the reported symptom and the file has
   no concept seam.
2. **Merging fragments**: files that are one concept read together —
   ping-pong calls, a helper file with one importer, "part 2" files —
   are combined back into one, and the merged file's row rises to its
   real size. Shrink or delete the emptied rows in the same diff.

Never raise for tests, docs, comments, or lines a review round asked
for — those either fit, split at a real seam, or do not belong. Generated
and vendored content is never raised either: it is excluded (the
exclusion list, `pattern<TAB>reason`) and leaves the counted set.

Exit codes: `0` clean, `1` violations, `2` usage/config/collection error
(malformed baseline or excludes, bad threshold, a tracked path containing
a tab or newline, or a file the gate could not measure). Line counts are
newline counts (`wc -l`). A tracked file absent from the worktree
(unstaged deletion, sparse checkout) is counted from the INDEX blob; an
unreadable index blob is a collection error (exit 2, naming the file),
never a skip. A submodule gitlink at a tracked path is not a countable file.

## `--update` — tighten only

`--update` lowers rows to the actual count or removes them (file shrank
to/under its threshold, was deleted, or is now excluded). It **never adds a
row and never raises a number**: a grown file keeps its old row and keeps
failing; a new offender stays a failure. Deliberate growth or a new freeze
is a hand-edit of the baseline TSV. After the rewrite the check re-runs;
`--update` exits 1 while growth or new offenders remain.

## `--seed` — bootstrap only

`--seed` writes the FIRST baseline: every tracked, non-excluded file over
its threshold enters at its current count, sorted, with a self-row when the
baseline outgrows its own threshold. It refuses if the baseline already has
rows in the worktree, the index or `HEAD`. Commit the seeded file.

## Configuration

Resolution order for every key: explicit environment > `.env.local`
(personal, untracked) > `.kendex/settings.toml` > the repo's committed
`kendex.settings.toml` (flat `KEY = "value"` under `[env]`) > `.env` >
built-in default. Only an ABSENT source is skipped: a source that is
unreadable, a directory, FIFO, socket, device, or a dangling symlink is a
config error (exit 2). `SIZE_RATCHET_SETTINGS_FILE=/dev/null` skips
`.env.local`, the settings file and `.env`, leaving environment variables
and the defaults.

| Key | Default | Meaning |
|---|---|---|
| `SIZE_RATCHET_THRESHOLD` | `400` | Line threshold for paths matching no class. |
| `SIZE_RATCHET_CLASSES` | *(none)* | `pattern=threshold` entries separated by `;`, first match wins. |
| `SIZE_RATCHET_BASELINE` | `tools/size-ratchet-baseline.tsv` | Baseline path (also `--baseline FILE`). |
| `SIZE_RATCHET_EXCLUDES` | `tools/size-ratchet-excludes` | Exclusion-list path (also `--excludes FILE`). |

**Path classes** — a file's threshold is the first `SIZE_RATCHET_CLASSES`
pattern it matches, else `SIZE_RATCHET_THRESHOLD`. Patterns use the excludes
file's glob syntax; a class only changes the number a path is judged against:

```toml
SIZE_RATCHET_CLASSES = "tests/*=800;*/tests/*=800;*.test.*=800"
```

A directory name needs both forms: root-level `tests/` matches only
`tests/*`, nested ones only `*/tests/*`.

A malformed entry (no `=`, an empty pattern, a non-positive-integer
threshold) is a config error naming the entry; an unset or empty value is
single-threshold behavior.

**Baseline format** — `path<TAB>lines`, `LC_ALL=C` sorted, unique paths,
counts above the path's threshold. **Excludes format** — `pattern<TAB>reason` per
line (shell glob against the full repo-relative path; `*` crosses `/`);
blank lines and `#` comments are ignored; a pattern without a reason is
a config error.

Formats, path classes, and seeding a first baseline: [README.md](README.md).
Collection internals and the migration note for repos already using this
format: [DEVELOPMENT.md](DEVELOPMENT.md).
