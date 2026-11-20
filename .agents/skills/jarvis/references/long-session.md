# Long sessions

Read each named rule, handoff or memory section with `.agents/skills/jarvis/scripts/jarvis-section FILE 'Heading text'`. Use the exact heading text from its owning file. A returned parent section includes its children; use that text rather than reading a child again.

## Homes

For additions to a Jarvis home, start at [Personal additions](home-contract.md#personal-additions). Each record kind has one home. Write a record to its home, never to the handoff.

| Record kind | Home |
|---|---|
| Standing rule | The skill or reference that owns it. |
| Durable fact, ruling, preference or lesson | A memory note under [memory.md:Notes](memory.md#notes). |
| Work, task or check | The tracker: an item, or a Done-when box on an item. |
| Open exchange | Its mailbox, read live: the user channel and each agent's channel. With orch installed, `lane-mail pending`, peer asks and the [Jarvis mailbox read](agent-reach.md#read). |
| Session state | The handoff. |

- A continuing session requires available tracker access and one user-selected project for its own tasks. Confirm that the tracker can read the workspace queue and retain tasks and checks. If setup or project selection is missing, request it through [Connect Linear](../workflows/setup-linear.md). Keep the current handoff untouched until these prerequisites hold.
- Select a session-task project in a Linear team that no repository's overseer dispatches. Confirm at project selection that no checkout's `LINEAR_TEAM` names that team. If this is unconfirmed, use [Connect Linear](../workflows/setup-linear.md) before continuing. Create each of the session's own tasks in that project through the tracker's existing issue creation command.
- Record a session's check on another item as a Done-when box on that item. The box names the check, its evidence source, its trigger and its deadline. It follows the tracker's Verifying lifecycle: an open box keeps the item in Verifying, and the box closes only on recorded evidence or an explicit disposition. Add no label.
- For a fix sent to another owner, put the Done-when box on a check item in the session's own task project instead. Link the other owner's item. Keep the box and check item open until the session records the check where the problem was seen. The other owner's Done mark closes neither the box nor the check item.
- Select the checks by the tracker's Verifying state across the workspace, and also read every open check item in the session's own task project. Read both selections live and through every page. When a read fails, report the checks unavailable.

Use [Task reconciliation](../workflows/tasks.md) to capture and reuse each requested outcome, apply current decisions and retain its next action before delegation, waiting or succession. Its tracker setup and migration steps precede reliance on open-item discovery.

## Handoff

Before normal succession, wait for every attached sub-agent this session launched to return in the current turn. Use the harness wait or result tool and collect each result. Record a failed child as failed. Launch an attached child only when the context room holds its return. Otherwise use the orch job runner described in `waiter-launch.md`, Launch, or a separate session. Record its run directory in the handoff. If the session is dead, walled, or cannot read its child state, the emergency handoff names each known unfinished child, its known output location, and any unknown state or location. An output location can be a file path or a harness reply. The successor reads existing child output before repeating the task.

The current handoff defaults to `state/handoff.md` in the [home layout](home-layout.md). A consumer's home contract may name another path. The `progress-log --handoff PATH` commit check reads that selected path from the index and refuses its established-file deletion. It uses the default only when no override is given. Its earlier generations live in the `archive/` directory beside it. Read this contract when writing, reading or checking a handoff or lane result during the [session workflow](../workflows/session.md). Each item has a durable id and a recorded time. The current handoff has these four sections. Each section occurs exactly once. Once committed, the handoff remains present in the candidate commit. New homes may omit it before their first session.

| Section | Required content |
|---|---|
| State | Entries selected by [State retention](#state-retention). Read the next report through `jarvis-session report-due`; retain no due row. The checkpoint records when this state was checked and the first and last log ids it covers, or none for an empty log. |
| Sub-agents | Each running lane or attached agent: its identity, task source and result destination. For an attached agent, identify its launch prompt and harness reply by the available agent or message ids. For a lane, record its task file and result file paths. Keep unfinished ids, available output locations and unknown state or locations under the emergency rule above. |
| Instructions in force | Each temporary instruction from the user, its source and the event that ends it. Link the home of a standing rule. |
| Progress log | One record at the time of each decision, state change, uncertain send, or user message handled without a reply, under the record contract below. |

### State retention

- Keep a State entry only if its absence would cause the successor to act wrongly or repeat work and the successor cannot recover the fact from its owning source. Examples include an unfinished operation with no receipt, a live lane, a temporary instruction, report coverage or a hold. Keep an existing entry whose source is unreadable until a readback succeeds.

An explicit session identity uses the existing `session=ID` token or a State entry opening `- SESSION ID`. Each session identity has one resumable State entry, even when entries carry different ask ids. When State carries a session identity, its checkpoint includes `session ID`; the checkpoint identity and every explicit session identity in that entry agree. The commit check compares staged text only and consults no running session or private transcript.

- Change a State entry with the single `progress-log` call under [Progress records](#progress-records). It replaces the whole entry or removes it and appends the record under the same file lock and write. Put the account in the record, never append it to the old State text.
- Update session-only state when it changes: an unfinished operation's next step, a running lane's identity or result path, a temporary instruction or its end event, report coverage, or a hold. Change only the affected lines and append the state-change record in the same write. Advance the checkpoint's covered log range with the update.
- At the scheduled report, refresh changed lines. Commit changed state at each scheduled report unless the user's standing instructions set another commit trigger. Never recompose the whole state for a report.
- Before succession transfers control, reconcile the checkpoint and later log records against live tracker items, the mailbox and relevant memory notes under [Homes](#homes). Record each correction as a state change and advance the checkpoint's covered log range.
- Rebuild state from the checkpoint and replay later state-change records in their recorded order. Compare the checkpoint time with the clock and the user's staleness bound. If the state is stale, its covered range is incomplete, or a source disagrees, widen the reads to the relevant source history and earlier log records. Do not refuse recovery solely because the state is stale.

- An archive may hold `INDEX.md`, one Markdown bullet for each file the handoff replacement step archives: `- FILE dates=START..END entries=JSON`.
  - It does not list the copy `jarvis-session succeed` saves.
  - FILE is the file's path inside the archive.
  - START and END are the UTC minutes, `YYYY-MM-DDTHH:MMZ`, of the file's first and last record.
  - `progress-log --archived FILE` adds the line, and writes `unread` for both dates when the file's records cannot date it: no record, or an undated pre-cutover entry.
  - The [progress parser](../scripts/lib/progress.py) owns the compact JSON `entries` array.
  - Each entry carries its source line, recorded id and time, tracker ids and mailbox or Slack message ids.
  - The entry time locates a recorded ruling or lesson; it does not date a cited external source.
  - An unavailable id, full time or identifier list is `unread`; no records gives an empty array.
  - Search these facts in the index, then read FILE at the entry's line.
  - Further `key=value` fields are space-separated.
  - Date readers ignore fields other than `dates`.
- A pre-cutover entry keeps its recorded `HH:MMZ` as `time`, with its full `at` still `unread`.
- To import a retained index row, run `progress-log --archived FILE` with its available source archive, adding `--handoff PATH` when needed.
  - It enriches each matching FILE row in place and preserves its dates, file identity and other fields.
  - Repetition adds no row.
  - Preexisting duplicate rows keep their date-filter meaning.
  - Import leaves archive bytes intact and infers no facts from file names or modification times.
  - A missing or unreadable archive refuses with `archive-missing` or `archive-unreadable` and leaves the index unchanged.
  - Keep a file's row after pruning; its retained facts remain available, while source evidence is unavailable.
  - `owner-unanswered` skips a file whose END precedes its window and reads a file with no row or an unreadable END.
  - Listed files that are gone and inside the window print one `owner-unanswered: archive-pruned=COUNT first=PATH last=PATH` line, with the first and last paths in sorted order: the run goes on, and messages only those files covered are listed again.
- On each `EVENT owner-unanswered` the watch loop adds, answer the message it names, or record what was done about it in the progress log. [Control-host events: Delivery](control-host-events.md#delivery) states when the loop adds it.
- Before each scheduled-report write and before succession, run `.agents/skills/jarvis/scripts/progress-log --check-state`, adding the `--handoff PATH` that selects the current handoff when it is not the default. In that same write, apply [State retention](#state-retention) to the existing entries. Keep completion evidence on its tracker item. A `not-issue` ref binds no entry.
- Keep standing rules in one home. Link that home rather than repeating its text in the handoff.
- Remove a temporary instruction when its end event occurs. Remove its copied text when the instruction's standing home now states it.
- Apply [accounts-and-secrets.md:Secret transfer](accounts-and-secrets.md#secret-transfer) to handoff contents.

### Progress records

Write a record only for a decision, a state change, a send whose delivery or effect is uncertain, or a user message handled without a reply. An action whose evidence already lives in the tracker or a mailbox gets no record of its own; a record that relies on that evidence cites its tracker or message id rather than copying it. Use named fields for each record. Record values rather than a prose account that the successor must interpret.

| Field | Required content |
|---|---|
| Id and time | The durable record id and the clock time of the action. |
| Operation | The action and the session or tracker id it affects. |
| Observed result and source | The checked outcome and its source reference. Mark unread evidence as unread. |
| Decision | The chosen action and its reason. Link any recorded disposition under [Lane results](#lane-results). |
| State change | `set State ID NEXT ACTION`, `remove State ID`, or `none`. A set carries the complete replacement next action on one line. |

- Write each record with `.agents/skills/jarvis/scripts/progress-log --operation TEXT --result TEXT --decision TEXT --state-change TEXT`. It stamps the id and the clock time. An id is `P-` and the UTC time as `YYYYMMDDTHHMMSSZ`, with `-2`, `-3` added for later records in the same second. The State checkpoint's log range uses these ids.
- `--state-change 'set State KEN-123 Read the pending reply'` sets or replaces that entry as its id, one next action and the new progress record id. `--state-change 'remove State KEN-123'` removes it. `none` writes only the record. A durable id is a whitespace-free token; session-only entries may use `session=ID`, `wake=ID` or `ask=ID`. An existing entry names its id on its opening line; `KEN-123`, `KEN-123:` and `` `KEN-123` `` name the same entry. Multiple matching entries refuse without writing, and so does a remove that matches no entry. When State holds one key twice under two spellings, such as `- KEN-123: ...` and `- KEN-123:: ...`, the writer refuses every spelling of that key and the staged commit check refuses every commit in the home; delete the stale entry from State by hand, then commit the handoff. Preserve an open question's exact words in its next action, with its message id. Keep location, holds, wake registrations and report coverage in the session entries when replacing them. Replay each later record's State change with that record's id; a set replaces the whole earlier value and a remove deletes it.
- To retain a searchable session id, put a bare `session=ID` token in Operation or Decision, separated from other text by whitespace. ID ends at the next whitespace. The archive index keeps each explicitly named id in `sessions`; an absent token is `unread`. A plain number, UUID or other spelling supplies no session id. The archive index also reads this token from a pre-cutover entry's text.
- When the consumer's home contract names another handoff, add `--handoff PATH`, for example `--handoff state/jarvis/handoff.md`. Relative paths start at the home root, including when invoked from a subdirectory; absolute paths select that file. The selected file must exist and contain one Progress log section. Omitting the option selects `state/handoff.md`.
- A record about a user's message names the message's full id in Operation or Decision. When the record handles a request without a reply, its Decision says `no reply`. `owner-unanswered` then stops listing the message.
- `owner-unanswered` takes the same `--handoff PATH` and reads the selected handoff and the archive beside it. A missing selected handoff refuses `handoff-missing`; a missing default reads as no records. The watch loop reads the default handoff.
- Archive files may hold pre-cutover `- HH:MMZ ...` entries. `owner-unanswered` reads each entry and its indented lines as both Operation and Decision, in archive files only. Write new records with `progress-log`; nothing writes the old form.

### Lane results

Each lane result opens with an Answer section. Use one decision record per finding with these named fields.

| Field | Required content |
|---|---|
| Id | The durable finding id. |
| Question | The question this finding answers. |
| Observed result and source | What the lane checked and the source that supports the result. |
| Harm and condition | What can go wrong and the condition that permits it. State likelihood only when the source establishes it; otherwise mark it unknown. |
| Instruction | The relevant instruction and its owning source. |
| Proposed disposition | The action the lane proposes for this finding. |
| Uncertainty | Unchecked facts, unread sources or unresolved choices; none when there are none. |

- The parent records each final disposition and its evidence on the owning tracker item. Link that record from the lane result and the progress record that acts on it.
- For a durable ruling, follow [memory.md:Notes](memory.md#notes). Link its tracker item to the affected standing rule. A changed rule states only the resulting current instruction, without the session's disposition history.
- Keep only unresolved next actions in the handoff's State section. Keep completed findings and their disposition evidence in their homes under [Homes](#homes).
- Read the recorded disposition at its home before acting on a finding again.
