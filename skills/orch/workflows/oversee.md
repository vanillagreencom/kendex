# Oversee

Standing fleet mode: burn down unblocked work items by launching one orch session per item and shepherding every PR to merge. The overseer launches, watches, unblocks, and merges — it never implements or reviews. It runs unattended: a blocked lane is the overseer's to unblock, not the user's to notice.

## 1. Resolve The Launch Surface

Once per session, first match wins:

1. `$TMUX` set → tmux lanes: launch each item with `open-terminal` (`handoff.md` § 2), a claude or codex item under § 3 Lane directive.
2. The harness ships session or thread launching (Codex threads, Claude Code agent teams, a desktop app's session tool or bundled skill) → use it: one managed session per item, carrying the same brief `open-terminal` would render.
3. Neither → no parallel surface. Say so once and work the queue sequentially in this session: `start [ISSUE_ID]` per item, § 2 selection between items.

A lane's questions arrive as `lane-question` and new tracker items as `triage`, both from the § 4 watch, on every surface. Only session banners are surface-specific: off the tmux surface, read them through the harness's own session tooling.

The owner sends the overseer a note without typing into its pane: `.agents/skills/orch/scripts/lane-mail send --item overseer --directive --file [PATH]`, run from any checkout of the project (`lane-mail --help`), and the § 4 watch reports it once as `owner-note`. A peer repository's overseer writes the same mailbox, reported as `peer-note` ([references/peer-mail.md](../references/peer-mail.md)).

Then read the overseer handoff file the fleet brief names (default `tmp/handoffs/OVERSEER-HANDOFF.md`): the prior session's live lanes, sequence and standing rulings. Absent, start from the tracker. `kendex apply` ignores the default path through `/tmp/`. For a custom path inside a repository, verify before the first read and each write that Git's index has no entry for the file and Git's ignore rules cover the path. If either check fails, stop and report the path. The handoff stays local to the overseer's host, which owns its disk or snapshot persistence, including paths outside a repository. § 5 rewrites it.

## 2. Select Work

Unblocked, non-terminal items from the tracker, gated exactly as `start.md` gates them (ancestor chain, blocker union, container rules). A GitHub item labeled `blocked` is not a candidate. An item whose `worktree create` exits 75 belongs to another session: skip it; its siblings still launch. On the tmux surface that claim IS `open-terminal`'s own worktree create — never pre-create the worktree. A surface that creates its own worktree environment (Codex app threads) records the claim in workflow-state before launch. Oversee runs as at most one session per repo. Read the lane cap and keep at most that many items in flight:

```bash
.agents/skills/orch/scripts/orch-env ORCH_OVERSEER_LANES 3
```

## 3. Launch

### Lane directive

A launch through `open-terminal` on the tmux surface for the claude or codex harness, whose launcher takes a lane config dir, takes these steps in order, local or on a remote control host. Every other surface or harness launches as § 1 says, with no inventory or pick.

1. Inventory: `lanes list`. On a control host the inventory is that host's login dirs.
2. Choose: `lanes pick --harness [HARNESS] --json`. Exit 3 means no lane qualifies, and nothing launches: read `lanes list`, wait only when its lanes are over the threshold, and report every `expired`, `unreachable`, `no_credentials`, `no_usage_data` or `error` lane to the operator. An `expired` lane is one whose token renewal failed; its `detail` names why. Every Claude account `expired` for a missing OAuth client id needs `ORCH_LANES_CLAUDE_CLIENT_ID`, set once per host.
3. Size: read the item's body once and make a quick judgement of its complexity (a colour, data, docs or bounded one-function fix; a mechanism change across one subsystem; a correctness predicate with several interacting writers or a review already past its round bound), pick the model that complexity needs, and write the model and that one-line reason beside `model` in the lane record below. Never pick a weaker model because the lane is near its wall: when the picked record's `headroom_pct` or `binding_bucket` says so, pick another lane, or wait for `binding_resets_at`.
4. Launch: the `handoff.md` § 2 `open-terminal` invocation plus `--lane [CONFIG_DIR]` from the picked record and the sized `--launch-flags`, one item per launch.

Placement: before each launch, read `lane-host resolve`; any value but `local` makes a hosted fleet. There every launch this directive makes adds `--host [HOST]`, and any other surface or harness is reported, never launched locally. `start` never launches a hosted lane: only `oversee` and `handoff` launch through `open-terminal --host`, so `/orch start [ISSUE_ID]` on a control host runs the item in that session. The credential reaches the sandbox per [schemas/lane-host.md](../schemas/lane-host.md) § Provider protocol, with no local `CLAUDE_CONFIG_DIR` prefix.

Per item, mint the brief `/orch start [ISSUE_ID]` (or `/orch start github [OWNER/REPO]#[N]`). The brief also carries question routing: "Every question for the overseer goes through `.agents/skills/orch/scripts/lane-mail` in this worktree, per [skill-rules.md § Coordination](../references/skill-rules.md#coordination): `lane-mail ask --item [ISSUE_ID] --file [PATH]`, then `lane-mail wait` on the printed id. Never use your harness's question tool. Read `lane-mail inbox --item [ISSUE_ID]` at every wait point." `/orch` slash syntax does nothing in Codex: a Codex CLI lane uses the form open-terminal renders — `Read .agents/skills/orch/SKILL.md and execute the orch start workflow for [ITEM]` — and a Codex Desktop thread uses `$orch start [ITEM]` (`handoff.md` § 2). Size launch flags to the item, read `[NOW]` for the lane record below, then launch on the § 1 surface.

A fleet brief can require user authorization for each merge with `ORCH_MERGE_AUTONOMY=ask`; `auto` stays the default. This setting is merge authorization, not an overseer validation grant. On the tmux surface set it in the overseer's tmux session before the first launch, so every lane window inherits it; on surface 2, pass it in the launcher's environment. The lane's merge question then reaches the overseer as `lane-question` ([oversee-events.md § Held merges](../references/oversee-events.md#judgement-rules)).

```bash
tmux set-environment ORCH_MERGE_AUTONOMY ask
```

The launch brief identifies the overseer and names `tmp/lane-status-[ISSUE_ID].md` and the mailbox `tmp/lane-mail/[ISSUE_ID]/`, both under the lane's worktree. It directs the lane to initialize and rewrite the status file with its current step, blocker, and handoff paths. The file holds at most 40 non-empty lines. The lane follows [skill-rules.md § Coordination](../references/skill-rules.md#coordination) for issue proposals and for every ask. For terminal launches, use `open-terminal --cmd` with the full harness command, chosen launch flags, and that brief. Record the status file's absolute path with the lane after launch.

### Recovery relaunch

A dead or walled terminal lane uses native resume. Start with the `handoff.md` § 2 terminal command. Add `--relaunch`, the selected `--lane`, and the chosen `--launch-flags`. Keep the tracker, repository, harness, and item arguments. Do not pass `--cmd`, because a custom command bypasses session lookup. A record carrying `host` adds `--host [HOST]`: the provider keeps its tree and the harness continues natively. After the harness resumes, use § Talking to a lane to send the continuation message that the recovery path requires.

Record the lane. Read `[NOW]` as `date -u +%Y-%m-%dT%H:%M:%SZ` before the launch it timestamps, never after; the first lane's value is the fleet start that § 4 passes as `--since`. First use only — when `exists` reports false, run `init` (init overwrites: never re-init a live lane log):

```bash
.agents/skills/orch/scripts/workflow-state exists --json oversee
```

```bash
.agents/skills/orch/scripts/workflow-state init oversee
```

Write `tmp/lane-record-[ISSUE_ID].json` with the harness file-write tool as this JSON object for a local lane:

```json
{"issue":"[ISSUE_ID]","surface":"[SURFACE]","model":"[MODEL]","model_reason":"[ONE_LINE_REASON]","launched_at":"[NOW]","status_file":"[ABSOLUTE_STATUS_PATH]","mail_root":"[LANE_WORKTREE_ON_ITS_OWN_HOST]"}
```

For a hosted lane, write this JSON object:

```json
{"issue":"[ISSUE_ID]","surface":"[SURFACE]","model":"[MODEL]","model_reason":"[ONE_LINE_REASON]","launched_at":"[NOW]","status_file":"[ABSOLUTE_STATUS_PATH]","mail_root":"[LANE_WORKTREE_ON_ITS_OWN_HOST]","host":"[HOST_SPEC]"}
```

```bash
.agents/skills/orch/scripts/workflow-state append-file oversee lanes tmp/lane-record-[ISSUE_ID].json
```

`mail_root` is the lane's worktree path as its own host sees it: the `path=` of a hosted lane's `tmux-opened` line. It is what § 4 passes as `--hosted [ISSUE_ID]=[MAIL_ROOT]` and `lane-mail send --root [MAIL_ROOT] --host` for a lane on another host; a lane on this host needs neither, and the record still carries the path. `host` is the hosted lane's `tmux-opened` `host=` value. Every later call for a lane whose record carries `host` runs with `ORCH_LANE_HOST` set to that value: `lane-mail --host`, `oversee-watch --hosted`, `lane-host cat`, `touch` and `close`.

## 4. Watch And Advance

One repeat-mode command watches for the whole session, passed the fleet's start as `--since` (the first lane's `launched_at` — the same value on every pass, never "now"), `--repo` for every repository the fleet has PRs in, `--items-file` naming a file that holds every live item, and `--windows-file` naming a file that holds every live lane's tmux window name, as `session:window` when the lane lives in another tmux session (none on a non-tmux surface), one per line. Each pass prints every event it found as one block, in the shape `oversee-watch --help` states, so no kind starves another — handle every line. An `EVENT` line on stdout is handled even when its pass exits non-zero: handle it and fix what stderr names; the next pass starts after the `--repeat` delay. The command does not exit on its own: run it in the background for the session and read its output as it arrives. The watch re-reads both files before every pass: add a launched lane's item and window, and remove a merged local item and a dead lane's window. A merged hosted item keeps its item, its window and its `--hosted` entry until the watch reports `lane-closed` or `lane-close-refused` for it. The watch reads `--hosted` only when it starts, and stops on an entry whose item the items file does not hold: when a lane on another host joins or leaves, change its item in the items file and start the watch again with its `--hosted [ISSUE_ID]=[MAIL_ROOT]` entry added or removed. When the watch exits, fix what stderr names and start it again. Never hand-roll a monitor. Without the review-gate skill the watch skips its pr-watch step and `gate-stale` is invisible ([references/gates.md](../references/gates.md) § Multi-PR watching); `LINEAR_TEAM` arms triage, so a fleet on a repo tracking its work elsewhere runs the same command and is told once on stderr that triage is off; a repeated pr-watch line is context appended to the next event rather than an event of its own (`oversee-watch --help`). A PR in a repo no `--repo` names is unwatched, so a fleet shepherding work into consumer repos names each of them, the repo holding the items FIRST: `merged` and the heartbeat's open-PR list read every one, each line naming its repo, and the first one's baseline holds the triage, lane and merged rows.

```bash
.agents/skills/orch/scripts/oversee-watch --repeat 60 --items-file tmp/oversee-items.txt --windows-file tmp/oversee-windows.txt --interval 240 --since [FLEET_SINCE] --repo [ITEMS_REPO] --repo [OTHER_REPO]... --hosted [ISSUE_ID]=[MAIL_ROOT]...
```

Pass `--hosted [ISSUE_ID]=[MAIL_ROOT]` for every lane whose record carries a `mail_root` on another host, and omit it for the rest. The mail pass reads each lane's mailbox, never a pane, so it runs on every surface and outside tmux.

### Bounded lane reads

Use the pane tail that `oversee-watch` prints as the lane state. It already contains at most the last 40 non-empty lines. Do not capture the pane again when that tail answers the event. When the tail does not answer it and what you need is the lane's state rather than its text, run `lanes state [ITEM]`: it prints one of `working`, `idle`, `asking`, `walled`, `exited` or `unjudged` from the same judge the watch and the wake ask, reading the lane's pane as the watch does. `unjudged` means the pane settled nothing, not that a wake would be refused: the wake reads the harness process as well, so it can still answer where this cannot. `idle` is likewise the pane's word alone, and a wake that reads the harness process as busy or as unreadable refuses the same lane. For a fresh status-file read, use `cp` locally or `lane-host cat` after a successful `lane-host touch` probe on a hosted lane. Run one source line, then the shared filter. Run each line in a separate tool call. The redirection keeps a hosted file out of the overseer until the filter emits its last 40 non-empty lines. A failed probe, source read, or filter stops the event. Never read a lane transcript.

```bash
cp -- [STATUS_FILE] tmp/oversee-lane-status-source
.agents/skills/orch/scripts/lane-host cat --item [ISSUE_ID] [STATUS_FILE] > tmp/oversee-lane-status-source
awk 'NF {line[++count]=$0} END {first=count-39; if (first < 1) first=1; for (i=first; i<=count; i++) print line[i]}' tmp/oversee-lane-status-source
```

### Bounded issue reads

For each `triage` or `heartbeat` pass, replace `[AGE]` with an `Nd` value that covers the fleet start and run each code line in a separate tool call. The first line redirects the complete response to ignored scratch storage, so no issue body enters the overseer. The second line is the only issue-list result the overseer reads. It emits each identifier, title, and `## Done when` body. The last line removes the complete response.

```bash
.agents/skills/linear/scripts/linear.sh issues list --team [TEAM] --created-since [AGE] --max --format=raw > tmp/oversee-triage-source.json
jq '[.issues.nodes[] | {identifier, title, done_when: ((("\n" + (.description // "")) | gsub("\r\n"; "\n") | split("\n## Done when\n")) as $sections | if ($sections | length) > 1 then ($sections[1] | split("\n## ")[0] | gsub("^[[:space:]]+|[[:space:]]+$"; "")) else "" end)}]' tmp/oversee-triage-source.json
rm -f tmp/oversee-triage-source.json
```

### Judgement at every event

- Judgement rules for every event: [oversee-events.md § Judgement rules](../references/oversee-events.md#judgement-rules).
- Handling per event kind: [oversee-events.md § Event kinds](../references/oversee-events.md#event-kinds).

### Talking to a lane

Answering and directing are the same two commands on every harness and every surface, inside tmux or not. Add `--root [MAIL_ROOT] --host` for a lane whose record puts it on another host.

```bash
.agents/skills/orch/scripts/lane-mail send --item [ISSUE_ID] --re [MESSAGE_ID] --file [PATH]
```

```bash
.agents/skills/orch/scripts/lane-mail send --item [ISSUE_ID] --directive --file [PATH]
```

Text crosses `--file` ([SKILL.md](../SKILL.md) § Harness-Safe Shell). A directive answers no ask and `--halt` in place of `--directive` halts the lane; the Lane mail rule in [skill-rules.md](../references/skill-rules.md) says when each reaches it. A lane whose turn already ended reads neither, so wake it after the send. Keep the lane's tracker, repository, harness, item, `--lane` and `--launch-flags` arguments. The wake resumes the lane's own session with one line that runs `lane-mail inbox`, and reaches only lanes on this host; it wakes a lane only when the shared judge calls it `idle`, and refuses any other state as `wake-refused reason=[STATE]`, so halt the lane or wait. Never send a lane text by keystroke.

```bash
.agents/skills/orch/scripts/open-terminal --wake --harness [HARNESS] [ISSUE_ID]
```

What stays per harness is launching, resuming and the harness's own dialogs; the Pi commands are the pi-session-bridge CLI, documented in its [README](https://github.com/vanillagreencom/kendex/blob/main/pi-extensions/pi-session-bridge/README.md) and `pi-bridge --help`, and every Pi call selects the lane by `--name` or `--cwd`.

**Pane paste.** Write the text to a file with the harness file tool. Run `tmux load-buffer <file>`, then `tmux paste-buffer -p -d -t <pane>`. Before each `Enter`, read `tmux display-message -p -t <pane> '#{pane_in_mode}'`. If it prints `1`, run `tmux send-keys -t <pane> -X cancel` and read the mode again. Send `tmux send-keys -t <pane> Enter` only when the mode reads `0`.

| Harness | Launch | Read state | Answer a harness dialog |
|---------|--------|------------|-------------------------|
| Claude Code | `open-terminal` into a tmux pane (§ 3). In a tmux pane, a first launch in a folder the wrapper has not trusted shows a trust prompt with "No, exit" selected: `Down`, `Enter`, then relaunch. | Follow § Bounded lane reads. | Move the dialog with the arrow keys and press `Enter` in the lane's pane; the recorded choice line confirms it. The rm-safety prompt ("Dangerous rm operation on possibly-empty variable path") fires even under bypass: read the command, and `Enter` on Yes when it stays inside the lane's own worktree. |
| Codex | `open-terminal` into a tmux pane (§ 3). | Follow § Bounded lane reads. | Type the number the dialog shows into the lane's pane, at the idle prompt. |
| Pi | `open-terminal` into a tmux pane (§ 3). | Follow § Bounded lane reads. Use `pi-bridge state` only when the event has no lane tail; never use `history` or `stream`. `pi-bridge questions` lists a pending dialog with its request id. | `pi-bridge answer` on the selected lane with that request id and the option label, never the pane: a typed number lands on the default option. |
| App or other | The session or thread launcher the harness or an app-specific skill exposes (§ 1). | Use its API or tooling to read only the bounded state that explains the event. | The API or tooling that surface exposes; a pane at its idle prompt only when nothing else exists. |

A lane under a session limit still needs its one-line continuation nudge pasted into its pane at the reset through Pane paste above, since a walled harness runs no turn and so reads no mail; the launch brief and a harness dialog's answer reach a pane the same way, and nothing else does.

A lane never arms the shared git hooks from its worktree; a guard-script PR whose new chain refuses the branch under main's installed scripts is a one-time transition the overseer sequences.

**Resuming a dead or walled lane.** Use § 3 Recovery relaunch, which resumes the item's newest session natively per `open-terminal --help` § `--relaunch`; a hosted lane has no local transcript lookup. Send one message after launch to re-arm the lane's waiters.

## 5. Stop

Queue empty, or the user stops it. On a hosted fleet, stop only when `lane-host list` has no row but `available`, or name each such host. Report one line per lane: merged SHAs, still-open PRs, items skipped as owned or blocked. Reapply the § 1 handoff-path check before rewriting the overseer handoff file in place for the next session, and delete stale per-session handoff files beside it at that rewrite, never leave them.
