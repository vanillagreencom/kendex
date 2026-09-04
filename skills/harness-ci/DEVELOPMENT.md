# harness-ci development

Maintainer notes. Consumer docs: [README.md](README.md); the wiring rules: [SKILL.md](SKILL.md).

## Invariants

- `--no-renames` is fixed, never a flag. Rename detection emits only the post-image, so `git mv src/app.ts .agents/skills/x/app.ts` would list one harness path and nothing else, and the deletion of `src/app.ts` would go unjudged. Without it both paths are listed and the diff answers `false`.
- `pull_request` uses the merge base (`base...head`) because the base branch moves under an open PR. `push` and `merge_group` use the two endpoints (`base head`): a force-push leaves the `before` sha off the head's history, and a merge base there is a commit the push already discarded, so measuring from it reads a push that dropped product work as render-only. A merge group's base is an ancestor of its head by construction, so the two forms agree there.
- An empty changed-file set answers `false`, because it is also what a diff that read nothing looks like.
- The engine derives `.kendex-generated.json` from rendered artifact files, shared registration files, and instruction shims. It excludes in-place declarations. Pi carrier payloads do not enter the render model and remain source.
- Inventory membership is exact, never a folder prefix. A generated file adopted as source must be absent from the head inventory, which causes product checks to run. Deletions use the base inventory.
- A missing or invalid inventory runs every lane, including the commit that first installs the inventory.

## Tests

`tests/` runs in kendex CI on every change to this repository; run one locally with `bash skills/harness-ci/tests/path-set.test.sh`.

| Suite | Covers |
| --- | --- |
| `path-set` | Writer-recorded paths, mixed diffs, carrier source, deletions, and unrecorded neighbors |
| `in-place` | Source adoption removes generated ownership |
| `rename-into-render` | The `git mv` into a render tree, and the control proving the flag is load-bearing |
| `event-ranges` | The force-push case, the moving base branch, merge groups |
| `fail-closed` | Unclassified events, unresolvable endpoints, an empty diff, a merge-base diff git refuses, a path git had to quote |
| `wiring-errors` | Exit 2 on bad calls, a flag where a value belongs included; `--output` and `$GITHUB_OUTPUT` behaviour |
| `wiring-shapes` | Every shape in `references/wiring.md` keeps each expression on one line, orders the push endpoints, names the shipped script path, and steps its indentation by two |

`tools/bash32-lint` checks the shipped script for Bash 4+ syntax, because consumer runners include macOS system Bash 3.2.
