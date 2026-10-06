---
name: docs-writing
description: "Load to write, rewrite, or review repository markdown or documentation HTML: README, DEVELOPMENT, architecture docs, reference docs, SKILL.md and AGENTS.md."
summary: "The writing standard, the repository layout, what each document holds, and a finished example per file type, with a blank-page rewrite workflow."
license: MIT
user-invocable: true
dependencies:
  required: [decider]
metadata:
  author: vanillagreen
  source: kendex
  repository: "https://github.com/vanillagreencom/kendex"
  bugs: "https://github.com/vanillagreencom/kendex/issues"
  version: "3.0.8"
tags: [docs]
---

# Docs Writing

A repository's markdown holds what the code cannot show: the principle behind a design, the rule an agent could break without noticing, a decision with its reason, a convention that differs from a tool default, and a pointer to the canonical code. Everything else lives in the code, its comments, the tests and git history.

This skill governs repository markdown and documentation HTML. It states one writing standard, one repository layout, what each file type holds, and the finished example an author reads before writing one.

Two exclusions hold in every file: a list a declaration file or a checker already holds is not copied into prose, and a claim that a checker enforces something names the checker.

## The standard

- Write short sentences. Put one idea in each sentence.
- Use active voice and name the actor. Say what the code does, not what is done.
- Use plain words. Basic technical terms are fine: CLI, API, repo, PR, hook, lock, glob.
- Use one term per thing, the same term every time.
- State each fact once. Point at the first statement instead of repeating it.
- Write a heading that names the subject. A heading never makes a claim.
- Write in the present tense. A rule states what holds.
- Delete sales language, quips, metaphors, and hedges.
- Delete a sentence nothing acts on.

| Instead of | Write |
|---|---|
| A value you set is never overwritten and one you deleted is never put back. | kendex does not overwrite a value you set, and does not restore a value you removed. |
| ## What you can count on | ## Features |
| Simply run the apply command and you are good to go. | Run `kendex apply`. |
| One place your whole setup finally lives, in harmony across every tool. | kendex installs packages into the directories each tool reads. |
| It is generally recommended that callers should probably check the result. | Check the result. |

## Layout

Every repository converges on this layout. A rewrite moves what it finds onto it. A repository departs from it only under a decision record that names the need and the owner who approved the departure; a rewrite keeps what that record covers and cites it.

| Path | Reader | Holds | Required |
|---|---|---|---|
| `README.md` | a person choosing or using it | the sections § `README.md` orders | yes |
| `AGENTS.md` | every agent, at session start | what the repo is, the commands, the conventions, and one "Read when" line per principle doc | yes |
| `CLAUDE.md` | Claude Code | one import line, written by kendex | yes, written by kendex |
| `DEVELOPMENT.md` | a maintainer | build, run, test and debug: only what the tooling does not show | where needed |
| `LICENSE` | a person | the licence | yes |
| `CHANGELOG.md`, `changelog.d/` | a person reading a release | release notes | released packages |
| `<dir>/AGENTS.md`, with its `<dir>/CLAUDE.md` import line | an agent working in that folder | the folder's commands, its do and never rules, and the principle doc that governs it | where a folder has its own rules |
| `docs/architecture/<name>.md` | an agent about to do the work the doc governs | one principle: the approach, why, the rules, one code example | where a principle exists |
| `docs/decisions/INDEX.md` and `D###-<slug>.md` | a reviewer or agent about to reverse a choice | decision records: the choice, why, the rejected option, when to revisit | where such choices exist |
| `docs/images/` | a reader of a README or doc | the screenshots and images those files show | when used |
| `docs/runbook.md` | an operator | step-by-step procedures for a running system | operated systems |
| `.github/instructions/*.instructions.md` | the Copilot review bot | review rules per path, written by kendex | yes, written by kendex |

Nothing else lives under `docs/`. A plan, a research report, a measurement or a handoff is tracker or `tmp/` content (§ Plans and research). Product content a repository ships to its users, such as a help site, legal pages or an adapter reference, stays and is named in that repository's `AGENTS.md`. A skill's reference docs stay in its `references/`.

### Reference rules

- The root `AGENTS.md` lists each principle doc with its trigger, one line each: "Before writing a plugin: `docs/architecture/plugins.md`".
- A nested `AGENTS.md` names the principle doc for its folder. Codex reads every `AGENTS.md` on the path to the working directory, Claude Code reads the nested `CLAUDE.md` import, and Copilot reads the nested file when it opens files there.
- The Copilot review instruction files point the review bot at the same principle docs for the matching paths; the bot-instructions skill renders them.
- Decision records are not listed in `AGENTS.md`. Review and dev workflows find them by keyword with `decisions search`, and a code comment cites a decision ID only where that code carries out the choice.
- A code comment holds a local reason or an external cause at its site, per the code-quality skill's SKILL.md § Comments and Prose, and nothing points to it.
- A README links to a doc only when a person needs it, such as "Writing a plugin".
- A doc is referenced when a "Read when" line names the task that triggers reading it. A filename in a list, a link from another doc or a mention in prose is not a route: a link proves only that the file can be found. Three files need no route and get none: a topic index, which lists other docs and is deleted because the "Read when" lines are the index; an example a tool generates, which its generator inventories; and a human page a site loads at run time, which `AGENTS.md` names as product content.

## Per file type

Each section says who reads the file, what it holds, and what it never carries. The finished example for each type is under [examples/](examples/); read it before writing one. Each example ends with a contrast drawn from a real failure and one sentence on why that failure fails the reader.

### `README.md`

Read by a person choosing or using the repository, package, skill, plugin or Pi extension. Its sections, in this order, each only where the thing needs it:

1. A brief description: what it is and who it is for.
2. A screenshot, where the thing has a screen.
3. Features: one direct line each.
4. Install: paste lines per route, no prose.
5. How it works: high level, in plain words, with no engineering terms.
6. Sub-packages, where they exist: a table, one line each.
7. Setup or customise: only the must-know settings.
8. Licence.

Another section only where the thing needs it. Never: internal vocabulary, invariants, internals, rationale, history, engineering detail, or a command listing `--help` already gives. Example: [examples/readme.md](examples/readme.md).

### `AGENTS.md`

Read by every harness at the start of every session. What the repo is in two or three sentences; the commands not discoverable from the tooling; the conventions that differ from a tool default or a language norm; one "Read when" line per principle doc and per nested `AGENTS.md`. Codex reads only the root-to-cwd chain of `AGENTS.md` files, so everything a Codex session must know is on that chain. Never: anything derivable from the code, rationale, history. Example: [examples/root-agents.md](examples/root-agents.md).

### `<dir>/AGENTS.md`

Read by an agent working in that folder. The folder's own commands and its do and never rules, with no rationale, and the principle doc behind them. Claude Code does not read it itself: kendex writes a `<dir>/CLAUDE.md` import line beside it. Folder rules live here; a cross-folder idea with its why lives in `docs/architecture/`. Examples: [examples/nested-agents-plugins.md](examples/nested-agents-plugins.md), [examples/nested-agents-components.md](examples/nested-agents-components.md).

### `CLAUDE.md`

The harness shim. kendex writes it, and its whole content is one import line.

- Never hand-write it, a `.claude/rules` file, or any other harness-specific instruction file.
- `kendex apply`, `kendex refresh` and `kendex verify` write and check it, and it is committed.

### `docs/architecture/<name>.md`

Optional. Read by an agent about to do the work the doc governs. A doc exists for one reader's task and the harmful mistake it prevents: name the work an agent does with the doc open, and what that agent breaks without it. A subsystem name alone is no reason for a file, and the rules one reader uses for one task are one doc, whatever folders they cross. No file count, size or line limit holds. It holds the approach, why, the rules as do and never lines that name the check enforcing a rule where one exists, the boundary an agent could break unknowingly, one canonical code example to copy, when to read it, the condition that reopens the approach, and what the principle does not govern. A value table, such as tokens, sizes or manifest keys, lives in code; the doc points to the file. No overview is required: the root `AGENTS.md` lists the docs with their triggers, and every retained doc has a trigger line there or in a nested `AGENTS.md`. Never: code walkthroughs, file or function inventories, test-row or fixture narration, run order, measurements, dates, upstream line numbers, task history.

The contrast, a journal paragraph against the principle it should be:

| Journal | Principle |
|---|---|
| `trash.rs::move_to_trash` is the one writer: the apply engine's `Trash` op, the project restore and a Pi package's replacement land through it, under a name that opens with the moment it was moved. Enforced by the tests `a_name_is_dated_by_the_stamp_it_opens_with` and `a_listing_reports_name_age_and_bytes_newest_first` in `trash/tests.rs`. | Removal never deletes. Every removed file goes to the trash through one writer, `trash::move_to_trash`, so a person can get it back; a second writer would be a removal nobody can undo. |

Three lines that read as rules and are not:

| Rule | Not a rule |
|---|---|
| A pointer to the enforcing check: "Never name a plugin id in the core; `scripts/check-plugin-boundary.py` refuses it." | Test-case narration: "Enforced by `test_attribution.py::two_speakers_one_microphone`, whose control removes the second speaker, and by `::no_transcript` for an empty recording." The reader learns which tests exist, not what the code must never do, and every test name goes stale at the next rename. |
| A contract: "One judge, `manifest.py::validate`, decides every manifest; a key it does not list refuses the manifest." | A field inventory: a table of every manifest key with its type, whether it is required and what it means. The judge's source and the reference doc hold it, and the table is wrong the day a key changes. |
| A high-level rule: "A release is built once; every stage deploys that one artifact and never rebuilds." | A call sequence: "`make release` runs `scripts/bundle.sh`, which writes `dist/app.tar`; `deploy staging` uploads it, restarts the service and runs `smoke.sh`; `deploy prod` repeats the steps." The reader is walked through the scripts and still does not know what a change to them must preserve. |

Examples: [examples/architecture-plugins.md](examples/architecture-plugins.md), [examples/architecture-design-system.md](examples/architecture-design-system.md).

### One home per fact

A fact has exactly one home. Ask the questions in order and stop at the first yes:

1. Is it one option kept over a named rejected alternative, whose reason the code cannot show and which a doc's rules cite rather than restate? A decision record: the choice, why, the rejected option and the revisit trigger, under the decider bar. Example: [examples/decision.md](examples/decision.md), one dismiss owner kept over per-component handling, cited by the design-system doc's rule.
2. Is it the approach one reader's task runs under, or a rule followed while doing it? An architecture doc: the approach, its why and its rules, citing any decision it rests on by ID and never restating it. Examples: [examples/architecture-plugins.md](examples/architecture-plugins.md), a surface goes in a plugin and never imports another; [examples/architecture-design-system.md](examples/architecture-design-system.md), every value a component draws comes from the token file.
3. Neither. A feature's behaviour, what a page, key or button does, lives in the code, its tests and the tracker item that asked for it. Counter-example: [examples/behaviour-spec.md](examples/behaviour-spec.md), a window written up control by control, with where each line goes.

### Decision records

Read by a reviewer or agent about to reverse a choice. The bar, the format and the workflows are the [decider](../decider/SKILL.md) skill's; this skill ships no second format. A principle doc cites a decision by ID and never restates it. Example: [examples/decision.md](examples/decision.md).

### `DEVELOPMENT.md`

Read by a maintainer, human or agent, working on the package itself. How to build, run, test and debug it, and only what the tooling does not show. Never: anything the code, the tests, `--help` or the README state, and architecture narration. A file left with nothing load-bearing is deleted. Example: [examples/development.md](examples/development.md).

### `SKILL.md`, `workflows/*.md`, `agents/*.md`

Read by an agent on every load. The shortest unambiguous rule, and the commands. A rule another file owns is cited, never restated. Never: mechanics, rationale, history, worked examples. Rationale moves to a decision record or a comment at the code. Example: [examples/skill-entry.md](examples/skill-entry.md).

### Reference docs

Read by an agent or maintainer looking up one value: `references/`, `schemas/`, `patterns/`, or a named file such as `CHECKS.md`. Tables and lists, one row per item; the value or the shape the contract fixes, its meaning, and its default; the semantics a reader needs to produce or consume that shape, and no more. Never: rationale, or narrative that defines nothing. A file under `references/` exists only where a named reader loads it: a skill, an agent, a workflow or a maintainer task that names the file. Example: [examples/reference.md](examples/reference.md).

### Documentation HTML

Read in a browser. An offline page a skill or repository ships beside its markdown, opening with no build step, under the rules of the equivalent markdown type, with local styles only and no framework or external asset. Inline SVG is available where a diagram shows a relationship more clearly than prose. Never: a page served from a web root or built by an application bundler; that is a product file.

### Human architecture page

Read by a person asking how the system works, on a help site or in another product content directory the repository ships. Its title is the reader's question, its first paragraph answers it in plain words, and one diagram shows the answer. It is product content: `AGENTS.md` names its directory as such, no "Read when" line routes an agent through it, and the rules an agent follows stay in `docs/architecture/`. Never: do and never lines, decision IDs, code paths, or a sentence written for an agent. Example: [examples/human-page.md](examples/human-page.md).

### `CHANGELOG.md` and `changelog.d/`

The `changelog-entries` lane owns the shape, and its release-version rule, the commit-guards skill's CHECKS.md § Release versions, owns the version and the fragment section. Follow the repository's `changelog.d/README.md`.

## Maintenance

- Update a doc when a change makes a claim in it false. A code change alone owes no doc change.
- A constraint without an enforcer names review, an operator step, or the gap.
- No document has a byte, line or count limit. The doc-limits check measures the files a harness loads every turn, `AGENTS.md`, `CLAUDE.md`, `GEMINI.md` and `SKILL.md`, and nothing else; shape elsewhere is held by the rules above and the owner's review of each rewrite.

## Plans and research

A plan, a research report, a measurement or a handoff is not repository content. Write it under `tmp/` and attach it to the tracker issue it serves. Research that is the evidence behind a constraint still in force is attached to that constraint's issue, verified readable, and the constraint links to it; every other research file is deleted when its work lands.

## Format

- One paragraph per line, one list item per line, no hard wraps inside either. Blank lines separate paragraphs, list blocks, headings, and fences. Tables and fenced code stay as written. The commit-guards `md-format` lane enforces it.
- Relative links in Markdown must resolve. The commit-guards skill's CHECKS.md § md-refs owns the checked forms.
- Keep history out of agent-loaded markdown so each load carries current instructions. This is writing guidance.
- A rule a shipped kendex package states is never restated in the repo's own markdown. The repo installs the package and customises through `kendex.toml`.

## Writing

A focused change edits the affected text and verifies each claim it touches against the code. Converting a document onto this convention, or restructuring it, follows [workflows/rewrite.md](workflows/rewrite.md) at the scope asked for, one file, one folder or the repository; the workflow extracts what is unique, then writes each file in scope from a blank page. The scope names the files: a `docs/` cleanup edits `AGENTS.md` only for the "Read when" lines of the docs it retains or deletes, and edits no `SKILL.md`; a rewrite of an `AGENTS.md` or `SKILL.md` body is a separate request the owner approves by naming the file. Both follow § Per file type and start from the example of the file type: [readme.md](examples/readme.md), [development.md](examples/development.md), [root-agents.md](examples/root-agents.md), [nested-agents-plugins.md](examples/nested-agents-plugins.md), [nested-agents-components.md](examples/nested-agents-components.md), [architecture-plugins.md](examples/architecture-plugins.md), [architecture-design-system.md](examples/architecture-design-system.md), [behaviour-spec.md](examples/behaviour-spec.md), [human-page.md](examples/human-page.md), [skill-entry.md](examples/skill-entry.md), [reference.md](examples/reference.md), [decision.md](examples/decision.md).
