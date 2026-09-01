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

## Cross-file sets

A set of ids or predicates written out in two files is two copies, and two
copies drift. This spec is mostly such sets, so the rule is: **every set of ids
or predicates that appears in more than one file is either derived from one
named source, or checked by a validator that reds when the copies diverge.**
Neither "compare them by reading" nor "keep them in sync" counts; both are what
the divergence gets past.

Its sites, and which answer each takes:

| Set | Answer |
|-----|--------|
| Doctrine block ids: the doctrine source's `###` headings against the routing table's rows | `doctrine-routing`, set equality in both directions |
| Which block reaches which destination, and in what order | Derived. The routing table in `renders.md` is the single source; per-surface sections cite it and state no order of their own |
| Content refusals: which input string is under which refusal, and what each refusal's predicate is | Derived. The table in `repo-toml.md` § The content refusals is the single source; `toml-schema`, `agents-section` and the Escaping paragraphs cite it |
| The Qodo verbs `[cadence] qodo_commands` accepts, and which half `qodo-parity` requires guidance for | Derived. `repo-toml.md` § `[cadence]` states the set and the split; `qodo-parity` reads it rather than carrying its own |
| Which paths a render reads: the marker's input list, `drift`'s `--staged` index set, the policy set, the open rule's coverage | Derived. SKILL.md § The render inputs is the single source; the routing table is one of them, and all four cite it rather than each naming its own set |
| The routing table's own shape: positions contiguous per column, no duplicates, and every block in the two all-eight columns | `doctrine-routing`, which judges the table as well as comparing it to the doctrine source |
| Rejection clauses against their controls | Checked by reading, and the one exception. § Controls makes the count checkable by requiring one control per clause, which is why every clause has to be enumerated somewhere a reader can count |

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
The clauses are the cells of `repo-toml.md` § The content refusals: every marked
cell is one clause with one control, and the predicates are that table's. That
table carries every one of them, `[tone] coderabbit`'s ASCII rule and the
`qodo_commands` verb set included, so neither list has anything the other lacks.
The glob row's path-shape rule is the one entry whose clauses that table names
rather than marks, because they are shapes rather than content refusals: an
empty glob, a leading or trailing `/`, a `..` component, and an empty component,
each its own clause with its own control. The character class catches none of
them — every byte in them is permitted, and an empty glob has no bytes at all.

Reading the table's marked cells is how the control count is checked, which is
what a validator restating its own copy of the predicates would defeat.

**Rejects, the cross-flag set.** `qodo_best_practices` or `qodo_review_md` true
while `qodo` is false. `copilot` or `coderabbit` true while `codex` is false,
because the `AGENTS.md` section is where both of those bots get most of their
doctrine and where the Copilot pointer sentence aims. A non-empty `[[surface]]`
set while `copilot`, `coderabbit`, `macroscope` and `qodo_best_practices` are
all false: surface text has no route to any other bot, so those surfaces are
instructions the author wrote and nothing will ever read.

Each of those is a flag combination where something enabled reaches nothing —
a file with no reader, a surface with no route, a bot missing the surface its
doctrine goes through. That is the shape these clauses catch, and it is
narrower than "renders nothing readable": **every flag false is a legitimate
state and passes.** `repo-toml.md` § `[bots]` says why, and `render` reports the
no-op rather than exiting quietly, since a silent nothing is the failure mode
this package exists to remove.

## `doctrine-routing`

**Silent failure.** The routing table is the generator's single routing input, so
a block reaches a surface only through a cell. The table's rows and the doctrine
source's `###` headings are two hand-kept copies of one set. A heading with no
row renders into nothing at all; a row naming a heading that does not exist
renders a hole. Both render clean.

`--spec` makes the mismatch designed-in rather than hypothetical: in the CI
lane this package prescribes, the spec copy comes from the tree under judgment
while the code runs from the trusted default-branch checkout, so a pull request
adding a doctrine block is a pull request changing the routing. "Block ids are
frozen" is a rule, and this is its enforcer. The one flag naming both files is
what keeps the two halves of the set arriving together; reading doctrine from
one copy and routing from another would red every legitimate change.

**Rejects, the set.** A `###` block id in the doctrine source with no row in the
routing table — an unrouted block is an error, never a silent drop. A
routing-table row naming an id the doctrine source does not define. Set equality
in both directions: the one-directional half leaves the orphaned row unchecked.

**Rejects, the table's own shape.** Nothing else judges the table, and it is the
generator's single routing input, so a one-character edit to it is a silent
policy change:

- A position repeated inside a column.
- A gap in a column's positions, which must run `1..n`.
- A missing block in the `AGENTS.md` or `macroscope doctrine.md` column. Both
  columns carry every block, because neither Codex nor Macroscope reads a second
  surface, and the table states that as an invariant of itself. Delete the `8`
  from `reply-contract`'s `AGENTS.md` cell and Codex loses the reply contract
  with every other validator green.

A byte validator — both inputs belong to the render, and `--spec` names the one
copy both come from, so they cannot arrive from different checkouts. One control
per clause above.

`qodo-parity` is the weaker relative and is worth reading as such: it compares a
render against the table the render was generated from, so only a render bug
reds it. What holds the table itself is here.

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

**Rejects, the completeness clause.** A top-level property the vendored schema
defines that the render does not carry. Schema validation alone judges what is
present and says nothing about what is absent, so a render that dropped a
property would validate while that setting silently resumed resolving down the
unversioned ladder — which is the whole thing full state exists to stop.
`renders.md` promises every top-level property; this is what holds the promise,
and it is what makes the next schema refresh report a newly added property
instead of quietly widening the gap.

**Rejects, also.** A missing, unreadable or unparseable
`.bot-instructions/coderabbit-schema.json`, whenever `[bots] coderabbit` is
true, on both verbs. Never a skipped validator: no verb writes that file, so
every repo starts without one, and a validator that skipped on its absence
would be silent for the life of a repo that never vendored it — which is the
failure this validator exists to catch, one level up. `references/checklist.md`
§ Adding a repo carries the step that puts the first copy there, and the absent
file is one of
this validator's controls.

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

**Rejects, also.** A non-empty exclusion set that a destination the routing
table marks as carrying the paths does not carry: `AGENTS.md`, `pr_agent
issues`, `pr_agent extra`. That is what holds the requirement in SKILL.md
§ Every rendered config excludes the render trees — without it a render could
drop the paths from the one surface Codex reads and violate nothing checkable.

**What it does not establish.** That the bots exclude the same files. Codex has
no exclusion mechanism at all, Copilot's lives in a settings page no repo file
can read, Qodo's `[ignore]` governs `/improve` rather than what the review
agent reads, and a Macroscope agent's own `include` overrides `ignore.md`. This
validator compares the strings the generator emitted. Effective parity across
five bots is not a property any repo-side check can assert.

## `copilot-frontmatter`

**Silent failure.** A `.instructions.md` file with no `applyTo`, or an empty
one, matches nothing and is never loaded. And `excludeAgent` fails in the
direction that looks fine: the value names the agent the file is hidden from, so
a missing key or the wrong one of the two leaves reviewer-only instructions
loading into the working agent — the inverse of what `reviewer_only` asks for,
with the file present and its frontmatter parsing.

**Rejects.** A generated `.instructions.md` with no `applyTo`, an `applyTo`
that is empty or whitespace, and an `applyTo` emitted as a YAML array rather
than a single comma-separated string.

**Rejects, on `excludeAgent`.** For a surface with `reviewer_only = true`: a
missing `excludeAgent`, and any value other than `cloud-agent`. `code-review` is
the documented opposite — it hides the file from the reviewer and leaves the
working agent reading it — so accepting either value here would accept the one
case the key exists to prevent. For a surface with `reviewer_only = false` the
render emits no `excludeAgent`; if one is present it must still be one of the
two values `references/limits.md` documents.

Three controls, per § Controls, one per clause: a reviewer-only surface
rendered with the key missing, one rendered with `code-review`, and an ordinary
surface rendered with an `excludeAgent` outside the two documented values. The
third is easy to leave out because the render emits no key there, which is
exactly why it needs naming — a clause nothing exercises is a clause nothing
proves.

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
rejects a `[github_app] pr_commands` entry **whose role in `repo-toml.md`
§ `[cadence]`'s verb table is review** and whose section carries no guidance.
The clause reads that table's role column rather than restating a set: a
non-review verb reads a section this render leaves alone by design, so its
presence is not a finding, and the vendor's own documented default carries
one.

The set it compares is the routing table's three `pr_agent` columns, read as
data rather than restated here. That is what keeps this a check on the render
and not a fourth hand-written copy of the routing: a block moved between the two
`[review_agent]` keys changes one table cell and nothing else, while a block
dropped from a column reds this validator.

## `qodo-best-practices`

**Silent failure.** A generated file nobody bounded is a file nobody reads.
Qodo's guidance is that long best-practices files are processed less
effectively, and it states no length at which it rejects or truncates one, so
there is no error to wait for and no signal that guidance went unread.

**Rejects.** A rendered `best_practices.md` over 800 lines, naming the surfaces
contributing the most lines so the author can see what to cut.

**That 800 is this package's budget, not a vendor cap.** Qodo documents it as
writing guidance; `references/limits.md` marks it a recommendation, and this
validator is where the package chooses to hold it — the same shape as
`copilot-budget` against a two-page reading. The failure message says so. A
render stopped here was stopped by this package, and telling an author Qodo
refused their file would send them to a vendor with nothing to find.

Organization and mapped-repository best-practices files layer above the
generated one and the generator cannot see them, so nothing here bounds the
total; `references/checklist.md` carries that as a question rather than a
number.

## `macroscope-render`

**Silent failure.** A `.macroscope/correctness/` file whose frontmatter
Macroscope cannot read is a file it will not apply, and the repo's only signal
is the absence of a comment it was expecting.

**Rejects.** In a generated correctness file for a `[[surface]]`: a frontmatter
key other than `include` or `exclude`, a value that is not a YAML array of
strings, an `include` that is empty **or absent**, and a body carrying no
instruction text below the marker. That last one is what makes SKILL.md's
promise that surface text reaches Macroscope true rather than assumed: without
it a render could emit frontmatter and a marker, satisfy every other clause
here, and tell Macroscope nothing. Absent is the one that
matters: omitted frontmatter applies repo-wide, so a renderer bug dropping
`include` silently widens a path-scoped surface to the whole repository with
every validator green.

`doctrine.md` is the one generated correctness file that carries no frontmatter,
and it is deliberate — the routing table gives it every block precisely because
it applies repo-wide. It is told apart by its name, which is reserved and which
no surface may take, so the two cases never have to be guessed at.

**Rejects, in the generated `ignore.md`.** A non-blank line that is neither a
glob in the dialect nor a single-line HTML comment, and any line after the first
`-->` on a comment line.

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

**Rejects, always.** A nested `AGENTS.md` anywhere below the root carrying a
`## Code Review Rules` section. Codex reads the nearest nested file covering each
changed path, so such a section reaches it without passing through doctrine, and
the generator writes only the root one.

Unconditional, and this is the clause the flag does not gate. `[bots] codex =
false` says this package does not manage the section; it says nothing about
whether Codex is installed, which an administrator changes without touching the
repo. A repo running Macroscope and Qodo with `codex` off would otherwise lose
the only detection of an unmanaged surface reaching a bot the TOML cannot switch
off, while the policy set still counts every `AGENTS.md` as policy-bearing for
exactly that reason. Its control is independent of the flag.

**Rejects, when `[bots] codex` is true.** A root `AGENTS.md` with no `## Code
Review Rules` heading, or with more than one. A doctrine or repo line matching
the heading predicate in `repo-toml.md` § The content refusals, which markdown
reads as a heading and which would end the owned region at the next render,
taking the rest of the section with it.

Both presuppose a managed region, so with the flag off there is none to judge
and rejecting a missing heading would fail a repo that never asked for one.

**The region's bytes are `drift`'s, not this validator's.** Every clause here is
structural — does the section exist, is it unique, is there an unmanaged nested
one, would a line break the region — and none compares anything against a
render. That is what lets all of them run before the write, which is what makes
the write-phase splice failure unreachable. A byte comparison could not: before
the write the repo holds the last render, so any change to doctrine, the TOML or
the tracker substitution would make it fire and `render` would write nothing,
leaving the region unable to be updated at all in a repo where `toml-schema`
requires `codex` true.

One owner also settles the isolation the § Controls rule needs. Two validators
rejecting the same byte difference means no fixture can red exactly one, and
`drift` is the owner because a byte comparison against a fresh render is its
entire subject and it already carries the rule that `AGENTS.md` is compared over
its region rather than whole.

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

**Retiring one is delete-then-render.** `render` runs this before the write and
fails on what it finds, so the render that would create the orphan never
completes; the deletion has to come first, in the same commit. `check` is what
catches a retirement that skipped the render, not the ordinary route. The
generator reports rather than deletes because removing a file is a decision the
commit's author makes, and sometimes the fix is not a deletion at all: another
check in the repo may require the file, in which case what that check reads
moves first. kendex is the worked example — its `tools/guard` fails when
`.github/copilot-instructions.md` is absent, so retiring `[bots] copilot` there
is move the pointer, delete the file, then render.

**De-orphaning the `AGENTS.md` region** is not a deletion of the file. The
heading is the repo's and has to survive; what goes is the marker and the body
below it, leaving the section for the repo to fill or leave empty. Until that
happens `render` fails, the same as for any other orphan.

## `drift`

**Silent failure.** A hand edit to a generated file survives until the next
render, then vanishes. Between those two moments the repo's behavior does not
match its source, and the edit's author has no reason to suspect it.

**Rejects.** Any path the current TOML produces whose bytes differ from a fresh
render, naming the path and the differing region.

`AGENTS.md` is the one path compared over a region rather than whole, and this
validator is that comparison's only owner. The generator never creates that file
and never adds its heading, so it always holds content the render did not write,
and a whole-file comparison would differ on every repo. What `drift` compares
there is the owned region, which is also all the write would have replaced.
`agents-section` judges that region's structure and cites this rule for its
bytes, so a region fixture reds exactly one validator.

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
outputs: every path in SKILL.md § The render inputs, read from that list rather
than from a copy of it here. A file absent from the index is that absence, not
its worktree copy. Outputs-only would be
wrong in both directions in the pre-commit lane this mode exists for: a commit
staging a TOML change with its re-rendered outputs would red, because the
outputs came from the index while the render was built from a worktree TOML
that may have moved on; and an unstaged doctrine edit
would silently decide what the staged outputs were compared against, passing or
failing on bytes nobody is committing.

**Controls.** The hand-edit fixture; a fixture whose only change is a deleted
marker line; a fixture editing the `AGENTS.md` owned region, which reds this
validator alone and is what proves the region comparison lives here rather than
in `agents-section`; and one pair per render input for the mode. Per input —
the TOML, the spec copy, the vendored schema, each install manifest read — a
staged, consistent set with a divergent worktree copy of that input, asserted
green, and a staged copy of that input that its staged outputs are stale
against, asserted red. Plus one for absence: an input staged as absent,
asserted on the absence rather than on its worktree copy.

A TOML-only pair is what a generator reading the index for the TOML and the
worktree for everything else passes, with the failure § Which tree names
shipping intact. One clause, one control, applied to the validator whose clause
names four inputs.

## Where these run

Two kinds, and the difference is what each judges.

**Byte validators** judge one render — its inputs and the bytes it produced —
and nothing around it, so they read the scratch tree, on both verbs:
`toml-schema`, `coderabbit-schema`, `coderabbit-filters`,
`copilot-frontmatter`, `copilot-budget`, `qodo-parity`, `qodo-best-practices`,
`macroscope-render`, `doctrine-routing`, and `exclusion-consistency`'s
cross-surface clause.

**Repo-state validators** judge the repository, so a scratch tree is the one
place they cannot fail. `orphan` looks for what the current TOML does not
produce, and the scratch tree holds only what it does produce. `drift` compares
a path's bytes against a fresh render, which in the scratch tree are the same
bytes. `exclusion-consistency`'s derived-set clause compares a set against a
fresh derivation from the same manifest in the same run. Every `agents-section`
clause reads the repo: the nested-`AGENTS.md` walk needs a repo to walk, and the
other two need a file the scratch tree does not hold at all, since `AGENTS.md`
is the one output the build never assembles whole — the build produces the
region's body and the write splices it. Comparing that body against itself is
the vacuity the split exists to remove.

So they read the repo:

| Validator or clause | `render` | `check` |
|---------------------|----------|---------|
| `orphan` | the repo, before the write | the repo |
| `agents-section`, every clause | the repo, before the write | the repo |
| `drift`, the `AGENTS.md` owned region included | skipped, and named as skipped | the repo |
| `exclusion-consistency`, derived-set clause | skipped, and named as skipped | the repo |

`orphan` runs before the write because that is the render that creates the
orphan: retiring a `[[surface]]` or flipping a bot flag is what leaves the file
behind, and a render that reports a clean pass and then does it is the fail-open
shape this package exists to remove.

`agents-section` runs before the write for the same reason from the other
direction. The write-phase splice fails when the owned region cannot be located,
and by then other outputs have been replaced — a partial render, against
SKILL.md's promise that a validator failure leaves the repo untouched. Checking
the heading before the write is what makes that failure unreachable. Every
clause it has is structural, so none of them compares against a render and none
needs skipping; the region's bytes belong to `drift`, which is skipped.

The two skips are not vacuous checks left running; they are checks with no
question to answer at render time, and the run says so rather than counting them
as passed. A render exists to change the bytes `drift` compares, so at render
time `drift` would red on its own purpose — the `AGENTS.md` region most of all,
where the repo holds the last render and any doctrine, TOML or tracker change
makes the bytes differ by design. And `exclusion-consistency`'s derived clause
compares a derivation against itself. Both have force in `check`, against
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
