# Validators

Every bot in this set fails silently. A rejected config, a mistyped enum, an
exclusion list that fell behind the tree it excludes: in each case the review
still runs, still posts, and says nothing about the configuration it discarded.
The pull request looks reviewed. Nobody learns otherwise until a defect ships.

So each validator below names the silent failure it exists to catch, then what
it rejects. A failure fails the run; none of them warns. Which tree each one
reads, and which verb runs it, is § Where these run, and it is not the same
answer for all of them.

## Controls

A validator's Rejects paragraph names several independent clauses. One fixture
per validator proves the validator can fail once and leaves every other clause
unproven, and an unproven clause that is dead, unreachable, or matching a decoy
stays green for good. So the rule is per clause, not per validator:

- **One red control per rejection clause.** Each asserts on that validator's
  own identity or message, never on the run's exit code. All the validators run
  together, so a `coderabbit-filters` fixture that also trips `toml-schema`
  reds for the wrong reason and reads as coverage.
- **One canonical valid render asserted green.** Without it, a validator that
  rejects everything satisfies the entire red set.
- **Two fixtures per numeric bound**, one crossing it and one a single unit
  inside. A `copilot-budget` fixture that stops short of `[budgets]
  copilot_chars`, or a `tone_instructions` fixture short of 250 code points,
  proves the run and not the bound.

A clause with no control is a spec violation, which makes the count checkable
by reading the Rejects paragraph against the fixture list. A repo-state
validator's controls are repo fixtures, not scratch-tree ones.

## The glob dialect's vectors

The dialect claims a set of patterns five targets read alike. That is a claim
about five engines rather than about this code, and only two of the five can be
asked: CodeRabbit's `path_filters` go through minimatch and through real `git
sparse-checkout`, both of which a test can run at a pinned version. Copilot's
`applyTo` matcher, Qodo's `[ignore]` matcher and Macroscope's `include` matcher
are unpublished — `references/limits.md` documents no grammar for any of them,
and says outright that Macroscope documents none.

So the vectors cover the two that can be measured, and the other three are a
one-time confirmation in `references/checklist.md`. Claiming five-engine
conformance from a harness that can reach two would be the false confidence
this file exists to prevent.

The harness needs its own control, and it cannot be a pattern the dialect
allows: if the dialect is right, no such pattern produces disagreement, so that
control could only be built by first finding a dialect bug. The buildable one
runs in the other direction. Feed a pattern the dialect **refuses** — a brace
and an extglob are two the dialect names, and their disagreement is exactly why
they are refused — through the vector harness with the dialect check bypassed,
and assert the harness reports the disagreement. That proves the instrument on
an input the dialect guarantees exists.

**What no validator can do.** Each one judges bytes this generator produced.
None of them observes a bot's actual behavior, and several of the guarantees
this package wants live outside any file: a Copilot content-exclusion path, an
organization CodeRabbit override, a portal toggle. Those are
`references/checklist.md`, and a validator that claimed to cover them would be
the false confidence this file exists to prevent.

## `toml-schema`

**Silent failure.** `bot-instructions.toml` is hand-written and is the one
input a person edits. A misspelled key that the reader ignores leaves the
default in force, and the render is plausible, complete, and wrong.

**Rejects, the shape set.** Any key or table the schema does not define, any
value of the wrong type, an empty glob list, a surface name that is empty,
malformed, duplicated or reserved, an unknown doctrine block id in
`[doctrine.append]` or `[doctrine.replace]`, and a `schema` value other than
`1`.

**Rejects, the content set.** Closure over keys and types leaves the contents of
values that land in a control position, and those are where an injection goes.
Each of these is its own clause with its own control:

- A glob holding any byte outside the dialect's character class, which covers a
  newline, a tab, another control character, leading or trailing whitespace, and
  `#`, as well as the metacharacters the class leaves out.
- A `[repo] name` that is multi-line or outside `[A-Za-z0-9._-]`.
- A line beginning `#`, `---`, or the marker text in `[repo] summary`, in a
  `[[surface]] instructions`, or in a `[doctrine.append]` or
  `[doctrine.replace]` value.
- A `[[exclusions.path]] reason` that is multi-line or contains `-->`.
- A `[cadence] qodo_commands` entry outside the documented verb set, or carrying
  whitespace or `--`.

Every content refusal `repo-toml.md` states is in that list. A refusal stated
there and missing here would ship with nothing proving it fires, which is what
the per-clause control rule exists to make checkable by reading one paragraph
against the other.

**Rejects, the cross-flag set.** `qodo_best_practices` or `qodo_review_md` true
while `qodo` is false. `copilot` or `coderabbit` true while `codex` is false,
because the `AGENTS.md` section is where both of those bots get most of their
doctrine and where the Copilot pointer sentence aims. A non-empty `[[surface]]`
set while `copilot`, `coderabbit`, `macroscope` and `qodo_best_practices` are
all false: surface text has no route to any other bot, so those surfaces are
instructions the author wrote and nothing will ever read.

A flag combination that renders nothing readable is the same defect as a flag
that renders a file reaching nothing. Both fail here rather than rendering
clean.

## `coderabbit-schema`

**Silent failure.** CodeRabbit rejects an invalid `.coderabbit.yaml` whole and
reviews with resolved defaults instead. The review posts normally, and nothing
on the pull request says the file was discarded. A repo can carry an inert
config for as long as nobody re-reads the file. One over-long
`tone_instructions` does this, and the root schema sets
`additionalProperties: false`, so a single misspelled top-level key does it too.

**Rejects.** Any deviation of the rendered file from CodeRabbit's published
schema, validated against the copy vendored at
`.bot-instructions/coderabbit-schema.json` rather than fetched at check
time: an unknown top-level key, a wrong type, an enum miss
(`reviews.profile` is `quiet`, `chill` or `assertive`), and every documented
length cap, of which `tone_instructions` at 250 and
`reviews.path_instructions[].instructions` at 20,000 are the two this package
can reach. Lengths count Unicode code points, which is what the schema's
`maxLength` counts; `[tone] coderabbit` is required to be ASCII so the local
count and the vendor's cannot disagree.

**Rejects, also.** A schema keyword the validator does not implement. A
hand-written validator that ignores an unknown constraint under-validates while
reporting success, which is the same class of failure one level up. Naming the
keyword and failing is the only safe answer, and it means a schema refresh can
block renders until the validator catches up: the vendored copy's provenance
and its refresh step are a checklist line for that reason. That copy is also a
policy path, since a loosened schema turns this validator green on a file
CodeRabbit discards whole and keeps it green afterwards.

## `coderabbit-filters`

**Silent failure.** Two of them. A `path_filters` list with one entry lacking
the `!` prefix is an allowlist, and every file in the repo that no entry names
stops being reviewed. And CodeRabbit feeds these same patterns to `git
sparse-checkout`, which understands plain globs only, so an extglob or brace
pattern matches nothing and excludes nothing while reading as an exclusion.

**Rejects.** Any `path_filters` entry not starting with `!`. Any entry whose
remainder is outside the glob dialect. Both are checked on the rendered file,
not on the TOML, so a future generator change cannot route around them.

## `exclusion-consistency`

**Silent failure.** A harness refresh renders a new skill into the repo. The
exclusion lists name the skills that existed when someone last wrote them, so
the new tree is reviewed as if it were this repo's code. Findings arrive on
files nobody here can fix, and the only signal is reviewer noise.

**Rejects.** A mismatch between the derived part of the rendered exclusion set
and the set derived fresh from the repo's resolved install manifest: every
rendered `.agents/skills/<name>`, no tree declared `in-place`, plus the
per-harness render directories the install declares. The comparison is over the
derived part alone, because the rendered set also holds every
`[[exclusions.path]]` entry and whole-set equality would fail on the first
hand-written exclusion. Runs only when `[exclusions] derive_render` is true.

**Rejects, also.** A resolved manifest that declares no install. Reading the
wrong file and finding nothing to exclude is indistinguishable from a repo with
nothing to exclude, and this comparison cannot tell them apart on its own: both
sides come back empty and agree. So emptiness is the finding. One of this
validator's controls is a source-catalog repo, where `kendex.toml` carries the
published catalog and `kendex-local.toml` carries the install — the shape that
would otherwise derive nothing and pass.

**Rejects, also.** An exclusion entry present in one rendered surface and
absent from another, where both surfaces have an exclusion mechanism.

**What it does not establish.** That the bots exclude the same files. Codex has
no exclusion mechanism at all, Copilot's lives in a settings page no repo file
can read, Qodo's `[ignore]` governs `/improve` rather than what the review
agent reads, and a Macroscope agent's own `include` overrides `ignore.md`. This
validator compares the strings the generator emitted. Effective parity across
five bots is not a property any repo-side check can assert.

## `copilot-frontmatter`

**Silent failure.** A `.instructions.md` file with no `applyTo`, or an empty
one, matches nothing and is never loaded. An `excludeAgent` value outside the
two GitHub accepts is not an error either; the file simply loads for every
agent, and reviewer doctrine reaches the working agent the flag was meant to
keep it from.

**Rejects.** A generated `.instructions.md` with no `applyTo`, an `applyTo`
that is empty or whitespace, an `applyTo` emitted as a YAML array rather than a
single comma-separated string, and an `excludeAgent` value other than
`code-review` or `cloud-agent`.

## `copilot-budget`

**Silent failure.** GitHub asks for "no longer than 2 pages" and documents no
numeric cap, so an over-long file has no error to produce. What happens past
that length is undocumented, which is itself the reason to hold a budget.

**Rejects.** A rendered `.github/copilot-instructions.md` over `[budgets]
copilot_chars`, naming the count, the budget, and the sections by size so the
author can see what to cut.

## `qodo-parity`

**Silent failure.** `/review` reads `[pr_reviewer] extra_instructions`.
`/agentic_review` reads `[review_agent]`. Guidance written into one section is
absent from the other command's path, and the review runs with less context
while the file looks configured.

**Rejects.** A doctrine block present in `[pr_reviewer] extra_instructions` and
absent from the union of `[review_agent] issues_user_guidelines` and
`compliance_user_guidelines`, or the reverse. Blocks are compared by identity
after the same normalization the render applies, not by whole-string equality:
the two sections carry the same set of blocks, split differently. It also
rejects a `[github_app] pr_commands` entry naming a command whose section
carries no guidance at all.

The set it compares is the routing table's three `pr_agent` columns, read as
data rather than restated here. That is what keeps this a check on the render
and not a fourth hand-written copy of the routing: a block moved between the two
`[review_agent]` keys changes one table cell and nothing else, while a block
dropped from a column reds this validator.

## `qodo-best-practices`

**Silent failure.** Qodo documents 800 lines per file and does not document what
it does past that. A repo cannot tell from a review whether its guidance was
read in full, truncated, or dropped.

**Rejects.** A rendered `best_practices.md` over 800 lines, naming the surfaces
contributing the most lines so the author can see what to cut.

That is the only best-practices cap on a live vendor page, and so the only one
enforced. Organization and mapped-repository best-practices files layer above
the generated one and the generator cannot see them, so nothing here bounds the
total; `references/checklist.md` carries that as a question rather than a
number.

## `macroscope-render`

**Silent failure.** A `.macroscope/correctness/` file whose frontmatter
Macroscope cannot read is a file it will not apply, and the repo's only signal
is the absence of a comment it was expecting.

**Rejects.** In a generated correctness file: a frontmatter key other than
`include` or `exclude`, a value that is not a YAML array of strings, and an
empty `include`. In the generated `ignore.md`: a non-blank line that is neither
a glob in the dialect nor a single-line HTML comment, and any line after the
first `-->` on a comment line.

The `ignore.md` half holds the render to this package's own conservative
grammar, not to a vendor rule: Macroscope documents none. The grammar assumes
every non-blank line is a pattern and keeps everything else inside a comment,
which is the safe direction to be wrong in. Whether Macroscope agrees is a
checklist line, not something this validator can answer.

Check-run agent frontmatter is not validated, because this package writes no
check-run agents. A validator for keys nothing emits passes vacuously.

## `agents-section`

**Silent failure.** Codex reads `AGENTS.md` § Code Review Rules and nothing
else. Rename the heading, move the section, or delete the file, and Codex
reviews every pull request with no repo rules at all, posting normally
throughout.

Runs only when `[bots] codex` is true, which `toml-schema` requires whenever
`copilot` or `coderabbit` is. A repo with every bot off has no rendered section
for this to judge, and rejecting a missing heading there would fail a repo that
never asked for one.

**Rejects.** A nested `AGENTS.md` anywhere below the root carrying a `## Code
Review Rules` section. Codex reads the nearest nested file covering each
changed path, so such a section reaches it without passing through doctrine,
and the generator writes only the root one. A root `AGENTS.md` with no `## Code
Review Rules` heading, or with more than one. An owned region whose bytes
differ from the render. A doctrine
or repo line whose first non-whitespace character is `#` after three or fewer
leading spaces, which markdown reads as a heading and which would end the owned
region at the next render, taking the rest of the section with it.

## `orphan`

**Silent failure.** A `[[surface]]` is removed from the TOML, or a bot
capability is switched off. The generator writes nothing for it and deletes
nothing, so the file it wrote is still there and the bot still loads it. The
repo's source says one thing and its bots read another, and no render will ever
touch that file again.

**Rejects.** Anything carrying this package's marker that the current TOML does
not produce. One rule, and the marker is the whole of it: this package wrote
every marked byte, so a marked file the TOML no longer accounts for is one it
abandoned.

That covers a retired surface's `.instructions.md` and `correctness/*.md`, the
root-level files of a bot whose flag went false (`.coderabbit.yaml`,
`.pr_agent.toml`, `best_practices.md`, `REVIEW.md`,
`.github/copilot-instructions.md`, the `.macroscope/` tree), and the marked
`## Code Review Rules` region inside `AGENTS.md` when `[bots] codex` goes false.
That last one is why the region carries a marker at all: it is never a whole
file, so a whole-file rule would leave live doctrine in the one place Codex
reads, reported by nothing.

**Unmarked files are not judged here, whatever the flags say.** A repo with
`qodo_review_md = false` and its own hand-written `REVIEW.md`, or `copilot =
false` and an existing `.github/copilot-instructions.md`, is a repo that owns
those files; this package never wrote them and does not get to call them stale.
That is also the state every incoming repo is in before `adopt` runs. Taking one
over is `adopt`'s job and needs the capability on.

**The scan is recursive, over what each bot reads rather than what the generator
writes.** `.github/instructions/**` and `.macroscope/correctness/**` both, since
Copilot and Macroscope walk those subtrees. A marked file one directory down,
left by a hand move or a directory rename, is at no path the generator would
write, so a flat scan would miss it while Copilot kept loading it.

The fix is usually a deletion in the commit that retired the surface or the bot,
which is why the generator reports rather than deletes: removing a file is a
decision the commit's author makes. It is not always a deletion. Another check
in the repo may require the file to exist, in which case the fix is to move what
that check reads before the file goes. kendex is an example: its `tools/guard`
fails when `.github/copilot-instructions.md` is absent, so retiring `[bots]
copilot` there means moving guard's reply-contract pointer first.

## `drift`

**Silent failure.** A hand edit to a generated file survives until the next
render, then vanishes. Between those two moments the repo's behavior does not
match its source, and the edit's author has no reason to suspect it.

**Rejects.** Any path the current TOML produces whose bytes differ from a fresh
render, naming the path and the differing region.

**Marker-agnostic, unlike every other rule here.** `render` refuses to replace
an unmarked file and `orphan` carves unmarked files out, so a marker-gated
`drift` would let a one-line deletion — the marker comment — drop a file out of
all three at once: unmarked for `drift`, carved out of `orphan`, refused by
`render`. Hand-controlled review policy would then sit at a generated path with
`check` reporting nothing, and a CI lane never renders in place, so `render`'s
refusal never fires there. Marker-agnostic makes the deleted marker its own byte
difference, which reds.

The intended consequence: a repo that has not run `adopt` reds on every
hand-written file at a path its TOML produces. That is the correct signal, and
it is what `adopt` clears. The seam with `orphan` is the TOML: `drift` judges
paths the TOML produces now, `orphan` judges marked files it does not. A file at
a path the TOML does not produce and that this package never wrote is neither.

**Which tree.** `check` reads the working tree by default. Under `--staged` it
reads the index — and the index for **every render input**, not only the
outputs: `bot-instructions.toml`, the doctrine source, the vendored schema,
and the resolved install manifest when `derive_render` is on. A file absent
from the index is that absence, not its worktree copy. Outputs-only would be
wrong in both directions in the pre-commit lane this mode exists for: a commit staging a TOML change with its re-rendered
outputs would red, because the outputs came from the index while the render was
built from a worktree TOML that may have moved on; and an unstaged doctrine edit
would silently decide what the staged outputs were compared against, passing or
failing on bytes nobody is committing.

**Controls.** The hand-edit fixture, a fixture whose only change is a deleted
marker line, and two for the mode: staged TOML plus staged outputs that agree
with a divergent worktree TOML, asserted green; and a staged TOML whose outputs
were not re-rendered, asserted red.

## Where these run

Two kinds, and the difference is what each judges.

**Byte validators** judge one render — its inputs and the bytes it produced —
and nothing around it, so they read the scratch tree, on both verbs:
`toml-schema`, `coderabbit-schema`, `coderabbit-filters`,
`copilot-frontmatter`, `copilot-budget`, `qodo-parity`, `qodo-best-practices`,
`macroscope-render`, `exclusion-consistency`'s cross-surface clause, and
`agents-section`'s clauses about the rendered region.

**Repo-state validators** judge the repository, so a scratch tree is the one
place they cannot fail. `orphan` looks for what the current TOML does not
produce, and the scratch tree holds only what it does produce. `drift` compares
a path's bytes against a fresh render, which in the scratch tree are the same
bytes. `exclusion-consistency`'s derived-set clause compares a set against a
fresh derivation from the same manifest in the same run. `agents-section`'s
nested-`AGENTS.md` clause searches a repo, which the scratch tree is not. Run
against a scratch tree, all four pass by construction and report a clean run.

So they read the repo:

| Validator or clause | `render` | `check` |
|---------------------|----------|---------|
| `orphan` | the repo, before the write | the repo |
| `agents-section`, nested-file clause | the repo, before the write | the repo |
| `drift` | skipped, and named as skipped | the repo |
| `exclusion-consistency`, derived-set clause | skipped, and named as skipped | the repo |

`orphan` runs before the write because that is the render that creates the
orphan: retiring a `[[surface]]` or flipping a bot flag is what leaves the file
behind, and a render that reports a clean pass and then does it is the fail-open
shape this package exists to remove.

The two skips are not vacuous checks left running; they are checks with no
question to answer at render time, and the run says so rather than counting them
as passed. A render exists to change the bytes `drift` compares, so at render
time `drift` would red on its own purpose. And `exclusion-consistency`'s derived
clause compares a derivation against itself. Both have force in `check`, against
a committed tree whose manifest and whose files have moved on since someone
last rendered — which is the question they were written for.

A repo wires `check` into whatever runs its other repo guards. This package
ships no hook of its own, because a repo that already has a commit chain does
not need a second one.

**In CI, run this package's copy from the default branch, not the pull
request's.** Three of the five bots read their instruction files from the head,
and the generator, the validators and the doctrine source are all files a pull
request can edit. A `check` run out of the head checkout proves that
head-controlled inputs agree with head-controlled code, which is not the
question. The repo-side rules that go with this are in SKILL.md § A pull
request changing its own review.
