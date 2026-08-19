# Changelog

## Consumer-impacting changes

### 2.8.7

- The completion poller no longer re-reads terminal transcripts every tick
  (vstack#1453). Fingerprints are keyed on the attempt, so a terminal
  transcript is parsed once and again only when its bytes change. A 17h session
  with 70MB of transcripts had been sitting at ~30% CPU while idle.

### 2.8.6

- The idle-stall watchdog skips panes with a pending rate-limit retry instead
  of condemning a throttled agent as a post-compaction stall (VST-361). The
  synthetic summary now states its cause as undetermined rather than asserting
  a hang it never verified.

### 2.8.5

- The Transcript timeline reads the nested `toolCall`/`tool_call` end-event
  carrier, so a nested end no longer renders as `✖ no result recorded` beside a
  separate neutral row, and a snake-case error flag no longer reads as success.

### 2.8.4

- The Agents popup Transcript tab renders an event timeline instead of raw
  JSONL (VST-327): one row per event, tool calls collapsed into a single
  start/result row, errors `✖`-marked, and no event type falling through to a
  raw line.
- The tail read grew 24 KB → 256 KB, cuts on a line boundary, and states how
  many earlier events were dropped.
- Decoded text is scrubbed of terminal control sequences before rendering.
- New `e` key opens the item's file in `$VISUAL`/`$EDITOR`.

### 2.8.3

- Agents popup times are run-times, not machine stamps (VST-316). Task rows
  show elapsed run-time instead of a local clock that was ambiguous and jumped
  on registry polls; `updatedAt` is no longer a time-of-day source.
- Detail panes render local human time instead of UTC ISO, and the Task Summary
  gains a Duration line once terminal.

### 2.8.2

- Oneshot transcript records are written in event order (vstack#1311). Separate
  concurrent appends could land out of order, so `getFinalOutput` reported the
  wrong message. A failed write now surfaces as a diagnostic instead of being
  dropped.

### 2.8.1

- Child spawning no longer trusts `process.argv[1]` as the pi entry
  (vstack#192). The resolved entry is verified before use, and the spawn fails
  with a stated reason rather than launching the wrong binary.

### 2.8.0

- Pi 0.84.0 parity: the failed-bg-agent transcript flush rebuilds the partial
  assistant message, so a failed run's output is recorded rather than lost.

### 2.7.1

- Bg one-shot tasks complete promptly after Pi emits `agent_settled`, instead
  of waiting out the poll interval.

### 2.7.0

- Baseline: changelog introduced at this version. Consumer-impacting changes
  are recorded here from this version forward.
