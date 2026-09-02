# harness-ci development

## The in-place read

The manifests come from the selected head tree. The reader knows the one shape
kendex writes: a `[skills.<name>]` header holding a bare or plain double-quoted
key, then `source = "in-place"`. It does not parse the other spellings TOML
allows.

The reader counts every line that could take part in spelling the value instead,
including a bare `in-place`, a `\u`/`\U`/`\x` escape, or a multiline `source`
string. It carves every `.agents/skills` path when one goes unaccounted. An
apostrophe-quoted key, dotted key, inline table, nested table, name with
whitespace, escaped name, or escaped value answers `false` that way.
`source = "in-place"` under any table except `[skills.<name>]` also answers
`false`.

## Tests

`tests/` runs in kendex CI on every change to this repository:

| Suite | Covers |
| --- | --- |
| `path-set` | Every render tree, mixed diffs, deletions, the near-miss paths |
| `in-place` | Trees either manifest declares in place, `.agents/hooks`, the coarse carve for a spelling the reader does not name, the no-manifest control |
| `rename-into-render` | The `git mv` into a render tree, and the control proving the flag is load-bearing |
| `event-ranges` | The force-push case, the moving base branch, merge groups |
| `fail-closed` | Unclassified events, unresolvable endpoints, an empty diff, a merge-base diff git refuses, a path git had to quote |
| `wiring-errors` | Exit 2 on bad calls (a flag where a value belongs included), `--output` and `$GITHUB_OUTPUT` behaviour |
| `wiring-shapes` | Every shape in `references/wiring.md` keeps each expression on one line, orders the push endpoints, names the shipped script path, and steps its indentation by two |

Run one locally with `bash skills/harness-ci/tests/path-set.test.sh`.

`tools/bash32-lint` checks the shipped script for Bash 4+ syntax. It scans the
roster from `tools/bash32-lint --list`; consumer runners include macOS system
Bash 3.2.
