# Validators

Every bot in this set fails silently. A rejected config, a mistyped enum, an
exclusion list that fell behind the tree it excludes: in each case the review
still runs, still posts, and says nothing about the configuration it discarded.
The pull request looks reviewed. Nobody learns otherwise until a defect ships.

So each validator below names the silent failure it exists to catch, then what
it rejects. A validator runs on every `render` before the tree is written and
on every `check`. A failure fails the run; none of them warns.

Each validator ships with a must-fail control: a fixture carrying exactly the
defect that validator names, asserted red. A validator with no red fixture is
indistinguishable from one that passes on everything.

The glob dialect gets the same treatment from the other side. It claims a set
of patterns every target reads alike, which is a claim about five engines and
not about this code, so it ships conformance vectors: each pattern evaluated
against each target's own matcher, with a red case for a pattern the dialect
allows and the engines disagree on. A dialect asserted only in prose is a
guess.

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

**Rejects.** Any key or table the schema does not define, any value of the
wrong type, an empty glob list, a glob outside the dialect in `repo-toml.md`, a
`reason` that is multi-line or contains `-->`, a surface name that is empty,
malformed, duplicated or reserved, an unknown doctrine block id in
`[doctrine.append]` or `[doctrine.replace]`, and a `schema` value other
than `1`.

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
schema, validated against a copy vendored in the consuming repo rather than
fetched at check time: an unknown top-level key, a wrong type, an enum miss
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
and its refresh step are a checklist line for that reason.

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
and the set derived fresh from the repo's own `kendex.toml`: every rendered
`.agents/skills/<name>`, no tree declared `in-place`, plus the per-harness
render directories the install declares. The comparison is over the derived
part alone, because the rendered set also holds every `[[exclusions.path]]`
entry and whole-set equality would fail on the first hand-written exclusion.
Runs only when `[exclusions] derive_render` is true.

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

**Rejects.** Any generated path whose bytes differ from a fresh render, naming
the path and the differing region. `check` reads the working tree by default
and the index under `--staged`, so a pre-commit lane judges what is about to be
committed rather than what happens to be on disk.

## Where these run

`render` runs all of them against the scratch tree before writing, and writes
nothing when one fails. `check` runs all of them against the repo.

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
