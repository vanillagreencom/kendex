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

`coderabbit`, string, optional, ASCII only. Renders to `tone_instructions`,
whose hard cap is 250 characters after the generator strips the newlines a TOML
multi-line string introduces. Over the cap, CodeRabbit rejects the entire file.
ASCII is required so that the local count and the vendor's cannot disagree
about what one character is. Absent, the shipped default is used; see
`renders.md` for its text.

### `[budgets]`

`copilot_chars`, integer, default `6000`. The rendered
`.github/copilot-instructions.md` may not exceed it. GitHub documents no
numeric cap for that file and asks for "no longer than 2 pages", so this is the
package's reading of two pages rather than a vendor limit. Raise it in a repo
whose surfaces genuinely need more, and say why in a comment.

### `[exclusions]`

`derive_render`, bool, default `false`. When true, the generator reads the
repo's install manifest and adds every rendered harness tree to the exclusion
set. What it derives is exactly two things: each `.agents/skills/<name>` whose
entry does not declare `source = "in-place"`, and each per-harness render
directory the repo's install declares. A skill declared `in-place` is this
repo's own file and stays in review scope.

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
the string is single-line ASCII with no `-->` and no `#`, so it satisfies every
constraint a rendered comment is under by construction rather than by check.
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
| `exclude_globs` | array of string | no | Subtracted from `globs`, and real subtraction only on Macroscope |
| `reviewer_only` | bool | no, default `false` | Renders `excludeAgent: "cloud-agent"` into the Copilot file, keeping reviewer doctrine away from the working agent. `copilot-frontmatter` requires exactly that key and value when this is true, since the other permitted value hides the file from the reviewer instead |
| `instructions` | string | yes | What a reviewer gets wrong here, and what is true instead |

`name` may not be `doctrine`, `correctness`, `ignore`, or `approvability`. Each
is a path this package or Macroscope already governs, and a surface claiming one
would silently lose a file to write order.
`.macroscope/correctness/correctness.md` is the one worth naming: it is
Macroscope's governing file, carrying `waitsFor`, `requires` and their two
timeouts for the whole correctness run, and `macroscope-render` permits no
frontmatter key but `include` and `exclude`, so an `adopt` over it would drop a
repo's check prerequisites for good. A `name` colliding with another
surface, or producing a path another output already claims, is an error.

`instructions` is under the heading, frontmatter and marker refusals below.
Each restructures at least one output: a heading ends the `AGENTS.md` owned
region, `---` opens frontmatter, and the marker decides which files this package
owns.

## The content refusals

One row per input string, one column per refusal class. Everything that judges
these — `toml-schema`, `agents-section`, and the Escaping paragraphs in
`renders.md` — cites this table rather than restating it, so a predicate written
here is the only predicate.

| Input string | heading | frontmatter | marker | comment-close | toml-delimiter | control | character class |
|--------------|---------|-------------|--------|---------------|----------------|---------|-----------------|
| `[repo] name` | – | – | – | – | – | – | single line, `[A-Za-z0-9._-]` |
| `[repo] tracker` | – | – | – | – | – | – | single line, `[A-Za-z0-9._-]` |
| `[repo] summary` | yes | yes | yes | – | yes | yes | – |
| `[[surface]] instructions` | yes | yes | yes | – | – | yes | – |
| `[doctrine.append]` / `[doctrine.replace]` values | yes | yes | yes | – | yes | yes | – |
| doctrine block text | yes | yes | yes | – | yes | yes | – |
| `[[exclusions.path]] reason` | – | – | yes | yes | – | yes | single line |
| `[[surface]] globs`, `exclude_globs`, `[[exclusions.path]] glob` | – | – | – | – | – | – | non-empty, the glob dialect above, and its path-shape rule |
| `[tone] coderabbit` | – | – | – | – | – | yes | ASCII only |
| `[cadence] qodo_commands` entries | – | – | – | – | – | – | a verb from the set above, no whitespace, no `--` |

The predicates, written once:

- **heading** — a line whose first non-whitespace character is `#` after three
  or fewer leading spaces. That is what markdown reads as a heading, and the
  wide form is the one the outputs need: a line indented two spaces before `#`
  ends the `AGENTS.md` owned region just as surely as one in column zero, so a
  narrower input rule would pass a value the render then refuses.
- **frontmatter** — a line that is exactly `---`, which opens or closes YAML
  frontmatter in a `.instructions.md` file.
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
- **control** — any C0 control character other than tab and newline, and DEL
  (`U+007F`). One predicate for both structured targets, because the values
  reaching them are the same set: a TOML basic multi-line string permits tab
  and newline and no other control, and so does a YAML scalar. TOML's own
  escapes are how one arrives — `summary = "\u0000"` parses cleanly and yields
  a literal NUL — so the value is already decoded by the time this sees it.

  A character class exempts a row from this mark only when it **enumerates the
  permitted characters**, because then no control is among them. A class that
  names an encoding does not: ASCII contains NUL and every C0 control, so
  `[tone] coderabbit` carries the mark despite having a class. Neither does a
  class constraining one dimension only: `single line` says nothing about the
  controls that are not newlines, which is why `[[exclusions.path]] reason`
  carries it too. Read the test against each class rather than counting the
  rows that have one.
- **character class** — as stated per row above. Three enumerate their
  permitted characters and so need no `control` mark: `[repo] name` and
  `[repo] tracker` take `[A-Za-z0-9._-]`, the globs take the dialect's own
  class, and `qodo_commands` takes a verb from a closed literal set. `[tone]
  coderabbit` is ASCII so the local length count and the vendor's cannot
  disagree about what one character is — which matters there and nowhere else,
  since `tone_instructions` is the cap CodeRabbit discards the whole file over —
  and ASCII is an encoding rather than an enumeration, so that row is marked
  `control` as well. Tab and newline stay legal there: the documented way to
  author a tone is a TOML multi-line string, and the render collapses its
  newlines to single spaces.

**Refusals, not escapes.** Every class here is refused at input. The render
escapes only what a format requires of text already known to be legal — a
backslash in a TOML basic string — and rewrites nothing else. An escape for one
of these would mean the generator silently altering an author's words to make
them fit a file, which is worse than telling the author the words do not fit.

**Render-side second checks.** `renders.md` re-checks the heading class when it
assembles the `AGENTS.md` region and the Copilot file, because doctrine text
does not come through this file at all and so is not covered by any input
refusal. It does not re-check frontmatter or marker there, and that is a
decision rather than an omission: neither can reach those two outputs from
doctrine without also reaching a `.instructions.md` file, where the frontmatter
the generator emits is fixed and the marker is written by the generator itself.

Every row is one clause with one control, and § Controls' count is checkable
against this table. `toml-schema` carries no list of its own: it names this
table and adds the one clause that is a path shape rather than a content
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
carrying an override that reaches nothing. Both are subject to the same
leading-`#`, `---` and marker refusals as `instructions`.

Prefer `append`. A `replace` means this repo disagrees with doctrine, which is
worth arguing at the doctrine source rather than in one repo's TOML. A
`replace` on `trust-model` or `render-out-of-scope` also weakens what every bot
is told about evidence and scope, so a repo whose gate reads bot output should
treat one as the policy change it is.
