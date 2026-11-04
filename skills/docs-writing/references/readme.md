# `README.md`

Read when writing, editing or reviewing a `README.md`.

Read by a person choosing or using the repository, package, skill, plugin or Pi extension. Its sections, in this order, each only where the thing needs it:

1. A brief description: what it is and who it is for.
2. A screenshot, where the thing has a screen.
3. Features: one direct line each.
4. Install: paste lines per route, no prose.
5. How it works: high level, in plain words, with no engineering terms.
6. Sub-packages, where they exist: a table, one line each.
7. Setup or customise: only the must-know settings.
8. Licence.

Another section only where the thing needs it. Never: internal vocabulary, invariants, internals, rationale, history, engineering detail, or a command listing `--help` already gives. Example: [examples/readme.md](../examples/readme.md).

When independent package parts need separate explanations under [the human-page split rule](human-page.md#when-to-split), keep How it works to one short paragraph and a pointer table. Each row names the person's question and links to its `references/HIW-<topic>.md` page. The end-to-end page owns the full explanation; the README introduces it without repeating its steps. Read [the finished HIW example](../examples/HIW-tasks.md) before writing a package page.
