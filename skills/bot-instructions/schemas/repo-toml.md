# `bot-instructions.toml`

One file per repo, at the repo root beside `.coderabbit.yaml` and
`.pr_agent.toml`. It holds everything about a repo that a bot needs and
doctrine cannot know: what the repo is, which bot capabilities are live here,
what is not this repo's code to fix, and what a reviewer gets wrong on a given
path.

The file is hand-written and never generated. It is the one file in the set a
person edits.

**The schema is closed.** An unknown key, an unknown table, or a value of the
wrong type is an error naming the key. A typo like `[bot]`, `derive_renders` or
`review_only` would otherwise be ignored while defaults produced plausible
output, which is the silent failure this whole package exists to remove.

## Shape

```toml
schema = 1

[repo]
name = "kendex"
summary = """
kendex is a distribution of agent-stack assets: skills, agent definitions,
hooks, Pi extensions, a Rust engine and CLI, and a Tauri app. Consumers vendor
the skills and re-vendor in deliberate batches.
"""
tracker = "KEN"

[bots]
codex = true
copilot = true
coderabbit = true
qodo = true
qodo_best_practices = true
qodo_review_md = false
macroscope = false

[cadence]
coderabbit_incremental = true
qodo_commands = ["/agentic_review"]
qodo_push_trigger = false

[tone]
coderabbit = """
Terse and technical. Give the defect, its triggering input, and the
consequence. No praise, diff restatement, or summary. One finding per thread.
"""

[budgets]
copilot_chars = 6000

[exclusions]
derive_render = true

[[exclusions.path]]
glob = "testdata/golden/**"
reason = "benchmark-host captured, never compared in CI"

[[surface]]
name = "tests"
globs = ["**/tests/**", "**/*.test.sh"]
reviewer_only = true
instructions = """
A scratch directory the test removes in its own EXIT trap is cleaned up. Do not
report it as a leak.
"""

[doctrine.append]
severity = "A performance claim needs a measurement, not an argument."

[doctrine.replace]
trust-model = "This repo has no gate. Any review object is advisory."
```

## The glob dialect

One pattern is written once and handed to Copilot's comma-separated `applyTo`,
CodeRabbit's minimatch and `git sparse-checkout`, Qodo's `[ignore]`, and
Macroscope's `include`. Those engines agree on very little, so the file accepts
only what all of them read the same way.

**Allowed characters, and nothing else:** the printable ASCII path characters
`A-Z a-z 0-9 . _ - /` plus the four metacharacters `*`, `?`, `[`, `]`. `**` is
the two-character form of `*`. Every other byte is refused, which covers a
newline, a tab, any other control character, leading or trailing whitespace,
and `#`.

Stating the dialect as a character class rather than as a list of banned
sequences is deliberate. A glob is rendered into files whose grammars are
line-oriented or comment-bearing: one holding a newline becomes two lines in
`.macroscope/ignore.md`, where every line is a pattern, so a second line reading
`**` takes the whole repo out of Macroscope's review while each line on its own
is a valid glob and every validator passes. One holding `#` becomes a comment in
`.coderabbit.yaml`. A ban list closes the shapes someone thought of; a character
class closes the rest.

**Path shape, on top of the class.** Refused: an empty glob, a leading `/`, a
trailing `/`, a `..` component, and an empty component. Each is its own clause,
so each ships its own control.

The class catches none of them. `.` and `/` are both permitted characters, so
`../**` and `/src/**` are made of nothing but allowed bytes; and the class
constrains which characters may appear rather than requiring one to, so `""`
satisfies it and everything else stated here.

Why each matters. A `..` component is a path escape in the one place this
package hands its own strings to a checkout tool, since `path_filters` reaches
`git sparse-checkout`. A leading `/` is an anchoring form the engines read
differently. An empty glob means something different to each of the five, so it
renders as a pattern whose effect is undefined and engine-dependent — the silent
failure this package exists to remove.

The metacharacters the class leaves out are worth naming for the error message:
a brace (`{`, `}`), extglob (`!(`, `@(`, `+(`, `?(`, `*(`), a comma, a
backslash, a leading `!`, and a double quote. A comma because Copilot's
`applyTo` splits on it and CodeRabbit's multi-glob join uses braces; the rest
because at least one engine reads them differently from the others, and a
pattern that means two things is worse than one that is rejected.

An empty glob list is an error wherever a glob list is required, which is the
list-level counterpart of the empty-glob clause above.

## Keys

### `schema`

Integer, required. `1`. The generator refuses a value it does not know rather
than rendering a partly understood file.

### `[repo]`

| Key | Type | Required | Meaning |
|-----|------|----------|---------|
| `name` | string | yes | The repo's own name, used in generated file headers. One line, `[A-Za-z0-9._-]` only, because it renders as a `#` heading line |
| `summary` | string | yes | What this repo is, in two to six sentences. Rendered near the top of the Copilot and Qodo surfaces, which is the only place a bot learns the shape of the codebase |
| `tracker` | string | no | Issue prefix, e.g. `KEN`. Substituted into the `reply-contract` block's `<issue>` placeholder, so it reaches every destination that block does, `.pr_agent.toml` included. Its character class in the table below is what keeps it safe in all of them. Absent leaves the placeholder generic, which a repo guard pinning the tracked reply form reads as the form being gone |

`summary` is prose about this repo, not doctrine. Anything in it that would be
true of another repo belongs in a doctrine block instead. It is under the same
content refusals as `[[surface]] instructions`; the table below says which
those are, for every string this package renders into a structured file.

### `[bots]`

Booleans, each defaulting to `false`, one per capability rather than one per
vendor. A vendor name covers products with different file support and different
portal toggles, and a single flag would render authoritative-looking files that
reach nothing.

| Key | Renders |
|-----|---------|
| `codex` | the `AGENTS.md` section, which is the doctrine root rather than a Codex-only file |
| `copilot` | `.github/copilot-instructions.md` and `.github/instructions/*.instructions.md` |
| `coderabbit` | `.coderabbit.yaml` |
| `qodo` | `.pr_agent.toml` |
| `qodo_best_practices` | `best_practices.md`. Automatic loading of that file is Qodo Merge, the commercial product; open-source PR-Agent does not read it |
| `qodo_review_md` | `REVIEW.md`. Inert until the portal's "REVIEW.md instructions" toggle is on, which is why it is a flag someone sets after doing the checklist line rather than something the generator infers |
| `macroscope` | the `.macroscope/` tree |

**Every flag false is not an error.** A TOML that enables nothing has nothing to
render, and that is a state worth holding: it is how a repo commits its
`bot-instructions.toml` in the repo-wide pass of `references/checklist.md`
§ Adding a repo, before its settings work has enabled anything, and how a fleet
stages a rollout one bot at a time. The default being `false` is what makes that
the safe direction — a minimal TOML writes no file the repo did not ask for.
`render` says it wrote nothing rather than exiting quietly, so an operator who
expected files learns the flags are off; rendering nothing in silence would be
the thing this package exists to prevent. Having nothing to render is not the same as a render that cannot stop:
`agents-section`'s nested-`AGENTS.md` clause is gated by no flag and runs before
every write, so an all-off render still fails on a repo holding such a section.
`references/checklist.md` § Adding a repo makes clearing one a pass-one step for
that reason.

What is an error is a flag combination where something enabled reaches nothing.
Three of those, all enforced by `toml-schema`:

- `qodo_best_practices` or `qodo_review_md` true with `qodo` false.
- `copilot` or `coderabbit` true with `codex` false. Both read the `AGENTS.md`
  section: CodeRabbit through `knowledge_base.code_guidelines.filePatterns`,
  Copilot code review directly on GitHub.com. Without it, `.coderabbit.yaml`
  carries one doctrine block and the Copilot file's reply-contract pointer aims
  at a section that does not exist, and both render clean.
- A non-empty `[[surface]]` set with `copilot`, `coderabbit`, `macroscope` and
  `qodo_best_practices` all false. Those four are every route surface text has,
  so the surfaces would be instructions nothing reads.

Turning a capability off renders none of its files and deletes none of them, so
the files this package wrote stay active until someone removes them. Deleting
them is the same commit's work and it comes first: `render` fails on an orphan
rather than creating one, so the order is delete, then flip the flag and render.
`check` is what catches a retirement that skipped the render.
`validators.md` § `orphan` carries the order. A file at one of those paths that
this package never wrote is the repo's own and is not judged: `adopt` is how one
becomes managed, and it needs the capability on.

### `[cadence]`

| Key | Type | Default | Renders to |
|-----|------|---------|------------|
| `coderabbit_incremental` | bool | `true` | `reviews.auto_review.auto_incremental_review` |
| `coderabbit_drafts` | bool | `false` | `reviews.auto_review.drafts` |
| `qodo_commands` | array of string | `["/agentic_review"]` | `[github_app] pr_commands` |
| `qodo_push_trigger` | bool | `false` | `[github_app] handle_push_trigger` |

Each `qodo_commands` entry is a bare verb from this set, which is the one
statement of it — `qodo-parity` reads the review half rather than carrying a
copy:

| Verb | Line | Role |
|------|------|------|
| `/agentic_review` | Review | review |
| `/review` | Merge | review |
| `/agentic_describe` | Review | not review |
| `/describe` | Merge | not review |
| `/improve` | Merge | not review |

`qodo-parity` requires guidance in the section a **review** verb reads, and this
render writes it for both. A verb in the other half reads a section this render
leaves alone by design — `/agentic_describe` and `/describe` write the pull
request body, `/improve` reads `[pr_code_suggestions]` — so the parity clause
does not apply to it and its presence is not a finding. Splitting by role rather
than narrowing the set is what keeps the vendor's own documented default,
`["/agentic_describe", "/agentic_review"]`, from being a schema error.

No whitespace and no `--` in an entry. A `pr_commands` entry carries inline
`--section.key=value` overrides, which is how Qodo's own examples are written,
so `/review --pr_reviewer.extra_instructions=""` would null the guidance the
render just wrote while `qodo-parity` passed: that validator compares the two
sections against each other and never reads a command line. Refusing the
override form at input is cheaper than teaching a validator to parse it.

First-push-only cadence is `coderabbit_incremental = false` with
`qodo_push_trigger = false`: neither bot re-reviews on push, and a reviewer is
summoned by comment at a batch boundary. It is the setting that decides how
many rounds a pull request costs, so it is a per-repo choice rather than a
doctrine constant, and no doctrine block asserts what a push triggers.

### `[tone]`

`coderabbit`, string, optional. Renders to `tone_instructions`, whose hard cap
is 250 characters after the generator strips the newlines a TOML multi-line
string introduces. Over the cap, CodeRabbit rejects the entire file. The cap
counts Unicode code points, which is what the vendored schema's `maxLength`
counts. Absent, the shipped default is used; see `renders.md` for its text.

### `[budgets]`

| Key | Type | Default | Bounds |
|-----|------|---------|--------|
| `copilot_chars` | integer | `6000` | the rendered `.github/copilot-instructions.md`, in characters |
| `qodo_best_practices_lines` | integer | `800` | the rendered `best_practices.md`, in lines |

Both are package budgets rather than vendor caps, and they are the same kind of
thing: GitHub documents no numeric cap and asks for "no longer than 2 pages",
Qodo recommends keeping a best-practices file under about 800 lines and states
no length at which it rejects or truncates one. `references/limits.md` carries
each recommendation and marks the budget built on it. Raise one in a repo whose
surfaces genuinely need more, and say why in a comment.

The vendor caps this package can reach — `tone_instructions` at 250 characters
and a `path_instructions` entry at 20,000 — take no key. They are the vendored
CodeRabbit schema's own `maxLength`, so `coderabbit-schema` is their single
enforcer and nothing here carries a second copy of either number.

### `[exclusions]`

`derive_render`, bool, default `false`. When true, the generator reads the
repo's install manifest and adds every rendered harness tree to the exclusion
set. What it derives is exactly two things: each `.agents/skills/<name>` whose
entry does not declare `source = "in-place"`, and each **immediate
subdirectory holding a tracked path** of each per-harness render root the
repo's install declares. A skill declared `in-place` is this repo's own file
and stays in review scope. The tracked-path condition is what keeps a
derivation and the dead-exclusion clause from contradicting each other: a
subtree the install has not produced, or one git ignores, excludes nothing,
and deriving it would name a glob that clause rejects with no edit an author
could make to clear it. A render root the index holds as an entry of its own — staged as a symlink, or
as a file — is refused naming that root rather than derived as an empty set,
because git stores such a root as one entry with the tree under its real name
and an empty derivation would leave that tree in review scope silently. A
derived glob is held to the glob dialect like a declared one, and a manifest
key or directory name outside it fails naming the manifest row that produced
it: this is the one glob source no author writes as
a glob, and the paths render as prose on the two surfaces that read them as
prose, where nothing would judge them as patterns at all.

**A harness root is never derived whole**, and the subdirectory rule is why. A
harness root holds two kinds of thing: subdirectories the harness install owns
whole, and root-level files it merges its own entries into while the repo owns
the rest — `.claude/settings.json`, `.codex/config.toml`, `.pi/settings.json`,
and the repo's own memory file beside them. Excluding the root would silence
bot review on files this repo actually owns and can fix, which is the opposite
of what the derivation is for: it exists to keep vendored render output out of
review, not to hide hand-maintained config.
`skills/review-gate/references/vendored-paths.md` § The harness-render variant
draws the same line for the review gate's own set and names the merged paths.

One harness root is the repo's own directory rather than the harness's:
Copilot's is `.github`, where the install owns `agents`, `hooks` and `skills`
and the repo owns everything else. That row names its subtrees instead of
taking the root. A harness the generator has no row for is an error rather than
a guessed root, because guessing wrong there is the silenced-settings-file
failure above.

**The manifest is the one kendex resolves, never a hardcoded filename.** That
is `kendex.toml`, except in a repo whose `kendex.toml` declares
`is_source_catalog = true`, where install state routes to the sibling
`kendex-local.toml` and `kendex.toml` holds the published catalog with no
install tables at all. kendex's own repo is such a catalog. A generator that
opened `kendex.toml` by name there would parse a present, valid file, derive an
empty set, exclude none of the rendered trees, and pass its own consistency
check comparing empty against empty — the exact silent failure this package
exists to remove.

**A resolved manifest that declares no install is an error**, not an empty
derivation. So is a missing or unparseable one. Either way the render produces
nothing, the hand-written exclusions included, because a repo the generator
cannot derive from should say so rather than ship a short list.

`derive_render` makes both manifests render inputs, because the root file is
read to decide where the install state lives and the sibling only when it says
so. SKILL.md § The render inputs states the pair; the marker names each by the
path actually read.

**A derived entry's reason is fixed, and this is the only place it is written:**

> harness render output, owned upstream — a defect here is fixed at the source
> and arrives by re-render

Every derived entry carries that exact string, because every derived entry is
excluded for that one reason and nothing about the tree distinguishes them. A
render rule that wants a reason takes it from here rather than restating it, and
the string is a single ASCII line with no `-->` and no `#`, so it satisfies
every constraint a rendered comment is under by construction rather than by
check.
Without it the render rules would demand bytes the schema never supplies:
`reason` is a required key on `[[exclusions.path]]` entries alone, and a derived
entry has no TOML row to carry one.

`[[exclusions.path]]` entries add repo-specific paths.

| Key | Type | Required | Meaning |
|-----|------|----------|---------|
| `glob` | string | yes | A pattern in the dialect above |
| `reason` | string | yes | Why this path is not reviewable. Rendered as a comment beside the entry on the surfaces whose render rules say so |

A reason is required because an exclusion with no stated reason is
indistinguishable from a mistake at the next read. That argument covers derived
entries too, which is why they carry the fixed string above rather than nothing;
what they do not have is a TOML row, so the required key stays on
`[[exclusions.path]]` and the generator supplies the rest.

### `[[surface]]`

A path set plus what a reviewer needs to know about it. Zero or more.

| Key | Type | Required | Meaning |
|-----|------|----------|---------|
| `name` | string | yes | Lowercase, `[a-z0-9-]`, non-empty, unique. Becomes the generated filenames |
| `globs` | array of string | yes | Non-empty. Paths this surface covers |
| `exclude_globs` | array of string | no | Subtracted from `globs`, and real subtraction only on Macroscope. Kept rather than cut: it is the only path-scoped subtraction any of the five bots offers a repo file, and losing it would leave narrowing `globs` as the only tool. Everywhere else it renders as prose asking a bot to disregard rules it has already loaded, which SKILL.md says plainly rather than dressing up |
| `reviewer_only` | bool | no, default `false` | Renders `excludeAgent: "cloud-agent"` into the Copilot file, keeping reviewer doctrine away from the working agent. The other permitted value, `code-review`, hides the file from the reviewer instead, so `renders.md` fixes which one is written |
| `instructions` | string | yes | What a reviewer gets wrong here, and what is true instead |

`name` may not be `doctrine`, `correctness`, `ignore`, or `approvability`. Each
is a path this package or Macroscope already governs, and a surface claiming one
would silently lose a file to write order.
`.macroscope/correctness/correctness.md` is the one worth naming: it is
Macroscope's governing file, carrying `waitsFor`, `requires` and their two
timeouts for the whole correctness run, and the render writes no frontmatter
key but `include` and `exclude`, so an `adopt` over it would drop a repo's
check prerequisites for good. A `name` colliding with another surface is
an error. There is no separate check for a path collision, because the name
**is** the generated filename: uniqueness plus the reserved set decides it, and
a second check could never red.

`instructions` is under the heading, marker and control refusals below. Each
restructures at least one output: a heading — `#` or an underline — ends the
`AGENTS.md` owned region or forges a section, and the marker decides which
files this package owns. It is also required to be non-empty, which is a rule
about the surface rather than about the string: whitespace renders a
`path_instructions` entry with no text, a `.instructions.md` carrying a marker
and nothing under it, and a best-practices section with no body — a surface
that costs its bots a read and tells them nothing. Drop the surface instead.

A `[...]` class is made of permitted characters and is not itself checked
character by character, so the dialect admits one shape no engine can compile:
a reversed range like `[z-a]`. `globs.check` proves the pattern compiles as its
last clause, which makes that a `toml-schema` finding naming the glob rather
than a traceback out of a validator much later. Consecutive `**/` are collapsed
to one before matching — `**/**/` covers exactly what `**/` covers, and nesting
the translation of `**/` is exponential in the number of them, which is a
runtime the dead-exclusion clause pays once per tracked path.

## The content refusals

One row per input string, one column per refusal class, and an **Enforced**
column saying which side reads that row's value. Every class here is one that
would break the STRUCTURE of a file this package emits; a value this package
merely dislikes is not refused. Everything that judges these —
`toml-schema` and the Escaping paragraphs in `renders.md` — cites this table
rather than restating it, so a predicate written here is the only predicate.
Three structures encode it, one per kind of cell: `refusals.ROWS` holds the
eight rows whose refusals are content classes, `globs.check` holds the glob
row, whose character class and path-shape clauses are its own, and
`config._cadence` holds the `qodo_commands` row. A reader counting clauses off
this table lands on those three, and `tests/toml-schema.test.sh` holds the
table against them so a row added on one side without the other reds.

The Enforced column exists because one row is not in `bot-instructions.toml` at
all. Doctrine block text lives in the spec copy, so `toml-schema` never sees it
and cannot be the clause's owner; the render-side check is. Without the column
a reader counting `toml-schema`'s clauses off this table would count three that
nothing there implements.

| Input string | heading | marker | comment-close | toml-delimiter | control | character class | Enforced |
|--------------|---------|--------|---------------|----------------|---------|-----------------|----------|
| `[repo] name` | – | yes | – | yes | yes | single line | `toml-schema` |
| `[repo] tracker` | – | yes | – | yes | yes | single line | `toml-schema` |
| `[repo] summary` | yes | yes | – | yes | yes | – | `toml-schema` |
| `[[surface]] instructions` | yes | yes | – | – | yes | – | `toml-schema` |
| `[doctrine.append]` / `[doctrine.replace]` values | yes | yes | – | yes | yes | – | `toml-schema` |
| doctrine block text | yes | yes | – | yes | yes | – | render-side |
| `[[exclusions.path]] reason` | – | yes | yes | – | yes | single line | `toml-schema` |
| `[[surface]] globs`, `exclude_globs`, `[[exclusions.path]] glob` | – | – | – | – | – | non-empty, the glob dialect above, and its path-shape rule | `toml-schema` |
| `[tone] coderabbit` | – | – | – | – | yes | – | `toml-schema` |
| `[cadence] qodo_commands` entries | – | – | – | – | – | a verb from the set above, no whitespace, no `--` | `toml-schema` |

The predicates, written once:

- **heading** — a line markdown reads as a heading, in **either** of the two
  forms `scripts/lib/markdown.py` states. ATX is one to six `#` after three or
  fewer leading spaces, followed by a space, a tab, or the end of the line.
  Wide about the indentation, because a line indented two spaces ends the
  `AGENTS.md` owned region as surely as one in column zero and a narrower input
  rule would pass a value the render then refuses. Exact about the delimiter,
  in both directions: `#1917` is a heading to no reader, and refusing it here
  made a doctrine block carrying a pull request number unrenderable, while `##`
  before a no-break space is a heading to no reader either and reading it as
  one ended the owned region early.
  Setext is a run of `=` or of `-`, indented at most three spaces with only
  whitespace after it, **under a non-blank line** — `Injected` over `===` is an
  H1 to every CommonMark reader. This half is wide on purpose: it does not ask
  whether the line above is a paragraph or the opener of a fenced block,
  because a refusal that is too wide costs an author a rewrite while one that
  is too narrow puts a structural heading into a generated file. The section
  terminators read ATX alone and `markdown.py` says why; what makes that safe
  is this row, which keeps a setext underline out of every string they parse.
- **marker** — a line carrying the marker text, which is what decides which
  files this package owns.
- **comment-close** — `-->`, which would end the HTML comment a `reason` is
  rendered inside and put the rest of the value on a line of its own.
- **toml-delimiter** — `"""`, which would end the TOML multi-line string the
  value is rendered inside. `.pr_agent.toml` carries every doctrine block and
  `[repo] summary` as basic multi-line strings, so a value holding the delimiter
  closes its own string and the rest of it becomes TOML. Marked on exactly the
  values that reach a TOML string; `[[surface]] instructions` reaches Qodo
  through `best_practices.md`, which is markdown.
- **control** — any C0 control character other than tab and newline, DEL
  (`U+007F`), and the three characters above that range a reader still breaks
  a line on: `U+0085` NEL, `U+2028` LINE SEPARATOR and `U+2029` PARAGRAPH
  SEPARATOR. One predicate for both structured targets, because the values
  reaching them are the same set: a TOML basic multi-line string permits tab
  and newline and no other control, and so does a YAML scalar. TOML's own
  escapes are how one arrives — `summary = "\u0000"` parses cleanly and yields
  a literal NUL — so the value is already decoded by the time this sees it.

  The three above C0 are in the class for the same reason the C0 ones are, one
  layer out: YAML 1.1 lists them as line breaks and every reader CodeRabbit's
  file reaches acts on them. A value carrying one is emitted as a single line
  here and read as two there, so a rendered `reason` comment becomes a
  `path_filters:` key of its own and the entry below it loses its `!` — the
  state `renders.md` § `reviews.path_filters` names as the one that turns the
  exclusion list into an allowlist. `scripts/lib/refusals.py` is the one
  statement of the class, and `coderabbit-schema` runs that same predicate over
  the document it validates: a default in the vendored schema reaches a
  rendered file through no row of this table.

  A `single line` class does not exempt a row from this mark: it refuses the
  line breaks and says nothing about the rest of the class — NUL, DEL, the C0
  controls that break no line. Read the test against each class rather than
  counting the rows that have one.
- **character class** — as stated per row above. `single line` on `[repo]
  name`, `[repo] tracker` and `[[exclusions.path]] reason`; the dialect's own
  class on the globs; a verb from a closed literal set on `qodo_commands`. Tab
  and newline stay legal in `[tone] coderabbit`: the documented way to author a
  tone is a TOML multi-line string, and the render collapses its newlines to
  single spaces.

**Refusals, not escapes.** Every class here is refused at input. The render
escapes only what a format requires of text already known to be legal — a
backslash in a TOML basic string — and rewrites nothing else. An escape for one
of these would mean the generator silently altering an author's words to make
them fit a file, which is worse than telling the author the words do not fit.

**Render-side second checks.** The `doctrine block text` row is enforced where
that value is read — when the generator parses the `## Doctrine` section — and it
carries **every** class the row marks, not the heading class alone. Doctrine
text does not come through this file, so no input refusal covers it, and each
of the three markdown classes is reachable on its own route: a heading line
ends the `AGENTS.md` owned region at the next render, and an underline under a
text line renders into `.github/copilot-instructions.md`, where blocks are `##`
subsections with paragraphs preserved, forging a section in the one file whose
Escaping paragraph exists so a repo string cannot forge one; a line that is
exactly `---` opens frontmatter where a block reaches byte 0; and the marker
text would forge ownership of a file the repo wrote. Doctrine text reaches no
`.instructions.md` file on any route — the routing table gives it eight
destinations and that is not one of them — so nothing about the generator
emitting that file's frontmatter itself covers any of the three.

Every marked cell is one clause with one control, and § Controls' count is
checkable against this table read with its Enforced column. `toml-schema`
carries no list of its own: it names this table, takes the rows Enforced marks
as its, and adds the one clause that is a path shape rather than a content
refusal.

Two surfaces may match the same file. Macroscope stacks both, CodeRabbit may
apply both `path_instructions` entries, and Copilot may load both files. No bot
resolves a contradiction between them in TOML declaration order, so keeping
overlapping surfaces consistent is the author's job.

Write `instructions` as claims about this repo that a competent reviewer would
otherwise get wrong: a convention that looks like a bug, a suggestion that has
already been made and is wrong, an invariant a test pins. A sentence that would
be true of any repo is doctrine, and belongs in a doctrine block.

### `[doctrine.append]` and `[doctrine.replace]`

Both are tables keyed by doctrine block id. `append` adds a paragraph to a
block for this repo; `replace` substitutes the block's whole text. An unknown
block id is an error, so a doctrine rename cannot leave a repo silently
carrying an override that reaches nothing. Their values carry the refusals
their own row in § The content refusals marks, which is a wider set than
`instructions` has and is stated only there. They are repo text, so their line
breaks are preserved wherever the block lands — a fenced example survives as
one — with the `AGENTS.md` owned region the one exception, since a block
renders there as a single bullet whatever wrote it.

Prefer `append`. A `replace` means this repo disagrees with doctrine, which is
worth arguing at the doctrine source rather than in one repo's TOML. A
`replace` on `trust-model` or `render-out-of-scope` also weakens what every bot
is told about evidence and scope, so a repo whose gate reads bot output should
treat one as the policy change it is.
