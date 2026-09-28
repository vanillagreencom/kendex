# doc-limits development

## Collection

`scripts/doc-limits` reads the tracked set from the index. Its Git batch supplies document blob sizes without materializing their content. The default mode replaces each size with the worktree measurement when that file exists. A missing worktree file uses its index size. The `--against` growth test keeps the index blob size, because REF's size is a blob size and the worktree size carries checkout conversion. Symlinks and submodule entries are outside the measured set.

The staged mode reads tracked settings and exclusions from the index. A policy file staged for deletion is absent even if its worktree copy remains. Untracked local settings and explicit process values still apply. `scripts/lib/settings.sh` owns settings resolution.

The shared inventory reader is `../commit-guards/scripts/lib/generated-paths.sh`. The inventory and exclusion contract is [references/policy.md](references/policy.md).

## Tests

Run each suite with Bash. The repository's skill-test CI job runs every suite under `tests/`.

- `tests/shipped-defaults.test.sh`: each document class at its limit and one byte over with its docs-writing rule anchor, the anchor for a project class, reasoned exclusions, a disabled-comparison control, and a shipped class row without its rule.
- `tests/staged-scope.test.sh`: staged document content and policy remain independent of unstaged edits and deletions.
- `tests/settings-and-config.test.sh`: settings precedence, class ordering, malformed policy, carve-back rows, and failed or incomplete Git collection, for the index batch and the `--against` REF batch.
- `tests/growth-margin.test.sh`: `--against` at the margin's edge and one byte inside it, unchanged, shrunk, new, over-limit, staged and unstaged documents, an unchanged document whose CRLF checkout adds bytes, two documents paired with their own sizes in the ref, the rule line after a near-limit finding, margin settings, refused margins and refs, and one mutant each for the margin rule, the growth test, growth read from stored sizes, the absent-document rule, the margin read under `--against` alone, the margin refusal and the ref refusal.
- `tests/generated-paths.test.sh`: adopted documents, exact generated paths, inventory state, refusal and disabled-exclusion controls.
