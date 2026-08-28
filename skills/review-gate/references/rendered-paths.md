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
| The upstream remedy | Re-vendor | `kendex report`, then re-render |
| Blast radius of one thread | This repo | Every consuming repo on its next refresh |

The last row is what changes the rule. The vendored template routes
upstream-remedy findings to the review summary body and keeps one carve-out: a
correctness, security, or data-loss regression the bump introduces gets an
inline comment and blocks.

**Over a render the carve-out goes.** It is the clause a reviewer argues with,
and a bot that believes it found a security defect in rendered output takes it
every time. The thread it opens blocks the merge until answered, in several
consuming repos at once, for a fix that can land in none of them. The rule
here is flat on every surface, and the remedy is `kendex report`.

## Deriving the glob

Two commands, run in the consumer repo:

```bash
# 1. The harness trees this repo commits.
git ls-files | grep -oE '^\.[a-z]+/' | sort -u

# 2. Items whose content this repo owns — their .agents subtree is NOT
#    render output and gets an ordinary review.
grep -E '^\[|^source = ' kendex.toml | grep -B1 '^source = "in-place"'
```

Two shapes the glob must not take:

- **`.github/**`.** Copilot renders into `.github/agents`, `.github/hooks`,
  and `.github/skills`; the rest of `.github` — workflows, this instruction
  directory, issue templates — is repo-owned and gets an ordinary review.
- **A whole `.agents/**` in a repo holding in-place items.** An item declared
  `source = "in-place"` keeps its content of record at `.agents/<kind>/<name>`
  and is edited here. Its per-harness copies are still render output.

Check the result against the file list of a real refresh PR before relying on
it.

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
   ([vendored-paths.md](vendored-paths.md) § Reviewer classes). A repo whose
   reviewers are ALL location-bound gets the one-consolidated-comment bound,
   not silence.
4. Mirror the rule in the repo's reviewer-guidance file, for reviewers that do
   not read path-scoped instructions.
5. Change no gate settings. A render tree carries evidence only through the
   `vendored` class and `REVIEW_GATE_VENDORED_PATHS`
   ([settings.md](settings.md)), and hand-edited policy markdown under it
   belongs in `REVIEW_GATE_CARRY_FORWARD_EXCLUDE`, which wins.

## Reporting a finding upstream

`kendex report --skill [NAME] --title [TITLE] --body-file [PATH]` routes the
issue to the repo that owns the item. `--agent`, `--hook`, and `--asset` are
the other selectors; pass at most one, and pass exactly one of `--body` or
`--body-file`. Two preconditions decide the route:

- **A skill routes on its installed `SKILL.md` frontmatter alone** — `source:
  kendex`, or a `repository:` naming the upstream slug. A committed render
  carries that frontmatter at the install path, which is what a scripts-only
  vendor lacks.
- **An agent, hook, or Pi extension routes on the lock entry** — its
  `source_repo` must match the upstream the report targets.

With no selector the CLI warns once and files against this repo. Verify the
route before relying on it, or open the upstream issue by hand.

Do not fix it locally, and do not file the same finding from each consumer.

## Verifying on a real refresh PR

Run [vendored-paths.md](vendored-paths.md) § Verifying on a real re-vendor PR
against the first refresh PR after the change, reading `pr-threads` over the
render trees rather than the vendored one. **Pass** for a render is stricter:
a trusted non-author review object at the current head, gate `success`, and no
unresolved thread over the render from a summary-capable reviewer — including
none raising a correctness, security, or data-loss defect, which the flat rule
routes upstream. Threads from a location-bound reviewer are counted and
recorded, not graded.
