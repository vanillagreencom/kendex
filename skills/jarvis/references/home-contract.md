# Home contract

Read when starting a session, finding a memory note or updating its index row.

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
