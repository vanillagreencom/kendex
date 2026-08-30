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
| What a local edit meets | Nothing automatic; the pin turns red | The next `kendex refresh` holds the item as a conflict and plans no write |
| A pin or checksum manifest | Exists, and is the point | Does not exist — the refresh's own conflict row is the red |
| A local fix | Wrong, and visible | Wedges that item's refresh until someone forks it or discards the edit |
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

# Skills whose content this repo owns, as bare names from both sides so the
# two lists subtract. Take the UNION: the manifest is the declaration, the
# lock is what the last apply recorded, and an item kendex refused to install
# keeps its old lock entry verbatim through every later refresh — where they
# disagree, the manifest settles it.
awk -F'[].[]' '/^\[skills\./ { n = $3 } /^[[:space:]]*source[[:space:]]*=[[:space:]]*.in-place./ { if (n != "") print n; n = "" }' kendex.toml
jq -r '.entries[] | select(.source == "in-place" and .kind == "skill") | .name' .kendex-lock.json | sort -u

# Recorded render destinations, as absolute paths to strip the repo root
# from. The lock carries this field for skills and commands only, so it names
# no agent file, no hook script, and nothing for the other kinds — it adds
# exact paths and never completes the list.
jq -r '.entries[] | select(.emitted != null) | .emitted.paths[]' .kendex-lock.json | sort -u
```

That awk reads top-level `[skills.<name>]` tables in `kendex.toml` and
nothing else. It does not see a `[skills]` table holding inline entries,
dotted or quoted keys, an indented declaration, or `kendex-local.toml`, which
a source catalog keeps its own install state in. A repo wanting a mechanical
answer over those has a worked precedent in the harness-ci skill's
`harness-only` script, § `manifest_carves`: it reads both manifests from the
head tree and fails closed, carving every skill path when a manifest will not
read or says `in-place` on a line it cannot tie to a name. Do not build a
second one here.

What backstops the gap is the section's own authority: an in-place skill's
content tree at `.agents/skills/<name>` is bytes kendex reads and never
writes, so a refresh PR never touches it. The per-harness link or copy into
`.claude/skills/<name>` and its siblings IS written, and does appear in the PR
that creates it.

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
  edited here and that an edit wedges the next refresh; over a merged path
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

```bash
kendex report --skill [NAME] --title [TITLE] --body-file [PATH] --dry-run
```

`--skill`, `--agent`, `--hook`, and `--asset` are the selectors; pass one, and
exactly one of `--body` or `--body-file`. `--dry-run` prints the decision and
the `gh` command it would run.

The lock is the one judge, and it records provenance for every kind — skills,
agents, hooks and Pi extensions alike. A name routes upstream when the lock
holds at least one entry for it, narrowed to the kind the selector names, and
EVERY matching entry's `source_repo` is kendex's own repo, the one candidate
the comparison holds. One entry recorded from somewhere else makes the name
ambiguous and keeps the report here, which is also what an unlocked name gets.
How the manifest spelled the repo does not decide it: a shorthand, an https URL
and a `git@` reference fold to one identity.

**Kendex is the only destination the route reaches.** An item rendered from a
third-party catalog carries that catalog in its lock entries, never the
candidate, and its report files against this repo — open the issue in that
catalog by hand.

With no selector at all the CLI warns once that ownership could not be
determined and files against this repo. Confirm with `--dry-run` before
relying on any of it.

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
