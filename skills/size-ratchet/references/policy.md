# Document size policy

## Path classes

- The check measures tracked regular files whose paths end in `.md`.
- `SIZE_RATCHET_CLASSES` contains project entries. `SIZE_RATCHET_DEFAULT_CLASSES` contains the shipped entries. Project entries come first. The first matching entry sets the document's byte ceiling.
- An entry is `pattern=Nk`, where `N` is a positive integer and `k` means 1024 bytes. Semicolons separate entries. Whitespace around entries and `=` is ignored.
- Patterns match the full repository-relative path. `*` crosses directory separators.
- `SHIPPED_CLASSES` in [scripts/size-ratchet](../scripts/size-ratchet) declares the document classes and their limits.
- An empty `SIZE_RATCHET_DEFAULT_CLASSES` removes the shipped list. A document with no matching class has no limit.

## Exclusion list

- `SIZE_RATCHET_EXCLUDES` selects the repository-relative file. Its default is `tools/size-ratchet-excludes`. `--excludes FILE` overrides it.
- Each row is `pattern<TAB>reason`. A missing pattern or reason is a configuration error. Blank lines and lines starting with `#` are ignored.
- A leading `!` restores matching documents to the measured set. It takes priority over every exclusion. `\!` matches a literal leading exclamation mark.
- Exclusions are the exception path for documents that cannot fit their class. The checker has no per-file allowance.

## Check result

| Exit | Meaning |
| --- | --- |
| `0` | Every measured document is within its class limit. |
| `1` | At least one document exceeds its class limit. The output names each document, size and limit. |
| `2` | Usage, configuration or collection failed. The check cannot report a complete size result. |
