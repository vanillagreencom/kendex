# harness-ci development

Maintainer notes. Consumer docs: [README.md](README.md); the wiring rules: [SKILL.md](SKILL.md).

## Invariants

- `--no-renames` is fixed, never a flag. Rename detection emits only the post-image, so `git mv src/app.ts .agents/skills/x/app.ts` would list one harness path and nothing else, and the deletion of `src/app.ts` would go unjudged. Without it both paths are listed and the diff answers `false`.
- `pull_request` uses the merge base (`base...head`) because the base branch moves under an open PR. `push` and `merge_group` use the two endpoints (`base head`): a force-push leaves the `before` sha off the head's history, and a merge base there is a commit the push already discarded, so measuring from it reads a push that dropped product work as render-only. A merge group's base is an ancestor of its head by construction, so the two forms agree there.
- An empty changed-file set answers `false`, because it is also what a diff that read nothing looks like.
- A Pi carrier package is source when its nearest `package.json` declares Pi extension entry points and a test command. The selected head and base both count, so deletion cannot remove its source classification.

## The in-place read

The manifests come from the selected head tree. The reader knows the one shape kendex writes: a `[skills.<name>]` header holding a bare or plain double-quoted key, then `source = "in-place"`. It does not parse the other spellings TOML allows.

The reader counts every line that could take part in spelling the value instead, including a bare `in-place`, a `\u`/`\U`/`\x` escape, or a multiline `source` string, and carves every `.agents/skills` path when one goes unaccounted. An apostrophe-quoted key, dotted key, inline table, nested table, name with whitespace, escaped name, or escaped value answers `false` that way. `source = "in-place"` under any table except `[skills.<name>]` also answers `false`. A manifest the head tree lists but that will not read, a symlink entry or an unreadable blob, carves every `.agents/skills` path.

## Tests

`tests/` runs in kendex CI on every change to this repository; run one locally with `bash skills/harness-ci/tests/path-set.test.sh`.

| Suite | Covers |
| --- | --- |
| `path-set` | Every render tree, mixed diffs, deletions, the near-miss paths |
| `in-place` | Trees either manifest declares in place, `.agents/hooks`, the coarse carve for a spelling the reader does not name, the no-manifest control |
| `rename-into-render` | The `git mv` into a render tree, and the control proving the flag is load-bearing |
| `event-ranges` | The force-push case, the moving base branch, merge groups |
| `fail-closed` | Unclassified events, unresolvable endpoints, an empty diff, a merge-base diff git refuses, a path git had to quote |
| `wiring-errors` | Exit 2 on bad calls, a flag where a value belongs included; `--output` and `$GITHUB_OUTPUT` behaviour |
| `wiring-shapes` | Every shape in `references/wiring.md` keeps each expression on one line, orders the push endpoints, names the shipped script path, and steps its indentation by two |

`tools/bash32-lint` checks the shipped script for Bash 4+ syntax, because consumer runners include macOS system Bash 3.2.
