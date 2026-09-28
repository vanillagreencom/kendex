# D010: An overseer's hook rows go to one file per session beside its mailbox, not into its outbound mailbox file

[← Decision Index](INDEX.md)

**Date**: 2026-09-27

**Status**: Active

**Research**: —

**Applies to**: `skills/orch/scripts/lib/session-rows.sh`, `hooks/lane-mail-check.sh`, `skills/orch/scripts/oversee-watch`

## Context

KEN-1960 moves the overseer's death and wall detection off its pane and onto rows its harness's hooks emit. The item's settled transport says the rows go "through the lane-mail transport, the session's outbound mailbox file". For the overseer that file is `tmp/lane-mail/overseer/to-overseer.jsonl`, which holds the owner asks it sent. `lane-mail drain`, `pending`, `events`, the owner relay and `oversee-report` read that file, and each treats every line as mail. A lane's `to-overseer.jsonl` is drained whole by the watch's mail pass and reported line by line.

A hook also writes its row at SessionStart, before any record names the session as the overseer, so the row has to be keyed by something the hook knows by itself.

## Decision

1. Rows are JSON lines in `tmp/lane-mail/overseer/session-<tmux server pid>-<pane number>.jsonl`, one file per session key, in the overseer mailbox directory lane mail already uses.
2. Appends take the mailbox's own lock and line rules (`lib/mailbox-append.sh`). The directory is the transport. The mail files stay mail.
3. The oversee state's `overseer.session_rows` names the file, and `oversee-watch` reads the path from the record. The one function `session_rows_overseer_file` computes it for the hook's writer, the record writers, `oversee register` and `oversee-succeed`.

## Rationale

- A row in `to-overseer.jsonl` reaches every mail reader. It would need a kind filter in `drain`, `pending`, `events`, the relay and the report, and each missed filter sends a hook row to the owner as mail.
- The pane key is the one identity a hook can name at SessionStart, and it is the pair the fleet state already keys the overseer on.
- A hosted session's mailbox directory reaches the watch the way its mail does, so the one-transport design of KEN-1659 still holds for the directory.

## Alternatives Considered

- Rows in `to-overseer.jsonl` with a new envelope kind: rejected for the reader count above.
- Rows keyed by `session_id`: rejected, because no reader holds the id before it reads a row, and the record keys the session by its pane.

**Revisit When**: KEN-1961 routes lane rows and needs one reader for mail and rows, or a harness other than tmux hosts the overseer.

**Verification**: `bash hooks/tests/session-rows.test.sh`; `bash skills/orch/tests/run-all.sh =oversee_watch_overseer_rows`.

**References**: KEN-1960, KEN-1659, KEN-1961
