# `[bot-instructions]`

- The `[bot-instructions]` table holds repo context, enabled bots, exclusions, path instructions and doctrine overrides.
- It belongs in the effective kendex manifest, beside `[skill-instructions]` and `[agent-additional-instructions]`.
- The generator reads the manifest kendex resolves, never a hardcoded filename: `kendex.toml`, or, when that file declares `is_source_catalog = true`, `kendex-local.toml` for all bot settings.
- It does not merge the two tables.
- This selection also applies when `derive_render` is false.
- The same resolved manifest supplies derived exclusions.
- The bot schema is closed within this table.
- Unknown keys, unknown child tables and wrong value types fail `toml-schema`.
- Other manifest tables are outside this schema.

## Shape

```toml
schema = 7

[bot-instructions]
schema = 1

[bot-instructions.repo]
name = "kendex"
summary = """
kendex is a distribution of agent-stack assets: skills, agent definitions,
hooks, Pi extensions, a Rust engine and CLI, and a Tauri app. Consumers vendor
the skills and re-vendor in deliberate batches.
"""
tracker = "KEN"

[bot-instructions.bots]
codex = true
copilot = true
coderabbit = true
qodo = true
qodo_best_practices = true
qodo_review_md = false
macroscope = false

[bot-instructions.cadence]
coderabbit_incremental = true
qodo_commands = ["/agentic_review"]
qodo_push_trigger = false

[bot-instructions.tone]
coderabbit = """
Terse and technical. Give the defect, its triggering input, and the
consequence. No praise, diff restatement, or summary. One finding per thread.
"""

[bot-instructions.budgets]
copilot_chars = 6000

[bot-instructions.exclusions]
derive_render = true

[[bot-instructions.exclusions.path]]
glob = "testdata/golden/**"
reason = "captured fixtures, never compared in CI"

[[bot-instructions.surface]]
name = "tests"
globs = ["**/tests/**", "**/*.test.sh"]
reviewer_only = true
instructions = """
A scratch directory the test removes in its own EXIT trap is cleaned up. Do not
report it as a leak.
"""

[bot-instructions.doctrine.append]
severity = "A performance claim needs a measurement, not an argument."

[bot-instructions.doctrine.replace]
trust-model = "This repo has no gate. Any review object is advisory."
```

## The glob dialect

One pattern is written once and handed to Copilot's comma-separated `applyTo`, CodeRabbit's minimatch and `git sparse-checkout`, Qodo's `[ignore]`, and Macroscope's `include`. The file accepts only what all of them read the same way.

**Allowed characters, and nothing else:** the printable ASCII path characters `A-Z a-z 0-9 . _ - /` plus the four metacharacters `*`, `?`, `[`, `]`.

- `**` is the two-character form of `*`.
- Every other byte is refused, which covers a newline, a tab, any other control character, leading or trailing whitespace, and `#`.
- Among the refused: a brace (`{`, `}`), extglob (`!(`, `@(`, `+(`, `?(`, `*(`), a comma, a backslash, a leading `!`, and a double quote.

**Path shape, on top of the class.**

- Refused: an empty glob, a leading `/`, a trailing `/`, a `..` component, and an empty component.
- Admit test protection under `validators.md` § Controls.

An empty glob list is an error wherever a glob list is required.

## Keys

### `[bot-instructions] schema`

Integer, required. `1`. The generator refuses a value it does not know rather than rendering a partly understood file.

### `[bot-instructions.repo]`

| Key | Type | Required | Meaning |
|-----|------|----------|---------|
| `name` | string | yes | The repo's own name, used in generated file headers |
| `summary` | string | yes | What this repo is, in two to six sentences |
| `tracker` | string | no | Issue prefix, e.g. `KEN` |
| `code_review_path` | string | no | Where the complete review doctrine is written |

`name`:

- One line, `[A-Za-z0-9._-]` only, because it renders as a `#` heading line.

`summary`:

- Rendered near the top of the Copilot and Qodo surfaces, which is the only place a bot learns the shape of the codebase.
- `summary` is prose about this repo. A claim that would be true of another repo belongs in a doctrine block instead.
- It is under the refusals its row in § The content refusals marks.

`tracker`:

- Substituted into the `reply-contract` block's `<issue>` placeholder, so it reaches every destination that block does, `.pr_agent.toml` included.
- Absent leaves the placeholder generic, which a repo guard pinning the tracked reply form reads as the form being gone.

`code_review_path`:

- The path the `AGENTS.md` directive, the Copilot pointer and CodeRabbit's `code_guidelines.filePatterns` all name.
- Defaults to `.github/instructions/code-review.md`.
- Six clauses, each its own refusal:
  1. The marker path class `[A-Za-z0-9._/-]`.
  2. A `.md` suffix.
  3. No empty, `.` or `..` component.
  4. A parent directory of exactly `.github/instructions`.
  5. No `AGENTS.md` basename in any case.
  6. No upper-case basename.
- A path this render already writes is refused where the whole output set exists, naming it.
- The parent-directory clause keeps a retired path findable: `orphan` walks `.github/instructions`, so a file left at a path an earlier value named is reported by `check` and removed by the next `render` after it writes the new path.
- It also keeps every path this package writes inside its declared `repo-effects.writes`.

### `[bot-instructions.bots]`

Booleans, each defaulting to `false`, one per capability rather than one per vendor.

| Key | Renders |
|-----|---------|
| `codex` | the pointed `code_review_path` file and the `AGENTS.md` section |
| `copilot` | `.github/copilot-instructions.md` and `.github/instructions/*.instructions.md` |
| `coderabbit` | `.coderabbit.yaml` |
| `qodo` | `.pr_agent.toml` |
| `qodo_best_practices` | `best_practices.md` |
| `qodo_review_md` | `REVIEW.md` |
| `macroscope` | the `.macroscope/` tree |

- Codex, Copilot and CodeRabbit reach the pointed file, and the `AGENTS.md` section is the directive line sending Codex there.
- Which destinations still carry a block of their own is `renders.md` § Doctrine routing.
- Automatic loading of `best_practices.md` is Qodo Merge, the commercial product; open-source PR-Agent does not read it.
- `REVIEW.md` is inert until the portal's "REVIEW.md instructions" toggle is on, so someone sets `qodo_review_md` after doing the checklist line; the generator never infers it.

**Every flag false is not an error.**

- A TOML that enables nothing has nothing to render: it is how a repo commits its `[bot-instructions]` in the repo-wide pass of `workflows/add-repository.md`, and how a fleet stages a rollout one bot at a time.
- `render` says it wrote nothing rather than exiting quietly.
- `agents-section`'s nested-`AGENTS.md` clause is gated by no flag and runs before every write, so an all-off render still fails on a repo holding such a section.

Three flag combinations, where something enabled reaches nothing, fail `toml-schema`:

- `qodo_best_practices` or `qodo_review_md` true with `qodo` false.
- `copilot` or `coderabbit` true with `codex` false. That flag writes the pointed file both of them read: CodeRabbit through `knowledge_base.code_guidelines.filePatterns`, Copilot by following the pointer in `.github/copilot-instructions.md`.
- A non-empty `[[bot-instructions.surface]]` set with `copilot`, `coderabbit`, `macroscope` and `qodo_best_practices` all false. Those four are every route surface text has.

Turning a capability off renders none of its files, and the next `render` removes the marked files this package wrote for it, after its writes.

- `check` catches a retirement that skipped the render.
- `codex` is the exception: the owned `AGENTS.md` region is no file to remove, and `render` refuses while it carries the marker. Turning `codex` off starts by deleting the region's body under its kept heading, then renders.
- `validators.md` § `orphan` carries both halves.
- A file at one of those paths that this package never wrote is the repo's own and is not judged; `adopt` makes one managed, with the capability on.

Retiring every capability, as removing the package does, keeps that order whole:

1. Delete every `[[bot-instructions.surface]]` entry first, since a surface set with every route false is refused.
2. Delete the region's body.
3. Set every flag false.
4. Render.

The table itself stays until the package is gone, because a render with no `[bot-instructions]` table removes nothing; `validators.md` § `orphan` says what it reports instead.

### `[bot-instructions.cadence]`

| Key | Type | Default | Renders to |
|-----|------|---------|------------|
| `coderabbit_incremental` | bool | `true` | `reviews.auto_review.auto_incremental_review` |
| `coderabbit_drafts` | bool | `false` | `reviews.auto_review.drafts` |
| `qodo_commands` | array of string | `["/agentic_review"]` | `[github_app] pr_commands` |
| `qodo_push_trigger` | bool | `false` | `[github_app] handle_push_trigger` |

Each `qodo_commands` entry is a bare verb from this set. The generator reads the table as data, from its running copy, so it is the one statement of the set, and `qodo-parity` reads its Role column, `review` or `not review`:

| Verb | Line | Role |
|------|------|------|
| `/agentic_review` | Review | review |
| `/review` | Merge | review |
| `/agentic_describe` | Review | not review |
| `/describe` | Merge | not review |
| `/improve` | Merge | not review |

- `qodo-parity` requires guidance in the section a **review** verb reads, and this render writes it for both.
- A verb in the other half reads a section this render leaves alone, so its presence is not a finding: `/agentic_describe` and `/describe` write the pull request body, and `/improve` reads `[pr_code_suggestions]`.
- The vendor's documented default, `["/agentic_describe", "/agentic_review"]`, passes.
- No whitespace and no `--` in an entry. A `pr_commands` entry can carry inline `--section.key=value` overrides, so `/review --pr_reviewer.extra_instructions=""` would null the rendered guidance while `qodo-parity`, which never reads a command line, passed.
- First-push-only cadence is `coderabbit_incremental = false` with `qodo_push_trigger = false`: neither bot re-reviews on push, and a reviewer is summoned by comment at a batch boundary.

### `[bot-instructions.tone]`

`coderabbit`, string, optional.

- Renders to `tone_instructions`, whose hard cap is 250 characters after the generator strips the newlines a TOML multi-line string introduces.
- Over the cap, CodeRabbit rejects the entire file.
- The cap counts Unicode code points, which is what the vendored schema's `maxLength` counts.
- Absent, the shipped default is used; see `renders.md` for its text.

### `[bot-instructions.retention]`

`coderabbit`, bool, default `true`. What CodeRabbit keeps between pull requests.

- `false` renders `knowledge_base.opt_out = true`, which removes its stored learnings and its issue and pull request context.
- Code guidelines and web search are stateless and stay on.
- A repo whose checked-in policy is complete sets it `false`, so no learning accumulated in chat shadows the policy.

### `[bot-instructions.budgets]`

| Key | Type | Default | Bounds |
|-----|------|---------|--------|
| `copilot_chars` | integer | `6000` | the rendered `.github/copilot-instructions.md`, in characters |
| `qodo_best_practices_lines` | integer | `800` | the rendered `best_practices.md`, in lines |

- Both are package budgets rather than vendor caps; `references/limits.md` carries each recommendation they are taken from.
- Raise one in a repo whose surfaces need more, and say why in a comment.
- The vendor caps this package can reach, `tone_instructions` at 250 characters and a `path_instructions` entry at 20,000, take no key: `coderabbit-schema` enforces them from the vendored schema.

### `[bot-instructions.exclusions]`

`derive_render`, bool, default `false`. When true, the generator adds every rendered harness tree to the exclusion set, and derives exactly two things:

- Each `.agents/skills/<name>` tree the writer inventory `.kendex-generated.json` lists a path under.
  - A skill kendex installs as another skill's dependency is derived without a `[skills.<name>]` row.
  - A skill declared `in-place` is this repo's own file; kendex lists none of its paths, so it stays in review scope.
- Each **immediate subdirectory holding a tracked path** of each per-harness render root the repo's install declares.
  - It is read from the index in both modes, so a worktree render and a `--staged` check agree.
  - A tracked path names a subdirectory only when something follows its first component under the root: an entry directly under the root, such as `.claude/settings.json` or a `.claude/CLAUDE.md` tracked as a link, derives nothing.
  - A subtree the install has not produced, or one git ignores, derives nothing.

**A harness root is never derived whole.**

- A harness root holds subdirectories the harness install owns whole beside root-level files the repo owns or shares, such as `.claude/settings.json`, `.codex/config.toml`, `.pi/settings.json` and the repo's memory file, and excluding the root would silence review on them.
- `skills/review-gate/references/vendored-paths.md` § The harness-render variant draws the same line for the review gate's own set.
- Copilot's root is `.github`, where the install owns `agents`, `hooks` and `skills` and the repo owns everything else: that row names its subtrees.
- A harness the generator has no row for is an error.

A render root the index holds as an entry of its own, staged as a symlink or as a file, is refused naming that root rather than derived as an empty set.

- A derived glob is held to the glob dialect like a declared one. An inventory path component or directory name outside it fails naming the inventory entry or manifest row that produced it.

**A resolved manifest that declares no install is an error**, not an empty derivation.

- So is a missing or unparseable one, and so is an absent or unreadable `.kendex-generated.json`.
- Either way the render produces nothing, the hand-written exclusions included.

`derive_render` makes both manifests and the inventory render inputs: SKILL.md § The render inputs states the set, and the marker names each by the path actually read.

**A derived entry's reason is fixed, and this is the only place it is written:**

> harness render output, owned upstream — a defect here is fixed at the source and arrives by re-render

Every derived entry carries that exact string. A render rule that wants a reason takes it from here.

`[[bot-instructions.exclusions.path]]` entries add repo-specific paths.

| Key | Type | Required | Meaning |
|-----|------|----------|---------|
| `glob` | string | yes | A pattern in the dialect above |
| `reason` | string | yes | Why this path is not reviewable |

- `reason` is rendered as a comment beside the entry on the surfaces whose render rules say so.

Two classes are worth an entry in most repos, each with its own reason:

- A vendored tree this repo pins byte for byte. Its reason names the upstream where the fix lands.
- Lock files (`Cargo.lock`, `package-lock.json`, `pnpm-lock.yaml` and the rest), wherever they sit. Their reason is that a package manager writes them.
  - This package's matcher, which `exclusion-consistency` decides with, reads a pattern with no `/` from the repo root only, while Macroscope reads one at any depth (`references/limits.md` § Macroscope), so write `**/Cargo.lock` to match at any depth.
  - Exclude a lock file, not the manifest beside it.

`exclusion-consistency`'s dead-exclusion clause names an entry this repo does not need.

### `[[bot-instructions.surface]]`

A path set plus what a reviewer needs to know about it. Zero or more.

- Every render appends the spec copy's default surfaces, `SKILL.md` § Default surfaces, which are judged by this table's keys and refusals.
- A `name` one of them holds is refused here, because the two would render to one file.

| Key | Type | Required | Meaning |
|-----|------|----------|---------|
| `name` | string | yes | Becomes the generated filenames |
| `globs` | array of string | yes | Paths this surface covers |
| `exclude_globs` | array of string | no | Subtracted from `globs` |
| `reviewer_only` | bool | no, default `false` | Renders `excludeAgent: "cloud-agent"` into the Copilot file |
| `instructions` | string | yes | What a reviewer gets wrong here, and what is true instead |

`name`:

- Lowercase, `[a-z0-9-]`, non-empty, unique.
- `name` may not be `doctrine`, `correctness`, `ignore`, or `approvability`: each is a path this package or Macroscope already governs.
- `.macroscope/correctness/correctness.md` is Macroscope's governing file, carrying the correctness run's prerequisites and timeouts, which a render over it would drop.
- A `name` colliding with another surface is an error; the name is the generated filename, so no separate path-collision check exists.

`globs`:

- Non-empty.
- A reversed range like `[z-a]` is made of permitted characters; `globs.check` proves each pattern compiles as its last clause, so it is a `toml-schema` finding naming the glob.
- Consecutive `**/` are collapsed to one before matching.

`exclude_globs`:

- Real subtraction only on Macroscope.
- Everywhere else it renders as prose asking a bot to disregard rules it has already loaded, so narrow `globs` where exact scoping matters.

`reviewer_only`:

- `excludeAgent: "cloud-agent"` keeps reviewer doctrine away from the working agent.

`instructions`:

- Under the heading, marker and control refusals below.
- Must be non-empty: a whitespace-only surface costs its bots a read and tells them nothing. Drop the surface instead.

## The content refusals

One row per input string and one column per refusal class.

- Every class here is one that would break the STRUCTURE of a file this package emits; a value this package merely dislikes is not refused.
- Everything that judges these, `toml-schema` and the Escaping paragraphs in `renders.md`, cites this table rather than restating it.
- The generator reads this table as data, from its running copy. It looks a row up by its input's name, so a row added here refuses that input's values with no other edit.
- `scripts/lib/refusals.py` encodes each column's predicate once, under the column's name.
- A row's refusals run in column order, and the first that matches names the refusal.
- A run that reads the table refuses a row naming no string input, a column naming no predicate, and a cell other than `yes` or a dash.
- `toml-schema` enforces every row except `doctrine block text`. Doctrine block text lives in the spec copy, not in `[bot-instructions]`, so the render-side check below enforces it.

**A repo input outside this table holds a class that admits no control character.**

- The section of this file that defines the input states its class, such as § The glob dialect for a glob key.
- Its refusals reach an operator as `toml-schema` findings like every row here.

| Input string | heading | marker | comment-close | toml-delimiter | control | single-line |
|--------------|---------|--------|---------------|----------------|---------|-------------|
| `[bot-instructions.repo] name` | – | yes | – | yes | yes | yes |
| `[bot-instructions.repo] tracker` | – | yes | – | yes | yes | yes |
| `[bot-instructions.repo] summary` | yes | yes | – | yes | yes | – |
| `[[bot-instructions.surface]] instructions` | yes | yes | – | – | yes | – |
| `[bot-instructions.doctrine.*]` values | yes | yes | – | yes | yes | – |
| doctrine block text | yes | yes | – | yes | yes | – |
| `[[bot-instructions.exclusions.path]] reason` | – | yes | yes | – | yes | yes |
| `[bot-instructions.tone] coderabbit` | – | – | – | – | yes | – |

The predicates, written once:

- **heading**: a line markdown reads as a heading, in **either** of the two forms `scripts/lib/markdown.py` states.
  - ATX is one to six `#` after three or fewer leading spaces, followed by a space, a tab, or the end of the line: `#1917` is no heading, and neither is `##` before a no-break space.
  - Setext is a run of `=` or of `-`, indented at most three spaces with only whitespace after it, **under a non-blank line**, whatever that line is.
  - The section terminators read ATX alone; this row keeps a setext underline out of every string they parse.
- **marker**: a line carrying the marker text, which decides which files this package owns.
- **comment-close**: `-->`, which would end the HTML comment a `reason` is rendered inside.
- **toml-delimiter**: `"""`, which would end the TOML multi-line string the value is rendered inside.
  - Marked on exactly the values that reach a TOML string in `.pr_agent.toml`.
  - `[[bot-instructions.surface]] instructions` reaches Qodo through `best_practices.md`, which is markdown.
- **control**: any C0 control character other than tab and newline, DEL (`U+007F`), and the three characters above that range a reader still breaks a line on: `U+0085` NEL, `U+2028` LINE SEPARATOR and `U+2029` PARAGRAPH SEPARATOR.
  - One predicate for both structured targets, TOML basic multi-line strings and YAML scalars.
  - TOML's own escapes are how one arrives, `summary = "\u0000"` parses to a literal NUL, so the class judges the decoded value.
  - `scripts/lib/refusals.py` is the one statement of the class, and `coderabbit-schema` runs that same predicate over the document it validates.
  - A `single-line` mark does not exempt a row from this mark: it refuses the line breaks and says nothing about the rest of the class.
- **single-line**: a value that reads as more than one line, a trailing break included.
  - Tab and newline stay legal in `[bot-instructions.tone] coderabbit`, whose newlines the render collapses to single spaces.

**Refusals, not escapes.**

- Every class here is refused at input.
- The render escapes only what a format requires of text already known to be legal, a backslash in a TOML basic string, and rewrites nothing else.

**Render-side second checks.** The `doctrine block text` row is enforced where that value is read, when the generator parses the `## Doctrine` section, and it carries **every** class the row marks, not the heading class alone.

- Every marked cell names a rejection clause.
- Admit its test protection under `validators.md` § Controls.
- `toml-schema` carries no list of its own: it names this table, takes every row but `doctrine block text`, and adds the class of each input outside it, per the rule above the table.

Two surfaces may match the same file.

- Macroscope stacks both, CodeRabbit may apply both `path_instructions` entries, and Copilot may load both files.
- No bot resolves a contradiction between them in TOML declaration order, so keep overlapping surfaces consistent.

Write `instructions` as claims about this repo that a competent reviewer would otherwise get wrong: a convention that looks like a bug, a suggestion that has already been made and is wrong, an invariant a test pins. A sentence that would be true of any repo is doctrine, and belongs in a doctrine block.

### `[bot-instructions.doctrine.append]` and `[bot-instructions.doctrine.replace]`

- Both tables use doctrine block IDs as keys.
- `append` adds text to a block; `replace` substitutes the whole block.
- Unknown block IDs fail validation.
- Values follow their row in § The content refusals.
- Line breaks are preserved on every destination that carries the block, per [the render contract](renders.md) § Common rules; no doctrine reaches the `AGENTS.md` region at all.
- Prefer `append`. A `replace` means this repo disagrees with doctrine, which is worth arguing at the doctrine source rather than in one repo's TOML.
- A `replace` on `trust-model` or `render-out-of-scope` also weakens what every bot is told about evidence and scope, so a repo whose gate reads bot output should treat one as the policy change it is.
- Put reviewer-only, repo-specific guidance in a `[[bot-instructions.surface]]` with `reviewer_only`, never in an override. A working agent may read `AGENTS.md`, whose directive names the pointed `code-review.md`, and that file carries every block; `excludeAgent` can hide only a `.instructions.md` file.
