# Home contract

Read when starting a session, adding or changing a personal customization, finding a memory note or updating its index row.

## Personal additions

Read this section for a request to add something to a Jarvis home. Use the existing owner in the table before acting.

Put text in a section read at every Start only when every Start acts on it. Otherwise give it a reading route for the action or event that needs it.

| Request | Source owner and reading route |
|---|---|
| Add an agent | The home's `agents/NAME.md`, its local source and `[agents.NAME]` declaration in `kendex.toml`, under [Customize](../README.md#customize) |
| Add a skill | The home's `skills/NAME/SKILL.md`, its local source and `[skills.NAME]` declaration, under [Customize](../README.md#customize) |
| Change an installed agent | The consumer manifest's existing agent overrides, or `kendex fork` |
| Add a standing rule | Its owning skill or reference under [Homes](long-session.md#homes), with a reading route under [Action routes](../workflows/session.md#action-routes) |
| Add an event duty | Its owning rule section, loaded for that event under [Action routes](../workflows/session.md#action-routes) and the [Event loop](../workflows/session.md#event-loop) |
| Add a temporary instruction | Instructions in force under [Handoff](long-session.md#handoff) |
| Add a tool | [Verification: Tools and records](verification.md#tools-and-records), which owns reuse and when a recurring operation warrants a tool |
| Keep a result | [Homes](long-session.md#homes), which selects its record destination |
| Remember a fact | [Memory: Notes](memory.md#notes) |
| Establish a workstream | A subject in `memory/workstreams.md`, indexed under [Memory: Notes](memory.md#notes) |
| Add a hook or schedule | Its owning package and declared capability |

- **Add an agent**:
  - Check existing installed agents first.
  - A new agent needs a distinct task scope and a launch route.
  - Installing one grants no task or private-record authority.
- **Add a skill**: reuse an installed skill when it already owns the task.
- **Change an installed agent**:
  - Use `[agent-additional-instructions]` for added instructions and `[agent-frontmatter]` for harness-specific fields.
  - Read the selected harness's supported fields before changing them.
  - Fork through `kendex fork` when the published body must change; read its help first.
  - Never edit a rendered agent to personalize it.
- **Add an event duty**: put its work and checks in their homes under [Homes](long-session.md#homes).
- **Keep a result**: use [Notes](memory.md#notes) for a durable fact, ruling, preference or lesson.
- **Establish a workstream**:
  - The subject holds intent, scope, owner and tracker references.
  - Read [Long sessions: Homes](long-session.md#homes) and [Task reconciliation](../workflows/tasks.md) for active tasks, acceptance and waiting conditions.
  - The note is no live queue; the handoff holds only session state.
- **Add a hook or schedule**:
  - Read [Verification](verification.md) and inspect the existing supported event, hook or native scheduling mechanism first.
  - Use its owning package and declared capability.
  - Universal lifecycle and delivery retain their existing runtime and mailbox owners.
  - Add no parallel watcher.

For agent and skill additions:

1. Inspect the existing source and selected harness support before changing a declaration.
2. Refresh in the consumer home and read back each selected supported harness's rendering.
3. Refresh again and check that the addition and its source remain.
4. Keep source, declarations and the resulting tracked outputs together through the home repository's normal commit and pull-request route.

A satellite forwards the change to Jarvis main under [Main and satellites](agent-reach.md#main-and-satellites).

After a rule changes, a consumer that renders it to another surface checks that the installed copy there has the new revision. It runs one relevant request at that surface.

An app-managed home's file tools can be limited to `state/`; that access grants no permission to write sources elsewhere.

- Report an unavailable source, installation failure or unsupported capability with the operation and cause.
- Keep the request incomplete until its owner resolves it; an unread or failed check is no successful installation.
- Preserve existing personal instructions and saved choices.

## Memory store and index

- The home has one memory store. Notes hold the content under subject headings, following [Notes](memory.md#notes).
- The home has one memory index at `memory/MEMORY.md`. Once committed, this recovery entry point remains present in the candidate commit; an initial empty home may omit it.
- Each index row names a note and when to read it.
  - Its location is the note's file and subject heading only.
  - Include no read command in a row.
- Home files have no size cap.

## Session start

- At session start, load only `memory/MEMORY.md` for memory. Do not load the notes with it.
- Read a note when the task meets the reading condition in its index row.

## Read a note

- A terminal session reads the note with `.agents/skills/jarvis/scripts/jarvis-section FILE 'Subject heading'`, using the file and exact heading from its index row.
- A session with only search access searches for the subject heading in the named file and reads that section.
- Read the selected heading and its content. Stop before the next heading of the same or higher level.

## Consumer recovery policy

The consumer owns:

- its index columns and routing layout, and memory-directory population;
- any requirement that headings be globally unique beyond [Notes](memory.md#notes)' replacement identity rules;
- resolution and replacement checks for legacy free-form note identities outside those supported forms.

Register these checks in the home's standing instructions when adopting those conventions.

The consumer also owns:

- migration and checks for legacy session records outside the explicit forms in [Handoff](long-session.md#handoff), including title-case, number-led and embedded historical SESSION forms;
- uniqueness of additional handoff sections, live memory audits, freshness rules, and reporting of audit findings, files and notes.

A home that adopts private task files owns their inventory, one-to-one file/record correspondence, unique task records, lifecycle status vocabulary, resumption trigger and result destination, including refusal of a missing task file. The package does not require private task files. Tracker work and State durable-id uniqueness retain their existing owners under [Homes](long-session.md#homes) and [Progress records](long-session.md#progress-records).
