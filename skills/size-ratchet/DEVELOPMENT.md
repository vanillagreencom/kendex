# size-ratchet development

Internals and maintenance for the size-ratchet gate. Consumer docs and the behavioural rules: [README.md](README.md); the agent contract: [SKILL.md](SKILL.md).

`scripts/size-ratchet` is the whole gate: collection, class resolution, verdicts, the tighten-only rewrite, `--seed`. `scripts/lib/settings.sh` is the layered settings resolution. `tests/` holds self-contained suites, each runnable directly; `bash tests/*.sh` is the lane `tools/validate-changed` derives for a change under this skill.

## Units

A class threshold carries its unit: a bare number counts lines, a `k` suffix counts kibibytes. Markdown is measured in bytes because a re-wrap moves a line count on prose and leaves the byte count alone; code keeps lines, which is what every linter caps.

The unit rides beside the threshold through class resolution (`PU`), through collection (one pending batch per unit, so an interleaved tree still batches rather than degrading to a call per file), into the counts rows, and out again as a baseline row's `b` suffix. Nothing compares across units. A row whose unit differs from its class's is reported as one to re-measure, and `--update` writes the current quantity in the new unit. `rows_raised` checks the unit tag before comparing numbers, and where the tag changed on a frozen row it measures `HEAD:<path>` in the new unit, once per crossing row, so the admission has a like quantity to bound it. The policy is [README.md § Trusted HEAD baseline](README.md#trusted-head-baseline).

## Collection

Symlinks are skipped; a submodule gitlink at a tracked path is not a countable file (a baseline row for one is stale). A tracked file absent from the worktree (unstaged deletion, sparse checkout) is counted from the index blob, so "every tracked file" holds on partial trees too. An index blob that cannot be read (corrupt object, promisor blob unavailable) is a collection error naming the file; a file the gate could not measure is never skipped. A blob that materializes but cannot then be counted refuses under its own wording. A tracked path containing a tab or newline is refused before any skip, so the refusal covers the whole tracked set, which is what the `check-attr` parse below relies on.

Every tracked blob is sniffed for a NUL in its leading 8000 bytes, git's own text/binary rule, which growth-guards states as `gg_blob_is_binary` and preflight as `content_is_binary`. The unit does not narrow the coverage: line class, byte class, and no class at all are all sniffed, because what is held is that the blob stays reviewable text. A hit is a collection error naming the path and the byte's offset, never the byte itself, because reprinting it would put a NUL into the log carrying the diagnostic on. The refusal runs after the walk and before any mode branch, so `--seed` and `--update` refuse through that one place rather than writing a meaningless count into the baseline.

The sniff's one exemption is git's own record. `git check-attr diff` answers `unset` for a path given `-diff` and `binary` for one given a binary diff driver; either way git keeps the path out of every textual diff, so its bytes were never reviewable text. The read pins `core.attributesFile` to `/dev/null`, so no user-global file grants it; a repo-local `.git/info/attributes` still does, per clone, never committed, never reviewed, and git offers no switch to skip it. A size-excluded text file is sniffed like every other tracked path, and only a path that is both size-excluded and diff-exempt is skipped outright. The attribute is resolved for the whole tracked set in one `git ls-files -z | git check-attr -z --stdin diff`, `--cached` under `--staged`; a fork per path measured five times slower. Under `--staged`, and for any path absent from the worktree, the blob is materialized once and the count and the sniff read that one copy.

The sniff runs in two stages, so it costs no subprocess on the files that pass. A bounded `read -d ''` under `LC_ALL=C` stops at a NUL and bounds itself in bytes, the unit git's rule is stated in, so a status of 0 over a chunk short of the window means a NUL inside it and nothing else. An `od` scan then locates the byte. Because the prefilter is byte-exact, a scan that runs, succeeds and finds nothing means the sniff is wrong, or, on the worktree path where the two stages read the file separately, a write landed between them; either way it refuses rather than reporting clean.

The baseline is policy input and never enters the measured set. A self row is therefore stale. This makes seed, update, and staged tightening converge without re-measuring output that contains its own measurement.

## `--staged` policy snapshot

Growth staged then undone in the worktree is invisible to the default mode, so `--staged` reads index blobs. Policy comes from the same snapshot: a tracked baseline, exclusion list or settings source is read from the index too, so an unstaged edit to any of them cannot authorize growth the commit does not carry, and a policy file staged for deletion governs as absent. An untracked source (a personal `.env.local`) is still the worktree copy, and an explicit environment variable still wins over everything. Besides that untracked source, the one thing `--staged` reads from the worktree is the baseline it is about to rewrite; the index copy still governs unless the rewrite lands.

## Trusted reference snapshot

`resolve_head_baseline_file` picks the reference path. With `--baseline` or a process `SIZE_RATCHET_BASELINE` it is the candidate's own path, read from HEAD. Otherwise it sets the settings library's HEAD mode and calls `sr_setting`: `sr_settings_resolve` owns source names, precedence, historical materialization, and tracked-symlink traversal; `sr_settings_source` is the memo front over it, recording each answer beside the snapshot it came from. A HEAD symlink at the source path itself is followed only while its target stays in the repository; one at a parent component refuses, because `git ls-tree` answers for a complete path only and a lookup that could not be performed is not an absent source. `sr_settings_head_absence_real` therefore classifies each ancestor before the absent sentinel may be returned: absent ends the walk, a tree continues it, and anything else refuses. An absolute, escaping, or candidate-only explicit source contributes nothing to the historical lookup; if it assigns this key, the run refuses because that value has no historical form. The same rule applies to an untracked `.env.local`.

Materialized copies are named `settings.file.<encoded path>` and the memos `settings.resolved.<encoded path>`, two namespaces the `settings.absent` sentinel cannot occupy, so no source name can materialize onto the path that means "not there". A memo is only a cache, so one whose name will not fit as a single filesystem component is not written and that source resolves uncached. The main script handles only the flag and process-key overrides, then reads the baseline at the returned path. `rows_raised` consumes only those rows. The behavioural rule is [README.md § Trusted HEAD baseline](README.md#trusted-head-baseline).

## The tighten-only rewrite

`--update` and `--staged` run the same rewrite: rows lowered to the measured size, rows re-measured where their unit changed, rows removed for files now at or under their threshold or out of the counted set. It never adds a row or raises a same-unit number.

That rewrite reads the worktree copy of the baseline, which is what gets staged; rebuilding from the index copy would delete a developer's unstaged row edits rather than carrying them. Two accepted edges follow, both visible in the diff: a `git commit -- <paths>` commit acquires the baseline change, and unrelated unstaged row edits go into the index with it. Neither loosens a row: the rewrite is tighten-only against the staged content, so an unstaged raise is pulled back down to the measured size, and wherever the rewrite does not land the index copy governs the verdict.

The rewrite lands only where it resolves the run. The commit's own snapshot is judged first; the rewrite then runs from saved copies and its candidate is re-judged, and only a clean candidate reaches `git add`. Anything else restores the worktree baseline byte for byte and reports what the snapshot earned, so a rejected commit carries no baseline change the developer never asked for. A worktree copy the rewrite cannot read (a malformed row, an unsorted file, a duplicated path) skips the rewrite rather than failing the run: a hand-edit in progress is not a gate, and the commit records the index copy. The skip says so on stderr with the row diagnostic that caused it.

Because collection excludes the baseline, a successful rewrite's saved counts remain valid after replacement. An immediate plain run asks the same questions over the same measured files.

## `--seed`

`--seed` collects by the same pass the gate itself trusts (index blobs, symlink skipping, tab/newline refusal), `LC_ALL=C` sorted, each row in its class's unit. It refuses when the selected baseline already has rows or does not parse. The baseline and exclusion list must be different plain leaf paths; either leaf being a symlink refuses; the baseline's physical parent must stay in the repository, and their future physical destinations must differ, including through in-repository parent symlinks. Only the baseline parent is containment-checked because seed does not write the exclusion path. Seed uses the trusted reference snapshot like every other mode; only a seed with no prior active rows is bootstrap. The seeded file lands uncommitted, so every offender enters the record in review.

In a sparse checkout that omits the baseline file, checks still run against the index copy, but `--update` refuses to rewrite a file the worktree cannot show. Materialize it first with `git update-index --no-skip-worktree -- <baseline-path> && git checkout-index -- <baseline-path>` (literal file paths in both commands; a later `git sparse-checkout reapply` re-hides the file), then rerun.

## Path-class evaluation

First match wins except on a frozen path, where the class inversion applies. [README.md § Path classes](README.md#path-classes) is the only statement of that rule; `path_threshold` implements it, one branch per exit. Nothing here restates it.

Both lists are parsed into one indexed array, the repo's entries first, and `REPO_CLASS_COUNT` divides them; a repo entry whose pattern the shipped list also carries is marked in `CLASS_RESTATED` once, after both parses. `path_threshold` stamps every repo entry it passes over or lets decide, so the verdict line is assembled after the classification pass and reports what each entry actually governed. An entry that decided some paths and was passed over on frozen ones reads `(yielded on frozen paths)`; one that decided none reads `(governed nothing: decided no counted path)`. It reports the state, not the cause: a pattern matching nothing and a pattern a preceding entry already claimed cannot be told apart, and a run printing an inert entry as the mapping in force would be a clean run advertising a threshold no file was judged against.

Markdown entries come before the test entries in the shipped list, so a README or a doc under a `tests/` directory is judged as the document it is. `*/tests/*` covers `pkg/tests/x` and never a root-level `tests/x`, which needs `tests/*`; the shipped class and frozen lists carry both forms for every directory pattern they name.

Whitespace around an entry and around its `=` is ignored, and an empty entry is skipped. A malformed entry (no `=`, an empty pattern, a threshold that is not a positive integer with an optional `k`) is a config error naming the entry, never a silent fall back to the base threshold.

Classes move only the number a path is judged against: new-offender, growth, and stale-row detection and the tighten-only `--update` all run per file against that file's own threshold, and every diagnostic names both the number and where it came from (`class */tests/*` or `default`).

## Exclusion list on partial trees

A tracked exclusion list the worktree does not carry (sparse or partial checkout) is read from the index, like the baseline, and gets the same row validation, so the exclusions hold on partial trees rather than collapsing to none.

## Settings sources

Only an absent source is skipped: a source that exists but is unusable (unreadable, a directory, FIFO, socket or device, or a symlink that does not resolve) is a config error, never a fall-through to the next layer. `SIZE_RATCHET_SETTINGS_FILE=/dev/null` selects no settings source at all, leaving explicit environment variables and the built-in defaults.

## Migration

A consumer already running a size ratchet with this baseline format (`path<TAB>size`, `LC_ALL=C` sorted) can swap this script in drop-in: keep the existing baseline file where it is and point `SIZE_RATCHET_BASELINE` (or `--baseline`) at it. Rows written before the units existed carry no suffix and read as line counts, which is what they were.

A unit migration re-measures the row in `--update`, then applies the HEAD comparison from [README.md § Trusted HEAD baseline](README.md#trusted-head-baseline).

A repo adopting the `400` default over a looser one gains offenders in the range between the two thresholds. Declare `SIZE_RATCHET_CLASSES` first, then freeze: freezing first baselines 401–800-line test files that the test class then puts back under their threshold, and a row for a file under its threshold is a stale row, so the migration fails immediately.

`--update` never adds rows, so the freeze is one hand-edit: with the classes declared, run the check and turn each reported `new offender` line into a `path<TAB>size` row (see [Seeding a first baseline](README.md#seeding-a-first-baseline)), then commit that baseline together with the settings change. Declaring `SIZE_RATCHET_THRESHOLD` explicitly keeps the previous number instead.

## Added and raised rows

`rows_raised` stamps candidate rows with frozen membership, joins them to the trusted reference snapshot, and emits `ADDED`, `RAISED`, `FROZEN`, or the unit variants. The rule behind those verdicts is stated once in [README.md § Trusted HEAD baseline](README.md#trusted-head-baseline).
