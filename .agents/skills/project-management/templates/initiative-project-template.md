# Initiative and project template

Use this template when roadmap-create creates an initiative or project.

## Description

`--description` is the 255-character subtitle. Write one plain sentence naming the outcome for an executive reader.

```text
[OUTCOME: one plain sentence]
```

## Content

`--content` is the markdown body.

- Open with the quoted Story and quoted Why this matters blocks, separated by an unquoted blank line, as [issue-description-template.md](issue-description-template.md) § Field Mapping and § Rules describe them.
- Then fill at most three short sections in plain words, in this order.
- Omit a section with nothing to say.
- Separate every section with blank lines.

```markdown
> **Story:** [Who this outcome is for.] [What they face today.] [What changes once it ships, and its consequence.]

> **Why this matters:** [The cost today, and what the outcome buys.]

## What ships

- [Deliverable]

## How we know it worked

- [Observable result]

## What is next

- [The next work or decision]
```

## Required inputs

1. Before the first create, take the required values below from the approved plan or the user's answers.
2. If any are missing, ask one question for all missing values for the project and any new initiative.
3. Use the answers for both creates.

| Create | Required values |
|--------|-----------------|
| Initiative | Name, owner email or id, lead team key or name, initiative-label names, resource label and URL |
| Project | Name, team key or name, lead email or id, project-label names |

- Take initiative-label names from the approved plan or the user's answers. The initiative create command resolves them against initiative labels.
- Read `linear.sh project-labels list --max` for project-label names.
- Initiative labels and project labels are separate label lists, as [labels.md](../references/labels.md) defines.

## Fields and links

- Keep mailbox ids, Slack ids, file paths and log lines out of both fields.
- Put research or design in a resource link with `--link LABEL=URL`.
- Put detail in a comment, written under the communication skill's references/reports.md § Work-item descriptions and comments.
- An initiative sets `--owner EMAIL|ID`, `--lead-team KEY|NAME`, `--labels A,B` and a resource `--link LABEL=URL`.
- A project sets `--lead EMAIL|ID` and `--labels A,B`.
- A project uses `--link LABEL=URL` for its research or design.
