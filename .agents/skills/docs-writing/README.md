# Docs Writing

Writing rules and finished examples for repository markdown and documentation HTML. Authors and reviewers use the same requirements for each kind of document.

## Features

- Supply a plain writing standard with examples.
- Offer a default repository layout for a repository with no established structure.
- Define the purpose and contents of each document type, and ship one finished example per type with a contrast drawn from a real failure.
- Sort internal design claims into a decision record, an architecture doc, or the code, its tests and the tracker; sort help, procedures and reference contracts by document type.
- Guide a focused edit to existing text, and a rewrite that extracts first and then writes from a blank page.
- Link decision-record work to the decider skill.

## Install

```bash
kendex add vanillagreencom/kendex --skill docs-writing
```

kendex also installs decider, which supplies the decision-record format, and the docs-writing-note hook on Claude Code, Codex and Pi.

## How it works

The author finds the document type in the table in [SKILL.md](SKILL.md), then reads that type's rules and its example. The author checks existing claims against the code. A focused change edits only the affected text; a rewrite extracts what is unique, then writes from a blank page.

On the first Markdown edit of a session, the docs-writing-note hook names that file's type, rules and example once, where commit-guards is installed in the same scope. Without commit-guards, the hook sends the session to the route table in SKILL.md. It never blocks the edit. When the change is committed or pushed, the commit-guards md-type check refuses a shape the table rules out for that type, such as a settings table in a README, and md-refs checks references. Refresh delivers the skill and the hook, so a repository needs no `AGENTS.md` line that sends Markdown edits here.

## Setup

Add repository writing instructions in `kendex.toml` under `[skill-instructions]`. kendex includes them in the installed skill.

## Licence

MIT, in the repository's LICENSE file.
