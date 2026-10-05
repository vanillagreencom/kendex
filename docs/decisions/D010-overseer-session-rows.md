# D010: An overseer's hook rows go to one file per session beside its mailbox

[← Decision Index](INDEX.md)

**Date**: 2026-09-27

**Status**: Active

**Research**: KEN-1960

**Decision**: An overseer's hook rows are JSON lines in `tmp/lane-mail/overseer/session-<tmux server pid>-<pane number>.jsonl`, one file per session key, in the mailbox directory lane mail already uses. Appends take the mailbox's own lock and line rules. The oversee state's `overseer.session_rows` names the file, and one function, `session_rows_overseer_file`, computes it for every writer and reader.

**Why**: A row in the outbound mail file reaches every mail reader as mail, and each missed filter sends a hook row to the owner. The pane key is the one identity a hook can name at session start, before any record names the session as the overseer.

**Rejected**: Rows in the mail file with a new envelope kind: every reader would need a filter. Rows keyed by session id: no reader holds the id before it reads a row.

**Revisit when**: Lane rows need one reader for mail and rows, or a harness other than tmux hosts the overseer.
