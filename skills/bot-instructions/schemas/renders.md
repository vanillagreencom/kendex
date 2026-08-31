# Render spec

One section per output. Each names the exact path, what the generator owns
inside it, which doctrine blocks it carries and in what order, and how repo
text from `bot-instructions.toml` is escaped into that file's syntax.

Doctrine block ids are `scope`, `rounds`, `severity`, `no-preferences`,
`declined`, `reply-contract`, `render-out-of-scope`, `trust-model`. They are
defined in the skill's SKILL.md § Doctrine, and the parse rule that finds them
is stated there.

## Common rules

**Block assembly.** A block's text is its heading's slice with the heading line
dropped and surrounding blank lines trimmed. `[doctrine.replace]` substitutes
the slice; `[doctrine.append]` adds its text as a final paragraph. The
`reply-contract` block's `<issue>` placeholder becomes `<PREFIX>-<n>` when
`[repo] tracker` is set.

**Marker.** Every file the generator owns whole, and the one region it owns
inside `AGENTS.md`, opens with a comment in that file's syntax naming this
package, its version, and its input files:
`bot-instructions.toml`, the doctrine source, and `kendex.toml` when
`[exclusions] derive_render` is true. The comment ends with the sentence `Edit
bot-instructions.toml or the doctrine source, then re-render.` A markdown
output uses an HTML comment; YAML and TOML use `#`.

The version in the marker is the one stamp a render carries. It is what makes a
repo running an older installed copy of this package visible: a version bump
re-renders every file, and the diff says which doctrine the repo moved to. The
marker is also how `render`, `adopt` and the `orphan` validator tell a
generated file from a hand-written one.

**Write phase.** The generator builds and validates a complete scratch tree,
writes a manifest of every path it is about to replace, then replaces them.
A failure part way through leaves the manifest, so re-running `render` finishes
the set, and `check` reds on every path still carrying the old bytes until it
does. What the design does not claim is an atomic multi-file replacement: no
filesystem offers one, and a mixed tree that says so beats one that does not.

**No timestamps and no input hashes** in a rendered file. A render is
reproducible from its inputs, and either would turn every unrelated re-render
into a diff.

**Ordering is fixed, never sorted at render time.** Doctrine blocks appear in
the order each section below states. `[[surface]]` entries appear in TOML
declaration order. Exclusion entries appear with the derived render trees
first, in lexicographic order, then `[[exclusions.path]]` entries in
declaration order. Stable ordering is what makes a re-render diff readable.

**Repo text is never reflowed.** Line breaks in a TOML multi-line string are
preserved except where a target's syntax forbids them, which is
`tone_instructions` alone.

**`exclude_globs` is real on one surface only.** Macroscope has an `exclude`
frontmatter key evaluated after `include`, so the subtraction is expressed
there. Copilot's frontmatter has no exclude key and CodeRabbit's
`path_instructions` entry has no exclude field, so on both the subtraction is
rendered as a closing sentence of the instruction text naming the paths the
rules do not cover. Those bots load the instructions for the excluded files and
are asked to disregard them. A surface needing exact scoping narrows `globs`.

## Doctrine routing

One table, one row per doctrine block, one column per destination that carries
doctrine. A number is that block's position in that destination; a dash is a
deliberate omission with its reason below. Every per-surface section below cites
this table rather than restating its own list, and the generator reads it as its
single routing input. A per-surface list written out in prose is a second copy
of this knowledge, and two copies drift.

| Block | AGENTS.md | copilot-instructions | .coderabbit.yaml | pr_agent issues | pr_agent compliance | pr_agent extra | REVIEW.md | macroscope doctrine.md |
|-------|-----------|----------------------|------------------|-----------------|---------------------|----------------|-----------|------------------------|
| `scope` | 1 | 1 | – (a) | 2 | – | 2 | 1 | 2 |
| `rounds` | 2 | 2 | – (a) | 3 | – | 3 | 2 | 3 |
| `severity` | 3 | 3 | – (a) | – | 1 | 4 | 3 | 4 |
| `no-preferences` | 4 | 4 | – (a) | 4 | – | 5 | 4 | 5 |
| `declined` | 5 | 5 | – (a) | – | 2 | 6 | 5 | 6 |
| `render-out-of-scope` | 6 | – (b) | 1 | 1 | – | 1 | – (c) | 1 |
| `trust-model` | 7 | – (b) | – (a) | – | 3 | 7 | – (c) | 7 |
| `reply-contract` | 8 | – (b) | – (a) | – | 4 | 8 | 6 | 8 |

`[repo] summary` follows the last block in `copilot-instructions`, both
`pr_agent` `[review_agent]` keys, `pr_agent extra`, and `macroscope
doctrine.md`.

**(a) `.coderabbit.yaml` carries one block.** CodeRabbit reaches the rest
through `knowledge_base.code_guidelines.filePatterns` naming `AGENTS.md`.
`render-out-of-scope` is the exception because it rides the `path: "**"`
instruction entry, where it is doing scoping work rather than repeating
doctrine.

**(b) Copilot reaches three blocks through `AGENTS.md`,** which code review
reads on GitHub.com. The pointer sentence in `copilot-instructions` is what
sends a reader there.

**(c) `REVIEW.md` omits two.** `render-out-of-scope` names trees whose exclusion
Qodo already carries in `[ignore]` and in the `[review_agent]` guidance, and
`trust-model` is about a merge gate's evidence rather than about writing a
finding. Both reach Qodo through `.pr_agent.toml`.

**`AGENTS.md` carries all eight**, and so does `macroscope doctrine.md`. Each is
its bot's only surface: neither Codex nor Macroscope reads a second instruction
file, has a path-scoped mechanism, or has anywhere else a block could arrive. A
block omitted from one of those two does not reach that bot at all.

**`best_practices.md` carries no doctrine.** It exists to give `[[surface]]`
text a route to Qodo, and `.pr_agent.toml` already carries every block.

**The `AGENTS.md` section is the doctrine root, not a Codex-only file.**
CodeRabbit reads it through `code_guidelines`, and Copilot code review reads it
directly, so `[bots] codex = false` with either of those on would leave
`.coderabbit.yaml` carrying one block and the Copilot pointer aimed at a section
that does not exist. `toml-schema` rejects that pair.

## `AGENTS.md` § Code Review Rules

Read by Codex, by Copilot code review on GitHub.com, and by CodeRabbit through
`knowledge_base.code_guidelines.filePatterns`. Rendered when `[bots] codex` is
true, which `toml-schema` requires whenever `copilot` or `coderabbit` is.

**Owned region.** From the heading line through the line before the next
`^#{1,2} ` heading, or end of file. The heading line matches `^## Code Review
Rules$` exactly: no trailing whitespace, no CR, no leading BOM. Exactly one such
heading must exist: zero is an error, and two is an error rather than a guess
about which one to replace. The generator replaces that region's body and
touches nothing else in the file.

The match is exact rather than forgiving on purpose. kendex's own `tools/guard`
slices this section with `grep -q '^## Code Review Rules$'` and an awk rule
keyed the same way, so a heading a looser generator accepted would be a heading
that repo's guard reports as missing. Where the two predicates differ, the
stricter one is the contract; a repo whose heading carries trailing whitespace
gets an error naming the byte rather than a render its own guard rejects.

**Missing section.** An error. The generator never creates `AGENTS.md` and
never adds the heading. Guidance for the repo: add the heading by hand, then
render.

**Body.** The marker as an HTML comment, then a line naming the audience and
pointing working agents elsewhere, then the blocks the `AGENTS.md` column of
the routing table carries, as bullets in its order. That this file is also read
by working agents is a reason to keep doctrine short, not a reason to route
part of it away from the one bot that reads nothing else.

One block renders as exactly one bullet, its paragraphs joined by a space and
no blank line inside. A repo guard that pins the reply contract reads it as a
single bullet, and a blank line ends that read.

A repo whose guard pins the tracked reply form needs `[repo] tracker` set.
kendex's does: it matches `Tracked: KEN-<n>` literally inside the `- Author
replies are` bullet, and an absent tracker leaves the generic `<issue>`
placeholder the render substitutes into, which that guard reads as the form
being gone.

**Escaping.** Markdown, passed through. A line that markdown would read as a
heading ends the owned region at the next render, so the generator refuses any
doctrine or repo line whose first non-whitespace character is `#` when it
follows three or fewer leading spaces. `bot-instructions.toml` refuses the same
shape at input time; this is the second check because doctrine text does not
come through that file.

## `.github/copilot-instructions.md`

Read by Copilot code review, repo-wide, from the pull request's head branch.

**Owned.** The whole file.

**Body.**

1. The marker comment.
2. `# <repo name>` followed by `[repo] summary`.
3. `# Code review calibration`, then the blocks the `copilot-instructions`
   column of the routing table carries, in its order, as `##` subsections.
4. `## Reply contract`, one sentence pointing at `AGENTS.md` § Code Review
   Rules, spelled with that exact file name and section name, emitted on one
   line and never wrapped. kendex's `tools/guard` matches
   `AGENTS\.md.*§ Code Review Rules` against a single line of this file, so a
   wrap splits the pointer in two and reds that guard.
5. `## Path rules`, one sentence naming `.github/instructions/` as where
   per-path rules live, emitted only when at least one `[[surface]]` exists.

Three blocks reach Copilot through `AGENTS.md` rather than through this file;
the routing table's note (b) says which and why.

**Budget.** The rendered file must not exceed `[budgets] copilot_chars`
(default 6000). Over it, the render fails naming the character count and the
budget. GitHub documents no numeric cap here; see `references/limits.md`.

**Escaping.** Markdown, passed through, with the same heading refusal as above
so a repo string cannot forge a section.

## `.github/instructions/<name>.instructions.md`

Read by Copilot code review on GitHub.com, JetBrains and Xcode, scoped by
`applyTo`.

**Owned.** One whole file per `[[surface]]`, named
`<surface.name>.instructions.md`. Files in that directory carrying no marker
are hand-written and are left alone; a marked file no current surface produces
is an orphan.

**Body.**

```markdown
---
applyTo: "<globs joined with a comma and no space>"
excludeAgent: "cloud-agent"
---

<!-- generated ... -->

<surface.instructions>
```

`excludeAgent` is emitted only when `reviewer_only = true`, and its only
permitted values are `code-review` and `cloud-agent`. `applyTo` is a single
non-empty string holding a comma-separated glob list, not a YAML array. The
glob dialect refuses a comma, so the join is unambiguous.

**Escaping.** The frontmatter is YAML. The glob dialect refuses `"`, so no
escaping is needed and a pattern that would need it is refused at input time.

## `.coderabbit.yaml`

Read by CodeRabbit from the pull request's head branch. The file outranks the
repository and organization dashboards and is itself outranked by an
organization or workspace global override, which a repo cannot see. Within what
the file controls, an unset key resolves down a precedence ladder this package
does not control, so the render writes full state including keys that match
their schema default.

**Owned.** The whole file.

**Head.** The `yaml-language-server` schema line, then the marker comment, then
a sentence stating that this file is not a delta and that a global override, if
one exists, outranks it.

**Keys.** In this order: `language`, `tone_instructions`, `early_access`,
`enable_free_tier`, `inheritance`, `reviews`, `chat`, `knowledge_base`.

`inheritance` is written `false` explicitly. It decides whether an unset key
takes a parent level's value instead of resolving down the ladder, which is the
one key that changes what "full state" means, so a full-state render states it
rather than relying on its default.

`tone_instructions` is `[tone] coderabbit` with newlines collapsed to single
spaces, emitted as a folded scalar, and hard-capped at 250 characters. The
shipped default when `[tone]` is absent:

> Terse and technical. Give the defect, its triggering input, and the
> consequence. No praise, diff restatement, or summary. One finding per thread.
> If unsure, name the part you could not verify.

`reviews` carries the findings-only posture: every summary, decoration,
labelling, reviewer-suggestion and fortune key false, `collapse_walkthrough`
true, `review_status` and `commit_status` true because a repo's gate may read
that status, `request_changes_workflow` true so a changes-requested review
converges without a human dismissing it, and every `finishing_touches` and
`pre_merge_checks` entry off because this package never lets a bot push code.

`reviews.auto_review.base_branches` is `[".*"]` rather than the default branch
by name. This one is fleet experience, not a documented behavior: naming the
branch has been observed to hit a base-branch mis-detection that skips pull
requests targeting the default branch, and the wildcard also covers stacked
pull requests.

**`reviews.path_filters`.** The exclusion set, each entry prefixed `!`, each
preceded by a comment carrying its `reason`. Exclusion-only: a single entry
without `!` turns the list into an allowlist and un-reviews every unlisted file
in the repo. The glob dialect is what keeps these patterns usable by `git
sparse-checkout`, which CodeRabbit feeds them to. Both rules are enforced by
`coderabbit-filters` in `validators.md` rather than left to the author.

**`reviews.path_instructions`.** One entry per `[[surface]]`. `path` is the
surface's globs joined as a brace alternation when there is more than one
(`{a/**,b/**}`), which minimatch understands and which is safe here because
`path_instructions` never reaches sparse-checkout. `instructions` is the
surface text with `exclude_globs`, when present, rendered as a closing sentence
naming the paths the rules do not cover. Each entry is capped at 20,000
characters.

A final entry with `path: "**"` carries `render-out-of-scope` when the
exclusion set is non-empty. The path filters already remove those trees; the
instruction is what stops a finding arriving through a file that references
them.

**`knowledge_base`.** `opt_out` false, every learning scope local, and
`code_guidelines.filePatterns` naming `AGENTS.md`. Pointing CodeRabbit at
`AGENTS.md` is the only way it reads that file.

**Escaping.** Every string is emitted as a block or folded scalar with explicit
indentation, never a quoted one-line scalar. Repo text is passed through with
no escaping, which block scalars make safe. A repo string containing a line
that would terminate the block is refused.

## `.pr_agent.toml`

Read by Qodo from the root of the default branch.

**Owned.** The whole file.

**Sections.**

- `[github_app]`: `pr_commands` from `[cadence] qodo_commands`,
  `handle_push_trigger` from `[cadence] qodo_push_trigger`.
- `[review_agent]`: `comments_location_policy = "inline"`,
  `issues_user_guidelines`, `compliance_user_guidelines`.
- `[pr_reviewer]`: `extra_instructions`, plus the noise keys off
  (`require_tests_review`, `require_security_review`,
  `require_ticket_analysis_review`, `enable_review_labels_security`,
  `enable_review_labels_effort`, `require_score_review`,
  `require_estimate_effort_to_review`, `require_can_be_split_review`,
  `persistent_comment`, all false).
- `[pr_description]`: `publish_labels = false`.

**Two sections carry the same guidance.** `/review` reads `[pr_reviewer]
extra_instructions`; `/agentic_review` reads `[review_agent]`. Whichever
command a repo runs, the guidance has to be in the section that command reads,
so the generator writes the same doctrine into both, split differently.

The routing table's three `pr_agent` columns say which block goes where and in
what order: `issues` and `compliance` split the set between the two
`[review_agent]` keys, and `extra` holds all eight in one string because
`[pr_reviewer]` has no per-agent split. `reply-contract` sits in `compliance`,
since a gate reading author replies is a compliance rule. Every block in `extra`
is in one of the two `[review_agent]` keys and the reverse, which is the
property `qodo-parity` checks.

`render-out-of-scope` leads all three, and this is the one place doctrine is
rendered ahead of everything else. Qodo has no per-path exclusion for review
content: its ignore surface is pull-request level plus
`allow_only_specific_folders`, an
allowlist gating whether analysis runs at all. Prose is the only exclusion
mechanism this bot has.

**`[ignore]`.** `glob` from the exclusion set, each entry as written, without
the `!` prefix CodeRabbit needs. This filters what Qodo analyzes for
`/improve`, not what the review agent reads, which is why the prose above
exists as well.

**Escaping.** Guidance strings are TOML basic multi-line (`"""`). A repo or
doctrine string containing `"""` is refused. Backslashes are escaped; TOML
basic strings interpret them.

## `best_practices.md`

Read by Qodo Merge, the commercial product, from the repo root. Rendered only
when `[bots] qodo_best_practices` is true.

**Owned.** The whole file.

**Body.** The marker comment, then one `##` section per `[[surface]]` holding
its `instructions`, headed by the surface name and its globs written out as
prose, and closing with the same `exclude_globs` sentence the Copilot and
CodeRabbit renders carry. Surface text has no other route to Qodo, so a
subtraction dropped here is a subtraction that never reaches it at all.

No doctrine. `.pr_agent.toml` carries every block already, which is why this
file has no column in the routing table.

**No surfaces.** The file is not written. An existing marked one becomes an
orphan, so retiring the last surface says so rather than leaving a
marker-only file that looks like current guidance.

**Caps.** 800 lines for this file. Qodo also documents a 2,000-line cap across
every best-practices source it loads, and the other sources are organization
and mapped-repository files this generator cannot see, so that cap is a
checklist line rather than a validator.

## `REVIEW.md`

Rendered only when `[bots] qodo_review_md` is true. That flag exists because
the file is inert until the portal's "REVIEW.md instructions" toggle is on, and
nothing in the repo can read the portal: someone works the checklist line, then
sets the flag.

**Body.** The blocks the `REVIEW.md` column of the routing table carries, in
its order, as plain markdown. Qodo documents no schema for it.

## `.macroscope/`

Rendered only when `[bots] macroscope` is true. Read from the most recent
commit on the pull request, except for a fork pull request, which reads the
default branch.

**`.macroscope/ignore.md`.** The marker as an HTML comment, then one glob per
line and nothing else. Each glob's `reason` is an HTML comment on the line
above it. Macroscope documents no grammar for this file, so the render assumes
the strictest reading, that every non-blank line is a pattern, and keeps every
non-pattern line inside a comment. Confirming that assumption once per repo is
a checklist line.

A `reason` is single-line and carries no `-->`, which is what stops a reason
from closing its own comment and putting a line of the author's choosing into
a file whose every line is a pattern. `bot-instructions.toml` refuses both at
input time.

Repository-wide: a check-run agent's own `include` overrides it, which is a
reason not to give an agent a broad `include`.

**`.macroscope/correctness/doctrine.md`.** No frontmatter, so it applies
repo-wide. Carries the blocks its routing-table column names, which is all
eight: `.macroscope/` is Macroscope's only instruction surface, it reads no
`AGENTS.md`, and a block left out here reaches it nowhere. Its name is reserved,
as are `correctness` and the two `.macroscope/` root names.

**`.macroscope/correctness/<name>.md`.** One per `[[surface]]`, frontmatter
`include` from `globs` and `exclude` from `exclude_globs`, both as YAML string
arrays. Macroscope evaluates `exclude` after `include`, which matches the
TOML's meaning directly, so this is the one surface where the subtraction needs
no restatement in prose.

**Not written.** `.macroscope/check-run-agents/`,
`.macroscope/approvability.md`, and `.macroscope/correctness/correctness.md`.
The first two create merge-blocking check runs and per-run spend, which is a
decision a repo owner makes, not one a doctrine render makes for eight repos at
once. The third is Macroscope's governing file: spelled exactly that way at the
top of `correctness/`, it carries `waitsFor`, `requires`, `waitsForTimeout` and
`waitsForDiscoveryTimeout` for the whole correctness run. `macroscope-render`
permits no frontmatter key but `include` and `exclude`, so a render over it
would drop those four permanently and Macroscope only warns. A repo keeps its
own governing file, hand-written and unmarked, and no surface may be named
`correctness`.

**Escaping.** Frontmatter is YAML; globs are emitted as quoted scalars, and the
glob dialect refuses the one character that would need escaping.
