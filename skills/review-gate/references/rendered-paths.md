# Reviewing the committed harness render

For consumers that commit `kendex refresh` output and merge refresh PRs.
Suppressing duplicate findings over that tree is a reviewer-instruction
problem; configuration answers break the gate.

The byte-pinned sibling is [vendored-paths.md](vendored-paths.md). Three of its
sections apply here unchanged and are not restated: **What suppression must not
break**, **The trap: reviewer path exclusion**, and **Reviewer classes**.

## What is different from a byte-pinned tree

| | Byte-pinned vendored tree | Harness render |
|---|---|---|
| What reverts a local edit | Nothing automatic; the pin turns red | The next `kendex refresh`, wholesale and silently |
| A pin or checksum manifest | Exists, and is the point | Does not exist |
| A local fix | Wrong, and visible | Reads as closed while the bytes go back |
| The upstream remedy | Re-vendor | An issue in the catalog repo, then re-render |
| Blast radius of one thread | This repo | Every consuming repo on its next refresh |

The last row is what changes the rule. The vendored template routes
upstream-remedy findings to the review summary body and keeps one carve-out: a
correctness, security, or data-loss regression the bump introduces gets an
inline comment and blocks.

**Over a render the carve-out goes, and so does the summary-body route.** The
carve-out is the clause a reviewer argues with, and a bot that believes it
found a security defect in rendered output takes it every time. The thread it
opens blocks the merge until answered, in several consuming repos at once, for
a fix that can land in none of them. The rule here is flat on every surface,
which also removes the reason the vendored template gives a location-bound
reviewer a consolidated-comment fallback: under a flat rule there is no
on-PR surface to fall back to.

## Deriving the glob

The trees kendex writes into a project are `.agents/skills`, `.claude`,
`.codex`, `.cursor`, `.gemini`, `.opencode`, `.pi`, and for Copilot the
`agents`, `hooks`, and `skills` subtrees of `.github`. The shared tree is
scoped to `skills` rather than all of `.agents`: adoption moves a custom
hook's own script into `.agents/hooks` and rewrites the registration around
it, and that script is the repo's. Each of the rest can also hold files kendex
never writes.

**The file list of a real refresh PR is the authority.** kendex exposes no
single answer to what it renders here, and the commands below only build a
candidate list to check against that PR.

```bash
# Candidates only — this lists every tracked lowercase dot-directory,
# including .vscode, .devcontainer, .husky and the rest.
git ls-files | grep -oE '^\.[a-z]+/' | sort -u

# Items whose content this repo owns. Subtract the UNION of both lists: the
# manifest is the declaration, the lock is what the last apply recorded, and
# an item kendex refused to install keeps its old lock entry verbatim through
# every later refresh — where they disagree, the manifest settles it.
awk -F'[].[]' '/^\[/ { t = $2; n = $3 } /^[[:space:]]*source[[:space:]]*=[[:space:]]*.in-place./ { print t "/" n }' kendex.toml
jq -r '.entries | to_entries[] | select(.value.source == "in-place") | .value.name' .kendex-lock.json | sort -u

# Recorded render destinations, as absolute paths to strip the repo root
# from. The lock carries this field for skills and commands only, so it names
# no agent file, no hook script, and nothing for the other kinds — it adds
# exact paths and never completes the list.
jq -r '.entries[] | select(.emitted != null) | .emitted.paths[]' .kendex-lock.json | sort -u
```

Four shapes the glob must not take:

- **`.github/**`.** Copilot renders into `.github/agents`, `.github/hooks`,
  and `.github/skills`. The rest of `.github` — workflows, this instruction
  directory, issue templates — is repo-owned. `.github/mcp.json` and
  `.github/copilot/settings.json` plus `settings.local.json` are a third
  thing, covered by the last shape below.
- **Every `.agents/skills/<name>` an item declares in-place.** An item
  declared `source = "in-place"` keeps its content of record there and is
  edited here. The subtraction is a name list, from the two commands above.
  The item's per-harness copies are still render output.
- **The harness memory files** — `CLAUDE.md`, `AGENTS.md`, `GEMINI.md`.
  kendex writes none of them. A repo keeping `.claude/CLAUDE.md` has one
  inside a `.claude/**` glob.
- **Anything kendex merges into rather than writes whole.** This is a class,
  not a list: where kendex writes its own entries into a file or directory the
  repo owns the rest of, that path is repo-owned and stays out. Named
  instances, which are examples and not the whole set —
  `.claude/settings.json` and `settings.local.json`, `.codex/config.toml`,
  `.codex/hooks.json`, `.cursor/hooks.json`, `.cursor/mcp.json`,
  `.gemini/settings.json`, `.pi/settings.json`, `.mcp.json`, the Copilot files
  above, `.opencode/instructions/` where only `kendex-hook-*.md` is render
  output, and — outside every dot-directory, so the candidate list cannot see
  it — the root `opencode.json` or `opencode.jsonc`. This is the shape that
  most needs keeping out. The template asserts that nothing under the glob is
  edited here and that a refresh overwrites it wholesale; over a merged path
  both are false, and the flat no-carve-out rule would then forbid raising a
  correctness or security defect over content this repo owns and can fix.

Read the shapes as the rule and the file list of a real refresh PR as the
check. A path that appears in neither the candidate list nor that PR does not
belong in the glob.

## Wiring a repo

1. Copy [`../templates/rendered-paths.instructions.md`](../templates/rendered-paths.instructions.md)
   into the repo's path-scoped reviewer instruction directory —
   `.github/instructions/`, as a `*.instructions.md` file — set `applyTo` to
   the glob derived above, and delete the fill comment. Repo-owned after the
   copy.
2. **Replace any existing instruction scoped to the same tree — do not add
   alongside it.** Merge any repo-specific carve-ins the old clause held into
   the new body.
3. Classify each reviewer the repo runs as summary-capable or location-bound
   ([vendored-paths.md](vendored-paths.md) § Reviewer classes). The flat rule
   asks the same thing of both: no finding over the render on any surface of
   this PR, and a submitted review either way. The residual that section
   records still holds — a reviewer whose schema binds one finding to one
   location emits a thread anyway, and that is answered, not graded.
4. Mirror the rule in the repo's reviewer-guidance file, for reviewers that do
   not read path-scoped instructions.
5. Change no gate settings. A render tree carries evidence only through the
   `vendored` class and `REVIEW_GATE_VENDORED_PATHS`
   ([settings.md](settings.md)), and hand-edited policy markdown under it
   belongs in `REVIEW_GATE_CARRY_FORWARD_EXCLUDE`, which wins.

## Filing the finding against the catalog repo

This is the refresh session's half, not a reviewer's. Once per refresh train,
on ONE consumer PR, collect the findings over the render and file them where
the render is written. Do not fix it locally, and do not file the same finding
from each consumer.

`kendex report --title [TITLE] --body-file [PATH]` files it, with one selector
and exactly one of `--body` or `--body-file`. `--dry-run` prints the route it
would take. What the route resolves to today, verified against
`crates/core/src/report.rs`:

- **`--agent`, `--hook`, and a `--asset` naming either** route on the lock
  entry's `source_repo`. That is the working path.
- **`--skill` and a `--asset` naming a skill route to this repo, not
  upstream.** Skill ownership is read from the installed `SKILL.md`
  frontmatter alone, and it accepts exactly two values: `source: kendex`, or a
  `repository:` equal to the built-in `vanillagreencom/kendex` — never what
  `--upstream` names, which only the lock branch compares against. Neither can
  match: the reader takes `source:` and `repository:` only at column zero,
  where a kendex skill nests both under `metadata:`, and renders `repository:`
  as a URL rather than the slug. Open the issue in the catalog repo by hand,
  or report it under the agent or hook that carries the skill.
- **With no selector** the CLI warns once and files against this repo.

Confirm with `--dry-run` before relying on any of it.

## Verifying on a real refresh PR

Run [vendored-paths.md](vendored-paths.md) § Verifying on a real re-vendor PR
against the first refresh PR after the change, reading `pr-threads` over the
render trees rather than the vendored one. **Pass** for a render is stricter
in one term: a trusted non-author review object at the current head, gate
`success`, and no unresolved thread over the render from a summary-capable
reviewer — including none raising a correctness, security, or data-loss
defect, which the flat rule routes to the catalog repo and the vendored
carve-out would have admitted. Threads from a location-bound reviewer are
counted and recorded, not graded.
