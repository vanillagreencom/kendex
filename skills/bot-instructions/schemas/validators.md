# Validators

Every bot in this set fails silently: a rejected config, a mistyped enum or a stale exclusion list still leaves the review running and posting, with nothing said about the configuration it discarded.

- Each validator below names the silent failure it catches, then what it rejects.
- A failure fails the run; none of them warns.
- § Where these run says which tree each one reads and which verb runs it.
- Remote-file validation below applies to full mode.
- Local mode judges the `AGENTS.md` region only, as `renders.md` § Local output defines.

**No validator parses a render back.**

- The structure is in hand before it is serialised, so a validator that judges a document reads that structure.
- What is left to judge on bytes is size.
- A validator whose input is the REPO's own files is a different thing: `orphan`, `drift` and `agents-section` are it.

## Controls

Admit validator tests and must-fail controls under code-quality § Tests. Apply code-quality § Prove Your Guards to control mechanics.

- Assert the validator's own structured identity. All validators run together, so the run's exit code alone can pass for the wrong rejection.
- Keep valid-render evidence where it protects against a validator that rejects everything.
- A bound test must reach the named bound. A fixture stopped by a prior guard proves no protection at that bound.
- A repo-state validator uses repo fixtures.

## The glob dialect's vectors

The dialect claims a set of patterns five targets read alike.

- **One** of the five can be asked from a repo carrying no third-party runtime: git's own wildmatch, the engine `git sparse-checkout` uses and the one CodeRabbit feeds `path_filters` to.
- minimatch needs a Node runtime this package does not depend on.
- Copilot's `applyTo`, Qodo's `[ignore]` and Macroscope's `include` matchers are unpublished.
- So the vectors cover git, and the other four are a one-time confirmation in `references/checklist.md`.
- The vectors compare this package's own matcher, the one `exclusion-consistency`'s dead-exclusion clause decides with, against git's.
- A disagreement means a dead-exclusion verdict is wrong.

The harness's control feeds a pattern the dialect **refuses** through the vector harness with the dialect check bypassed, and asserts the harness reports the disagreement.

- An empty component is the sharpest: git normalizes `a//f` to `a/f` and selects a file where this package's matcher selects nothing.
- A leading `/` and a `..` component make git refuse the pathspec outright rather than answer.

## Cross-file sets

**Every set of ids or predicates that appears in more than one file is derived from one named source.** Neither "compare them by reading" nor "keep them in sync" counts.

- A set still kept by hand in two files is held by a validator that reds when the copies diverge.
- That validator is a stopgap under code-quality § Over-Engineering, not an answer: its row names the item that derives one copy from the other.

**"Derived" covers two different things, and a row says which.**

- *Derived, read at run time* means the generator parses the source and the set arrives as data. Four sources are read that way:
  - the doctrine source and the routing table, from the spec copy SKILL.md § The render inputs names;
  - the content-refusal table and the verb table in `repo-toml.md`, from the running copy, because they decide what the code accepts and `kendex verify` runs a trusted copy with `--spec` naming the copy inside the tree it judges.
- *Derived, one statement* means one constant in the implementation holds the set and every reader reads that constant.
- A file carrying **text a render emits** is data.
- A spec table that states a set the implementation also encodes is a second hand-kept copy, not a derivation.

Its sites, and which answer each takes:

| Set | Answer |
|-----|--------|
| Doctrine block ids | Derived, read at run time |
| Which block reaches which destination, and in what order | Derived, read at run time |
| Content refusals | Derived, read at run time |
| The Qodo verbs `[bot-instructions.cadence] qodo_commands` accepts | Derived, read at run time |
| The marker line | Derived, one statement |
| The routing table's own shape | `doctrine-routing` |
| Validator test protection | § Controls |

- **Doctrine block ids**: the doctrine source's `###` headings are the one statement.
  - The routing table's rows, `[bot-instructions.doctrine.append]` and `[bot-instructions.doctrine.replace]` each name ids from it, and a name it does not define is refused where it is read.
  - The render addresses two blocks by id, `render-out-of-scope` and `reply-contract`, so a doctrine source without either is refused.
- **Which block reaches which destination**: the routing table in `renders.md` is the single source; per-surface sections cite it and state no order of their own. Every block has a row there, which `doctrine-routing` holds.
- **Content refusals**: which input string is under which refusal, and what each refusal's predicate is.
  - The table in `repo-toml.md` § The content refusals is the single source of which input is under which refusal; `toml-schema` and the Escaping paragraphs cite it.
  - `refusals.py` encodes each predicate once, under the name the table's column spells, and holds no row.
- **The Qodo verbs**, and which half `qodo-parity` requires guidance for: the verb table in `repo-toml.md` § `[bot-instructions.cadence]` states the set and the split, and both `toml-schema` and `qodo-parity` read it.
- **The marker line**: its exact form, the prologue that may precede it, and the one field it varies by.
  - One function emits the marker and one answers ownership against its opener, which both read from one constant, so the writer and the reader cannot spell it differently and a marker an earlier copy wrote still reads as owned.
  - One function splits the prologue, and both the ownership test and the marker's insertion read it.
  - The path class is one constant, which `spec.py` refuses outside of.
- **The routing table's own shape**: a row for every doctrine block, positions contiguous per column, no duplicates, and every row in the three all-block columns. `doctrine-routing` judges the table's rows.
- **Validator test protection**: judge the evidence against the named rejection and its cost under § Controls; no control count defines admission.

**A block id rename is a breaking change, refused where it would reach nothing.**

- A consuming repo's `[bot-instructions.doctrine.append]` or `[bot-instructions.doctrine.replace]` keyed on the old id is a `toml-schema` finding on its next render, never an override that silently reaches nothing.
- Renaming `render-out-of-scope` or `reply-contract` is refused in the spec copy itself, since the render addresses both.

**What no validator can do.**

- Each one judges bytes this generator produced.
- None observes a bot's actual behavior.
- Guarantees that live outside any file, such as a Copilot content-exclusion path, an organization CodeRabbit override or a portal toggle, are `references/checklist.md`'s.

## `toml-schema`

**Silent failure.** A misspelled key that the reader ignores leaves the default in force, and the render is plausible, complete, and wrong.

**Rejects, the shape set.**

- Any key or table the schema does not define.
- Any value of the wrong type.
- An empty glob list.
- A surface name that is empty, malformed, duplicated or reserved.
- An unknown doctrine block id in `[bot-instructions.doctrine.append]` or `[bot-instructions.doctrine.replace]`.
- An exclusion glob that appears twice in the resolved set.
- A `schema` value other than `1`.

**Rejects, an absent required key.**

- The clause derives from the Required column of `repo-toml.md` § Keys rather than restating which fields are required.
- It covers any key that column marks, plus any `repo-toml.md` states in prose rather than in a table row, as it does `schema`.
- Absent is a different state from empty, which the empty-value clauses cover.

**Rejects, the content set.**

- The clauses are the cells of `repo-toml.md` § The content refusals **whose row this file supplies**: every marked cell on such a row names a rejection clause, and the predicates are that table's.
- The `doctrine block text` row is not this validator's: its enforcer is the render-side check `repo-toml.md` § Render-side second checks names.
- A glob outside `repo-toml.md` § The glob dialect, and each of its path shapes: an empty glob, a leading or trailing `/`, a `..` component, and an empty component, each a rejection clause.
- A `qodo_commands` entry outside the verb table in `repo-toml.md` § `[bot-instructions.cadence]`, or one carrying whitespace or `--`.

**`[bot-instructions.repo] code_review_path` is outside that table.**

- Its clauses are shapes rather than content refusals: the marker path class, a `.md` suffix, no empty, `.` or `..` component, the `CODE_REVIEW_TREE` parent, no `AGENTS.md` basename in any case, and no upper-case basename.
- `config._code_review_path` encodes them, and `repo-toml.md` § `[bot-instructions.repo]` states them under the key.
- Judge needed test protection under § Controls rather than a second list of rejection clauses.

**Rejects, the cross-flag set.**

- The three flag combinations `repo-toml.md` § `[bot-instructions.bots]` lists, each a flag whose output reaches nothing.
- **Every flag false is a legitimate state and passes**, and `render` reports the no-op.

## `doctrine-routing`

**Silent failure.**

- The routing table is the generator's single routing input, so a one-character edit to a position is a silent policy change that renders clean.
- In the CI lane this package prescribes, the spec copy comes from the tree under judgment while the code runs from the trusted default-branch checkout, so a pull request changing the routing changes it in the same copy.
- `--spec` names both the doctrine source and the routing table from one copy.

**Rejects, the table's own shape.** Nothing else judges the table:

- A doctrine block with no row. A row the reader skips, such as one missing its closing pipe, leaves its block with none, so the malformed row is this finding.
- A position repeated inside a column.
- A gap in a column's positions, which must run `1..n`.
- A row leaving out the `code-review.md`, `pr_agent extra` or `macroscope doctrine.md` column. Those columns carry every block.

Which blocks exist is the doctrine source's alone, so this validator holds the table to the doctrine source's headings with no second list of ids, and a row naming no block is refused where the table is read.

A byte validator: both inputs belong to the render, from the one copy `--spec` names. Judge the validator's test protection under § Controls.

## `coderabbit-schema`

**Silent failure.**

- CodeRabbit discards an invalid `.coderabbit.yaml` whole and reviews with resolved defaults, saying nothing on the pull request (`references/limits.md` § CodeRabbit).
- One over-long `tone_instructions` does this, and so does a single misspelled top-level key under the root's `additionalProperties: false`.

**Rejects.** Any deviation of the rendered document from CodeRabbit's published schema, validated against the copy vendored at `.bot-instructions/coderabbit-schema.json` rather than fetched at check time:

- An unknown top-level key.
- A wrong type.
- An enum miss (`reviews.profile` is `quiet`, `chill` or `assertive`).
- Every documented length cap, of which `tone_instructions` at 250 and `reviews.path_instructions[].instructions` at 20,000 are the two this package can reach. Lengths count Unicode code points, which is what the schema's `maxLength` counts.

**Rejects, the completeness clause.** A property the vendored schema defines a default for, at **any depth**, that the render does not carry.

- What is in the clause is what `renders.md` § `.coderabbit.yaml` § Keys puts in full state, read through the same `in_full_state` predicate the render reads.
- So a property the vendor defines **no default for** is outside the clause until this package overrides it.

**Rejects, the keyword clause.** A schema keyword the validator does not implement, named in the finding.

- A vendored-schema refresh can therefore block renders until the validator catches up.
- `references/checklist.md` § CodeRabbit has the repo record the copy's provenance and how to refresh it.

**Rejects, the unresolved-override clause.** An override this package chooses that the vendored copy defines no property for, which would otherwise be dropped and resolve to the vendor default.

- This clause runs before the ones above, which read the rendered document.

**Rejects, also.** A missing, unreadable or unparseable `.bot-instructions/coderabbit-schema.json`, whenever `[bot-instructions.bots] coderabbit` is true, on both verbs.

- Never a skipped validator: no verb writes that file, so a validator that skipped on its absence would be silent for the life of a repo that never vendored it.

**Rejects, the control-class clause.** A string in the rendered document carrying a character a YAML reader breaks a line on: C0 less tab and newline, DEL, U+0085, U+2028, U+2029.

- This covers the arrival route that `repo-toml.md` § The content refusals, which holds every repo input to its table or to a class that admits no control character, does not: a value from a vendored-schema default or from this package's own overrides.
- The refusal is this validator's finding rather than a raise out of the emitter.

## `exclusion-consistency`

**Silent failure.** A harness refresh renders a new skill into the repo, the exclusion lists still name only the old skills, and the new tree is reviewed as if it were this repo's code.

**Rejects, the dead-exclusion clause.** A declared exclusion glob matching no tracked path, such as a typo or a wrong anchor.

- A glob matching no tracked path is dead wherever it sits, symlink entries included: a pull request editing the tree behind a link carries that tree's real path in its diff.
- In a repo tracking no files, the clause reports that its verdict is unreachable rather than reporting each exclusion as dead.
- A repo declaring no exclusion has nothing that can be dead.

**Rejects, also.** A declared render root the index holds as an entry of its own, a harness root staged as a symlink or as a file, naming the root.

- The derived set is `repo-toml.md` § `[bot-instructions.exclusions]`'s.
- The rendered exclusion lists are not compared against each other, nor against a fresh derivation.
- On `check`, a destination whose bytes disagree with a fresh render is `drift`'s finding.

**Rejects, also.** A resolved manifest that declares no install, and an absent or unreadable `.kendex-generated.json`.

- Emptiness is the finding, since reading the wrong file and a repo with nothing to exclude both come back empty.
- One of this validator's controls is a source-catalog repo, where `kendex.toml` carries the published catalog and `kendex-local.toml` carries the install.

**Rejects, also.** A non-empty exclusion set that a destination the routing table marks as carrying the paths does not carry: `code-review.md`, `pr_agent issues`, `pr_agent extra`.

- Each is read as the value the bot reads, the rendered pointed file, `[review_agent] issues_user_guidelines` and `[pr_reviewer] extra_instructions`.
- Never as the whole rendered file, since `.pr_agent.toml` also lists every exclusion under `[ignore] glob`.
- This clause holds SKILL.md § Every rendered config excludes the render trees.
- Each destination's `Those paths here:` sentence is parsed into its entries and compared as a SET, so the clause also rejects a destination listing a path the TOML does not exclude.

**What it does not establish.** That the bots exclude the same files. This validator compares the strings the generator emitted.

## `copilot-budget`

**Silent failure.** GitHub asks for "no longer than 2 pages" and documents no numeric cap, so an over-long file has no error to produce.

**Rejects.** A rendered `.github/copilot-instructions.md` over `[bot-instructions.budgets] copilot_chars`, naming the count, the budget, and the sections by size so the author can see what to cut.

## `qodo-parity`

**Silent failure.**

- `/review` reads `[pr_reviewer] extra_instructions`.
- `/agentic_review` reads `[review_agent]`.
- Guidance written into one section is absent from the other command's path, and the review runs with less context while the file looks configured.

**Rejects.** A `[github_app] pr_commands` entry **whose role in `repo-toml.md` § `[bot-instructions.cadence]`'s verb table is review** and whose section carries no guidance.

- A non-review verb is not a finding.
- Which section that is comes from the routing table: `/review` reads `[pr_reviewer] extra_instructions`, `/agentic_review` the union of the two `[review_agent]` keys.
- The guidance is read as the value the render composed for each key, before it was written into TOML.
- The routing table, read as data, says which block reaches which key.

## `qodo-best-practices`

**Silent failure.** Qodo processes long best-practices files less effectively and states no length at which it rejects or truncates one, so there is no error to wait for.

**Rejects.** A rendered `best_practices.md` over `[bot-instructions.budgets] qodo_best_practices_lines`, default 800, naming the count, the budget, and the surfaces contributing the most lines so the author can see what to cut.

- That 800 is this package's budget, not a vendor cap, and the failure message says so.
- Never tell an author Qodo refused their file.

## `agents-section`

**Silent failure.**

- `AGENTS.md` § Code Review Rules holds the directive naming the pointed file.
- Rename the heading, move the section, or delete the file, and Codex reviews every pull request with no repo rules at all, posting normally throughout.

**Rejects, always.** A nested `AGENTS.md` anywhere below the root carrying a `## Code Review Rules` section.

- Codex reads the nearest nested file covering each changed path, so such a section reaches it without passing through doctrine.
- The scan is over the repository's tracked paths, which is what a bot reads.

**Rejects, when `[bot-instructions.bots] codex` is true.** A root `AGENTS.md` with no `## Code Review Rules` heading, or with more than one.

- With the flag off there is no managed region to judge.

**The heading predicate over the region's content is not a clause here.** No doctrine or repo string reaches the region, so the clause would be unreachable.

**The region's length is not a clause here either.**

- On `check`, `drift` reds a region longer than the directive line.
- `adopt` runs no validator, so its own clause, `verbs._region_finding`, reports a longer region under `agents-region`.

**The region's bytes are `drift`'s, not this validator's.**

- Every clause here is structural, so all of them run before the write, which makes the write-phase splice failure unreachable.
- A byte comparison before the write would fire on every doctrine, TOML or tracker change and leave the region unable to be updated.

## `orphan`

**Silent failure.**

- A `[[bot-instructions.surface]]` is removed from the TOML, or a bot capability is switched off.
- Until a render runs, the file it wrote is still there and the bot still loads it.

**Rejects.** Anything carrying this package's marker that the current TOML does not produce. That covers:

- A retired surface's `.instructions.md` and `correctness/*.md`.
- The root-level files of a bot whose flag went false (`.coderabbit.yaml`, `.pr_agent.toml`, `best_practices.md`, `REVIEW.md`, `.github/copilot-instructions.md`, the `.macroscope/` tree).
- The pointed `code-review.md` at whatever path `[bot-instructions.repo] code_review_path` names.
- Each `## Code Review Rules` section of `AGENTS.md` that opens with the marker, however many such headings there are, when `[bot-instructions.bots] codex` goes false.

**The scan is recursive, over what each bot reads rather than what the generator writes.**

- It walks `.github/instructions/`, `.macroscope/correctness/` and `.macroscope/check-run-agents/` whole.
- It reads `.macroscope/approvability.md`.
- Copilot and Macroscope read all four, though the generator writes neither of the last two.

**Unmarked files are not judged here, whatever the flags say.**

- A file at one of these paths that this package never wrote is the repo's own.
- Taking one over is `adopt`'s job and needs the capability on.

**Retiring one is a render.**

- With the `[bot-instructions]` table in place, `render` removes every marked file this rule names after its writes and the region splice succeed.
- It rereads the marker at the moment of removal, so a write that fails leaves each orphan for the next render.
- It prints `removed PATH` for each, and `would remove PATH` under `--dry-run` and `--discover`.
- A package version that retires a default surface therefore needs no hand step in any repo that renders.
- `check` reports the files, because it writes nothing.

**A manifest with no `[bot-instructions]` table** produces nothing.

- On `render`, `check` and `adopt`, each marked file the judged tree holds at a path this rule scans is an `orphan` finding.
- Each marked `## Code Review Rules` section of `AGENTS.md` is also an `orphan` finding, however many such headings there are.
- No render removes these outputs without the table.
- If the scan finds none, `render` and `check` exit 0 and write nothing. This includes `render --dry-run`, `render --discover` and `check --staged`.
- Plain output starts with `bot-instructions: unconfigured=MANIFEST` and `bot-instructions: renders=none`. The second line attests that the orphan scan ran and found nothing.
- `check --json` instead writes only `{"version":1,"paths":[]}` to stdout, the empty owned-file report the trusted verifier parses.
- `adopt` still exits 2 with the same record and attestation on stderr: no configured set exists to take over.
- The commit-guards pre-commit lane also accepts an older check's refusal only when it carries that attestation. A copy older than the scan omits it.
- `retire` and `region-bounds` read no manifest, so they report neither.
- This list owns the unconfigured contract.

**De-orphaning the `AGENTS.md` region** is not a deletion of the file.

- The heading is the repo's and has to survive.
- What goes is the marker and the body below it, leaving the section for the repo to fill or leave empty.
- `render` removes no region, so until that happens it fails on this one.

## `drift`

**Silent failure.** A hand edit to a generated file survives until the next render, then vanishes.

**Rejects.** Any path the current TOML produces whose bytes differ from a fresh render, naming the path and the differing region.

- A path that fails to read is a finding naming the path and the failure.
- A `check` finding never quotes a region out of a file that failed to read.
- `AGENTS.md` is the one path compared over a region rather than whole, and this validator is that comparison's only owner.
- `agents-section` judges that region's structure and cites this rule for its bytes, so a region fixture reds exactly one validator.

**Marker-agnostic, unlike every other rule here.**

- A deleted marker is its own byte difference, which reds.
- A marker-gated `drift` would let a one-line deletion drop a file out of `drift`, `orphan` and `render` at once.

A repo that has not run `adopt` reds on every hand-written file at a path its TOML produces.

- `adopt` keeps the file's bytes and adds the marker, so the finding stands until the `render` after it, which clears it.
- The seam with `orphan` is the TOML: `drift` judges paths the TOML produces now, `orphan` judges marked files it does not.
- A file at a path the TOML does not produce and that this package never wrote is neither.

**Which tree.**

- `check` reads the working tree by default.
- Under `--staged` it reads the index for **every render input**, not only the outputs: every path in SKILL.md § The render inputs.
- A file absent from the index is that absence, not its worktree copy.

## Where these run

**Byte validators** judge one render, its inputs and the document it produced, so they read the scratch tree, on both verbs: `toml-schema`, `coderabbit-schema`, `copilot-budget`, `qodo-parity`, `qodo-best-practices`, `doctrine-routing`, and `exclusion-consistency`'s prose-destination clause.

**Repo-state validators** judge the repository, so they read the repo.

- A scratch tree holds only what the TOML produces.
- `AGENTS.md` is the one output the build never assembles whole.

| Validator or clause | `render` | `check` |
|---------------------|----------|---------|
| `orphan`, the region clause | the repo, before the write | the repo |
| `orphan`, the file clause | skipped | the repo |
| `agents-section`, every clause | the repo, before the write | the repo |
| `drift`, the `AGENTS.md` owned region included | skipped | the repo |
| `exclusion-consistency`, dead-exclusion clause | the repo, before the write | the repo |

- A skipped row is named as skipped.
- On `render`, `orphan`'s files are removed after the write.
- These rows hold while the manifest declares a `[bot-instructions]` table. With none, no validator runs: § `orphan` says what `render`, `check` and `adopt` report instead, and `render` writes and removes nothing.
- `orphan`'s region clause runs before the write because that render is what creates the orphan: it refuses on a marked region before it writes and removes the files after.
- `agents-section` runs before the write so the write-phase splice cannot fail after other outputs were replaced.
- A skipped row is a check with no question to answer at render time, and the run says so rather than counting it as passed.
- `drift` has force in `check`, against a committed tree that has moved on since someone last rendered; at render time it would red on the render's own purpose.
