# harness-ci development

Maintainer notes. Consumer docs: [README.md](README.md); the wiring rules: [SKILL.md](SKILL.md).

## Invariants

- `--no-renames` is fixed, never a flag. Rename detection emits only the post-image, so `git mv src/app.ts .agents/skills/x/app.ts` would list one harness path and nothing else, and the deletion of `src/app.ts` would go unjudged. Without it both paths are listed and the diff answers `false`.
- `pull_request` uses the merge base (`base...head`) because the base branch moves under an open PR. `push` and `merge_group` use the two endpoints (`base head`): a force-push leaves the `before` sha off the head's history, and a merge base there is a commit the push already discarded, so measuring from it reads a push that dropped product work as render-only. A merge group's base is an ancestor of its head by construction, so the two forms agree there.
- An empty changed-file set answers `false`, because it is also what a diff that read nothing looks like.
- Docs mode answers `false` when any changed path is outside the path set in `harness-only --help`. The `docs-only` suite enforces the set.
- The engine derives `.kendex-generated.json` from rendered artifact files, shared registration files, and instruction shims. It excludes in-place declarations. Pi carrier payloads do not enter the render model and remain source.
- Inventory membership is exact, never a folder prefix. A generated file adopted as source must be absent from the head inventory, which causes product checks to run. Deletions use the base inventory.
- A missing or invalid inventory runs every lane, including the commit that first installs the inventory. Inventory additions also run every lane before the new paths become trusted base data.
- `aggregate-needs` accepts a skipped job only when the classifier succeeded, its waiver is `true`, and the job is in the caller's explicit skippable set.
- `change-class` reads no diff range of its own: it calls `harness-only` for the changed-path set and for the generated-path ownership rules, and repeats only that run's `changed-path:` lines.
- The `render` class needs `kendex verify` to answer clean. A missing binary, a non-zero verdict, or a changed configuration or instruction source leaves it unproven, and the diff takes the class its other rules give it.
- The measured classes come from orch's `branch_size_classified`, which owns the production/test split and the render-mirror pairing `branch-size-check` judges an allowance by. It measures a branch against its base branch, so only `--event pull_request` reaches a measured class; every other event answers `render` or `standard`.
- A glob list is split with pathname expansion off. Splitting it under the default would replace a glob naming a real directory with the files under the caller's working directory, and the list would no longer be the list.

## Tests

`tests/` runs in kendex CI on every change to this repository; run one locally with `bash skills/harness-ci/tests/path-set.test.sh`.

| Suite | Covers |
| --- | --- |
| `path-set` | Writer-recorded paths, mixed diffs, carrier source, deletions, and unrecorded neighbors |
| `in-place` | Source adoption removes generated ownership |
| `rename-into-render` | The `git mv` into a render tree, and the control proving the flag is load-bearing |
| `event-ranges` | The force-push case, the moving base branch, merge groups |
| `fail-closed` | Unclassified events, unresolvable endpoints, an empty diff, a merge-base diff git refuses, a path git had to quote |
| `docs-only` | Documentation paths, excluded source paths, pull requests, merge groups, and the path-set must-fail control |
| `aggregate-needs` | Successful dependencies, authorized skips, refused results, invalid input, and must-fail controls for classifier success, dependency success, the waiver, and skippable membership |
| `wiring-errors` | Exit 2 on bad calls, a flag where a value belongs included; `--output` and `$GITHUB_OUTPUT` behaviour |
| `wiring-shapes` | Every shape in `references/wiring.md` keeps each expression on one line, orders the push endpoints, names the shipped script path, and steps its indentation by two |
| `change-class` | One row per class and per boundary, the author-writable fields that assert nothing, the wiring outputs, both trivial settings, and the must-fail control where a classifier trusting the inventory passes a hand edit inside a render |

`tools/bash32-lint` checks the shipped script for Bash 4+ syntax, because consumer runners include macOS system Bash 3.2.
