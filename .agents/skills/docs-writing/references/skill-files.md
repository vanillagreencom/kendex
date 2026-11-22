# `SKILL.md`, `workflows/*.md`, `agents/*.md`

Read when writing, editing or reviewing a `SKILL.md`, a workflow or an agent file.

Read by an agent when the task loads the file. `SKILL.md` holds what every loader needs before it knows which workflow it runs: activation, the roles where there are several, the routes, and the rules every loader needs. A rule one workflow or one lookup needs goes to that file. With several roles, the entry names each role and what it runs, and routes each reference with a `## Read when` line naming the task that sends a loader there.

In the front matter, `description` is the activation line, and `summary` is the one line kendex shows wherever it names the package. An edit to the body changes neither unless it makes one of them false.

`workflows/` holds the steps an agent follows, in order, to finish one job.

`references/` holds contracts and detail an agent looks up while doing a job.

Agent files hold the role's rules. Worked examples live in named supporting files.

To choose a folder, name the file's job and its reader. If the reader runs it from first line to last to finish that job, it is a workflow. If the reader opens it at one section while doing another job, it is a reference. Split a file that does both: put the steps in a workflow and keep the contract in a reference. One cites the other. Put shared setup steps in one cited workflow, and shared setup contracts in one cited reference.

Give each supporting file an explicit reading trigger. Cite a rule another file owns. A fact about another tool or workflow stays a statement about that actor, never an instruction to the reader. Never: implementation narration, rationale or history. Rationale belongs in an admitted principle doc, a decision under decider's bar or a comment at the code. Where a reason is the only statement of a rule, write the rule and delete the reason. Example: [examples/skill-entry.md](../examples/skill-entry.md).
