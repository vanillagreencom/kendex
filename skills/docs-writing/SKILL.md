---
name: docs-writing
description: "Load when creating or editing any Markdown file or documentation HTML, such as README, DEVELOPMENT, architecture docs, reference docs, SKILL.md and AGENTS.md, and when rewriting or reviewing one."
summary: "The writing standard, the repository layout, what each document holds, and a finished example per file type, with a rewrite workflow that keeps only what each file's readers need."
license: MIT
user-invocable: true
dependencies:
  required: [decider]
  hooks: [docs-writing-note]
metadata:
  author: vanillagreen
  source: kendex
  repository: "https://github.com/vanillagreencom/kendex"
  bugs: "https://github.com/vanillagreencom/kendex/issues"
tags: [docs]
---

# Docs Writing

A repository's internal design documentation holds what the code cannot show: the principle behind a design, the rule an agent could break without noticing, a decision with its reason, a convention that differs from a tool default, and a pointer to the canonical code. Everything else lives in the code, its comments, the tests and git history.

This skill governs repository markdown and documentation HTML. Policy and operating documents also follow § Writing.

Do not hand-copy code-owned inventories or defaults.

## The standard

- Write short sentences. Put one idea in each sentence. A condition and its exception are one idea, and so are a field and its grammar.
- Give each instruction of a step its own sentence or list item, in the order the reader follows them.
- A table cell holds one fact. A rule with conditions moves out of its cell into a list under the table.
- State a condition in full: "If the read fails, stop", not "Read fails: stop".
- Use active voice. Name the actor. Say what the code does, not what is done.
- Use plain words. Basic technical terms are fine: CLI, API, repo, PR, hook, lock, glob.
- Use one term per thing, the same term every time.
- State each fact once. In a reference read by section, state the fact in its home section and point to it from elsewhere. In other documents, point at the first statement instead of repeating it. A rule's "never" clause is part of the rule, not a second statement of it.
- Write a heading that names the subject. A heading never makes a claim. A heading or rule name that other files cite stays as written, unless the same change updates every citer.
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

This is the default layout for a repository with no established structure. A repository's existing structure wins: a rewrite keeps the locations and names it finds and does not move established documents onto this layout.

| Path | Reader | Holds | Required |
|---|---|---|---|
| `README.md` | a person choosing or using it | the sections [references/readme.md](references/readme.md) orders | yes |
| `AGENTS.md` | every agent, at session start | what the repo is, the commands, the conventions every agent needs, and task routes to principle docs, directly or through named nested instructions | yes |
| `DEVELOPMENT.md` | a maintainer | build, run, test and debug: only what the tooling does not show | where needed |
| `LICENSE` | a person | the licence | yes |
| `CHANGELOG.md`, `changelog.d/` | a person reading a release | release notes | released packages |
| `<dir>/AGENTS.md` | an agent working in that folder | the folder's commands, rules every agent there needs that no linked principle doc owns, and task triggers for the principle docs that govern it | where a folder has its own rules |
| `docs/architecture/<name>.md` | an agent about to do the work the doc governs | one principle: the approach, why, the rules, one code example | where a principle exists |
| `docs/decisions/INDEX.md` and `<DECISION_ID>-<slug>.md` (names and locations follow decider) | a reviewer or agent about to reverse a choice | decision records: the choice, why, the rejected option, when to revisit | where such choices exist |
| `docs/images/` | a reader of a README or doc | the screenshots and images those files show | when used |
| `docs/runbook.md` | an operator | step-by-step procedures for a running system | operated systems |
| `.github/copilot-instructions.md` | Copilot features that support repository instructions, including code review | repository instructions and the review pointer; bot-instructions owns the render | yes, written by kendex |
| `.github/instructions/*.instructions.md` | Copilot features that support matching path instructions | path rules; bot-instructions owns the render and cloud-agent exclusion | yes, written by kendex |
| `.github/instructions/code-review.md` | review agents following the generated pointer | shared review doctrine; bot-instructions owns the render, not a native Copilot instruction file | yes, written by kendex |

Nothing else lives under `docs/`. A software implementation plan, research report, measurement or handoff is tracker or `tmp/` content (§ Plans and research). An assistant home's policy, memory and session records keep their owning locations and reading routes. When writing or rewriting those records, read [references/assistant-home.md](references/assistant-home.md). Product content a repository ships to its users, such as a help site, legal pages or an adapter reference, stays. That repository's `AGENTS.md` names it. A skill's reference docs stay in its `references/`.

### Reference rules

- The root `AGENTS.md` gives each principle doc a task trigger, or routes to a nested `AGENTS.md` that gives the local trigger: "Before writing a plugin: `docs/architecture/plugins.md`".
- A nested `AGENTS.md` names the principle doc for its folder.
- The Copilot review instruction files point the review bot at the same principle docs for the matching paths. The bot-instructions skill renders them.
- Decision records are not listed in `AGENTS.md`. Review and dev workflows find them by keyword with `decisions search`. A code comment cites a decision ID only where that code carries out the choice.
- A code comment holds a local reason or an external cause at its site, per the code-quality skill's SKILL.md § Comments and Prose. Nothing points to it.
- A README links to a doc only when a person needs it, such as "Writing a plugin".
- An architecture topic document is referenced when a "Read when" line names the task that triggers reading it. A filename in a list, a link from another doc or a mention in prose is not a task route. Delete an architecture topic index that only repeats these routes. This rule does not replace decision discovery, skill reference loading or human navigation. Keep the decider index. Generated examples use their generator inventory. Human pages a site loads use the product-content declaration in `AGENTS.md`.

## Per file type

Each finished example under [examples/](examples/) ends with a contrast drawn from a real failure and one sentence on why that failure fails the reader.

A passage stays in a file only if a reader of that file needs it for their task. A file's readers are the ones its type's section names, where § Per file type has one. A file with two readers, such as a `DEVELOPMENT.md` or a runbook, keeps a passage that either reader needs. For an agent, a rule is needed only when the mistake it prevents is real and costly, and nothing else already prevents it: a command that refuses the wrong input, a rule the same agent already loads, a step of the workflow it runs, or ordinary competence. Move a passage that a reader of another file needs to that file under § Layout. Delete the rest. A licence or notice file keeps the text its licence requires.

Before writing a file, find its type in this table. Then read its section and its example. The first row whose path matches wins. `*` matches across `/`. Shape names the structural rules that apply to the type: `order` is the numbered section order, and `value-table` is the rule against a value table. The commit-guards `md-type` lane checks them.

| Path | Section | Example | Shape |
|---|---|---|---|
| `docs/decisions/*.md` | § Decision records | [decision.md](examples/decision.md) | none |
| `docs/architecture/*.md` | [architecture.md](references/architecture.md) | [architecture-plugins.md](examples/architecture-plugins.md) | `value-table` |
| `docs/runbook.md` | § Runbooks | [runbook.md](examples/runbook.md) | none |
| `AGENTS.md` | [agents.md](references/agents.md) | [root-agents.md](examples/root-agents.md) | none |
| `*/AGENTS.md` | [agents.md](references/agents.md) | [nested-agents-plugins.md](examples/nested-agents-plugins.md) | none |
| `SKILL.md`, `*/SKILL.md`, `*/workflows/*.md`, `agents/*.md`, `*/agents/*.md` | [skill-files.md](references/skill-files.md) | [skill-entry.md](examples/skill-entry.md) | none |
| `*/documentation/*.md` | [human-page.md](references/human-page.md) | [HIW-tasks.md](examples/HIW-tasks.md) | none |
| `*/references/*.md`, `*/schemas/*.md`, `*/patterns/*.md`, `CHECKS.md`, `*/CHECKS.md` | [reference-docs.md](references/reference-docs.md) | [reference.md](examples/reference.md) | none |
| `DEVELOPMENT.md`, `*/DEVELOPMENT.md` | [development.md](references/development.md) | [development.md](examples/development.md) | none |
| `README.md`, `*/README.md` | [readme.md](references/readme.md) | [readme.md](examples/readme.md) | `order`, `value-table` |
| none: the product content directory a repository names | [human-page.md](references/human-page.md) | [human-page.md](examples/human-page.md) | none |

### One home per fact

For an internal design claim, ask the questions below in order. Stop at the first yes. First classify user help, operating steps, skill procedures and reference contracts by their file-type section.

1. Is it one option kept over a named rejected alternative, whose reason the code cannot show and whose reasons and alternatives a doc's rules cite rather than repeat? A decision record: the choice, why, the rejected option and the revisit trigger, under the decider bar. Example: [examples/decision.md](examples/decision.md), one dismiss owner kept over per-component handling, cited by the design-system doc's rule.
2. Is it the approach one reader's task runs under, or a rule followed while doing it? An architecture doc: the approach, its why and its rules. It states the current actionable rule. It cites any decision it rests on by ID, without repeating its reasons or alternatives. Examples: [examples/architecture-plugins.md](examples/architecture-plugins.md), a surface goes in a plugin and never imports another; [examples/architecture-design-system.md](examples/architecture-design-system.md), every value a component draws comes from the token file.
3. Neither. A feature's behaviour, what a page, key or button does, lives in the code, its tests and the tracker item that asked for it. Counter-example: [examples/behaviour-spec.md](examples/behaviour-spec.md), a window written up control by control, with where each line goes.

### Decision records

Read by a reviewer or agent about to reverse a choice. The bar, the format and the workflows are the [decider](../decider/SKILL.md) skill's. This skill ships no second format. A principle doc states the current actionable rule. It cites the decision ID. It does not repeat the decision's reasons or alternatives. Example: [examples/decision.md](examples/decision.md).

### Runbooks

Read by an operator, a person or an agent, maintaining or recovering a running system. A procedure names the task and when to use it, the target environment, required access and tools, and approval for effects that change service or data. Put steps in execution order. Give each step its expected reading and the condition that permits the next step. Name the source of the reading, such as a status page, command result or log. An unavailable reading is unresolved, not success.

State when the operator stops, how to leave or restore the system, and who receives a failure with its evidence. Describe recovery only where the system's current operating contract supports it. Finish with the end-state check and cleanup of temporary access, files or changed settings. Preserve evidence until its handoff is checked.

Never: build and test instructions for package development, design rationale, incident history or a record of one run. Those facts keep their homes under § Layout and § Plans and research. Example: [examples/runbook.md](examples/runbook.md).

### Documentation HTML

Read in a browser. An offline page a skill or repository ships beside its markdown. It opens with no build step. It follows the rules of the equivalent markdown type. It uses local styles only, and no framework or external asset. Inline SVG is available where a diagram shows a relationship more clearly than prose. Never: a page served from a web root or built by an application bundler. Such a page is a product file.

### `CHANGELOG.md` and `changelog.d/`

Read by a person reading a release. The `changelog-entries` lane owns the shape. Its release-version rule, the commit-guards skill's CHECKS.md § Release versions, owns the version and the fragment section. Follow the repository's `changelog.d/README.md`.

## Maintenance

- Update a doc when a change makes a claim in it false. A code change alone owes no doc change.
- A claim that a checker enforces something names the checker. A constraint without an enforcer names review, an operator step, or the gap.
- This writing standard sets no fixed document-size limit. Harness limits still apply to loaded instructions, including imports. For example, [Codex limits combined project instructions](https://developers.openai.com/codex/guides/agents-md) to 32 KiB by default. The doc-limits check measures instruction files, `AGENTS.md`, `CLAUDE.md`, `GEMINI.md` and `SKILL.md`, and nothing else. The commit-guards `md-type` lane checks the shapes the route table names. Review holds every other rule. A rewrite's check by use also holds its cuts.

## Plans and research

A software implementation plan, research report, measurement or handoff is not repository content. Write it under `tmp/`. Attach it to the tracker issue it serves. Research that is the evidence behind a constraint still in force is attached to that constraint's issue. That attachment is verified readable. The constraint links to it. Every other research file is deleted when its work lands. An assistant home's sourced memory and live handoff follow their owning contracts, not this software-artifact rule.

## Format

- Write each paragraph on one line. Write each list item on one line. Neither holds a hard wrap. Blank lines separate paragraphs, list blocks, headings, and fences. Tables and fenced code stay as written. The commit-guards `md-reflow` script rewrites a file to this format. `md-reflow --check` names a file that departs from it.
- Relative links in Markdown must resolve. The commit-guards skill's CHECKS.md § md-refs owns the checked forms.
- A link sits in a sentence that says when to read its target or what the target holds.
- Keep release and implementation narration out of agent-loaded markdown. Keep dates, attribution, source links and supersession that establish a current rule or qualify its evidence.
- A rule a shipped kendex package states is never restated in the repo's own markdown. The repo installs the package. It customises the package through `kendex.toml`.

## Writing

A focused change edits the affected text. A focused change whose paragraph adds a fact first takes § One home per fact. Converting a document onto this convention, restructuring it, or cutting what its readers do not need follows [workflows/rewrite.md](workflows/rewrite.md) at the scope asked for: one file, one folder or the repository. The workflow names each file's readers. It keeps only the rules they need. It checks the result on their tasks. Both verify each claim against its owning source. Both use code where code owns the claim. Both preserve the actor, scope, exceptions, required order, dates, attribution, supersession and evidence status. An unread source leaves verification unresolved; it does not establish or erase the claim. Both follow § Per file type. Both start from the example its table names for the file type.
