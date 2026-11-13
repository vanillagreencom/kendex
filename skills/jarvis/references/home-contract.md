# Home contract

Read when starting a session, adding or changing a personal customization, finding a memory note or updating its index row.

## Personal additions

Read this section for an ordinary request to add an agent, add a skill, remember a fact, establish a workstream, or add a hook or schedule. Use the existing owner in the table before acting.

| Request | Source owner and reading route |
|---|---|
| Add an agent | The home's `agents/NAME.md`, its local source and `[agents.NAME]` declaration in `kendex.toml`, under [Customize](../README.md#customize). Check existing installed agents first; a new agent needs a distinct task scope and a launch route. Installing one grants no task or private-record authority. |
| Add a skill | The home's `skills/NAME/SKILL.md`, its local source and `[skills.NAME]` declaration, under [Customize](../README.md#customize). Reuse an installed skill when it already owns the task. |
| Change an installed agent | The consumer manifest's existing agent overrides: `[agent-additional-instructions]` for added instructions and `[agent-frontmatter]` for harness-specific fields. Read the selected harness's supported fields before changing them. Fork through `kendex fork` when the published body must change; read its help first. Never edit a rendered agent to personalize it. |
| Remember a fact | [Memory: Notes](memory.md#notes) owns its source, date, supersession and index update. |
| Establish a workstream | A subject in `memory/workstreams.md`, indexed under [Memory: Notes](memory.md#notes), holds intent, scope, owner and tracker references. Read [Long sessions: Homes](long-session.md#homes) and [Task reconciliation](../workflows/tasks.md) for active tasks, acceptance and waiting conditions. The note is no live queue; the handoff holds only session state. |
| Add a hook or schedule | Read [Verification](verification.md) and inspect the existing supported event, hook or native scheduling mechanism first. Use its owning package and declared capability. Universal lifecycle and delivery retain their existing runtime and mailbox owners. Add no parallel watcher. |

For agent and skill additions, inspect the existing source and selected harness support before changing a declaration. Refresh in the consumer home and read back each selected supported harness's rendering, then refresh again and check that the addition and its source remain. Keep source, declarations and the resulting tracked outputs together through the home repository's normal commit and pull-request route. A satellite forwards the change to Jarvis main under [Main and satellites](agent-reach.md#main-and-satellites).

An app-managed home's file tools can be limited to `state/`; that access grants no permission to write sources elsewhere. Report an unavailable source, installation failure or unsupported capability with the operation and cause. Keep the request incomplete until its owner resolves it; an unread or failed check is no successful installation. Preserve existing personal instructions and saved choices.

## Memory store and index

- The home has one memory store. Notes hold the content under subject headings, following [Notes](memory.md#notes).
- The home has one memory index at `memory/MEMORY.md`.
- Each index row names a note and when to read it. Its location is the note's file and subject heading only. Include no read command in a row.
- Home files have no size cap.

## Session start

- At session start, load only `memory/MEMORY.md` for memory. Do not load the notes with it.
- Read a note when the task meets the reading condition in its index row.

## Read a note

- A terminal session reads the note with `.agents/skills/jarvis/scripts/jarvis-section FILE 'Subject heading'`, using the file and exact heading from its index row.
- A session with only search access searches for the subject heading in the named file and reads that section.
- Read the selected heading and its content. Stop before the next heading of the same or higher level.
