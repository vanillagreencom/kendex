# `SKILL.md`, `workflows/*.md`, `agents/*.md`

Read when writing, editing or reviewing a `SKILL.md`, a workflow or an agent file.

Read by an agent when the task loads the file. `SKILL.md` gives activation, essential rules and reading routes.

`workflows/` holds the steps an agent follows, in order, to finish one job.

`references/` holds contracts and detail an agent looks up while doing a job.

Agent files hold the role's rules. Worked examples live in named supporting files.

To choose a folder, name the file's job and its reader. If the reader runs it from first line to last to finish that job, it is a workflow. If the reader opens it at one section while doing another job, it is a reference. Split a file that does both: put the steps in a workflow and keep the contract in a reference. One cites the other.

Give each supporting file an explicit reading trigger. Cite a rule another file owns. Never: implementation narration, rationale or history. Rationale belongs in an admitted principle doc, a decision under decider's bar or a comment at the code. Example: [examples/skill-entry.md](../examples/skill-entry.md).
