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

A fleet brief can require user authorization for each merge with `ORCH_MERGE_AUTONOMY=ask`; `auto` stays the default. This setting is merge authorization, not an overseer validation grant. On the tmux surface set it in the overseer's tmux session before the first launch, so every lane window inherits it; on surface 2, pass it in the launcher's environment. The lane's merge question then reaches the overseer as `lane-question` (§ 4 Held merges).

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

Use the pane tail that `oversee-watch` prints as the lane state. It already contains at most the last 40 non-empty lines. Do not capture the pane again when that tail answers the event. For a fresh status-file read, use `cp` locally or `lane-host cat` after a successful `lane-host touch` probe on a hosted lane. Run one source line, then the shared filter. Run each line in a separate tool call. The redirection keeps a hosted file out of the overseer until the filter emits its last 40 non-empty lines. A failed probe, source read, or filter stops the event. Never read a lane transcript.

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

The overseer owns fleet judgement, not just liveness; every § 4 event is handled under these rules:

- **Lane proposals.** Record each lane's `Proposal comment:` notice in the fleet log as an authorized tracker, repository, issue, and returned comment ID or URL binding. Partition pending authorized comments by tracker and source PR repository. For each batch, mint a fresh tracker-valid launch item from the UTC epoch, such as `KEN-[UTC_EPOCH]` for Linear or `[UTC_EPOCH]` for GitHub; record the launcher's carrier ID, and never use a fleet issue identity. On the § 1 terminal surface, run the low-cost TPM [proposal-sweep](../../project-management/workflows/proposal-sweep.md) lane from the source repository with `open-terminal --cmd`. On the managed-session surface, use its native launcher with the same fresh identity, source-repository checkout, low-cost model, and brief. On the no-parallel surface, defer the batch until a parallel surface exists; never run its TPM analysis in the overseer. The brief supplies the batch tracker, tracker repository, source repository, issue IDs, authorized and resolved comment bindings, status file, and mailbox. Add `[CARRIER_ID]` to the watch's items file; for a hosted terminal sweep, also start the watch again with its `--hosted [CARRIER_ID]=[MAIL_ROOT]` entry, per § 4. Wait for its `lane-notice` whose text, with the watch's two-space indent removed, is exactly `Proposal sweep complete: [STATUS_FILE]`; read no output file before that durable event. Read the status through § Bounded lane reads. For a hosted terminal sweep, use `lane-host cat` after the successful probe to transfer the audit. On the managed-session surface, use its native file transfer. Stop on any failure. Put the audit bytes at `tmp/proposal-audit-[CARRIER_ID].json` in the overseer's checkout; for a local terminal sweep, copy the named audit there. Read no verification text. Check the local rows against live fleet work, then invoke [audit-issues](../../project-management/workflows/audit-issues.md) from § 1 as `audit-issues --analyzed tmp/proposal-audit-[CARRIER_ID].json` under `PM_CREATE_AUTONOMY`. Its normal route parses the tracker, runs its tracker preflight and label inventory, skips TPM analysis, and continues through §§ 5-7. For Linear, reply with `.agents/skills/linear/scripts/linear.sh comments create [ISSUE_ID] --parent [COMMENT_ID] --body-file [PATH]`. For GitHub, use `gh issue comment [NUMBER] --repo [OWNER/REPO] --body-file [PATH]`; its first line is `Proposal outcome for [COMMENT_URL]:`. Each outcome carries the created issue ID or one-line decline. Record the source and outcome in the fleet log. After transfer, close the hosted terminal with `.agents/skills/orch/scripts/lane-host close --item [CARRIER_ID]`, the local terminal with `tmux kill-window -t [SWEEP_WINDOW]`, or the managed session with its native close. Remove a terminal checkout with `.agents/skills/worktree/scripts/worktree remove [CARRIER_ID]`; use native checkout disposal on the managed surface. A failed close or removal blocks the next batch; record successful disposal.
- **Heartbeat backstop for lane proposals.** Include every fleet issue in its tracker and repository batch at each `heartbeat` and before fleet close. This catches a comment posted without another event. Never reuse a sweep identity. Record its disposal before the next batch.
- **Cut scope blowups.** A PR whose diff outgrows its issue's Done-when goes back to the contract: keep the oversized work on a branch, land the contract. Machinery no issue ordered — a new subsystem, scanner, or lexer — is cut, never reviewed into shape.
- **End spirals.** A round whose finding shares a root cause with one a prior round patched is dispositioned by [references/finding-disposition.md § Recurrence](../references/finding-disposition.md#recurrence), which states the branches and their limits. Bots drip-feeding one class get the class exhausted in one audit pass, then dispositions without pushes. After five bot rounds on one PR, the lane answers the standing threads once and starts no further fix round. The review gate and the user's merge authorization still apply. The overseer never orders a blanket `Declined` across a PR's open findings: each one is dispositioned on its own mechanism, and a decline that is nothing but a label turns the gate red.
- **Fix the source.** The same finding class on a third PR is a mechanism gap: file it and route the smallest deterministic check (a guard lane, a preflight rule, a refusing script) or one sentence in the owning skill through a lane as its own item — the overseer still implements nothing. Deterministic beats prose where it stays simple; complex or brittle machinery is worse than either.
- **Rule once for the fleet.** A ruling that answers one lane's question is sent to every lane in the same situation and recorded in the fleet log.
- **Held merges.** Under `ORCH_MERGE_AUTONOMY=ask` (§ 3) the lane's merge question arrives as `lane-question`. Read the gate results without reproducing them, then relay the question to the user. Send `MERGE` to the lane only after the user authorizes it, or send exactly one directive the user gave. A directive may carry the authorization ("with that landed, MERGE stands"), and the lane then merges once the change is in without a second answer. Under `ask` a `disarmed` pr-watch line is not a wake.
- **Hand off a lane before it runs out.** On the § 1 tmux surface, at every § 4 event, read each live lane's context use:

  ```bash
  .agents/skills/orch/scripts/lanes context
  ```

  `lanes context` reports each lane's context use and marks its handoff required at the `ORCH_HANDOFF_HEADROOM_PCT` threshold, per `lanes --help` § `context`. At each event, tell every required lane to write its handoff at the next safe point, as for the context mark. Use § Talking to a lane until lane mail is installed; then send the directive through lane mail. The context mark is `CONTEXT_TOKENS` past about 500000. At either mark, wait for a safe point such as a landed merge or held PR. Never interrupt a round or an unpushed tree. The lane records the fixed shape below and exits. The watch reports `handoff [ISSUE_ID]` once. Relaunch the item through § 3 Recovery relaunch, which uses the handoff record as durable recovery state.

  ```bash
  .agents/skills/orch/scripts/workflow-state set [ISSUE_ID] handoff '{"written_at":"[NOW]","merged":["[PR]"],"remaining":["[STEP]"],"branch":"[BRANCH]","worktree":"[WORKTREE_PATH]","open_pr":[PR_NUMBER_OR_NULL],"traps":["[TRAP]"]}'
  ```

  The record, the event and the relaunch are surface-independent. Surfaces 2 and 3 register no lane claim, so `lanes context` reports no worker lane there: on surface 2 read a lane's context through the harness's own session tooling and hand off at the same mark; surface 3 has no lane to hand off.

  On a hosted fleet, also run `lane-host list`: a row not `available` whose item, the last segment of repository/item, is not in the items file is a sandbox with no live claim; surface it to the user.

  The overseer's own case: its own pane is in the `lanes context` report, claim or no claim. On a 1M-window overseer past the context mark, wait for a safe point with no `merged` event mid-handling and no lane waiting on a root answer. Rewrite the overseer handoff file per § 5, then run `.agents/skills/orch/scripts/oversee-succeed -- [FLAGS]` under a shell-tool timeout longer than its `--wait-secs`. `[FLAGS]` are the permission flags this overseer runs under, plus its own model and effort flags when `ORCH_OVERSEER_PREFERENCE` is empty. Add `--handoff [PATH]` when the fleet brief names another handoff path. It opens the successor overseer on the first `ORCH_OVERSEER_PREFERENCE` entry with a qualifying lane and closes this window. On `context-below-mark`, keep running and run it again at a later event. On `succession-off`, `window-below-mark` or a refusal, keep running and hand off by hand: tell the user the handoff file is written and a fresh overseer session must start.

- **Decide without the user.** SKILL.md's ask gates stand unchanged — scope expansion, recorded decisions, and merge autonomy still ask. Any other reversible call takes the option that costs nothing, recorded in the fleet log; destructive actions and product direction wait for a human.


- `merged` → the PR is in; the owning lane finishes `merge-pr.md` § 5 on its own and a GitHub merge alone is not lane completion. A hosted item stays in the watch until its `lane-closed` or `lane-close-refused` event, per § 4. Wake it only if it is not still inside that run, and read a reported failure there rather than advancing the item. On a hosted fleet the base checkout is the control host: run `.agents/skills/orch/scripts/sync-base` and `kendex refresh --scope project --yes --leave` there; CI and the lane ran build and verify. Otherwise, in the overseer base checkout, run `.agents/skills/orch/scripts/post-merge`, then the repo's lifecycle check. Stop on a failed step and report its status. Either way, classify the paths from `git diff --name-only [MERGE_COMMIT]^..[MERGE_COMMIT]` against the source-catalog layout from the repository's `kendex.toml`: the manifest itself, the configured or default skill and agent directories, and the format's fixed directories for other package kinds are shipped paths. A match runs [consumer-train.md](consumer-train.md) after those steps, with `MERGED_RANGE` bound to `[MERGE_COMMIT]^..[MERGE_COMMIT]`. When the fleet's LAST item completes, run the `heartbeat` triage pass before closing out, whatever the tracker; items living in Linear also get `.agents/skills/orch/scripts/reconcile-work-items` (a GitHub-item fleet skips that with a note). Report both with the close-out.
- `lane-exited` → the window is alive but the harness under it is gone (its pane tail says why). A lane stopped by a harness session limit ("You've hit your session limit · resets 9:50am") is not dead: resume it under another auth lane (`lanes pick`, then § 3 Recovery relaunch), or wait for the shown reset and use Recovery relaunch on the original account. Send the one-line continuation message after resume. A lane that reported `handoff` on an earlier run is relaunched per that event, not resumed or nudged. Any other exit is the `window-gone` rule below.
- `handoff` → the item's lane recorded its handoff and exited: relaunch it per § 4 Hand off a lane; the record follows the event line.
- `lane-closed` → the watch closed the merged hosted lane's sandbox through `lane-host close`: record the `kept=` line that follows in the fleet log, the provider's `kept=PATH` or the watch's `kept=none` for a close that archived no tmp records.
- `lane-close-refused` → `lane-host close` exited 3: a checkout of the merged hosted lane, its clone or its worktree, has uncommitted files and the sandbox stays: surface the `path=` line that follows to the user. Never run `lane-host close --force`.
- `usage-limit` → read the pane tail first and confirm the banner is the harness's own, not text the lane printed while working; a lane still working is left alone. Confirmed: keep the window and its watch registration while selecting a replacement. Run `lanes pick` for the same harness first. When a lane qualifies, kill the old window and use § 3 Recovery relaunch on the selected lane. When no lane of that harness qualifies, pick another terminal harness. When that lane qualifies, kill the old window and launch with the one-sentence continuation brief from `handoff.md` § 2, including the matching path from the prior harness's transcript store. When no replacement qualifies and the event has `resets=`, keep the old window and wait for that reset. The window then announces `usage-limit-passed`, and the overseer sends its one-line continuation nudge. A `resets=` pinned from a clock or weekday is an upper bound, so read the tail. Never launch onto the spent account again until its reset, and never park a lane against an estimate of your own when `resets=` states the time. A parked lane stays in the watch: its window is what announces the reset, as `usage-limit-passed`. A wall reported without `resets=` is announced once and nothing announces it again, so select another account on that event. If none qualifies, report the blocked recovery and keep the old window until a replacement qualifies.
- `usage-limit-passed` → read the pane tail first, as for `usage-limit` above: a lane still working is left alone. Confirmed, the wall named by `resets=` has already lifted and the lane is still sitting under the old banner. Send it a one-line continuation nudge; do not move the item and do not wait. The nudge is the whole remedy: this event never licenses a fresh launch onto that account, and a nudge that does not take means the wall still stands.
- `model-capacity` → resend one continuation line through Pane paste; the next pass watches the lane again. Never relaunch the lane: the selected model stopped one turn, not the session.
- `idle-after-return` → read its pane tail. A lane that has returned is available for another fleet launch; a lane still inside `merge-pr.md` § 5 step 1 is blocked on its queue wait, which reads as work in flight rather than idle. A directive for an idle lane is sent and then woken per § Talking to a lane.
- A lane whose session ended AFTER its PR merged but before `merge-pr.md` § 5 steps 2-6 finished → relaunch it into `merge-pr [PR_NUMBER]`. That run's already-merged route skips the merge and runs the tracker sync, project verification and worktree removal the dead lane never reached. The rule below does not reach this lane: its PR did merge.
- `window-gone`, or any lane whose session ended with no merged PR → inspect its worktree and PR state, then re-launch once with the same brief through § 3 Recovery relaunch. Without `--relaunch`, the existing worktree reads as another session's claim and the item is skipped. The launcher starts from the normal brief only when no matching transcript exists. A second death is surfaced to the user, not retried.
- `lane-question` → the lane's own question, and the only shape one arrives in. Answer it when available evidence already decides it, apply the ruling, record it in the fleet log, and send the answer back per § Talking to a lane. Repo state, the issue body, a stated convention, scope-narrowing calls, and a lane's own well-argued recommendation are available evidence. Relay any other question to the user only when it changes the product for a user or spends the owner's standing (retiring a reviewer, filing outside the repo, closing as won't-do). A merge question under `ORCH_MERGE_AUTONOMY=ask` follows Held merges above and always goes to the user. Every emitted question is answered: the lane is blocked in `lane-mail wait` on this line. An overseer resuming a fleet reads what it still owes with `lane-mail pending --item [ISSUE_ID]`, adding `--root [MAIL_ROOT] --host` for a lane whose record puts it on another host.
- `lane-notice` → the lane reported something it is not waiting on. Act on it where it needs acting on; it needs no reply.
- `owner-note` → the owner's note to the overseer; its text follows. Every text and `options:` line under `lane-question`, `lane-notice`, `peer-note` and `owner-note` is indented two spaces, so only a watch record begins with `EVENT`. Act on it, or record it in the fleet log as a ruling; it needs no reply.
- `peer-note [REPOSITORY] [ID]` → a peer repository's overseer wrote to this one; its text follows. Answer it, or put a question to a peer, per [references/peer-mail.md](../references/peer-mail.md). Record the exchange in the fleet log.
- `lane-asking` → a harness dialog, never a question for the overseer: a permission prompt, a trust prompt, a model picker. Answer it in the lane's own dialog per § Talking to a lane.
- `triage` → team-wide: run § Bounded issue reads and set `[ISSUES]` to the emitted identifiers. Launch one fresh canonical `generalist` verifier with the source repository and the lowest-cost model the surface exposes. The launch call is Claude's generated-agent tool, Codex `spawn_agent` after `scripts/spawn-adapter spawn generalist` followed by `send_input`, OpenCode `functions.task`, or Pi `subagent`, as [SKILL.md § Runtime Notes](../SKILL.md#runtime-notes) specifies. On the terminal surface, call it from the overseer session. On the managed-session surface, use that surface's native call. In sequential mode, make the same call and wait for it before resuming. Send this literal task: `Verify only these Linear issues: [ISSUES]. For each issue, read its full body and source, apply the filing bar regardless of lane authorship, post the full evidence as one Linear comment on that issue, write no report or evidence file, and return only this row: [ISSUE] | verdict: [kept|canceled] | owner: [REPO_PATH_OR_NONE] | Done-when: [ONE_LINE_RESULT] | delta: [EXPECTED_DELTA_LINE_OR_NONE].` Capture only the single final return defined by [skill-rules.md § Single Return Message](../references/skill-rules.md#single-return-message). Accept it only when it contains no other text and has exactly one row for every requested issue, no duplicate or unrequested issue, each required field, and only a `kept` or `canceled` verdict. Stop without writing `triaged` on a launch, capture, parse, or validation failure. Route each valid kept item or cancel it, record the terminal verdict in the fleet state's `triaged` list; every pass emits the item again until that record exists. triaged is the verdict log, not the watcher baseline. The watcher rebuilds acknowledged triage keys from it in the first repository's OVERSEE_WATCH_STATE_DIR baseline; the default directory is `<project-root>/tmp/oversee-watch`. Deleting that baseline resets watcher dedup: the next pass rebuilds terminal keys, while pending items emit again.
- `pr-watch` → handle every attention line. What each kind MEANS is `pr-watch.sh --help`; what follows is only what the overseer does about it. A detail ending in `(QUEUED: dequeue before pushing)` rides several kinds and outranks all of them: the lane dequeues before it can push anything.
  - `gate-stale` → healed only where a `heal-dispatched` line rides the same reduction. The reducer re-dispatches on every pass the line stands, so a standing line is dispatch-to-converge lag, not a queue of work: judge it on whether the dispatched writer run COMPLETED, never on a pass count, and read a cancelled pending duplicate in the writer's concurrency group as ordinary lag too. A standing line comes back only as reducer output appended to the next wake or heartbeat, never as a fresh event. Beside an `error` naming a failed writer dispatch, nothing was healed and the once-per-invocation budget is spent, so no other stale PR got a dispatch either: fix the dispatch path for the repo the line names before waiting on another pass, the workflow name against `PR_WATCH_WRITER_WORKFLOW`, `actions:write` on the credential, Actions enabled on that repo.
  - `heal-dispatched` → the reducer's note that this invocation's one dispatch fired. Nothing to do, and never an event on its own.
  - `threads-open` → verify the count against the API, then wake the owning lane with it.
  - `changes-requested` → wake the owning lane: a standing objection is the lane's to answer, never the overseer's to dismiss.
  - `untracked-claim`, `unreasoned-decline` → wake the lane to rewrite the reply per [references/finding-disposition.md](../references/finding-disposition.md); the gate stays red until it does.
  - `suppressed-findings` → wake the lane with the file:line list on the line: the reviewer wrote those findings into its review body, so no thread carries them. The lane dispositions each entry and answers it in one PR comment as the PR author, opening with the line `Dispositions at <sha>` naming this head, the only thing that binds the comment, and opening a line per entry with the `file:line` the line above prints, followed by `Fixed in <sha>`, `Declined: <reason>` or `Tracked: <ID>` ([merge-pr.md](merge-pr.md) § 3.2). The lane answers every entry in the review body's `Suppressed comments (N)` block, which is the complete list; the status detail and this line are bounded and say how many they dropped. An entry the comment answers is subtracted; a label, an unanchored tracking claim, or a comment with no `Dispositions at <sha>` line for this head still blocks.
  - `disarmed` → under `ORCH_MERGE_AUTONOMY=auto`, wake the lane to arm auto-merge; under `ask` it is not a wake, the lane holds the PR for § 4 Held merges. Arming stays the lane's reply-pass discipline; the overseer never adopts it as its own step. A detail marked `UNCONFIRMED` came from a cheap-mode reducer, and that one is evaluated before anyone arms.
  - `awaiting-stale` → trigger a re-review, or apply the fleet's on-timeout policy.
  - `head-moved` → the reduction describes the old head. Do nothing; the next pass reads the new head.
  - `error` → many producers, and each line's own detail carries its remedy: follow that. One exception, whose remedy the detail does not carry: `writer dispatch failed for …` means fixing the dispatch path, never re-running, since a re-run re-attempts the same failing dispatch. An unevaluated PR is never healthy.
- `heartbeat` → the triage pass: run § Bounded issue reads. Drop IDs already recorded in the fleet state's `triaged`, and send the remaining candidate IDs through the `triage` verifier. Judge only issues a fleet lane filed — the candidate set is each lane item's created-issue records in workflow state (`audit_issues_created`, `pr_comment_review.issues_created`) plus each lane PR body's Created Issues section; the created-since listing backstops trackers without that state. Anything outside the set is left alone. Record each verdict with `workflow-state append oversee triaged '{"issue": "[ID]", "verdict": "[kept|canceled]", "reason": "[ONE_LINE]"}'`; the next pass runs on its own.

### Talking to a lane

Answering and directing are the same two commands on every harness and every surface, inside tmux or not. Add `--root [MAIL_ROOT] --host` for a lane whose record puts it on another host.

```bash
.agents/skills/orch/scripts/lane-mail send --item [ISSUE_ID] --re [MESSAGE_ID] --file [PATH]
```

```bash
.agents/skills/orch/scripts/lane-mail send --item [ISSUE_ID] --directive --file [PATH]
```

Text crosses `--file` ([SKILL.md](../SKILL.md) § Harness-Safe Shell). A directive answers no ask and `--halt` in place of `--directive` halts the lane; the Lane mail rule in [skill-rules.md](../references/skill-rules.md) says when each reaches it. A lane whose turn already ended reads neither, so wake it after the send. Keep the lane's tracker, repository, harness, item, `--lane` and `--launch-flags` arguments. The wake resumes the lane's own session with one line that runs `lane-mail inbox`, and reaches only lanes on this host; a working Claude lane or a live Codex lane is refused as `wake-refused`, so halt it or wait. Never send a lane text by keystroke.

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
