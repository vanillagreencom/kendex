# Size policy

## Trusted HEAD baseline

- The reference baseline comes from HEAD, the current commit. A process `SIZE_RATCHET_BASELINE` or `--baseline` selects its path directly. Otherwise, the committed settings sources select it.
- A settings source without a committed form cannot select the reference path. This includes an untracked local file or an absolute path outside the repository.
- Changing the candidate baseline path does not change the reference rows. Change the path in a separate commit before changing its rows. The checker does not enforce that commit sequence.
- An empty reference permits the initial baseline. The result identifies that initial setup.
- In the same unit, a frozen row cannot increase. An open row can increase only when the process sets `RATCHET_RAISE=1`. Adding a row beside existing reference rows also requires that declaration.
- A unit change requires a new measurement. A frozen row must equal the current file measurement and must not exceed the committed file measured in that unit. An open row requires `RATCHET_RAISE=1`.
- Record the reason for a permitted increase in the commit body. The checker reads the process declaration, not the commit message.

## Path classes

- `SIZE_RATCHET_CLASSES` contains project entries. `SIZE_RATCHET_DEFAULT_CLASSES` contains the shipped entries. The first matching entry selects the file's limit, subject to the frozen-class rule below. Unmatched files use `SIZE_RATCHET_THRESHOLD`.
- An entry is `pattern=threshold`. Semicolons separate entries. Patterns match the full repository-relative path, and `*` crosses directory separators.
- A bare threshold counts lines. The `k` suffix counts bytes in units of 1024.
- The declarations `SHIPPED_CLASSES` and `SHIPPED_FROZEN_CLASSES` in [scripts/size-ratchet](../scripts/size-ratchet) define the shipped lists.
- For a path in a frozen class, a project entry with a different pattern from the matching shipped class is skipped. The shipped class applies. An explicit project entry using that shipped pattern can override it. If no shipped class matches, the project entry applies.
- Empty `SIZE_RATCHET_DEFAULT_CLASSES` removes the shipped list. Empty project classes as well select the single-threshold behavior.
- Patterns for a directory at any depth need both the root and nested forms, such as `tests/*` and `*/tests/*`.

## Baseline format

- The default file is `tools/size-ratchet-baseline.tsv`. `SIZE_RATCHET_BASELINE` or `--baseline FILE` changes its path.
- Each row contains `path<TAB>size`. A byte count has a `b` suffix. A line count has no suffix.
- Sort rows with `LC_ALL=C`. Paths must be unique and counts positive.
- A row is stale if it exceeds the measured file, names a file now within its limit, names an untracked file or uses the wrong unit. The baseline cannot contain its own path.
- `--update` lowers rows, removes stale rows and measures changed units again. It does not add rows or increase a same-unit value.

## Seeding a first baseline

- Configure path classes before running `--seed`.
- The seed records tracked, included files that exceed their limits at their current sizes.
- The selected baseline must parse and contain no rows. The seed also follows the committed-reference rules above.
- Changing classes after seeding can make rows stale. Update the baseline when the new class puts a file within its limit.

## Exclusion list

- The default file is `tools/size-ratchet-excludes`. `SIZE_RATCHET_EXCLUDES` or `--excludes FILE` changes its path.
- Each row is `pattern<TAB>reason`. Patterns match full repository-relative paths. Blank lines and comment lines are ignored.
- A pattern beginning with `!` includes matching paths again. It wins over exclusion rows regardless of order. Escape a literal leading exclamation mark as `\!`.
- The checker adds a `CHANGELOG*.md` exclusion for release records.
- Exclusions remove size limits. They do not permit binary content to be measured as text. Git's `binary` or `-diff` attribute marks a file as binary.
