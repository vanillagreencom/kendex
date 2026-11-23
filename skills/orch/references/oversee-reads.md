# Oversee reads

Read when [oversee.md § 4](../workflows/oversee.md#4-watch-and-advance) handles an event whose entry in [oversee-events.md § Event kinds](oversee-events.md#event-kinds) reads a lane's state or status file, or before any read of a lane's pane or transcript or of the watch log for an event (§ Bounded lane reads), and at each `triage` pass and the triage backstop at `heartbeat` (§ Bounded issue reads).

## Bounded lane reads

- Take the pane payload the watch prints as the lane's state.
- Never read the log's tail to handle an event: the follow delivers each line once.
- Each event carries only the lines its handling reads, from below the lane's last user turn, capped by `ORCH_WATCH_TAIL_LINES` ([settings.md § Fleet watch](settings.md#fleet-watch)); [oversee-events.md § Event kinds](oversee-events.md#event-kinds) says which.
- Do not capture the pane again when that payload answers the event.

When it does not, read the lane's state.

- The item key selects its one in-flight record.
- `result.state` is the lane's state.
- An unreadable observation carries its cause and never means an exited lane.
- [lane-reach.md § Lane states](lane-reach.md#lane-states) holds what each state licenses.

```bash
.agents/skills/orch/scripts/orch-runtime lane status --item [ITEM]
```

For a fresh status-file read:

1. Copy the file locally. On a hosted lane, read it through its provider after a successful `touch` probe.
2. Run the source line, then the filter, each in its own tool call. The redirect keeps the file out of the overseer's context; the filter prints only its last 40 non-empty lines.
3. A failed probe, read or filter stops the event.
4. Never read a lane transcript.

```bash
cp -- [STATUS_FILE] tmp/oversee-lane-status-source
.agents/skills/orch/scripts/orch-runtime host --host [HOST] touch --item [ITEM]
.agents/skills/orch/scripts/orch-runtime host --host [HOST] cat --item [ITEM] [STATUS_FILE] > tmp/oversee-lane-status-source
awk 'NF {line[++count]=$0} END {first=count-39; if (first < 1) first=1; for (i=first; i<=count; i++) print line[i]}' tmp/oversee-lane-status-source
```

## Bounded issue reads

For each `triage` pass, and the triage backstop at `heartbeat`:

1. Replace `[AGE]` with an `Nd` value that covers the fleet start.
2. Run each line in its own tool call.
   - The first line redirects the whole response to ignored scratch storage, so no issue body enters the overseer.
   - The second prints the only issue-list result the overseer reads: each identifier, title and `## Done when` body.
   - The last removes the response.

```bash
.agents/skills/linear/scripts/linear.sh issues list --team "[TEAM]" --created-since [AGE] --max --format=raw > tmp/oversee-triage-source.json
jq '[.issues.nodes[] | {identifier, title, done_when: ((("\n" + (.description // "")) | gsub("\r\n"; "\n") | split("\n## Done when\n")) as $sections | if ($sections | length) > 1 then ($sections[1] | split("\n## ")[0] | gsub("^[[:space:]]+|[[:space:]]+$"; "")) else "" end)}]' tmp/oversee-triage-source.json
rm -f tmp/oversee-triage-source.json
```
