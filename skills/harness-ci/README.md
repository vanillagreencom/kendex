# harness-ci

A repository that commits its kendex render gets diffs that touch nothing it
builds, lints, typechecks or tests. This package ships the one function that
recognises them — changed paths in, `harness_only=true|false` out — plus the
tests that prove the semantics, run in kendex CI on every change. Content
the repository authors inside the render trees — skills its manifests
(`kendex.toml`, or `kendex-local.toml` in a source catalog) declare
`source = "in-place"` for, scripts under `.agents/hooks` — is project
source, and any change to it answers `false`.

Opt-in: running CI over harness directories is a policy choice, and a repo
that wants it simply does not install this.

## The contract

**This package never touches `.github/`.** The classifier is portable; a
workflow is not. Installing into a stranger's CI renames jobs, drops
required contexts, and wedges merge queues.

What a consumer owns is one thin step calling the rendered script, written
by hand, once. What upstream owns is the answer that step gets. Copy a shape
from [references/wiring.md](references/wiring.md).

## Usage

```bash
.agents/skills/harness-ci/scripts/harness-only \
  --event pull_request --base "$BASE_SHA" --head "$HEAD_SHA"
```

| Flag | Meaning |
| --- | --- |
| `--event` | `pull_request`, `merge_group` or `push`. Any other event answers `false`. |
| `--base` | The PR base sha, the merge group's base sha, or a push's `before` sha. |
| `--head` | The head endpoint. Default `HEAD`. |
| `--repo` | Classify this checkout instead of the working directory. |
| `--output` | Append the verdict line to this file. Default `$GITHUB_OUTPUT`. |

Checkout with `fetch-depth: 0`: the classifier diffs two real commits, and a
shallow clone does not hold both.

**Install with the default symlink delivery.** That writes the shared
`.agents/skills/harness-ci/` tree every harness reads, which is the path above
and the path in every wiring example. `--method copy` writes each tool its own
tree instead (`.claude/skills/harness-ci/`, and so on) and writes no `.agents`
tree at all — a repo on copy delivery has to point its step at whichever of
those trees it committed.

## Semantics

- **The harness path set**: `.agents/`, `.claude/`, `.codex/`, `.opencode/`,
  `.cursor/`, `.pi/`, and the root OpenCode config under either spelling —
  `opencode.json` or `opencode.jsonc`, which is the file kendex writes when a
  project carries that one. Prefixes match on the separator and the config
  names match whole, so `.agentsfoo/x`, `opencode.json.bak` and
  `ui/opencode.json` are product paths.
- **`--no-renames`, always.** Rename detection emits only the post-image, so
  `git mv src/app.ts .agents/skills/x/app.ts` would list one harness path and
  nothing else — the deletion of `src/app.ts` would go unjudged. With the
  flag, both paths are listed and the diff answers `false`.
- **The in-place read**: the manifests come from the selected head tree, and
  the reader knows the one shape kendex writes — a `[skills.<name>]` header
  holding a bare or plain double-quoted key, then `source = "in-place"`. It
  does not parse the other spellings TOML allows. It counts every line that
  could take part in spelling the value instead — a bare `in-place`, a
  `\u`/`\U`/`\x` escape, a multiline `source` string — and carves every
  `.agents/skills` path when one goes unaccounted. An apostrophe-quoted key,
  a dotted key, an inline table, a nested table, a name wearing whitespace,
  an escaped name and an escaped value all answer `false` that way, and so
  does `source = "in-place"` under any table but `[skills.<name>]`, the only
  one that accounts.
- **Merge base on `pull_request`** (`base...head`): the base branch moves
  under an open PR, and only the merge base isolates what the PR changed.
- **Two endpoints on `push` and `merge_group`** (`base head`): a force-push
  leaves the `before` sha off the head's history, and a merge base there is a
  commit the push already discarded — measuring from it reads a push that
  dropped product work as render-only. A merge group's base is an ancestor of
  its head by construction, so the two forms agree there.
- **Verdict channel**: `stdout` carries `harness_only=true|false` and nothing
  else. Changed paths and failure reasons go to `stderr`.
- **Exit codes**: `0` with every verdict; `2` on a wiring error (unknown flag,
  missing `--event`, a flag where a value belongs, unwritable `--output`),
  which prints no verdict.

## Fail-closed

Anything the classifier cannot prove answers `false`, which runs every lane:

- an unclassified event
- a missing, empty, or unresolvable endpoint — the all-zero sha a first push
  sends included
- a diff git cannot read
- an empty changed-file set, which is also what a diff that read nothing
  looks like
- a path git had to quote (an embedded newline or quote character), which
  matches no harness prefix
- a manifest the head tree lists but that will not read — a symlink entry, an
  unreadable blob — which carves every `.agents/skills` path

There is no flag that turns any of these into a `true`.

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

Bash 4+ syntax in the shipped script is `tools/bash32-lint`, which scans the
roster `tools/bash32-lint --list` prints — consumer runners include macOS
system Bash 3.2.

## Upgrades

The script is upstream's. `kendex refresh` rewrites the render tree, and a
local edit to `.agents/skills/harness-ci/` is drift that the next refresh
overwrites. Send changes to
[vanillagreencom/kendex](https://github.com/vanillagreencom/kendex) via
`kendex report`.
