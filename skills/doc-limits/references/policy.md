# Document size policy

## Path classes

- The check measures tracked regular Markdown files and HTML files under `docs/`.
- `DOC_LIMITS_CLASSES` contains project entries. `DOC_LIMITS_DEFAULT_CLASSES` contains the shipped entries. Project entries come first. The first matching entry sets the document's byte ceiling.
- An entry is `pattern=Nk`, where `N` is a positive integer and `k` means 1024 bytes. Semicolons separate entries. Whitespace around entries and `=` is ignored.
- Patterns match the full repository-relative path. `*` crosses directory separators.
- `SHIPPED_CLASS_ROWS` in [scripts/doc-limits](../scripts/doc-limits) declares the document classes, their limits, and for each class the anchor of its docs-writing rule. The anchors are kept by hand in step with docs-writing [§ Per file type](../../docs-writing/SKILL.md#per-file-type); the `*.md` catch-all names that section as a whole. A row with an empty rule refuses with exit `2`.
- An empty `DOC_LIMITS_DEFAULT_CLASSES` removes the shipped list. A document with no matching class has no limit.

## Exclusion list

- Generated files are excluded by exact path from the render writer's `.kendex-generated.json`. Adopted in-place source remains governed because the writer leaves it out of that inventory. Adoption needs no ownership row in the exclusions file.
- An absent inventory is an empty one: nothing is excluded and every tracked document is measured. A project whose items are all in-place, or one installed below the Git root, writes no repository inventory and needs none. An unreadable or malformed inventory fails with exit `2`; install or refresh kendex at the Git repository root in the main checkout and stage the inventory with the renders.
- The default mode reads the worktree inventory, falling back to its index copy when absent. Staged mode reads the tracked index copy; an inventory staged for deletion is absent. An untracked inventory reads from the worktree.
- `DOC_LIMITS_EXCLUDES` selects the repository-relative file. Its default is `tools/doc-limits-excludes`. `--excludes FILE` overrides it.
- Each row is `pattern<TAB>reason`. A missing pattern or reason is a configuration error. Blank lines and lines starting with `#` are ignored.
- A leading `!` restores matching documents to the measured set. It takes priority over every exclusion, including inventory entries. `\!` matches a literal leading exclamation mark.
- Exclusions are the exception path for documents that cannot fit their class. The checker has no per-file allowance.

## Growth margin

- `--against REF` adds one rule to the class limit. A document whose index copy is larger than its copy in REF's own tree fails when its measured size is more than its limit minus the margin.
- Growth compares stored blob sizes, so a checkout conversion such as `eol=crlf` or `core.autocrlf` adds no growth. An unstaged edit counts as growth once it is staged.
- `DOC_LIMITS_MARGIN_PCT` sets the margin as a percent of each limit: a decimal integer from 0 to 99 without leading zeros. Its default is `2`. The margin in bytes rounds down. `0` leaves the limit alone. Any other value refuses with exit `2`, and only a run with `--against` reads it.
- A document REF does not hold at its path counts as grown from 0 bytes, a renamed document included.
- A document the change leaves unchanged or shrinks is judged on its limit alone.
- REF is the tree the change is measured from, because every difference from REF counts as the change's growth. A pull request run in CI passes the merge commit's first parent, `HEAD^1`. A local run or a head-only checkout passes `$(git merge-base HEAD <base>)`, never a base branch tip that moved after the branch point. Two pull requests that each pass against the same base then put one document over its limit in a merge group only when each grows it by more than the margin. A merge group run passes no `--against`, so a group that fits its limits merges.

## Check result

| Exit | Meaning |
| --- | --- |
| `0` | Every measured document is within its class limit and, under `--against`, none grew into its margin. |
| `1` | At least one document exceeds its class limit, or under `--against` grew into its margin. The output names each document with `notice=document-over-limit` or `notice=document-near-limit`, its size and limit. A `notice=document-rule rule=docs-writing/SKILL.md#ANCHOR` line follows each one and names the docs-writing rule for its class. A class the shipped rows do not declare names `#per-file-type`. |
| `2` | Usage, configuration or collection failed. The check cannot report a complete size result. |
