# size-ratchet

A tighten-only gate on file size. No tracked file gets bigger than its threshold, and files already over it only shrink: they are frozen in a baseline at their current sizes, and a row's number may only go down while its unit stays the same. Markdown is measured in bytes and code in lines. For a repository that wants files an agent can load and reason about whole, with growth stopped at commit time rather than noticed in review.

## Install

```bash
kendex add vanillagreencom/kendex --skill size-ratchet
.agents/skills/size-ratchet/scripts/size-ratchet --seed
```

Needs `git`, `awk` and the usual POSIX userland; Bash 3.2 is enough. `--seed` writes the first baseline, uncommitted, so the initial freeze is a reviewed diff; the rules are under [Seeding a first baseline](#seeding-a-first-baseline). Where `growth-guards` is installed its pre-commit chain runs `size-ratchet --staged` itself.

## What it does

- Fails a new offender: a file over its threshold with no baseline row.
- Fails growth: a baselined file whose actual size exceeds its row.
- Fails a baseline looser than reality: a row above the file's size, a row for a file now under its threshold, or a row for a file that left the tracked set. Stale slack is a failure, not headroom.
- Fails a row in the wrong unit, and a row added, raised or changed to another unit against the trusted baseline.
- Refuses to measure a blob carrying a NUL in its leading 8000 bytes, git's own text rule, naming the path and the byte's offset; the one exemption is a path `.gitattributes` gives `binary` or `-diff`.

## How it works

```bash
.agents/skills/size-ratchet/scripts/size-ratchet            # check (pre-PR / CI)
.agents/skills/size-ratchet/scripts/size-ratchet --staged   # check what a commit records (git hook)
.agents/skills/size-ratchet/scripts/size-ratchet --update   # tighten the baseline
.agents/skills/size-ratchet/scripts/size-ratchet --seed     # write the FIRST baseline
```

Every tracked file is measured, tests included, minus the exclusion list and the baseline itself. A class threshold counts lines when it is a bare number and bytes when it carries the `k` suffix (`24k` is 24×1024 bytes). Each file resolves to exactly one threshold through [Path classes](#path-classes), and every verdict runs per file against it.

`--staged` counts index blobs, what the commit records, and runs the tighten-only rewrite itself, staging the baseline so a commit that shrinks a limited file passes on the first attempt. `--update` lowers rows to the actual size, re-measures rows whose unit changed, and removes rows for files now at or under their threshold or out of the counted set; it never adds a row or raises a same-unit number. Exit codes: `0` clean, `1` violations, `2` usage, config or collection error. Flags: `size-ratchet --help`. Mechanism: [DEVELOPMENT.md](DEVELOPMENT.md).

## Trusted HEAD baseline

Every mode judges the candidate baseline against one reference: HEAD's copy of the baseline. `--baseline` or a process `SIZE_RATCHET_BASELINE` names that path directly; otherwise the settings sources as HEAD carries them select it, and a source with no historical form (an absolute or escaping path, an untracked `.env.local`) refuses the run if it assigns the key rather than guessing. The rows at that HEAD path are the only reference, even when the candidate uses another path or its target already held dormant rows. Repoint in a commit that changes nothing else, then change its rows next; the gate does not check that sequence. No rows at the selected path is a true bootstrap, and the verdict line says so.

For a candidate row in the same unit, the reference number is its ceiling. A larger open row, or a first row beside an existing reference set, needs `RATCHET_RAISE=1` on the invocation; a frozen row never rises. When the units differ the numbers are not compared: an open row needs the same declaration, and a frozen row is admitted only at this run's measurement of the file, and only while that sits at or below HEAD's blob in the same unit. The gate reads no commit message, so put the declaration's reason in the commit body.

## Path classes

A file's threshold is the first entry whose pattern matches its full repo-relative path across `SIZE_RATCHET_CLASSES`, then `SIZE_RATCHET_DEFAULT_CLASSES`, else `SIZE_RATCHET_THRESHOLD`. Patterns are shell globs (`*` crosses `/`), and `;` separates entries. The package ships this list, most specific entry first:

| Class | Threshold |
|---|---|
| `docs/architecture/overview.md` | 12k bytes |
| `docs/architecture/*.md` | 16k bytes |
| `AGENTS.md` | 16k bytes |
| `CLAUDE.md` and nested `*/CLAUDE.md` | 24k bytes |
| nested `*/AGENTS.md` | 6k bytes |
| `*/SKILL.md` | 24k bytes |
| `README.md` | 16k bytes |
| nested `*/README.md` | 12k bytes |
| `*/workflows/*.md` | 40k bytes |
| every other `*.md` | 64k bytes |
| `tests/*`, `test/*`, `__tests__/*`, `tests.rs` and their `*/` forms, plus `*test_util.rs`, `*.test.*`, `*.spec.*` | 800 lines |
| everything else | `SIZE_RATCHET_THRESHOLD`, 400 lines |

A repo overrides a class, never the list: its own entries are matched first, and the shipped list decides everything they leave alone.

```toml
[env]
SIZE_RATCHET_CLASSES = "*/SKILL.md=32k"
```

A repo entry never shadows a frozen class. `*` crosses `/`, so `ui/*.ts=250` also matches the test files under `ui/`, and `docs/*=250` reaches documents too; those paths already have a shipped class naming them, and the entry would retitle it silently, the counting unit included. Such an entry is skipped on those paths and the shipped class decides, in both directions, so no consumer restates a shipped threshold to scope a narrower policy to one directory:

```toml
[env]
SIZE_RATCHET_CLASSES = "ui/*.ts=250;ui/*.tsx=250"  # ui/ test files stay at 800
```

To move a frozen class deliberately, restate that class's own pattern, as the `*/SKILL.md` example does: an entry naming a pattern the shipped list carries still wins. Where the shipped list names no class for a frozen path, the repo entry stands. This is the only statement of the rule; every other surface points here.

`SIZE_RATCHET_DEFAULT_CLASSES = ""` drops the shipped list; single-threshold behavior needs the repo's own `SIZE_RATCHET_CLASSES` empty too. A directory name takes both forms, `tests/*` and `*/tests/*`, because `*/tests/*` requires a slash before the name; the shipped list carries both for every directory it names.

## Baseline format

`tools/size-ratchet-baseline.tsv` by default (`SIZE_RATCHET_BASELINE` or `--baseline FILE` to relocate). One row per frozen offender, `path<TAB>size`, the size suffixed `b` when its class counts bytes:

```
crates/core/src/error.rs	495
docs/handbook.md	86104b
```

Rows are `LC_ALL=C` sorted, paths unique, counts positive. A malformed, unsorted or duplicated baseline is a config error, never a silent pass. A row naming the baseline itself is stale because the baseline is outside the measured set.

### Seeding a first baseline

`--update` never adds rows, so the first baseline has its own mode: `--seed` writes every tracked, non-excluded file over its threshold at its current size. It refuses a selected baseline that already has rows or does not parse, and it judges the seed against the [trusted HEAD baseline](#trusted-head-baseline) like every other mode, so only a seed with no prior rows is a bootstrap. Declare `SIZE_RATCHET_CLASSES` before seeding: a class declared afterwards puts files back under their threshold and turns their rows stale.

## Exclusion list

`tools/size-ratchet-excludes` by default (`SIZE_RATCHET_EXCLUDES` or `--excludes FILE`). One shell glob per line against the full repo-relative path, with a mandatory reason: `pattern<TAB>reason`. Blank lines and `#` comments are ignored. The package adds `CHANGELOG*.md` on its own, where one long file is the documented norm.

```
Cargo.lock	lockfile — generated, size is not a design signal
.agents/*	kendex render, governed at its source
!.agents/skills/my-skill/*	in-place skill: this tree IS the source
```

A pattern opening with `!` carves its matches back into the measured set and beats every exclusion row whatever the order, the only way to keep hand-written source inside a rendered tree governed. A row that must name a path literally beginning with `!` escapes it as `\!foo`. Exclusion answers which paths carry no size bound; it grants no exemption from the NUL refusal.

## Customise

Every `SIZE_RATCHET_*` key and its default: `size-ratchet --help`. Each resolves environment > `.env.local` > `.kendex/settings.toml` > committed `kendex.settings.toml` (flat `KEY = "value"` under `[env]`) > default; a `.env` file is never read, and a source that exists but is unusable is a config error, never a fall-through. `--baseline` and `--excludes` override every source for those paths, and an empty value is a config error. Relative paths are repo-root-relative.

`RATCHET_RAISE=1` is not configuration: it is a per-invocation declaration, read from the environment alone, that this run's added or raised rows are deliberate.
