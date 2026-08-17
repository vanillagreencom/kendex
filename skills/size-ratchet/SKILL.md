---
name: size-ratchet
description: "Tighten-only file-size gate: tracked files over the line threshold are frozen in a baseline TSV that only ever moves down. Load to add, tune, or debug the ratchet, its baseline, or SIZE_RATCHET_* settings."
license: MIT
user-invocable: true
metadata:
  author: vanillagreen
  source: vstack
  repository: "https://github.com/vanillagreencom/vstack"
  bugs: "https://github.com/vanillagreencom/vstack/issues"
  version: "1.0.0"
---

# Size Ratchet

> **Problem with this skill?** Run `vstack report` — it files to the owning repo automatically. Do not hand-file.

One check, one direction: **no tracked file gets bigger than the threshold,
and the files already over it only shrink.** Existing offenders are frozen
in a baseline at their current line counts; everything else — including
tests — must stay at or under the threshold. The baseline is a ratchet, not
a ledger: rows only go down or away, and the only way a number goes up is a
human editing the row in a reviewed diff.

```bash
.agents/skills/size-ratchet/scripts/size-ratchet            # check (pre-PR / CI)
.agents/skills/size-ratchet/scripts/size-ratchet --staged   # check what a commit records (git hook)
.agents/skills/size-ratchet/scripts/size-ratchet --update   # tighten the baseline
```

`--staged` judges the commit's snapshot: index blobs, and index policy.
Details in [README.md](README.md).

## Verdicts

`check` scans every tracked file (`git ls-files`) minus the exclusion list
and fails (exit 1) on any of:

| Failure | Meaning |
|---|---|
| **new offender** | Over the threshold with no baseline row. |
| **baselined file grew** | Actual lines exceed the file's baseline row. |
| **baseline looser than reality** | A row higher than the file's actual count, a row for a file now at/under the threshold, or a row for a file no longer tracked (or now excluded). Slack in the baseline is itself a failure — the ratchet must move down. |

Every diagnostic names the file, its count, and the threshold or baseline
row it violated, plus the remedies: *split at a concept seam, or raise the
baseline row in this diff with justification*.

Exit codes: `0` clean, `1` violations, `2` usage/config/collection error
(malformed baseline or excludes, bad threshold, a tracked path containing
a tab or newline, or a file the gate could not measure). Line counts are
newline counts (`wc -l`). A tracked file absent from the worktree
(unstaged deletion, sparse checkout) is counted from the INDEX blob — a
partial tree can neither smuggle a new offender past the gate nor loosen a
baselined row; an index blob that cannot be read is a collection error
(exit 2, naming the file), never a skip. A submodule gitlink at a tracked
path is not a countable file.

## `--update` — tighten only

`--update` rewrites the baseline to current reality in the downward
direction only: rows are lowered to the actual count or removed (file
shrank to/under the threshold, was deleted, or is now excluded). It **never
adds a row and never raises a number** — a grown file keeps its old row and
keeps failing, and a new offender stays a failure. Deliberate growth or a
new freeze is a hand-edit of the baseline TSV, visible in the diff. After
the rewrite the check re-runs, so `--update` exits 1 while growth or new
offenders remain.

## Configuration

Resolution order for every key: explicit environment > `.env.local`
(personal, untracked) > `.vstack/settings.toml` > the repo's committed
`vstack.settings.toml` (flat `KEY = "value"` under `[env]`) > `.env` >
built-in default. Only an ABSENT source is skipped: a source that exists
but is unusable — unreadable, a directory, FIFO, socket or device, or a
symlink that does not resolve — is a config error (exit 2), never a
fall-through to the next layer. `/dev/null` forces the built-in defaults.

| Key | Default | Meaning |
|---|---|---|
| `SIZE_RATCHET_THRESHOLD` | `1000` | Line threshold for new files. |
| `SIZE_RATCHET_BASELINE` | `tools/size-ratchet-baseline.tsv` | Baseline path (also `--baseline FILE`). |
| `SIZE_RATCHET_EXCLUDES` | `tools/size-ratchet-excludes` | Exclusion-list path (also `--excludes FILE`). |

**Baseline format** — `path<TAB>lines`, `LC_ALL=C` sorted, unique paths,
counts above the threshold. **Excludes format** — `pattern<TAB>reason` per
line (shell glob against the full repo-relative path; `*` crosses `/`);
blank lines and `#` comments are ignored, and a pattern without a reason is
a config error — every exclusion carries its justification (generated,
vendored, fixtures, lockfiles).

Formats, seeding a first baseline, and the migration note for repos already
using this format: [README.md](README.md).
