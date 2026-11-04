# Human architecture page

Read when writing, editing or reviewing a human architecture page.

Read by a person asking how the system works, on a help site, in another product content directory the repository ships, or in a package's `references/HIW-<topic>.md`. The topic is lowercase and hyphenated. The title is the reader's question. The first paragraph answers it briefly in plain words, followed by one diagram showing the answer.

## When to split

Use separate how-it-works pages only when a person needs to understand independent parts with different jobs and one README section would make them piece those jobs together. Otherwise keep the explanation in the README. The README's [How it works section](readme.md) introduces and links the pages.

One page owns the end-to-end explanation. It shows ordinary completion directly. Waiting for later evidence and recovery are exceptions. Other pages answer their own questions and link to the end-to-end page rather than repeat the lifecycle. Keep message, delegation and check semantics at their distinct explanatory owners.

## Page sections

After the question, short answer and diagram, explain these subjects in order. Use headings that name the subject in the reader's words.

1. What starts it.
2. How it moves.
3. What is kept, and who owns it.
4. How it finishes or recovers.
5. What the person can change, only when applicable.
6. Related pages.

A section can combine related subjects when that makes the explanation clearer. Bind behavior claims to the current package. Name planned or unavailable behavior as such and retain unresolved evidence limits. Explanation does not move the rules an agent follows out of their owners.

## Diagrams and readers

For package how-it-works pages, use a fenced `mermaid` diagram that GitHub renders natively. Use a few high-level boxes with familiar actors and outcomes, and short verb labels for their relationships. Keep script names, variable names, source tags and implementation detail out of the diagram. No generated picture or renderer is needed. Other human product pages can use their site's supported diagram format.

These are human pages. For site content, `AGENTS.md` names the product content directory. For package HIW pages, the file-type route and README provide classification and navigation. No "Read when" line routes an agent through either kind of page. The rules an agent follows keep their existing skill, workflow, reference or `docs/architecture/` owner.

Never: do and never lines, decision IDs, code paths, or a sentence written for an agent. Read [the human-page example](../examples/human-page.md) for site content or [the HIW example](../examples/HIW-tasks.md) for a package page.
