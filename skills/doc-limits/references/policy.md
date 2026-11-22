# Document size policy

## Path classes

- The measured set is the tracked regular files named `AGENTS.md`, `CLAUDE.md`, `GEMINI.md` or `SKILL.md`, at the root and at any depth. No other file is measured, whatever a class names.
- `DOC_LIMITS_CLASSES` contains project entries. `DOC_LIMITS_DEFAULT_CLASSES` contains the shipped entries. Project entries come first. The first entry matching a measured file sets that file's byte ceiling. An entry that can match no file in the measured set sets nothing.
- An entry is `pattern=Nk`, where `N` is a positive integer and `k` means 1024 bytes. Semicolons separate entries. Whitespace around entries and `=` is ignored.
- Patterns match the full repository-relative path. `*` crosses directory separators.
- `SHIPPED_CLASSES` in [scripts/doc-limits](../scripts/doc-limits) declares the shipped classes and their limits.
- An empty `DOC_LIMITS_DEFAULT_CLASSES` removes the shipped list. A measured file with no matching class has no limit.

## Exclusion list

- Generated files are excluded by exact path from the render writer's `.kendex-generated.json`. Adopted in-place source remains governed because the writer leaves it out of that inventory. Adoption needs no ownership row in the excludes file.
- An absent inventory is an empty one: nothing is excluded and every file in the measured set is measured. A project whose items are all in-place, or one installed below the Git root, writes no repository inventory and needs none.
- The default mode reads the worktree inventory, falling back to its index copy when absent. Staged mode reads the tracked index copy; an inventory staged for deletion is absent. An untracked inventory reads from the worktree.
- Each row of the excludes file is `pattern<TAB>reason`. `doc-limits --help` names the setting and the flag that select the file. Blank lines and lines starting with `#` are ignored.
- A leading `!` restores matching documents to the measured set. It takes priority over every exclusion, including inventory entries. `\!` matches a literal leading exclamation mark.
- Exclusions are the exception path for documents that cannot fit their class.
