# Initiative and project template

Use this template when roadmap-create creates an initiative or project.

## Description

`--description` is the 255-character subtitle. Write one plain sentence naming the outcome for an executive reader.

```text
[OUTCOME: one plain sentence]
```

## Content

`--content` is the markdown body. Begin with the same quoted opening as the issue template, then fill the three sections in order, in plain words. Separate the opening blocks and every section with blank lines. Omit a section with nothing to say.

```markdown
> **Story:** [Who this is about.] [What happens today.] [What the grouped work changes, and its consequence.]

> **Why this matters:** [The harm or cost today, and what the change buys.]

## What ships

- [Deliverable]

## How we know it worked

- [Observable result]

## What is next

- [The next work or decision]
```

## Required inputs

Before the first create, take the required values below from the approved plan or the user's answers. If any are missing, ask one question for all missing values for the project and any new initiative. Use the answers for both creates.

| Create | Required values |
|--------|-----------------|
| Initiative | Name, owner email or id, lead team key or name, initiative-label names, resource label and URL |
| Project | Name, team key or name, lead email or id, project-label names |

Take initiative-label names from the approved plan or the user's answers. The initiative create command resolves them against initiative labels. Read `linear.sh project-labels list --max` for project-label names. These are separate label lists, as [labels.md](../references/labels.md) defines.

## Fields and links

- Keep mailbox ids, Slack ids, file paths and log lines out of both fields. Put research or design in a resource link with `--link LABEL=URL`. Put detail in a comment under [SKILL.md](../SKILL.md) § Where each rule lives.
- An initiative sets `--owner EMAIL|ID`, `--lead-team KEY|NAME`, `--labels A,B` and a resource `--link LABEL=URL`.
- A project sets `--lead EMAIL|ID` and `--labels A,B`. Use `--link LABEL=URL` for its research or design.
