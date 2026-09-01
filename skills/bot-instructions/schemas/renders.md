# Render spec

One section per output. Each names the exact path, what the generator owns
inside it, which doctrine blocks it carries and in what order, and how repo
text from `bot-instructions.toml` is escaped into that file's syntax.

Doctrine block ids are the `###` headings of the doctrine source, whose parse
rule is SKILL.md § Doctrine. The routing table below is the only other place
they are written down, and `doctrine-routing` holds the two to the same set.

## Common rules

**Block assembly.** A block's text is its heading's slice with the heading line
dropped and surrounding blank lines trimmed. `[doctrine.replace]` substitutes
the slice; `[doctrine.append]` adds its text as a final paragraph. The
`reply-contract` block's `<issue>` placeholder becomes `<PREFIX>-<n>` when
`[repo] tracker` is set.

**Marker.** Every file the generator owns whole, and the one region it owns
inside `AGENTS.md`, carries a marker: the file's **first comment**, preceded
only by a prologue the format requires. There are exactly two such prologues,
and no output has any other: YAML frontmatter in a `.instructions.md` file,
which is frontmatter only at byte 0, and the `yaml-language-server` schema line
at the top of `.coderabbit.yaml`. Ownership is decided by the marker being
present, never by its offset, so `render`, `adopt` and `orphan` all ask the same
question of every output.

The marker is a comment in that file's syntax naming this package, the spec
copy's version, and the paths this render read — SKILL.md § The render inputs
is the set, and each is named by the path actually read. The comment ends with
the sentence `Edit bot-instructions.toml or the spec copy, then re-render.` A
markdown output uses an HTML comment; YAML and TOML use `#`.

The version is the spec copy's, not the running copy's, since `--spec` can point
them at different copies and the stamp has to name the doctrine the file
carries. It is the one stamp a render carries, and what makes a repo running an
older installed copy of this package visible: a version bump
re-renders every file, and the diff says which doctrine the repo moved to. The
marker is also how `render`, `adopt` and the `orphan` validator tell a
generated file from a hand-written one.

**The marker gate is read on the file opened for the replacement**, never on an
earlier read of the repo. A path whose marker is absent at that moment fails
naming the path rather than being replaced — the same form § `AGENTS.md` uses
for a region that moved between the build and the write, and for the same
reason. The gate is what stops a render from destroying hand-written bot files,
so proving it against a copy read before the write phase leaves the whole write
phase as a window: a hand edit, a marker deletion, or another run landing in it
would have the render overwrite exactly the content the gate exists to protect,
silently. `orphan` keeps its pre-write read of the repo, because it reports and
writes nothing.

**Write phase.** The generator builds and validates a complete scratch tree,
writes a manifest of every path it is about to replace, then replaces them.
A failure part way through leaves the manifest, so re-running `render` finishes
the set, and `check` reds on every path still carrying the old bytes until it
does. What the design does not claim is an atomic multi-file replacement: no
filesystem offers one, and a mixed tree that says so beats one that does not.

**Each individual replacement is atomic**, the `AGENTS.md` splice included. An
interrupted write leaves the old bytes, never a truncated file. That is what
makes the mixed tree above a recoverable state rather than a lost one: every
path holds either its old content or its new one, so a recovery render has
something to compare and `check` has something to report. It matters most for
`AGENTS.md`, which the splice makes a genuine read-modify-write during the write
phase — a truncate-then-write interrupted midway would leave the repo's own file
cut off, and that file is the doctrine root three of the five bots read. This
repo's own convention is the mechanism: write a temp file and rename it over the
target, one temp name per write.

The rest of the write path — how the lock is acquired and released, where the
scratch tree lives and how it is made unique per run, where the manifest lives
and when it is removed — is the generator's to define. This spec states the
properties a caller can rely on; KEN-1006 owns the mechanics that hold them.

`AGENTS.md` is outside that scheme, because it is the one output whose
non-owned bytes belong to the repo. Carrying a build-phase copy of the whole
file through validation and writing it back would discard anything written to
it in that window — an editor, a formatter, another lane of the repo's commit
chain — silently, in the one file this package says it does not own. So the
build produces the region's body alone, and § `AGENTS.md` says what the write
does with it.

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

`[repo] summary` placement, since the destinations differ: it opens
`copilot-instructions`, immediately after the `# <repo name>` line and before
every block. Everywhere else it follows the last block — both `pr_agent`
`[review_agent]` keys, `pr_agent extra`, and `macroscope doctrine.md`.

**The exclusion set's placement.** Where it is rendered, it follows the
`render-out-of-scope` block immediately, in the same bullet or paragraph that
block renders as, in the exclusion set's own fixed order. Three destinations
carry it: `AGENTS.md`, `pr_agent issues`, and `pr_agent extra` — the columns
whose `render-out-of-scope` cell carries a number and whose bot has no
file-based review exclusion. Copilot needs no fourth, because note (b) already
routes this block to it through `AGENTS.md`, which it reads.

`.coderabbit.yaml` and `macroscope doctrine.md` carry the block without the
paths: `path_filters` and `ignore.md` subtract them for real a few keys away,
and a second copy of a list the same file enforces is the drift this spec spends
a rule avoiding. `REVIEW.md` omits the block entirely, which note (c) records.

What that buys, per surface, since the five do not get the same thing:

| Surface | Mechanism | Enforced |
|---------|-----------|----------|
| CodeRabbit | `reviews.path_filters`, exclusion-only | yes, the files are not reviewed |
| Macroscope | `.macroscope/ignore.md` | yes, repo-wide across check runs |
| Codex | the rendered paths in the `AGENTS.md` owned region | no |
| Copilot | the same rendered paths, since it reads `AGENTS.md` | no |
| Qodo | the rendered paths in `issues` and `extra` | no |

The three unenforced rows are why the paths are rendered at all. Codex has no
file-based exclusion, Copilot's is a settings page no repo file reaches, and
Qodo's `[ignore]` governs `/improve` analysis rather than review content. Naming
the paths makes the instruction actionable; SKILL.md § Every rendered config
excludes the render trees carries the requirement and the plain statement that
those three may comment anyway.

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
heading at level 1 or 2, or end of file. The generator replaces that region's
body and touches nothing else in the file.

The two ends use different predicates, deliberately. The **opening** matches
`^## Code Review Rules$` exactly — no trailing whitespace, no CR, no leading
BOM — because kendex's `tools/guard` slices this section the same way, and a
heading a looser generator accepted would be one that repo's guard reports as
missing. Exactly one such heading must exist: zero is an error, and two is an
error rather than a guess about which one to replace. The **terminator** uses
the wide heading predicate from `repo-toml.md` § The content refusals, at level
1 or 2. Anything narrower would fail to see a following section whose `#` sits
after one to three spaces — markdown reads that as a heading, so the repo owns
it, and a terminator that missed it would let the splice swallow that section
and everything below it. It is also the predicate the input refusals already
use, so the two agree.

Where the opening predicates differ, the stricter one is the contract: a repo
whose heading carries trailing whitespace gets an error naming the byte rather
than a render its own guard rejects.

**Missing section.** An error. The generator never creates `AGENTS.md` and
never adds the heading.

**The bootstrap is add-the-heading, set `[bots] codex`, `adopt`, then
`render`.** The flag precedes the `adopt` because `adopt` takes a region over
only for a capability that is on. A hand-added heading leaves an unmarked region
at a generated path, and `render` refuses to replace one of those — the rule
that stops it destroying hand-written bot files. `adopt` is the verb that makes
an unmanaged thing managed, and a region is no different from a file in that
respect, so it takes the region over and
names it in what it prints. No bootstrap exemption: an exemption would need a
boundary between a region `render` may write unmarked and a hand-written one it
must refuse, and every boundary anyone can state there reopens the overwrite the
marker gate exists to prevent.

**The splice happens at write time.** The build phase produces the region's
body; the write re-reads `AGENTS.md`, locates the owned region in those bytes,
and replaces it there. Nothing outside the region is ever carried through the
build, so an edit landing between the build and the write survives instead of
being overwritten by a copy taken before it. A file whose region cannot be
located at write time — the heading gone, or duplicated, since the build read it
— fails naming the path rather than guessing where the region went.

**Body.** The marker as an HTML comment, then a line naming the audience and
pointing working agents elsewhere, then the blocks the `AGENTS.md` column of
the routing table carries, as bullets in its order. That this file is also read
by working agents is a reason to keep doctrine short, not a reason to route
part of it away from the one bot that reads nothing else.

One block renders as exactly one bullet, its paragraphs joined by a space and
no blank line inside. A repo guard that pins the reply contract reads it as a
single bullet, and a blank line ends that read.

The `render-out-of-scope` bullet is the one that carries data as well as
doctrine: the exclusion set follows its text in the same bullet, comma-joined in
the set's fixed order. It stays inside the owned region like everything else the
generator writes there, so the region's rules are unchanged — one bullet, no
blank line, no line a heading predicate would catch — and a path is not a
heading, so nothing about the region's boundaries moves. This is the only place
Codex can receive those paths, since it reads no second file.

A repo whose guard pins the tracked reply form needs `[repo] tracker` set.
kendex's does: it matches `Tracked: KEN-<n>` literally inside the `- Author
replies are` bullet, and an absent tracker leaves the generic `<issue>`
placeholder the render substitutes into, which that guard reads as the form
being gone.

**Escaping.** Markdown, passed through. A line that markdown would read as a
heading ends the owned region at the next render, so the generator refuses any
doctrine or repo line matching the heading predicate in `repo-toml.md` § The
content refusals. That file refuses the same predicate at input time; this is
the second check because doctrine text does not come through it, and that table
records which classes get a second check here and which do not.

## `.github/copilot-instructions.md`

Read by Copilot code review, repo-wide, from the pull request's head branch.

**Owned.** The whole file.

**Body.**

1. The marker comment.
2. `# <repo name>` followed by `[repo] summary`, which the routing table's
   placement note names as this destination's opening rather than its close.
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

**Escaping.** Markdown, passed through, with the same heading predicate as
above so a repo string cannot forge a section.

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

`excludeAgent` is emitted only when `reviewer_only = true`, and then only as
`cloud-agent`. The value names the agent the file is hidden from, so
`cloud-agent` keeps it from the working agent and leaves code review reading it;
`code-review` is the exact opposite and is never what a reviewer-only surface
wants. `copilot-frontmatter` requires the key and that value for such a surface
rather than accepting the enum. `applyTo` is a single non-empty string holding a
comma-separated glob list, not a YAML array. The glob dialect refuses a comma,
so the join is unambiguous.

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

**The vendored schema** `coderabbit-schema` validates against lives at
`.bot-instructions/coderabbit-schema.json`. The path is fixed by this spec
rather than configurable, because a configurable one is repointable by the same
pull request whose file the schema is meant to judge, and it has to be
enumerable to sit in the policy set at all. A change to it is a policy change:
loosened, the validator goes green on a file CodeRabbit discards whole, and
stays green afterwards.

**Keys.** Every top-level property the vendored schema defines, in this order:
`language`, `tone_instructions`, `early_access`, `enable_free_tier`,
`inheritance`, `reviews`, `chat`, `knowledge_base`, `code_generation`,
`issue_enrichment`.

The last two are here for the same reason as the rest. Full state means every
key, or the ones left out keep resolving down the ladder this package does not
control, and the file's claim about itself stops being true.
`code_generation` is written with its docstring and unit-test generation off,
matching the `finishing_touches` posture that never lets a bot push code;
`issue_enrichment` is written off, since this package configures review and not
issue triage.

The list is transcribed from a schema that moves, which is the shape that goes
stale, so `coderabbit-schema` also fails when the render omits a top-level
property the vendored schema defines. The next schema refresh then reports the
gap instead of silently widening it.

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
preceded by a comment carrying its reason — the entry's own `reason` where it
has one, and the fixed string `repo-toml.md` § `[exclusions]` states for a
derived entry, which has no TOML row to carry one. Exclusion-only: a single entry
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
indentation, never a quoted one-line scalar. Repo text is passed through with no
escaping, which block scalars make safe for everything a YAML scalar can hold. A
repo string containing a line that would terminate the block is refused, and so
is one carrying a control character, by the same refusal `.pr_agent.toml` relies
on: a block scalar cannot carry one either, and one predicate covers both
targets because the values reaching them are the same set.

## `.pr_agent.toml`

Read by Qodo from the root of the default branch.

**Owned.** The whole file.

**Head.** The marker comment, before the first section, as `#` lines.

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

`render-out-of-scope` takes position 1 in the two columns that carry it, which
is the one place doctrine is rendered ahead of everything else; the table says
which those are. In `issues` and `extra` it carries the exclusion paths after
its text, because Qodo's `[ignore]` filters what it analyzes for `/improve`
rather than what the review agent reads, so prose is the only route those paths
have to it. Qodo has no per-path exclusion for review content: its ignore
surface is pull-request level plus `allow_only_specific_folders`, an
allowlist gating whether analysis runs at all. Prose is the only exclusion
mechanism this bot has.

**`[ignore]`.** `glob` from the exclusion set, each entry as written, without
the `!` prefix CodeRabbit needs. This filters what Qodo analyzes for
`/improve`, not what the review agent reads, which is why the prose above
exists as well.

**Escaping.** Guidance strings are TOML basic multi-line (`"""`), which is why
every value reaching one is under that table's toml-delimiter and control
refusals in `repo-toml.md` § The content refusals — the table marks which
values, and carries both predicates. A backslash is escaped, which is the only
rewriting done here: it is a legal character a format requires escaping, not
content the render is deciding to change. Everything the format cannot carry is
refused at input instead.

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

**Budget.** 800 lines for this file. Qodo gives that number as writing guidance
and states no length at which it rejects or truncates, so the budget is this
package's own, taken from that guidance the way `[budgets] copilot_chars` is
taken from a two-page reading; `references/limits.md` marks it a recommendation
and carries the page. Organization and mapped-repository best-practices files
layer above this one and the generator cannot see them, so nothing here bounds
the total.

## `REVIEW.md`

Rendered only when `[bots] qodo_review_md` is true. That flag exists because
the file is inert until the portal's "REVIEW.md instructions" toggle is on, and
nothing in the repo can read the portal: someone works the checklist line, then
sets the flag.

**Body.** The marker as an HTML comment, then the blocks the `REVIEW.md` column
of the routing table carries, in its order, as plain markdown. Qodo documents no
schema for it, which makes the marker the only thing identifying the file as
this package's: without it the next render refuses to replace its own output and
`orphan` cannot tell it from a file the repo wrote.

## `.macroscope/`

Rendered only when `[bots] macroscope` is true. Read from the most recent
commit on the pull request, except for a fork pull request, which reads the
default branch.

**`.macroscope/ignore.md`.** The marker as an HTML comment, then one glob per
line and nothing else. Each glob's reason is an HTML comment on the line above
it, taken from the same two sources `path_filters` uses: the entry's `reason`,
or the fixed derived string. Macroscope documents no grammar for this file, so
the render assumes the strictest reading, that every non-blank line is a
pattern, and keeps every
non-pattern line inside a comment. Confirming that assumption once per repo is
a checklist line.

A `reason` is single-line and carries no `-->`, which is what stops a reason
from closing its own comment and putting a line of the author's choosing into
a file whose every line is a pattern. `bot-instructions.toml` refuses both at
input time.

Repository-wide: a check-run agent's own `include` overrides it, which is a
reason not to give an agent a broad `include`.

**`.macroscope/correctness/doctrine.md`.** No frontmatter, so it applies
repo-wide: the marker as an HTML comment, then the blocks its routing-table
column names, which is all eight: `.macroscope/` is Macroscope's only
instruction surface, it reads no `AGENTS.md`, and a block left out here reaches
it nowhere. Its name is reserved,
as are `correctness` and the two `.macroscope/` root names.

**`.macroscope/correctness/<name>.md`.** One per `[[surface]]`: frontmatter
`include` from `globs` and `exclude` from `exclude_globs`, both as YAML string
arrays, then the marker, then the surface's `instructions` as the body. The body
is the point of the file — a marker and frontmatter with no guidance under them
is a correctness file that tells Macroscope nothing, which is what
`macroscope-render` rejects. Macroscope evaluates `exclude` after `include`,
which matches the TOML's meaning directly, so this is the one surface where the
subtraction needs no restatement in prose.

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
