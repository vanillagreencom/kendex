# size-ratchet — development notes

Internals, design, and maintenance for the size-ratchet skill. Consumer docs
live in README.md.

## Structure

- `scripts/size-ratchet` — the whole gate: collection, class resolution,
  verdicts, `--update`, `--seed`
- `scripts/lib/settings.sh` — layered settings resolution
- `SKILL.md` — agent-facing skill definition
- `README.md` — consumer documentation
- `tests/` — run any file directly; each is self-contained

`bash tests/*.sh` is the lane `tools/validate-changed` derives for a change
under this skill.

## Collection

Symlinks are skipped; a submodule gitlink at a tracked path is not a
countable file (a baseline row for one is stale). A tracked file absent from
the worktree (unstaged deletion, sparse checkout) is counted from the INDEX
blob, so "every tracked file" holds on partial trees too — a sparse checkout
can neither smuggle a new offender past the gate nor loosen a baselined row.
An index blob that cannot be read (corrupt object, promisor blob
unavailable) is a collection error (exit 2, naming the file) — a file the
gate could not measure is never skipped. A tracked path containing a tab or
newline is refused loudly (exit 2; exclude it to skip the gate) — it cannot
be represented in the line-oriented records.

## `--staged` policy snapshot

Growth staged then reverted in the worktree is invisible to the default
mode, so `--staged` reads index blobs. Policy comes from the same snapshot —
a TRACKED baseline, exclusion list or settings source is read from the index
too, so an unstaged edit to any of them cannot authorize growth the commit
does not carry, and a policy file staged for DELETION governs as absent. An
untracked source (a personal `.env.local`) is still the worktree copy, and
an explicit environment variable still wins over everything.

## `--seed`

`--seed` collects by the same pass the gate itself trusts (index blobs,
symlink skipping, tab/newline refusal), `LC_ALL=C` sorted, with a self-row
when the baseline outgrows its own threshold. It refuses a baseline that
already has rows in the worktree, the index **or** `HEAD`: the ratchet is
live there, and growth stays a reviewed hand-edit — staging the baseline's
deletion or truncation is not a reseed ticket. The seeded file lands
uncommitted, so every frozen offender enters the record deliberately.

In a sparse checkout that omits the baseline file, checks still run against
the index copy, but `--update` refuses (it will not rewrite a file the
worktree cannot show): materialize it first with
`git update-index --no-skip-worktree -- <baseline-path> && git checkout-index -- <baseline-path>`
(literal file paths in both commands — works in cone and non-cone mode for
any path shape; a later `git sparse-checkout reapply` re-hides the file),
then rerun.

## Path-class evaluation

A directory name takes both class forms: `*` may match nothing but the
literal `/` in `*/tests/*` still must be there, so `*/tests/*` covers
`pkg/tests/x` and never a root-level `tests/x` — that one needs `tests/*`.

Whitespace around a `SIZE_RATCHET_CLASSES` entry and around its `=` is
ignored, and an empty entry is skipped. A malformed entry — no `=`, an empty
pattern, a threshold that is not a positive integer — is a config error
(exit 2) naming the entry, never a silent fall back to the base threshold.
Unset or empty is exact single-threshold behavior.

Classes move only the number a path is judged against: new-offender, growth,
and stale-row detection and the tighten-only `--update` all run per file
against that file's own threshold, and every diagnostic names both the
number and where it came from (`class */tests/*` or `default`).

## Exclusion list on partial trees

A tracked exclusion list the worktree does not carry (sparse or partial
checkout) is read from the index, like the baseline, and gets the same row
validation — the exclusions hold on partial trees rather than collapsing to
none.

## Settings sources

Only an ABSENT source is skipped: a source that exists but is unusable —
unreadable, a directory, FIFO, socket or device, or a symlink that does not
resolve — is a config error (exit 2), never a fall-through to the next
layer. `SIZE_RATCHET_SETTINGS_FILE=/dev/null` selects no settings source at
all — `.env.local`, the settings file and `.env` are all skipped — leaving
explicit environment variables and the built-in defaults.

## Migration

Consumers already running a size ratchet with this exact baseline format
(`path<TAB>lines`, `LC_ALL=C` sorted) can swap this script in drop-in: keep
the existing baseline file where it is and point `SIZE_RATCHET_BASELINE`
(or `--baseline`) at it. Semantics are unchanged by agreement across repos:
same three failure directions, same tighten-only `--update`.

A repo adopting the `400` default over a looser one gains offenders in the
range between the two thresholds. Order matters: declare
`SIZE_RATCHET_CLASSES` **first**, then freeze. Freezing first baselines
401–800-line test files that the test class then puts back under their
threshold, and a row for a file under its threshold is a stale row — an
immediately failing migration.

`--update` never adds rows, so the freeze is one hand-edit: with the classes
declared, run the check and turn each reported `new offender` line into a
`path<TAB>lines` row (see
[Seeding a first baseline](README.md#seeding-a-first-baseline)), then commit
that baseline together with the settings change. Declaring
`SIZE_RATCHET_THRESHOLD` explicitly keeps the previous number instead.
