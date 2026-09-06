# doc-limits development

## Collection

`scripts/doc-limits` reads the tracked set from the index. Its Git batch supplies document blob sizes without materializing their content. The default mode replaces each size with the worktree measurement when that file exists. A missing worktree file uses its index size. Symlinks and submodule entries are outside the measured set.

The staged mode reads tracked settings and exclusions from the index. A policy file staged for deletion is absent even if its worktree copy remains. Untracked local settings and explicit process values still apply. `scripts/lib/settings.sh` owns settings resolution.

## Tests

Run each suite with Bash. The repository's skill-test CI job runs every suite under `tests/`.

- `tests/shipped-defaults.test.sh`: each document class at its limit and one byte over, reasoned exclusions, and a disabled-comparison control.
- `tests/staged-scope.test.sh`: staged document content and policy remain independent of unstaged edits and deletions.
- `tests/settings-and-config.test.sh`: settings precedence, class ordering, malformed policy, carve-back rows, and failed or incomplete Git collection.
