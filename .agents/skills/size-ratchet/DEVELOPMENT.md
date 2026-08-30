# size-ratchet — development notes

Internals, design, and maintenance for the size-ratchet skill. Consumer docs
live in README.md.

## Structure

- `scripts/size-ratchet` — the whole gate: collection, class resolution,
  verdicts, the tighten-only rewrite, `--seed`
- `scripts/lib/settings.sh` — layered settings resolution
- `SKILL.md` — agent-facing skill definition
- `README.md` — consumer documentation
- `references/` — procedures SKILL.md links out to
- `tests/` — run any file directly; each is self-contained

`bash tests/*.sh` is the lane `tools/validate-changed` derives for a change
under this skill.

## Units

A class threshold carries its unit: a bare number counts lines, a `k` suffix
counts kibibytes. Markdown is measured in bytes because a re-wrap moves a
line count on prose and leaves the byte count alone; code keeps lines, which
is what every linter caps.

The unit rides beside the threshold through class resolution (`PU`), through
collection (one pending batch per unit, so an interleaved tree still batches
rather than degrading to a call per file), into the counts rows, and out
again as a baseline row's `b` suffix. Nothing compares across units: a row
whose unit no longer matches its class is reported as one to RE-MEASURE, and
`--update` rewrites it at the current size in the new unit. That is the whole
migration path — one `--update` per repo, and no mode of its own.

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
an explicit environment variable still wins over everything. Besides that
untracked source, the one thing `--staged` reads from the worktree is the
baseline it is about to REWRITE — see the next section, where the index copy
still governs unless the rewrite lands.

## The tighten-only rewrite

`--update` and `--staged` run the same rewrite: rows lowered to the measured
size, rows re-measured where their unit changed, rows removed for files now
at/under their threshold or out of the counted set, and never a row added or
raised. `--staged` runs it so a commit that SHRINKS a limited file passes on
the first attempt instead of failing, waiting for a `--update`, and being
made again; it then stages the result.

That rewrite reads the WORKTREE copy of the baseline, which is what gets
staged — rebuilding from the index copy would delete a developer's unstaged
row edits rather than carrying them. Two accepted edges follow, both visible
in the diff: a `git commit -- <paths>` commit acquires the baseline change,
and unrelated unstaged row edits go into the index with it. Neither loosens a
row: the rewrite is tighten-only against the STAGED content, so an unstaged
raise is pulled back down to the measured size, and wherever the rewrite does
not land the INDEX copy governs the verdict, so a row the worktree carries
and the commit does not still fails the run.

The rewrite lands only where it RESOLVES the run. The commit's own snapshot
is judged first; the rewrite then runs from saved copies and its candidate is
re-judged, and only a clean candidate reaches `git add`. Anything else
restores the worktree baseline byte for byte and reports what the snapshot
earned, so a rejected commit carries no baseline change the developer never
asked for. A worktree copy the rewrite cannot read — a malformed row, an
unsorted file, a duplicated path — skips the rewrite rather than failing the
run: a hand-edit in progress is not a gate, and the commit records the index
copy. The skip says so on stderr, with the row diagnostic that caused it,
because a rewrite that quietly does not happen leaves the run failing on the
verdict it existed to resolve.

The baseline is itself a counted file, so the rewrite reconciles its own row
against the file it is about to become. A line row settles in one pass —
editing a value in place cannot change a line count — but a byte row does
not, since the digits are part of the length it records, so the pass repeats
to a fixed point and a candidate that will not settle fails loud rather than
being written out to fail its own check.

## `--seed`

`--seed` collects by the same pass the gate itself trusts (index blobs,
symlink skipping, tab/newline refusal), `LC_ALL=C` sorted, each row in its
class's unit, with a self-row when the baseline outgrows its own threshold —
solved by the same fixed-point iteration, because the row's own digits are
part of what it measures.

It refuses a baseline that already has rows in the worktree, the index **or**
`HEAD`: the ratchet is live there, and growth stays a reviewed hand-edit —
staging the baseline's deletion or truncation is not a reseed ticket. The
seeded file lands uncommitted, so every frozen offender enters the record
deliberately.

In a sparse checkout that omits the baseline file, checks still run against
the index copy, but `--update` refuses (it will not rewrite a file the
worktree cannot show): materialize it first with
`git update-index --no-skip-worktree -- <baseline-path> && git checkout-index -- <baseline-path>`
(literal file paths in both commands — works in cone and non-cone mode for
any path shape; a later `git sparse-checkout reapply` re-hides the file),
then rerun.

## Path-class evaluation

The class list a path is matched against is `SIZE_RATCHET_CLASSES` (the
repo's own overrides) followed by `SIZE_RATCHET_DEFAULT_CLASSES` (the list
the package ships), first match wins. A repo therefore overrides a class
without restating the list, and `SIZE_RATCHET_DEFAULT_CLASSES=""` drops the
shipped list alone — exact single-threshold behavior needs the repo's own
`SIZE_RATCHET_CLASSES` empty too. Markdown entries come before the test
entries in the shipped list, so a README or a doc under a `tests/` directory
is judged as the document it is.

A directory name takes both class forms: `*` may match nothing but the
literal `/` in `*/tests/*` still must be there, so `*/tests/*` covers
`pkg/tests/x` and never a root-level `tests/x` — that one needs `tests/*`.
The shipped class and frozen lists carry both forms for every directory
pattern they name, so a root-level `tests/` — where Rust puts its
integration tests — is judged and frozen like any other test directory.

Whitespace around an entry and around its `=` is ignored, and an empty entry
is skipped. A malformed entry — no `=`, an empty pattern, a threshold that is
not a positive integer with an optional `k` — is a config error (exit 2)
naming the entry, never a silent fall back to the base threshold.

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
all — `.env.local` and the settings files are both skipped — leaving
explicit environment variables and the built-in defaults.

## Migration

Consumers already running a size ratchet with this baseline format
(`path<TAB>size`, `LC_ALL=C` sorted) can swap this script in drop-in: keep
the existing baseline file where it is and point `SIZE_RATCHET_BASELINE`
(or `--baseline`) at it. Rows written before the units existed carry no
suffix and read as line counts, which is what they were.

A baseline whose markdown rows are line counts migrates in one `--update`:
each such row is re-measured in bytes, or removed where the file is under its
byte class, and the run reports no growth doing it.

A repo adopting the `400` default over a looser one gains offenders in the
range between the two thresholds. Order matters: declare
`SIZE_RATCHET_CLASSES` **first**, then freeze. Freezing first baselines
401–800-line test files that the test class then puts back under their
threshold, and a row for a file under its threshold is a stale row — an
immediately failing migration.

`--update` never adds rows, so the freeze is one hand-edit: with the classes
declared, run the check and turn each reported `new offender` line into a
`path<TAB>size` row (see
[Seeding a first baseline](README.md#seeding-a-first-baseline)), then commit
that baseline together with the settings change. Declaring
`SIZE_RATCHET_THRESHOLD` explicitly keeps the previous number instead.

## Added and raised rows

A hand-edited baseline row is the only way past a threshold, so a row a
change adds or raises is that threshold routed around. `RATCHET_RAISE=1` on
the invocation declares it: `baseline row added` and `baseline row raised`
fail without it. No commit message is read, because a pre-commit hook cannot
see one — the reason belongs in the commit body, where review reads it.

`SIZE_RATCHET_FROZEN_CLASSES` refuses a RAISE regardless of that
declaration, and defaults to every markdown class and every test class. It
does not refuse a first row: a new path still gets its bootstrap row, which
is what a repo adopting a class needs on day one.

Rows already at HEAD are grandfathered, because the gate judges the change
and not the history it inherited. A HEAD with no baseline (an unborn HEAD,
a first `--seed`, a baseline this change introduces) has nothing to compare,
so the raise gate alone is skipped — every other verdict still judges the
snapshot and can fail it — and the verdict line says the added and raised
checks did not run, because "no reference" must never read as "checked and
clean". A commit that MOVES the
baseline reaches that same emptiness without being one of the three, and every
raise in it would land unjudged, so it is refused instead. The gate does not
follow the move: where HEAD's baseline was is a question only HEAD's settings
answer, and they resolve through a chain this script consults but does not
own, so answering it means keeping a second implementation of that contract in
step with it. The discriminator is what the change does to the old file, a path
HEAD carried a row set at that the judged snapshot no longer carries, which
none of the three bootstraps produces. A move whose rows arrive byte for byte
as they left passes, because no row rose across it. The bound worth knowing is
that a change pointing the setting elsewhere while leaving the old file tracked
removes nothing, and is not a move the check can name. A row whose
file is at or under its threshold is reported as stale instead, so one root
cause reads as one verdict. A class that changes its UNIT does not escape:
HEAD's row is re-expressed in the unit the class counts now, measured from
HEAD's own blob, so the comparison runs in one unit and only a file that did
not grow re-measures for free.
