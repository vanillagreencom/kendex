---
name: docs-writing
description: "Load to write, rewrite, or review any markdown file a repository owns: README, DEVELOPMENT, architecture docs, reference docs, SKILL.md and AGENTS.md."
summary: "One writing standard for every markdown file a repo owns, a directive list and a template per file type, and the blank-page rewrite workflow."
license: MIT
user-invocable: true
dependencies:
  required: [decider]
metadata:
  author: vanillagreen
  source: kendex
  repository: "https://github.com/vanillagreencom/kendex"
  bugs: "https://github.com/vanillagreencom/kendex/issues"
  version: "2.0.0"
tags: [docs]
---

# Docs Writing

A repository's markdown holds what the code cannot show: invariants, layer boundaries, decisions with their reason, conventions that differ from tool defaults, and pointers to canonical code and to the test that proves a claim. Everything else lives in the code, the tests, and git history.

This skill governs every markdown file the repository owns. It states one writing standard, then what each file type is for and what it must not carry.

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

## Per file type

Each list says who reads the file, what it holds, and what it excludes. A file carries only what its list permits.

### `README.md`

Read by a person choosing or using the package or repo.

- What it is and who it is for, in two or three sentences.
- Install: the one command, or a bullet or table row per platform or method where more than one exists.
- One section named Features, with one plain feature per bullet. No Guarantees or What you can count on section. Use plain noun headings throughout, such as Install, Features, How it works, Supported tools, and Settings.
- How it works: three to six plain sentences or bullets naming the parts the user meets and what happens in order. Every sentence must make sense without reading the code.
- Where to customise: the settings a reader sets, and the file each is set in.
- Excluded: internal vocabulary, coined phrases, metaphors, product voice, invariants, detailed internals, rationale, history, and a command listing `--help` already gives.

### `DEVELOPMENT.md`

Read by a maintainer, human or agent, working on the package itself.

- The mechanics a maintainer needs and the layout of the code.
- Ordering and compatibility constraints the code cannot show.
- How to run, test, and debug the package.
- The test strategy: what each suite proves.
- Excluded: anything the code, the tests, `--help`, or the README already states, and any architecture narration.
- A file left with nothing load-bearing is deleted, and any surviving line moves to the README.

### `docs/architecture/overview.md`

Read by an agent or maintainer before structural work. One per repository.

- The one idea every part projects, in one paragraph.
- Vocabulary: one line per term the code uses with a meaning a reader could get wrong.
- Layer boundaries: what each layer may depend on and what it may never contain.
- Invariants, one line each, with the test or check that enforces it.
- An index of the topic files, each with the condition that sends a reader there.
- Excluded: directory layouts, file-by-file descriptions, behaviour walkthroughs, command listings, CI topology, and step-by-step flows.

### `docs/architecture/<topic>.md`

Read on demand for one subsystem. The `doc-drift-check` hook names it when covered code changes.

- A `Covers:` line naming the paths it describes. A plain repo-relative path covers that file or directory. A shell glob matches the full path, with `*` crossing `/`.
- The same content kinds as the overview, for one subsystem.
- A topic file exists only where a subsystem has invariants or boundaries of its own. A subsystem with none is a line in the overview.

### Reference docs

Read by an agent or maintainer looking up one value. Any lookup document: `references/`, `schemas/`, `patterns/`, a named file such as `CHECKS.md`, or one under `docs/`.

- Tables and lists. One row per item.
- The value or the shape the contract fixes, its meaning, and its default.
- The semantics a reader needs to produce or consume that shape, and no more.
- Excluded: rationale, and narrative that defines nothing.
- A file under `references/` exists only where a named workflow loads it on demand.

### `SKILL.md`, `workflows/*.md`, `agents/*.md`

Read by an agent on every load.

- The shortest unambiguous rule, and the commands.
- Excluded: mechanics, rationale, history, and worked examples.
- A rule another file owns is cited, never restated.
- Rationale moves to `DEVELOPMENT.md` or a decision record.

### `AGENTS.md`

Read by every harness at the start of every session, at the repository root.

- A map, not a manual: what the repo is in two or three sentences.
- Everything a Codex session must know, because Codex reads only the root-to-cwd chain of `AGENTS.md` files, at launch, under a 32 KiB combined cap.
- The commands that are not discoverable from the tooling itself.
- The conventions that differ from a tool default or a language norm.
- One line per deeper doc, saying when to read it.
- A nested `AGENTS.md` holds the conventions and invariants local to its directory, and stays small.
- Excluded: anything derivable from the code.

### `CLAUDE.md`

The harness shim. kendex writes it, and its whole content is one import line.

- Never hand-write it, a `.claude/rules` file, or any other harness-specific instruction file.
- `kendex apply`, `kendex refresh` and `kendex verify` write and check it, and it is committed.

### Decision records

Read when opened. The format, templates, and workflows are the `decider` skill's.

- Follow [`../decider/SKILL.md`](../decider/SKILL.md). This skill ships no second template and states no second format.
- Architecture docs cite a decision by ID and never restate it.

### `CHANGELOG.md` and `changelog.d/`

The `changelog-entries` lane owns the shape. Follow the repository's `changelog.d/README.md`.

## Format

- Docs change in the same commit as the code they describe. The `doc-drift-check` hook shows unchanged covering docs to the user as a notice; it does not block a stop.
- One paragraph per line, one list item per line, no hard wraps inside either. Blank lines separate paragraphs, list blocks, headings, and fences. Tables and fenced code stay as written. The commit-guards `md-format` lane enforces it and `md-reflow` converts a file once.
- Every relative link, `<path>.md § Heading` or `<path>.md#anchor` citation, and decision ID resolves. The `md-refs` lane checks them.
- Agent-loaded markdown carries no history. The `prose` lane checks it.
- Document byte limits and exceptions follow [doc-limits policy](../doc-limits/references/policy.md).
- A rule a shipped kendex package states is never restated in the repo's own markdown. The repo installs the package and customises through `kendex.toml`.

## Writing

Rewrite from a blank page, never by editing the old text: [workflows/rewrite.md](workflows/rewrite.md).

Templates: [README.md](templates/README.md), [DEVELOPMENT.md](templates/DEVELOPMENT.md), [overview.md](templates/overview.md), [topic.md](templates/topic.md), [reference.md](templates/reference.md), [agent-SKILL.md](templates/agent-SKILL.md), [root-AGENTS.md](templates/root-AGENTS.md), [nested-AGENTS.md](templates/nested-AGENTS.md).
