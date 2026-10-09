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
tags: [docs]
---

<!-- kendex:project-instructions:start -->
## Project Instructions

<!-- kendex:shared-instructions:start -->
Problems with a kendex-owned skill go through `kendex report`; check ownership in the file first.
<!-- kendex:shared-instructions:end -->

After an authorized documentation rewrite changes kendex-owned inputs, use the repository refresh and verification route. Respect a launched lane's refresh restriction. Keep refresh with the existing owner: kendex uses its lock-record Actions workflow and rolling kendex/lock pull request; consumers with automatic refresh use their kendex-refresh Actions workflow and rolling kendex/refresh pull request. When no refresh workflow exists and the fleet is local, the overseer owns refresh in the base checkout. Keep the local-fleet full post-merge route. This local owner is not a hosted control VM. Confirm any other execution owner before adoption. A hosted consumer without a refresh workflow must confirm an authorized owner outside the control VM. The hosted control checkout receives committed outputs through sync-base after they merge.

Migrate this repository hand-written harness instructions only through an authorized instruction migration. Put rules used by one installed skill in that skill's named [skill-instructions] key in kendex.toml, or kendex-local.toml only for a source catalog. Put agent-specific rules in the named [agent-additional-instructions] key and command-specific rules in the named [command-instructions] key. Keep only rules every agent needs in AGENTS.md. Keep operator instructions in consumer docs. Preserve every still-required rule. Remove an empty source instruction file only after its replacement is checked.

<!-- kendex:project-instructions:end -->

# Docs Writing

A repository's internal design documentation holds what the code cannot show: the principle behind a design, the rule an agent could break without noticing, a decision with its reason, a convention that differs from a tool default, and a pointer to the canonical code. Everything else lives in the code, its comments, the tests and git history.

This skill governs repository markdown and documentation HTML. It states one writing standard, one repository layout, what each file type holds, and the finished example an author reads before writing one.

Do not hand-copy code-owned inventories or defaults. A reference may define a contract not declared elsewhere, or explain semantics beside a link to its declaration. A generated reference may show declared values. A claim that a checker enforces something names the checker.

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

This is the default repository layout. A rewrite moves what it finds onto it. A material departure needs an owner-approved decision under the decider bar. A supported naming or location variant needs no separate decision. A rewrite keeps and cites an approved departure.

| Path | Reader | Holds | Required |
|---|---|---|---|
| `README.md` | a person choosing or using it | the sections § `README.md` orders | yes |
| `AGENTS.md` | every agent, at session start | what the repo is, the commands, the conventions, and task routes to principle docs, directly or through named nested instructions | yes |
| `CLAUDE.md` | Claude Code sessions that need an import | the project's own `@AGENTS.md` import (§ `CLAUDE.md`) | only where a session needs an import |
| `DEVELOPMENT.md` | a maintainer | build, run, test and debug: only what the tooling does not show | where needed |
| `LICENSE` | a person | the licence | yes |
| `CHANGELOG.md`, `changelog.d/` | a person reading a release | release notes | released packages |
| `<dir>/AGENTS.md` | an agent working in that folder | the folder's commands, rules no linked principle doc owns, and task triggers for the principle docs that govern it | where a folder has its own rules |
| `docs/architecture/<name>.md` | an agent about to do the work the doc governs | one principle: the approach, why, the rules, one code example | where a principle exists |
| `docs/decisions/INDEX.md` and `<DECISION_ID>-<slug>.md` (names and locations follow decider) | a reviewer or agent about to reverse a choice | decision records: the choice, why, the rejected option, when to revisit | where such choices exist |
| `docs/images/` | a reader of a README or doc | the screenshots and images those files show | when used |
| `docs/runbook.md` | an operator | step-by-step procedures for a running system | operated systems |
| `.github/copilot-instructions.md` | Copilot features that support repository instructions, including code review | repository instructions and the review pointer; bot-instructions owns the render | yes, written by kendex |
| `.github/instructions/*.instructions.md` | Copilot features that support matching path instructions | path rules; bot-instructions owns the render and cloud-agent exclusion | yes, written by kendex |
| `.github/instructions/code-review.md` | review agents following the generated pointer | shared review doctrine; bot-instructions owns the render, not a native Copilot instruction file | yes, written by kendex |

Nothing else lives under `docs/`. A plan, a research report, a measurement or a handoff is tracker or `tmp/` content (§ Plans and research). Product content a repository ships to its users, such as a help site, legal pages or an adapter reference, stays and is named in that repository's `AGENTS.md`. A skill's reference docs stay in its `references/`.

### Reference rules

- The root `AGENTS.md` gives each principle doc a task trigger, or routes to a nested `AGENTS.md` that gives the local trigger: "Before writing a plugin: `docs/architecture/plugins.md`".
- A nested `AGENTS.md` names the principle doc for its folder. Codex reads every `AGENTS.md` on the path to the working directory. Claude Code loads nested instructions under § `CLAUDE.md`. Copilot reads the nested file when it opens files there.
- The Copilot review instruction files point the review bot at the same principle docs for the matching paths; the bot-instructions skill renders them.
- Decision records are not listed in `AGENTS.md`. Review and dev workflows find them by keyword with `decisions search`, and a code comment cites a decision ID only where that code carries out the choice.
- A code comment holds a local reason or an external cause at its site, per the code-quality skill's SKILL.md § Comments and Prose, and nothing points to it.
- A README links to a doc only when a person needs it, such as "Writing a plugin".
- An architecture topic document is referenced when a "Read when" line names the task that triggers reading it. A filename in a list, a link from another doc or a mention in prose is not a task route. Delete an architecture topic index that only repeats these routes. This rule does not replace decision discovery, skill reference loading or human navigation. Keep the decider index. Generated examples use their generator inventory; human pages a site loads use the product-content declaration in `AGENTS.md`.

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

Read by every harness at the start of every session. What the repo is in two or three sentences; the commands not discoverable from the tooling; the conventions that differ from a tool default or a language norm; task triggers for principle docs, directly or through named nested `AGENTS.md` files. Keep only rules no linked principle doc owns; route to that doc instead of repeating its rules. Codex reads only the root-to-cwd chain of `AGENTS.md` files. Before changing a directory, read its applicable nested instructions even when the harness did not load them. Never: anything derivable from the code, rationale, history. Example: [examples/root-agents.md](examples/root-agents.md).

### `<dir>/AGENTS.md`

Read by an agent working in that folder. Keep the folder's commands and rules no linked principle doc owns, with no rationale. Give a task trigger for that doc instead of repeating its rules. An approach belongs in architecture when one reader's task needs it to prevent a harmful mistake, whatever folders the task crosses. Claude Code's native loading and personal-import fallback follow § `CLAUDE.md`. Examples: [examples/nested-agents-plugins.md](examples/nested-agents-plugins.md), [examples/nested-agents-components.md](examples/nested-agents-components.md).

### `CLAUDE.md`

[Claude Code reads `AGENTS.md` natively](https://code.claude.com/docs/en/memory#agents-md) from [v2.1.277](https://github.com/anthropics/claude-code/blob/main/CHANGELOG.md#21277). Bedrock and telemetry-off sessions need v2.1.281. By default, a `CLAUDE.md`, `.claude/CLAUDE.md` or `CLAUDE.local.md` in the working directory or above prevents native loading. A nested `AGENTS.md` loads when Claude reads a file there, unless that directory has one of those Claude files. Files under `.agents/` do not load.

kendex writes no `CLAUDE.md`. An existing root or nested `CLAUDE.md` with an `@AGENTS.md` import belongs to the project. kendex leaves it in place and does not check it. A person who needs an older session, a disabled native plugin or Project instructions set to `claude-md` keeps their own `CLAUDE.md` with that import.

### `docs/architecture/<name>.md`

Optional. Read by an agent about to do the work the doc governs. A doc exists for one reader's task and the harmful mistake it prevents: name the work an agent does with the doc open, and what that agent breaks without it. A subsystem name alone is no reason for a file, and the rules one reader uses for one task are one doc, whatever folders they cross. No file count, size or line limit holds. It holds the approach, why, the rules as do and never lines that name the check enforcing a rule where one exists, the boundary an agent could break unknowingly, one canonical code example to copy, when to read it, the condition that reopens the approach, and what the principle does not govern. A value table, such as tokens, sizes or manifest keys, lives in code; the doc points to the file. No overview is required: the root `AGENTS.md` gives task triggers or routes to named nested instructions, and every retained doc has a trigger line at the root or in those nested instructions. Never: code walkthroughs, file or function inventories, test-row or fixture narration, run order, measurements, dates, upstream line numbers, task history.

The contrast, a journal paragraph against the principle it should be:

| Journal | Principle |
|---|---|
| `trash.rs::move_to_trash` is the one writer: the apply engine's `Trash` op, the project restore and a Pi package's replacement land through it, under a name that opens with the moment it was moved. Enforced by the tests `a_name_is_dated_by_the_stamp_it_opens_with` and `a_listing_reports_name_age_and_bytes_newest_first` in `trash/tests.rs`. | Removal never deletes. Every removed file goes to the trash through one writer, `trash::move_to_trash`, so a person can get it back; a second writer would be a removal nobody can undo. |

Three lines that read as rules and are not:

| Rule | Not a rule |
|---|---|
| A pointer to the enforcing check: "Never name a plugin id in the core; `scripts/check-plugin-boundary.py` refuses it." | Test-case narration: "Enforced by `test_attribution.py::two_speakers_one_microphone`, whose control removes the second speaker, and by `::no_transcript` for an empty recording." The reader learns which tests exist, not what the code must never do, and every test name goes stale at the next rename. |
| A contract: "One judge, `manifest.py::validate`, decides every manifest; a key it does not list refuses the manifest." | A field inventory: a table of every manifest key with its type, whether it is required and what it means. The judge's declaration owns the shape and defaults; the reference links to it and explains semantics. A hand-copied table is wrong the day a key changes. |
| A high-level rule: "A release is built once; every stage deploys that one artifact and never rebuilds." | A call sequence: "`make release` runs `scripts/bundle.sh`, which writes `dist/app.tar`; `deploy staging` uploads it, restarts the service and runs `smoke.sh`; `deploy prod` repeats the steps." The reader is walked through the scripts and still does not know what a change to them must preserve. |

Examples: [examples/architecture-plugins.md](examples/architecture-plugins.md), [examples/architecture-design-system.md](examples/architecture-design-system.md).

### One home per fact

For an internal design claim, ask the questions below in order and stop at the first yes. First classify user help, operating steps, skill procedures and reference contracts by their file-type section.

1. Is it one option kept over a named rejected alternative, whose reason the code cannot show and whose reasons and alternatives a doc's rules cite rather than repeat? A decision record: the choice, why, the rejected option and the revisit trigger, under the decider bar. Example: [examples/decision.md](examples/decision.md), one dismiss owner kept over per-component handling, cited by the design-system doc's rule.
2. Is it the approach one reader's task runs under, or a rule followed while doing it? An architecture doc: the approach, its why and its rules, stating the current actionable rule and citing any decision it rests on by ID without repeating its reasons or alternatives. Examples: [examples/architecture-plugins.md](examples/architecture-plugins.md), a surface goes in a plugin and never imports another; [examples/architecture-design-system.md](examples/architecture-design-system.md), every value a component draws comes from the token file.
3. Neither. A feature's behaviour, what a page, key or button does, lives in the code, its tests and the tracker item that asked for it. Counter-example: [examples/behaviour-spec.md](examples/behaviour-spec.md), a window written up control by control, with where each line goes.

### Decision records

Read by a reviewer or agent about to reverse a choice. The bar, the format and the workflows are the [decider](../decider/SKILL.md) skill's; this skill ships no second format. A principle doc states the current actionable rule and cites the decision ID. It does not repeat the decision's reasons or alternatives. Example: [examples/decision.md](examples/decision.md).

### `DEVELOPMENT.md`

Read by a maintainer, human or agent, working on the package itself. How to build, run, test and debug it, and only what the tooling does not show. Never: anything the code, the tests, `--help` or the README state, and architecture narration. A file left with nothing load-bearing is deleted. Example: [examples/development.md](examples/development.md).

### `SKILL.md`, `workflows/*.md`, `agents/*.md`

Read by an agent when the task loads the file. `SKILL.md` gives activation, essential rules and reading routes. Workflows hold executable task steps. Agent files hold the role's rules. References hold detailed contracts and conditional instructions for a named task. Worked examples live in named supporting files. Give each supporting file an explicit reading trigger. Cite a rule another file owns. Never: implementation narration, rationale or history. Rationale belongs in an admitted principle doc, a decision under decider's bar or a comment at the code. Example: [examples/skill-entry.md](examples/skill-entry.md).

### Reference docs

Read by an agent or maintainer looking up a contract or task detail: `references/`, `schemas/`, `patterns/`, or a named file such as `CHECKS.md`. Use tables, lists, schemas and necessary examples. A reference owns a contract not declared elsewhere, or explains its meaning beside a link to the declaration that owns the machine shape and defaults. A generated reference may show those declared values. Include only the semantics and conditional instructions its named task needs. Never: rationale, or narrative that defines nothing. A file under `references/` exists only where a named reader loads it: a skill, an agent, a workflow or a maintainer task that names the file. Example: [examples/reference.md](examples/reference.md).

### Documentation HTML

Read in a browser. An offline page a skill or repository ships beside its markdown, opening with no build step, under the rules of the equivalent markdown type, with local styles only and no framework or external asset. Inline SVG is available where a diagram shows a relationship more clearly than prose. Never: a page served from a web root or built by an application bundler; that is a product file.

### Human architecture page

Read by a person asking how the system works, on a help site or in another product content directory the repository ships. Its title is the reader's question, its first paragraph answers it in plain words, and one diagram shows the answer. It is product content: `AGENTS.md` names its directory as such, no "Read when" line routes an agent through it, and the rules an agent follows stay in `docs/architecture/`. Never: do and never lines, decision IDs, code paths, or a sentence written for an agent. Example: [examples/human-page.md](examples/human-page.md).

### `CHANGELOG.md` and `changelog.d/`

The `changelog-entries` lane owns the shape, and its release-version rule, the commit-guards skill's CHECKS.md § Release versions, owns the version and the fragment section. Follow the repository's `changelog.d/README.md`.

## Maintenance

- Update a doc when a change makes a claim in it false. A code change alone owes no doc change.
- A constraint without an enforcer names review, an operator step, or the gap.
- This writing standard sets no fixed document-size limit. Harness limits still apply to loaded instructions, including imports. For example, [Codex limits combined project instructions](https://developers.openai.com/codex/guides/agents-md) to 32 KiB by default. The doc-limits check measures instruction files, `AGENTS.md`, `CLAUDE.md`, `GEMINI.md` and `SKILL.md`, and nothing else; shape elsewhere is held by the rules above and the owner's review of each rewrite.

## Plans and research

A plan, a research report, a measurement or a handoff is not repository content. Write it under `tmp/` and attach it to the tracker issue it serves. Research that is the evidence behind a constraint still in force is attached to that constraint's issue, verified readable, and the constraint links to it; every other research file is deleted when its work lands.

## Format

- One paragraph per line, one list item per line, no hard wraps inside either. Blank lines separate paragraphs, list blocks, headings, and fences. Tables and fenced code stay as written. The commit-guards `md-format` lane enforces it.
- Relative links in Markdown must resolve. The commit-guards skill's CHECKS.md § md-refs owns the checked forms.
- Keep history out of agent-loaded markdown so each load carries current instructions. This is writing guidance.
- A rule a shipped kendex package states is never restated in the repo's own markdown. The repo installs the package and customises through `kendex.toml`.

## Writing

A focused change edits the affected text and verifies each claim it touches against the code. Converting a document onto this convention, or restructuring it, follows [workflows/rewrite.md](workflows/rewrite.md) at the scope asked for, one file, one folder or the repository; the workflow extracts what is unique, then writes each file in scope from a blank page. The scope names the files: a `docs/` cleanup edits `AGENTS.md` only for the "Read when" lines of the docs it retains or deletes, and edits no `SKILL.md`; a rewrite of an `AGENTS.md` or `SKILL.md` body is a separate request the owner approves by naming the file. Both follow § Per file type and start from the example of the file type: [readme.md](examples/readme.md), [development.md](examples/development.md), [root-agents.md](examples/root-agents.md), [nested-agents-plugins.md](examples/nested-agents-plugins.md), [nested-agents-components.md](examples/nested-agents-components.md), [architecture-plugins.md](examples/architecture-plugins.md), [architecture-design-system.md](examples/architecture-design-system.md), [behaviour-spec.md](examples/behaviour-spec.md), [human-page.md](examples/human-page.md), [skill-entry.md](examples/skill-entry.md), [reference.md](examples/reference.md), [decision.md](examples/decision.md).
