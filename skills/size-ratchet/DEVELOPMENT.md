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
again as a baseline row's `b` suffix. Nothing compares across units. A row
whose unit no longer matches its class is reported as one to re-measure, and
`--update` writes the current quantity in the new unit. `rows_raised` checks
the unit tag before comparing numbers. The policy is
[README.md § Trusted HEAD baseline](README.md#trusted-head-baseline).

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

The baseline is policy input and never enters the measured set. A self row is
therefore stale. This makes seed, update, and staged tightening converge
without re-measuring output that contains its own measurement.

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

## Trusted reference snapshot

`resolve_head_baseline_file` sets the settings library's HEAD mode and calls
`sr_setting`. `sr_settings_source` owns source names, precedence, historical
materialization, and tracked-symlink traversal. `git ls-tree` answers for a
complete path only, so before it may report a source absent from HEAD,
`sr_settings_head_absence_real` classifies each ancestor: absent ends the
walk, a tree continues it, and anything else — a symlink above all — is a
lookup that could not be performed and refuses. Materialized copies are named
`settings.file.<encoded path>`, a namespace the `settings.absent` sentinel
cannot occupy, so no source name can materialize onto the path that means "not
there". The main script handles only the flag and process-key overrides, then
reads the baseline at the returned path. `rows_raised` consumes only those rows. The behavioral rule is
[README.md § Trusted HEAD baseline](README.md#trusted-head-baseline).

## The tighten-only rewrite

`--update` and `--staged` run the same rewrite: rows lowered to the measured
size, rows re-measured where their unit changed, rows removed for files now
at/under their threshold or out of the counted set. It never adds a row or
raises a same-unit number. `--staged` runs it so a commit that shrinks a
limited file passes on the first attempt; it then stages the result.

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

Because collection excludes the baseline, a successful rewrite's saved counts
remain valid after replacement. An immediate plain run asks the same questions
over the same measured files.

## `--seed`

`--seed` collects by the same pass the gate itself trusts (index blobs,
symlink skipping, tab/newline refusal), `LC_ALL=C` sorted, each row in its
class's unit. It refuses when the selected baseline already has rows or does
not parse. Both policy leaves must be plain, and their future physical paths
must differ. Only the baseline parent is containment-checked because seed does
not write the exclusion path. Seed uses the trusted reference snapshot like
every other mode; only a seed with no prior active rows is bootstrap. The
seeded file lands uncommitted, so every offender enters the record in review.

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

First match wins except on a frozen path, where the class inversion applies.
[README.md § Path classes](README.md#path-classes) is the only statement of
that rule; `path_threshold` implements it, one branch per exit. Nothing here
restates it — a rule paraphrased at six sites loses a clause at one of them.

What belongs here is the shape of the implementation. Both lists are parsed
into one indexed array, the repo's entries first, and `REPO_CLASS_COUNT`
divides them; a repo entry whose pattern the shipped list also carries is
marked in `CLASS_RESTATED` once, after both parses. `path_threshold` stamps
every repo entry it passes over or lets decide, so the verdict line can be
assembled after the classification pass rather than at parse time — it
reports what each entry actually governed, and an entry that decided nothing
is named as such however it got there, because a run printing an inert entry
as the mapping in force would be a clean run advertising a threshold no file
was judged against.

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

A unit migration re-measures the row in `--update`, then applies the HEAD
comparison from [README.md § Trusted HEAD baseline](README.md#trusted-head-baseline).

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

`rows_raised` stamps candidate rows with frozen membership, joins them to the
trusted reference snapshot, and emits `ADDED`, `RAISED`, `FROZEN`, or the unit
variants. The rule behind those verdicts is stated once in
[README.md § Trusted HEAD baseline](README.md#trusted-head-baseline).
