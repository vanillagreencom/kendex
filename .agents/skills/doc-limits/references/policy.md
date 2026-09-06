# Document size policy

## Path classes

- The check measures tracked regular files whose paths end in `.md`.
- `DOC_LIMITS_CLASSES` contains project entries. `DOC_LIMITS_DEFAULT_CLASSES` contains the shipped entries. Project entries come first. The first matching entry sets the document's byte ceiling.
- An entry is `pattern=Nk`, where `N` is a positive integer and `k` means 1024 bytes. Semicolons separate entries. Whitespace around entries and `=` is ignored.
- Patterns match the full repository-relative path. `*` crosses directory separators.
- `SHIPPED_CLASSES` in [scripts/doc-limits](../scripts/doc-limits) declares the document classes and their limits.
- An empty `DOC_LIMITS_DEFAULT_CLASSES` removes the shipped list. A document with no matching class has no limit.

## Exclusion list

- Generated files are excluded by exact path from the render writer's `.kendex-generated.json`. Adopted in-place source remains governed because the writer leaves it out of that inventory. Adoption needs no ownership row in the exclusions file.
- The inventory is required at the Git repository root. An absent, unreadable or malformed inventory fails with exit `2`. Install or refresh kendex at that root in the main checkout and stage the inventory with the renders. An installation confined below the Git root produces no repository inventory.
- The default mode reads the worktree inventory, falling back to its index copy when absent. Staged mode reads the tracked index copy; an inventory staged for deletion is absent. An untracked inventory reads from the worktree.
- `DOC_LIMITS_EXCLUDES` selects the repository-relative file. Its default is `tools/doc-limits-excludes`. `--excludes FILE` overrides it.
- Each row is `pattern<TAB>reason`. A missing pattern or reason is a configuration error. Blank lines and lines starting with `#` are ignored.
- A leading `!` restores matching documents to the measured set. It takes priority over every exclusion, including inventory entries. `\!` matches a literal leading exclamation mark.
- Exclusions are the exception path for documents that cannot fit their class. The checker has no per-file allowance.

## Check result

| Exit | Meaning |
| --- | --- |
| `0` | Every measured document is within its class limit. |
| `1` | At least one document exceeds its class limit. The output names each document, size and limit. |
| `2` | Usage, configuration or collection failed. The check cannot report a complete size result. |
