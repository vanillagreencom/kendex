# Oversee

Standing fleet mode: burn down unblocked work items by launching one orch session per item and shepherding every PR to merge. The overseer launches, watches and unblocks (lanes merge their PRs) — it never reviews, and it implements nothing but a `micro` item § 3 Item Tier leaves it to run. It runs unattended: a blocked lane is the overseer's to unblock, not the user's to notice.

## 1. Resolve The Launch Surface

Once per session, first match wins:

1. `$TMUX` set → tmux lanes: launch each item with `open-terminal` (`handoff.md` § 2), a claude or codex item under § 3 Lane directive.
2. The harness ships session or thread launching (Codex threads, Claude Code agent teams, a desktop app's session tool or bundled skill) → use it: one managed session per item, carrying the same brief `open-terminal` would render.
3. Neither → no parallel surface. Say so once and work the queue sequentially in this session, running each item's § 3 Item Tier brief: `start [ISSUE_ID]`, `small [ISSUE_ID]`, or [micro.md](micro.md) in this session for a `micro` item, with § 2 selection between items. On a hosted fleet this session runs no item: [SKILL.md](../SKILL.md) § The Cycle, Item work stays in lanes.

A lane's questions arrive at least once as `lane-question` and new tracker items as `triage`, both from the § 4 watch, on every surface. Only session banners are surface-specific: off the tmux surface, read them through the harness's own session tooling.

The owner sends the overseer a note without typing into its pane: `.agents/skills/orch/scripts/lane-mail send --item overseer --directive --file [PATH]`, run from any checkout of the project (`lane-mail --help`), and the § 4 watch reports it at least once as `owner-note`. A peer repository's overseer writes the same mailbox, reported as `peer-note` ([references/peer-mail.md](../references/peer-mail.md)).

First in every session, before the handoff file, read that mailbox: `.agents/skills/orch/scripts/lane-mail inbox --item overseer` prints every note no reader has taken yet and moves the mailbox's own cursor past them. Act on each or record it in the fleet log. The § 4 watch reads through the same cursor, so it does not report them again, save a note it had read before this and not yet acknowledged; a repeated note id is one already seen. `lane-mail pending --item overseer` takes nothing: it lists the owner and peer directives no reader has taken and the asks this overseer sent that no peer has answered. An unread peer ask or answer shows only through `inbox`.

Then read the overseer handoff file the fleet brief names (default `tmp/handoffs/OVERSEER-HANDOFF.md`): the prior session's live lanes, sequence and standing rulings. Absent, start from the tracker. `kendex apply` ignores the default path through `/tmp/`. For a custom path inside a repository, verify before the first read and each write that Git's index has no entry for the file and Git's ignore rules cover the path. If either check fails, stop and report the path. The handoff stays local to the overseer's host, which owns its disk or snapshot persistence, including paths outside a repository. § 5 rewrites it. Then read `.agents/skills/orch/scripts/workflow-state fleet-log takeover`, the last `ORCH_TAKEOVER_ROWS` fleet log rows other than `cycle` rows, and no other part of the fleet log.

## 2. Select Work

Unblocked, non-terminal items from the tracker, gated exactly as `start.md` gates them (ancestor chain, blocker union, container rules). A GitHub item labeled `blocked` is not a candidate. An item whose `worktree create` exits 75 belongs to another session: skip it; its siblings still launch. On the tmux surface that claim IS `open-terminal`'s own worktree create — never pre-create the worktree. A surface that creates its own worktree environment (Codex app threads) records the claim in workflow-state before launch. Oversee runs as at most one session per repo. `open-terminal --state-dir` enforces `ORCH_OVERSEER_LANES` per fleet and `ORCH_LANE_ACCOUNT_CLAIMS` per account (`--help`). Select no more items than the fleet cap has room for; on other surfaces keep at most that many in flight yourself:

```bash
.agents/skills/orch/scripts/orch-env ORCH_OVERSEER_LANES 3
```

## 3. Launch

### Item Tier

Every selected item takes a tier before it launches. `item-tier` assigns it, and its `--help` owns the rule:

```bash
.agents/skills/orch/scripts/item-tier --production [ESTIMATE] --path [LOCATION_PATH] --repo [MAIN_REPO_ROOT]
```

`[ESTIMATE]` is this session's estimate of the production lines the item adds, made from the body read once under § Lane directive step 2. An `**Expected delta**` line is one input to that estimate and never the tier source; `branch-size-check --help` owns that line. Pass one `--path` per file the item's `**Location**` names, and none when it names none. The output line's `brief=` word is the brief § Lane directive mints:

- `micro`: `/orch micro [ISSUE_ID]`, which runs [micro.md](micro.md): no dev subagent, no review cycle, no QA cycle.
- `small`: `/orch small [ISSUE_ID]`, which runs [small.md](small.md): the standard session under thin review bounds.
- `start`: `/orch start [ISSUE_ID]`, the `standard` tier, as the rest of this section states.

A `micro` item launches as a lane like any other, sized under § Lane directive step 2 at the simplest complexity it names, and always with `--cmd`. On a hosted fleet it launches only that way, waiting for a free lane ([SKILL.md](../SKILL.md) § The Cycle, Item work stays in lanes). Otherwise, with no lane free, or on the § 1 no-parallel surface, the overseer runs [micro.md](micro.md) in this session from the main checkout; that run holds the checkout on the item's branch until § 3 there returns it to the base, so start it between events and never beside another read of the base checkout.

A run that ends at [micro.md](micro.md) § Escape or [small.md](small.md) § Escape comes back as an item to launch at the next class up, on the branch it left. So does a run that stops without reaching an escape, a failed push or create among the causes. Run `item-tier` again with `--floor` naming the class above the one the run held, plus `--base origin/[BASE_BRANCH] --head [BRANCH] --repo [CHECKOUT]` wherever the branch lives, pushed or local-only. `[CHECKOUT]` is the lane's worktree, or the path the `worktree create` of [micro.md](micro.md) § Escape printed. A micro run that escaped at condition 1 cut no branch and takes `--floor` alone. Read a micro run's § 5 `Checkout` value: a main checkout still on the item's branch is returned to the base before the next launch.

### Lane directive

A launch through `open-terminal` on the tmux surface for the claude or codex harness, whose launcher takes a lane config dir, takes these steps in order, local or on a remote control host. Every other surface or harness launches as § 1 says, with no inventory or pick.

1. Inventory: `lanes list`. On a control host the inventory is that host's login dirs. On a hosted fleet it also carries the provider's own reading of each account it holds a credential for; the `THROUGH` column, `measured_through` under `--json`, says which credential measured each row, and the two readings of one account can disagree.
2. Size: read the item's body once and make a quick judgement of its complexity (a colour, data, docs or bounded one-function fix; a mechanism change across one subsystem; a correctness predicate with several interacting writers or a review already past its round bound), and pick the model and the reasoning effort that complexity needs. Every launch names both. The model is sized BEFORE the lane, because it is what the lane is judged on: an account with plan-wide room can have none left for one model, and choosing the lane first picks an account the launch then opens a usage banner on. Never pick a weaker model because a lane is near its wall: pick another lane.
3. Choose: `lanes pick --harness [HARNESS] --model [MODEL] --json`, naming the model step 2 sized. The threshold is read against the highest usage in the shared 5-hour window, the all-model weekly window, and the named model's scoped weekly window. A shared window can wall every model even when the scoped model window has room. The returned `binding_bucket` names the window that decided. A lane whose windows measure nothing for the model is dropped rather than treated as free. Exit 3 means no lane has room for that model, and nothing launches: [lane-directive.md § No lane has room](../references/lane-directive.md#no-lane-has-room) says what to read, wait on and report. Pass the model in the text the launch runs: inside the `--cmd` command where the launch carries its own harness argv, and in `--launch-flags` where it does not. The launcher records it beside the lane.
4. Launch: the `handoff.md` § 2 `open-terminal` invocation plus `--lane [CONFIG_DIR]` from the picked record, the sized model and effort in the text that launch runs, and `--state-dir [OVERSEE_STATE_DIR]` (§ Lane record), one item per launch. A fleet launch carries its brief in `--cmd`, so its model, effort and permission flags go inside that command and never in `--launch-flags`; a launch without `--cmd` puts them in `--launch-flags`. [lane-directive.md § Launch gate](../references/lane-directive.md#launch-gate) holds how `open-terminal` judges the launch and what each refusal licenses.

Launch caps and their refusals: [lane-directive.md § Caps](../references/lane-directive.md#caps).

Placement: before each launch, read `lane-host resolve`; any value but `local` makes a hosted fleet. There every launch this directive makes adds `--host [HOST]`, and any other surface or harness is reported, never launched locally. `start` never launches a hosted lane: only `oversee` and `handoff` launch through `open-terminal --host`. Under [SKILL.md](../SKILL.md) § The Cycle, Item work stays in lanes, every item launches as a hosted lane through this directive, and a session with no tmux surface reports the queue once, naming that surface as the route. The credential reaches the sandbox per [schemas/lane-host.md](../schemas/lane-host.md) § Provider protocol, with no local `CLAUDE_CONFIG_DIR` prefix.

Per item, mint the brief § Item Tier assigned (or its `github [OWNER/REPO]#[N]` spelling). The brief also carries question routing: "Every question for the overseer goes through `.agents/skills/orch/scripts/lane-mail` in this worktree, per [skill-rules.md § Coordination](../references/skill-rules.md#coordination): `lane-mail ask --item [ISSUE_ID] --file [PATH]`, then `lane-mail wait` on the printed id. Never use your harness's question tool. Read `lane-mail inbox --item [ISSUE_ID]` at every wait point." A lane whose harness has an Arm in [watch-delivery.md](../references/watch-delivery.md#lane-mailbox-monitor) also gets its brief line. `/orch` slash syntax does nothing in Codex: a Codex CLI lane uses the form open-terminal renders — `Read .agents/skills/orch/SKILL.md and execute the orch start workflow for [ITEM]` — and a Codex Desktop thread uses `$orch start [ITEM]` (`handoff.md` § 2); a pi lane takes `/skill:orch start [ITEM]`, and an opencode lane the `/orch` form. At the `micro` and `small` tiers each of those reads the tier's `brief=` word where it reads `start`. A `micro` or `small` item therefore always launches with `--cmd` carrying its brief: `open-terminal`'s own template renders `start` for every tracker and harness pair it handles, so a launch without `--cmd` runs the standard cycle whatever the tier said. Size launch flags to the item, then launch on the § 1 surface.

A fleet brief can require user authorization for each merge with `ORCH_MERGE_AUTONOMY=ask`; `auto` stays the default. This setting is merge authorization, not an overseer validation grant. On the tmux surface set it in the overseer's tmux session before the first launch, so every lane window inherits it; on surface 2, pass it in the launcher's environment. The lane's merge question then reaches the overseer as `lane-question` ([oversee-events.md § Held merges](../references/oversee-events.md#judgement-rules)).

```bash
tmux set-environment ORCH_MERGE_AUTONOMY ask
```

Resolve `ORCH_USER_MODE` once for every question this fleet relays to the user:

```bash
.agents/skills/orch/scripts/orch-env ORCH_USER_MODE ceo
```

The launch brief identifies the overseer and names `tmp/lane-status-[ISSUE_ID].md` and the mailbox `tmp/lane-mail/[ISSUE_ID]/`, both under the lane's worktree, which its record carries as `mail_root`. It directs the lane to initialize and rewrite the status file with its current step, blocker, handoff paths and validation minutes per round. The file holds at most 40 non-empty lines. The lane follows [skill-rules.md § Coordination](../references/skill-rules.md#coordination) for issue proposals and for every ask. For terminal launches, use `open-terminal --cmd` with the full harness command, and `--state-dir [OVERSEE_STATE_DIR]`. A `--cmd` command carries the chosen model, effort and permission flags, the question-tool words, and that brief INSIDE it: the template is rendered verbatim, so `--launch-flags` beside it reach nothing and are refused.

### Recovery relaunch

A dead or walled terminal lane uses native resume, as [lane-directive.md § Recovery relaunch](../references/lane-directive.md#recovery-relaunch) states.

### Lane record

The fleet's record is the oversee workflow state ([schemas/workflow-state.md § Oversee state](../schemas/workflow-state.md#oversee-state)), at one address for the whole session: `[OVERSEE_STATE]` is the file `workflow-state path oversee` prints from the overseer's checkout, which § 4 passes as `--state`, and `[OVERSEE_STATE_DIR]` is the directory it sits in, which every `open-terminal` launch, relaunch and wake passes as `--state-dir`, so a launch run from another repository (the proposal sweep) records into the same fleet and not into that repository's own state.

```bash
.agents/skills/orch/scripts/workflow-state path oversee
```

On the tmux surface `open-terminal` creates the state on the first launch and records every lane it launches, relaunches or wakes as one `lanes[]` entry; nothing is written by hand. [lane-directive.md § Tmux session](../references/lane-directive.md#tmux-session) names the tmux session its windows open in. On surface 2 and surface 3 the overseer's first hand-written write creates it: a surface-2 lane record below, or a `fleet_log` or `triaged` append ([oversee-events.md](../references/oversee-events.md)). Before that first write, when `exists` reports false, run `init` (init overwrites: never re-init a live fleet state):

```bash
.agents/skills/orch/scripts/workflow-state exists --json oversee
```

```bash
.agents/skills/orch/scripts/workflow-state init oversee
```

A record's `item` is the lane's record key, `[ITEM_KEY]` throughout this workflow: the Linear id for a Linear item and `issue-N` for a GitHub item, as `open-terminal` records it and `oversee-watch` names it, never the `[OWNER/REPO]#[N]` the brief spells. On surface 2, whose launcher is the harness's own, append the same record after the launch, with `window` null:

```bash
.agents/skills/orch/scripts/workflow-state append oversee lanes '{"item":"[ITEM_KEY]","tracker":"[TRACKER]","repo":"[OWNER/REPO_OR_NULL]","harness":"[HARNESS]","window":null,"account":null,"host":null,"mail_root":"[LANE_WORKTREE]","surface":"[SURFACE]","model":"[MODEL]","session_id":null,"launched_at":"[NOW]","status":"running"}'
```

`[NOW]` is `date -u +%Y-%m-%dT%H:%M:%SZ`, read before the launch it timestamps and never after, because the first record's `launched_at` is the fleet start that § 4 passes as `--since`:

```bash
.agents/skills/orch/scripts/workflow-state get oversee '.lanes[0].launched_at'
```

`mail_root` is the lane's worktree path as its own host sees it, and the lane's status file is `[MAIL_ROOT]/tmp/lane-status-[ISSUE_ID].md`. Every later mailbox call for a lane whose record carries `host` runs with `ORCH_LANE_HOST` set to that value and names the root: `lane-mail send --root [MAIL_ROOT] --host`, and `lane-host cat` or `touch`; `lane-close` reads the host from the record. A lane on this host needs neither, and a local lane whose `mail_root` is a worktree of another repository (the proposal sweep) still takes `--root [MAIL_ROOT]`, run from a checkout of that repository: `lane-mail` refuses a cross-repository `send` as `lane-foreign`.

## 4. Watch And Advance

One watch command runs for the whole session, launched and read as § Watch delivery states: repeat mode under the orch job runner, or single passes without `--repeat` where the harness wakes only at a background command's exit. Pass the fleet's start as `--since`. Use the first record's `launched_at`, which stays the same on every pass. Pass `--state [OVERSEE_STATE]` with the file that § 3 Lane record resolves. Before every pass, and before every loop that a quiet pass makes, the watch reads every `lanes[]` record whose status is `running`. It reads the item, its window, and its `mail_root`. It uses the named host for a record that has one. Automatic close uses the directory containing `[OVERSEE_STATE]`; each lane's own workflow-state reads keep their lane-specific location. A lane launch, relaunch, or close while the watch runs needs no watch restart. Each pass prints every event it found as one block in the shape that `oversee-watch --help` states. Handle every line, even when its pass exits nonzero. Fix the cause that stderr names. The next pass starts after the `--repeat` delay. `lane-close` is the only terminal-lane close-out; [lane-reach.md § Lane close](../references/lane-reach.md#lane-close) holds how it ends a lane, what each refusal asks, and each surface's close. A successful dead-overseer or walled-overseer succession makes the single pass exit 3. The repeat command converts that status to 0 and stops because the successor runs its own watch. Notice-only recovery, an exhausted retry, and a blocked recovery that no account in the fleet qualifies for also stop the repeat command with status 0, so a manual replacement starts one new watch and owns the overseer mailbox. Do not restart the old watch after any of those stops. For any other exit, fix the cause that stderr names and start it again. Never hand-roll a monitor. Without the review-gate skill, the watch skips its pr-watch step and `gate-stale` is invisible ([references/gates.md](../references/gates.md) § Multi-PR watching). `LINEAR_TEAM` enables triage. A fleet that tracks work elsewhere runs the same command and gets one stderr notice that triage is off. A repeated pr-watch line becomes context for the next event rather than an event of its own. A pull request in a repository that no `--repo` names is unwatched. Name each repository that the fleet uses, with the item repository first. `merged` and the heartbeat's open pull request list read every repository. The first repository's baseline holds the triage, lane, and merged rows.

```bash
.agents/skills/orch/scripts/lane-close --state-dir [OVERSEE_STATE_DIR] [ITEM_KEY]
```

```bash
.agents/skills/orch/scripts/oversee-watch --repeat 60 --state [OVERSEE_STATE] --interval 240 --since [FLEET_SINCE] --repo [ITEMS_REPO] --repo [OTHER_REPO]... -- [FLAGS]
```

`[FLAGS]` are the permission flags this overseer runs under, plus its current model and effort flags. Pass all of them even when `ORCH_OVERSEER_PREFERENCE` is set. The watch records this session. A caller, print or walled succession keeps the flags whole except the question-tool words, which a successor carries exactly when `ORCH_OVERSEER_QUESTION_TOOL` is off. A named same-harness entry replaces model and effort but keeps the permission words exact. A named cross-harness entry requires one full-bypass mode with an exact equivalent, and no other permission word, and writes the target harness's spelling. Other cross-harness permission modes refuse before launch. The record binds the launch line to the tmux server, pane and window because a dead pane names neither its model nor its account. Start the watch from the overseer's own pane. Missing permission flags can stop a caller-entry successor at a prompt. Missing model or effort flags can relaunch it with harness defaults.

The watch refuses a second start on the same state as `watch-running`, a bare window name no tmux session resolves as `session-unresolved`, and a hosted lane while `lane-host resolve` answers `local` as `hosted-without-host`. After a self-succession the successor's own start takes over the watch `oversee-succeed` restarted and first prints what it reported, under `watch-replayed`: handle those lines as events. `oversee-watch --help` states each rule.

The watch runs two passes on one clock. The mail pass starts every `ORCH_WATCH_MAIL_INTERVAL` seconds (default 20) and reads every mailbox and the lane records, printing what it finds as it finds it. The long pass, holding pr-watch, the merged check, triage and the pane reads, runs every `--interval` seconds; one that overruns holds up no mail pass. A lane's note is read within one mail interval, whatever `--interval` is, save the delays and the overseer-pane hold `oversee-watch --help` names. The mail pass never reads a lane's pane, so it runs on every surface and outside tmux.

### Watch delivery

Launch, follow and re-arm the repeat watch as [references/watch-delivery.md](../references/watch-delivery.md) states.

### Bounded lane reads

Use the pane payload that `oversee-watch` prints as the lane state, and never read the watch log's tail to handle an event: the follow delivers each line once. Each event carries only the lines its own handling reads, taken from below the lane's last user turn and capped by `ORCH_WATCH_TAIL_LINES`, default 12; which lines each kind carries is `oversee-watch --help` § Events. Do not capture the pane again when that payload answers the event. When the payload does not answer it and what you need is the lane's state rather than its text, run `lanes state [WINDOW]`, whose argument is the lane record's `window` as it stands, `SESSION:WINDOW`, and not the `[ITEM]` used elsewhere here, as the `lanes` help says. It prints one of `working`, `idle`, `asking`, `walled`, `exited` or `unjudged` from the same judge the watch and the wake ask, reading the lane's pane as the watch does; [lane-reach.md § Wake refusals](../references/lane-reach.md#wake-refusals) holds how its words differ from a wake's and what each wake refusal licenses. For a fresh status-file read, use `cp` locally or `lane-host cat` after a successful `lane-host touch` probe on a hosted lane. Run one source line, then the shared filter. Run each line in a separate tool call. The redirection keeps a hosted file out of the overseer until the filter emits its last 40 non-empty lines. A failed probe, source read, or filter stops the event. Never read a lane transcript.

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

Answering and directing are the same two commands on every harness and every surface, inside tmux or not. Add `--root [MAIL_ROOT] --host` for a lane whose record puts it on another host, and `--root [MAIL_ROOT]` alone, run from a checkout of that repository, for a local lane whose `mail_root` is another repository's worktree.

```bash
.agents/skills/orch/scripts/lane-mail send --item [ISSUE_ID] --re [MESSAGE_ID] --file [PATH]
```

```bash
.agents/skills/orch/scripts/lane-mail send --item [ISSUE_ID] --directive --file [PATH]
```

Text crosses `--file` ([SKILL.md](../SKILL.md) § Harness-Safe Shell). A directive answers no ask and `--halt` in place of `--directive` halts the lane; the Lane mail rule in [skill-rules.md](../references/skill-rules.md) says when each reaches it. Wake the lane after the send where [watch-delivery.md](../references/watch-delivery.md#lane-mailbox-monitor) says. Keep the lane's tracker, repository, harness, item, `--lane` and `--launch-flags` arguments. The wake resumes the lane's own session with one line that runs `lane-mail inbox`, and reaches only lanes on this host, run from the checkout the send used, because the wake resolves the lane's tree from the caller's own project; it wakes a lane only when the shared judge calls it `idle`, and refuses any other state as `wake-refused reason=[STATE]`. Never send a lane text by keystroke.

```bash
.agents/skills/orch/scripts/open-terminal --wake --harness [HARNESS] --state-dir [OVERSEE_STATE_DIR] [ISSUE_ID]
```

After a directive, wait for the watch's `directive-read` for its id: the lane's own mailbox cursor passing it, whichever read path moved it, on every harness and on a hosted lane. Never read a pane to confirm a delivery. `directive-unread` is the directive still unread past `ORCH_DIRECTIVE_UNREAD_SECS`: wake the lane, reach it by Pane paste, or relaunch it, by the lane's state and [lane-reach.md](../references/lane-reach.md).

**A refusal is a state, not a remedy.** A halt or an answer to a lane with no monitor that the wake refuses lands only where the Lane mail rule above says. Send where the reason allows it; mail that cannot wait takes [lane-reach.md](../references/lane-reach.md#mail-the-wake-cannot-deliver).

[references/lane-reach.md](../references/lane-reach.md) holds what each wake refusal reason licenses and, per harness, how a lane is launched, how its state is read and how its harness dialogs are answered.

**Pane paste.** Write harness input to a file with the harness file tool, then type it with the one pane writer. `[WINDOW]` is the lane record's `window`, and `[PROCESS]` is the record's `harness`, or `ssh` for a record carrying `host`:

```bash
.agents/skills/orch/scripts/pane-write --window [WINDOW] --expect [PROCESS] --file [PATH]
```

It cancels copy mode, pastes the file and presses `Enter`. A dialog key takes `--key [KEY]` in place of `--file`. A refusal, exit 1, types nothing, and its `fix=` line names the remedy (`pane-write --help`). Exit 2, `write-failed`, may have typed part of the input: read the pane before a retry. Never paste a shell command into a lane pane. Stop a process inside a hosted sandbox through `lane-host stop --item [ITEM] --harness [HARNESS]`. Never type a process-name kill at a prompt that can belong to the control host.

A lane under a session limit still needs its one-line continuation nudge pasted into its pane at the reset through Pane paste above, since a walled harness runs no turn and so reads no mail; the launch brief and a harness dialog's answer reach a pane the same way, and nothing else does.

A lane never arms the shared git hooks from its worktree; a guard-script PR whose new chain refuses the branch under main's installed scripts is a one-time transition the overseer sequences.

**Resuming a dead or walled lane.** Use [lane-directive.md § Recovery relaunch](../references/lane-directive.md#recovery-relaunch), which resumes the item's newest session natively per `open-terminal --help` § `--relaunch`; a hosted lane has no local transcript lookup. The resumed command carries the continuation line that re-arms the lane's waiters, so the relaunch is the whole step, except on a hosted codex lane, which that section says resumes without the line and takes it by Pane paste afterwards.

## 5. Stop

Queue empty, or the user stops it. Stop a detached repeat watch first, as [references/watch-delivery.md](../references/watch-delivery.md) states, then end the follow, so no pass reports this overseer dead and no successor resumes a stopped fleet. On a hosted fleet, stop only when `lane-host list` has no row but `available`, or name each such host. Run `.agents/skills/orch/scripts/oversee-cycle --state-dir [OVERSEE_STATE_DIR] rollup`, which writes the per-class rollup to the fleet log, where the owner reads it against the routes that landed. Report one line per lane in the rows [../references/communication-modes.md](../references/communication-modes.md) § Status report gives: merged SHAs under Landed, still-open PRs and items skipped as owned or blocked under Running, each running lane's `validate_rounds` minutes or `none` under Validation, the queue remainder or `none` under Next, open questions or `none` under Waiting on you. Reapply the § 1 handoff-path check before rewriting the overseer handoff file in place for the next session. The handoff file carries no tmux command: a pane write it hands on names `pane-write`, as Pane paste in § Talking to a lane gives it. Write each status report given in chat, this one included, to the path `workflow-state progress-report-path` prints as well. At that rewrite, here and at a succession, run the retention [schemas/workflow-state.md § Recording policy](../schemas/workflow-state.md#recording-policy) states. Where it prints a `kept=` line, record that line in the fleet log; its other outputs are [§ Prune](../schemas/workflow-state.md#prune)'s. A succession writes its report as [references/oversee-events.md](../references/oversee-events.md#judgement-rules), Hand off a lane, states and, under a repeat watch, keeps that watch's `[RUN_DIR]`:

```bash
.agents/skills/orch/scripts/workflow-state prune --keep [RUN_DIR]
```

Single passes, and Stop, whose watch is already stopped, run `prune` with no `--keep`.
