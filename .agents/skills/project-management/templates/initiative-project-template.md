# Initiative and project template

Use this template when roadmap-create creates an initiative or project.

## Description

`--description` is the 255-character subtitle. Write one plain sentence naming the outcome for an executive reader.

```text
[OUTCOME: one plain sentence]
```

## Content

`--content` is the markdown body. Fill at most four short sections in plain words. Omit a section with nothing to say.

```markdown
## Why

[The need and its effect on people]

## What ships

- [Deliverable]

## How we know it worked

- [Observable result]

## What is next

- [The next work or decision]
```

## Fields and links

- Keep mailbox ids, Slack ids, file paths and log lines out of both fields. Put research or design in a resource link with `--link LABEL=URL`. Put detail in a comment under [SKILL.md](../SKILL.md) § Where each rule lives.
- An initiative sets `--owner EMAIL|ID`, `--lead-team KEY|NAME`, `--labels A,B` and a resource `--link LABEL=URL`.
- A project sets `--lead EMAIL|ID` and `--labels A,B`. Use `--link LABEL=URL` for its research or design.
- Use the approved plan and the user's answers for the owner, lead, team and resource link. Read live project labels with `linear.sh project-labels list --max`. Initiative and project labels are project labels, as [labels.md](../references/labels.md) defines.
