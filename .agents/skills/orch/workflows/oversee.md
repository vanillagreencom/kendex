# Oversee

Standing fleet mode: burn down unblocked work items by launching one orch session per item and shepherding every PR to merge. The overseer launches, watches, unblocks, and merges — it never reviews, and it implements nothing but a `micro` item § 3 Item Tier leaves it to run. It runs unattended: a blocked lane is the overseer's to unblock, not the user's to notice.

## 1. Resolve The Launch Surface

Once per session, first match wins:

1. `$TMUX` set → tmux lanes: launch each item with `open-terminal` (`handoff.md` § 2), a claude or codex item under § 3 Lane directive.
2. The harness ships session or thread launching (Codex threads, Claude Code agent teams, a desktop app's session tool or bundled skill) → use it: one managed session per item, carrying the same brief `open-terminal` would render.
3. Neither → no parallel surface. Say so once and work the queue sequentially in this session, running each item's § 3 Item Tier brief: `start [ISSUE_ID]`, or [micro.md](micro.md) in this session for a `micro` item, with § 2 selection between items. On a hosted fleet this session runs no item: § 3 Lane directive, Placement.

A lane's questions arrive as `lane-question` and new tracker items as `triage`, both from the § 4 watch, on every surface. Only session banners are surface-specific: off the tmux surface, read them through the harness's own session tooling.

The owner sends the overseer a note without typing into its pane: `.agents/skills/orch/scripts/lane-mail send --item overseer --directive --file [PATH]`, run from any checkout of the project (`lane-mail --help`), and the § 4 watch reports it once as `owner-note`. A peer repository's overseer writes the same mailbox, reported as `peer-note` ([references/peer-mail.md](../references/peer-mail.md)).

Then read the overseer handoff file the fleet brief names (default `tmp/handoffs/OVERSEER-HANDOFF.md`): the prior session's live lanes, sequence and standing rulings. Absent, start from the tracker. `kendex apply` ignores the default path through `/tmp/`. For a custom path inside a repository, verify before the first read and each write that Git's index has no entry for the file and Git's ignore rules cover the path. If either check fails, stop and report the path. The handoff stays local to the overseer's host, which owns its disk or snapshot persistence, including paths outside a repository. § 5 rewrites it.

## 2. Select Work

Unblocked, non-terminal items from the tracker, gated exactly as `start.md` gates them (ancestor chain, blocker union, container rules). A GitHub item labeled `blocked` is not a candidate. An item whose `worktree create` exits 75 belongs to another session: skip it; its siblings still launch. On the tmux surface that claim IS `open-terminal`'s own worktree create — never pre-create the worktree. A surface that creates its own worktree environment (Codex app threads) records the claim in workflow-state before launch. Oversee runs as at most one session per repo. `open-terminal` holds a tmux fleet to two caps on every fresh launch under `--state-dir`, counted and recorded under one lock so two launchers never both pass: `ORCH_OVERSEER_LANES` for the fleet's lanes, refused as `cap-reached`, and `ORCH_LANE_ACCOUNT_CLAIMS` for the lanes on one account, refused as `account-cap-reached` (`open-terminal --help` holds what each counts). Select no more items than the fleet cap leaves room for; on the other surfaces, keep at most that many items in flight yourself:

```bash
.agents/skills/orch/scripts/orch-env ORCH_OVERSEER_LANES 3
```

## 3. Launch

### Item Tier

Every selected item takes a tier before it launches, read from the audit's `**Expected delta**` line in the item's own body and from nothing else. `branch-size-check --help` owns that line's grammar, and the same script measures the branch later in [micro.md](micro.md) § 3. This gate has no branch to measure, so it reads the line by that grammar rather than running it.

- `micro` — the line's production count is at or under `micro_max_production` in [references/narrow-change.conf](../references/narrow-change.conf), this tier's ceiling and stated only there, and the body names no file [micro.md](micro.md) § Escape condition 3 excludes. The brief is `/orch micro [ISSUE_ID]`, which runs [micro.md](micro.md): no dev subagent, no review cycle, no QA cycle.
- `standard` — every other item. The brief is `/orch start [ISSUE_ID]`, as the rest of this section states.

An item with no `**Expected delta**` line takes `standard`. So does one whose line that grammar rejects, and that line is reported once as a defect in the item, since `branch-size-check` exits 3 on it later.

A `micro` item launches as a lane like any other, sized under § Lane directive step 2 at the simplest complexity it names, and always with `--cmd`. On a hosted fleet it launches only that way, waiting for a free lane (§ 3 Lane directive, Placement). Otherwise, with no lane free, or on the § 1 no-parallel surface, the overseer runs [micro.md](micro.md) itself in this session from the main checkout; that run holds the checkout on the item's branch until § 3 there returns it to the base, so start it between events and never beside another read of the base checkout.

A run that ends at [micro.md](micro.md) § Escape comes back as an item to launch at `standard`, on the branch it left. So does one that stops without reaching an escape, a failed push or create among the causes. Read that run's § 5 `Checkout` value: a main checkout still on the item's branch is returned to the base before the next launch.

### Lane directive

A launch through `open-terminal` on the tmux surface for the claude or codex harness, whose launcher takes a lane config dir, takes these steps in order, local or on a remote control host. Every other surface or harness launches as § 1 says, with no inventory or pick.

1. Inventory: `lanes list`. On a control host the inventory is that host's login dirs. On a hosted fleet it also carries the provider's own reading of each account it holds a credential for; the `THROUGH` column, `measured_through` under `--json`, says which credential measured each row, and the two readings of one account can disagree.
2. Size: read the item's body once and make a quick judgement of its complexity (a colour, data, docs or bounded one-function fix; a mechanism change across one subsystem; a correctness predicate with several interacting writers or a review already past its round bound), and pick the model and the reasoning effort that complexity needs. Every launch names both. `open-terminal` refuses a lane launch on a harness its flag table names that names no model, and one that names no effort where that harness has an effort flag, one keyed refusal per missing half, because a harness default changes without notice. The model is sized BEFORE the lane, because it is what the lane is judged on: an account with plan-wide room can have none left for one model, and choosing the lane first picks an account the launch then opens a usage banner on. Never pick a weaker model because a lane is near its wall: pick another lane.
3. Choose: `lanes pick --harness [HARNESS] --model [MODEL] --json`, naming the model step 2 sized. The threshold is read against the highest usage in the shared 5-hour window, the all-model weekly window, and the named model's scoped weekly window. A shared window can wall every model even when the scoped model window has room. The returned `binding_bucket` names the window that decided. A lane whose windows measure nothing for the model is dropped rather than treated as free. Exit 3 means no lane has room for that model, and nothing launches: read `lanes list`, wait only when its lanes are over the threshold, and report every `expired`, `unreachable`, `no_credentials`, `no_usage_data` or `error` lane, and every `rate_limited` lane with a null `headroom_pct`, to the operator. An `expired` lane is one whose token renewal failed on a login proven dead; its `detail` names why, and it is the only one of these an operator answers by logging in again. A `rate_limited` lane met an endpoint answering HTTP 429. A usage refresh refused while the host holds a figure younger than the 5-hour session window is reported on that figure, with its age in `usage_age_s`, and judged on it like an `ok` lane. A token renewal refused with 429, or a usage 429 with no such figure, carries no window. An `unreachable` one met an endpoint answering 5xx, an endpoint it could not reach, or a credentials lock another tool held. Both leave the login untested, so the answer is another lane and never a re-login. Where an endpoint answered, `detail` carries the code and the lane is left alone until the recorded window passes. An `error` lane failed a step on this machine, a renewal's included. Every Claude account `error` for a missing OAuth client id needs `ORCH_LANES_CLAUDE_CLIENT_ID`, set once per host. Pass the model in the text the launch runs: inside the `--cmd` command where the launch carries its own harness argv, and in `--launch-flags` where it does not. The launcher records it beside the lane.
4. Launch: the `handoff.md` § 2 `open-terminal` invocation plus `--lane [CONFIG_DIR]` from the picked record, the sized model and effort in the text that launch runs, and `--state-dir [OVERSEE_STATE_DIR]` (§ Lane record), one item per launch. A fleet launch carries its brief in `--cmd`, so its model, effort and permission flags go inside that command and never in `--launch-flags`; a launch without `--cmd` puts them in `--launch-flags`. `open-terminal` reads the model and the effort out of the one text the launch runs: the `--cmd` command where there is one, `--launch-flags` where there is not. It refuses a launch that names either nowhere, and refuses `--launch-flags` beside `--cmd`, which are appended to no command and reach nothing. It then judges the named lane on that model a second time, so a lane picked without `--model` can be refused here. A hosted `--relaunch` is judged on that window too; only an account nothing measured turns on the provider's answer, per `open-terminal --help` § `--host`. It still names a model and an effort. The gate emits seven refusals, each with its own answer:
   - `launch-model-missing` and `launch-effort-missing` (naming `harness`, `lane` and the `spellings` that harness takes): the launch made only part of the choice of lane, model and effort. Add the missing word to the text the launch runs; never let the harness pick.
   - `launch-flags-unreachable` (naming the `flags`): the launch passed `--launch-flags` beside `--cmd`, which renders its template verbatim and appends nothing, so those words would have gated and been recorded while the harness ran its own default. Move them inside the `--cmd` command, or drop `--cmd`.
   - `lane-model-walled` (naming `lane`, `model`, `pct`, and `bucket`): that account's deciding shared or model window is at or above the threshold. Re-run step 3 with `--model`, never retry the same lane. A hosted relaunch meets it too: the window belongs to the account, so resuming would spend the sandbox start to open on a usage banner.
   - `lane-model-unreadable`: no window of that account measures the model, or its usage could not be read at all. An unread window is never an empty one, so the answer is the same re-pick.
   - `host-credential-dead`: this machine's copy of the account expired and could not be renewed, and the provider reports holding that same account. Renew the login on this machine for that config dir; a provider that re-seeds the host from that directory at every `create` sends the dead copy again. Reported for claude lanes, the only ones whose local credential `lanes` reads an unrenewable expiry from. A relaunch onto that same account proceeds instead, on the copy the provider installed.
   - `lane-judge-failed`: the judge refused before it answered, a malformed `--lane-max-pct` among the causes. The keyed `lanes:` line above it names which.

   An unreadable in-flight claim store is not a refusal here: this gate asks for a wall, which no claim count enters, so `lanes` reports the store on stderr as `pick-lane-claims` and answers the wall anyway. Fix the claims directory, or set `OVERSEE_WATCH_STATE_DIR`, so the next `lanes pick` across the fleet can still see what is running.

   `host-accounts-unanswered` is a notice, not a refusal: nothing said which accounts the host holds, so the launch is judged on this machine's reading as an unhosted one is. A keyed `lanes:` line above the notice names a provider failure, with the provider's own message above that line; no line above it means the read of the answer failed on this machine. Fix what that line names, or read the launch's outcome as a local measurement.

The caps refuse a launch before its worktree. A `--relaunch` meets them only where it adds a lane or moves one to another account, and `--wake` meets neither:

- `cap-reached` (naming `cap`, the `running` records and the unrecorded live `claims`): the fleet is full. Launch the next item once a lane closes.
- `account-cap-reached` (naming `lane`, `cap` and that lane's `claims`): the picked account carries its share. Launch once a lane on that account closes, or with `--wait-slot`.
- `cap-unreadable`, `cap-lock-failed` and `claim-unrecorded`: the count could not be made as one locked step, or could not see a lane this run launched. Fix what the line names; never launch around it.

A launch queued behind the caps, such as a chain script that launches the next item when a slot opens, is `open-terminal --wait-slot`: it counts again without holding the lock, judges its lane again, and launches under the lock once both caps have room (`open-terminal --help`). The overseer writes no counting loop of its own. `--over-cap` admits one deliberate exception, reported as `over-cap-admitted` and recorded in the lane record's `over_cap`.

Placement: before each launch, read `lane-host resolve`; any value but `local` makes a hosted fleet. There every launch this directive makes adds `--host [HOST]`, and any other surface or harness is reported, never launched locally. `start` never launches a hosted lane: only `oversee` and `handoff` launch through `open-terminal --host`. The overseer therefore never runs `/orch start [ISSUE_ID]` or `/orch micro [ISSUE_ID]` in its own session on a hosted fleet ([SKILL.md](../SKILL.md) § The Cycle, The overseer reads results): every item launches as a hosted lane through this directive, and a session with no tmux surface reports the queue once, naming that surface as the route. The credential reaches the sandbox per [schemas/lane-host.md](../schemas/lane-host.md) § Provider protocol, with no local `CLAUDE_CONFIG_DIR` prefix.

Per item, mint the brief for the tier § Item Tier assigned: `/orch start [ISSUE_ID]` at `standard`, `/orch micro [ISSUE_ID]` at `micro` (or the `github [OWNER/REPO]#[N]` spelling of either). The brief also carries question routing: "Every question for the overseer goes through `.agents/skills/orch/scripts/lane-mail` in this worktree, per [skill-rules.md § Coordination](../references/skill-rules.md#coordination): `lane-mail ask --item [ISSUE_ID] --file [PATH]`, then `lane-mail wait` on the printed id. Never use your harness's question tool. Read `lane-mail inbox --item [ISSUE_ID]` at every wait point." `/orch` slash syntax does nothing in Codex: a Codex CLI lane uses the form open-terminal renders — `Read .agents/skills/orch/SKILL.md and execute the orch start workflow for [ITEM]` — and a Codex Desktop thread uses `$orch start [ITEM]` (`handoff.md` § 2); a pi lane takes `/skill:orch start [ITEM]`, and an opencode lane the `/orch` form. At the `micro` tier each of those reads `micro` where it reads `start`. A `micro` item therefore always launches with `--cmd` carrying its brief: `open-terminal`'s own template renders `start` for every tracker and harness pair it handles, so a launch without `--cmd` runs the standard cycle whatever the tier said. Size launch flags to the item, then launch on the § 1 surface.

A fleet brief can require user authorization for each merge with `ORCH_MERGE_AUTONOMY=ask`; `auto` stays the default. This setting is merge authorization, not an overseer validation grant. On the tmux surface set it in the overseer's tmux session before the first launch, so every lane window inherits it; on surface 2, pass it in the launcher's environment. The lane's merge question then reaches the overseer as `lane-question` ([oversee-events.md § Held merges](../references/oversee-events.md#judgement-rules)).

```bash
tmux set-environment ORCH_MERGE_AUTONOMY ask
```

Resolve `ORCH_USER_MODE` once for every question this fleet relays to the user:

```bash
.agents/skills/orch/scripts/orch-env ORCH_USER_MODE ceo
```

The launch brief identifies the overseer and names `tmp/lane-status-[ISSUE_ID].md` and the mailbox `tmp/lane-mail/[ISSUE_ID]/`, both under the lane's worktree, which its record carries as `mail_root`. It directs the lane to initialize and rewrite the status file with its current step, blocker, and handoff paths. The file holds at most 40 non-empty lines. The lane follows [skill-rules.md § Coordination](../references/skill-rules.md#coordination) for issue proposals and for every ask. For terminal launches, use `open-terminal --cmd` with the full harness command, and `--state-dir [OVERSEE_STATE_DIR]`. A `--cmd` command carries the chosen model, effort and permission flags and that brief INSIDE it: the template is rendered verbatim, so `--launch-flags` beside it reach nothing and are refused.

### Recovery relaunch

A dead or walled terminal lane uses native resume. Start with the `handoff.md` § 2 terminal command. Add `--relaunch`, the selected `--lane`, the chosen `--launch-flags` and `--state-dir [OVERSEE_STATE_DIR]`. A relaunch onto another account, or of an item whose record is not `running`, meets the caps above. Keep the tracker, repository, harness, and item arguments. Do not pass `--cmd`, because a custom command bypasses session lookup. A `micro` item relaunched this way demotes to `standard`: with no `--cmd` the launcher renders its `start` template, and the resumed session runs the full cycle on the branch the micro run left. A record carrying `host` adds `--host [HOST]`: the provider keeps its tree and the harness continues natively. A hosted relaunch is judged on the account's usage window like any other launch, and is refused as `lane-model-walled` when that window is at or above the threshold; `open-terminal --help` § `--host` holds what the provider's answer decides, which is the unreadable case alone. A relaunch the provider reports holding the account for proceeds there, reported as `host-relaunch-credential`, and the resumed session reports its own usage banner, which § 4 reads as `usage-limit`. The launcher delivers the continuation line in the resumed command itself and keeps a merged item's tree as it stands, so nothing is pasted into the pane after the resume. A hosted codex lane is the exception: `codex resume` refuses a prompt beside `--last`, so it resumes with no line and the launcher reports `resume-lineless`. Paste that lane's continuation line into its pane through § Talking to a lane, Pane paste, the way a walled lane gets its nudge.

### Lane record

The fleet's record is the oversee workflow state ([schemas/workflow-state.md § Oversee state](../schemas/workflow-state.md#oversee-state)), at one address for the whole session: `[OVERSEE_STATE]` is the file `workflow-state path oversee` prints from the overseer's checkout, which § 4 passes as `--state`, and `[OVERSEE_STATE_DIR]` is the directory it sits in, which every `open-terminal` launch, relaunch and wake passes as `--state-dir`, so a launch run from another repository (the proposal sweep) records into the same fleet and not into that repository's own state.

```bash
.agents/skills/orch/scripts/workflow-state path oversee
```

On the tmux surface `open-terminal` creates the state on the first launch and records every lane it launches, relaunches or wakes as one `lanes[]` entry; nothing is written by hand. Every lane window opens in one tmux session, named in the record's `window` as `SESSION:WINDOW`: `ORCH_TMUX_SESSION` when set, else the session the state records as `tmux.session`, else the launching pane's session. The first tmux launch records the session it opened in, `ORCH_TMUX_SESSION` or the pane's, once tmux confirms it exists. A launch with no live pane and neither refuses as `tmux-session-unresolved`, and a named session tmux does not hold refuses as `tmux-session-missing` with its source. A detached launch chain still needs `$TMUX` set, as a `setsid` chain or a `run-shell` job started inside tmux has; one without it refuses as `tmux-missing`. Set `ORCH_TMUX_SESSION` for such a chain. On surface 2 and surface 3 the overseer's first hand-written write creates it: a surface-2 lane record below, or a `fleet_log` or `triaged` append ([oversee-events.md](../references/oversee-events.md)). Before that first write, when `exists` reports false, run `init` (init overwrites: never re-init a live fleet state):

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

One watch command runs for the whole session, launched and read as § Watch delivery states: repeat mode, or single passes without `--repeat` where the harness wakes only at a background command's exit. Pass the fleet's start as `--since`. Use the first record's `launched_at`, which stays the same on every pass. Pass `--repo` for every repository that has fleet pull requests. Pass `--state [OVERSEE_STATE]` with the file that § 3 Lane record resolves. Before every pass, and before every loop that a quiet pass makes, the watch reads every `lanes[]` record whose status is `running`. It reads the item, its window, and its `mail_root`. It uses the named host for a record that has one. Automatic close uses the directory containing `[OVERSEE_STATE]`; each lane's own workflow-state reads keep their lane-specific location. A lane launch, relaunch, or close while the watch runs needs no watch restart. Each pass prints every event it found as one block in the shape that `oversee-watch --help` states. Handle every line. Handle an `EVENT` line even when its pass exits nonzero. Fix the cause that stderr names. The next pass starts after the `--repeat` delay. `lane-close` is the only terminal-lane close-out. It exits an idle Claude or Codex harness. A Claude harness that ends its session at once rather than showing its exit dialog closes in that same call. An already exited lane needs no harness-specific exit operation. It calls the recorded lane host, kills the window by pane id, and records `done`. `--keep-sandbox` records `stopped` instead. A merged hosted item keeps its record `running` until the watch calls that verb and reports `lane-closed` or `lane-close-refused`. Every other `lane-close` exit is neither event: the watch writes `lane-close-failed item=[ITEM] exit=[N]` on stderr with the verb's own refusal lines under it, leaves the record `running` and retries the close on the next pass, so an `ask-unanswered` or a `mail-read-failed` refusal repeats until the cause the refusal names is fixed, the ask answered or the mailbox repaired. A nonterminal or working lane refuses as `lane-live`. Two panes with the recorded name refuse as `pane-ambiguous`, and a window no pane on this server carries as `pane-missing`; the recorded window resolves in either form tmux accepts, a bare name or `SESSION:WINDOW` whose session name must match exactly. A lane whose composer holds unsent text refuses as `composer-draft`, and one whose live input line nothing on the screen measures as `composer-unreadable`: `/exit` is typed at the cursor, so a composer the close cannot read as empty is never typed into. Clear a draft by hand and run the close again; for an unreadable one, quit the harness in the pane, which leaves an exited lane the close reads no composer for ([references/oversee-events.md](../references/oversee-events.md#event-kinds)). A lane holding an ask nobody answered refuses as `ask-unanswered`; answer it with `lane-mail send --item [ITEM] --re [ASK_ID] --file [PATH]`, which a lane whose record carries `host` takes with `--root [MAIL_ROOT] --host` under the § 3 mailbox rule, and close again, and a mailbox the close cannot read refuses as `mail-read-failed`. An exited lane takes neither refusal, and the `stopped` record `--keep-sandbox` leaves behind takes the ask one, its kept sandbox being relaunchable into a session that reads the reply. A record written before the launcher recorded the lane's tracker, repository and harness carries none of the three; an exited lane closes without them, and an idle one reads its tracker from a tracker-identifier item key and its harness from the pane where that pane runs the harness. An `issue-N` key answers no tracker, being the key a GitHub lane and a Linear lane are both given, so such a record refuses as `tracker-read-failed cause=key-ambiguous`. The identity a caller still supplies is `--tracker linear|github` for an `issue-N` record carrying none, `--repo [OWNER/REPO]` for a GitHub lane and `--harness claude|codex` for a lane whose pane runs a wrapper; where the item key does answer the tracker, `--tracker` only pins what it says. Each fills only a field the record leaves null or absent and refuses as `record-invalid` where it contradicts one the record carries. Surface 2 uses its native close and then sets its lane record `done`, because it has no tmux pane for `lane-close` to resolve. Surface 3 continues in the overseer session and has no separate session or lane record to close. A successful dead-overseer or walled-overseer succession makes the single pass exit 3. The repeat command converts that status to 0 and stops because the successor runs its own watch. Notice-only recovery, an exhausted retry, and a blocked recovery that no account in the fleet qualifies for also stop the repeat command with status 0, so a manual replacement starts one new watch and owns the overseer mailbox. Do not restart the old watch after any of those stops. For any other exit, fix the cause that stderr names and start it again. Never hand-roll a monitor. Without the review-gate skill, the watch skips its pr-watch step and `gate-stale` is invisible ([references/gates.md](../references/gates.md) § Multi-PR watching). `LINEAR_TEAM` enables triage. A fleet that tracks work elsewhere runs the same command and gets one stderr notice that triage is off. A repeated pr-watch line becomes context for the next event rather than an event of its own. A pull request in a repository that no `--repo` names is unwatched. Name each repository that the fleet uses, with the item repository first. `merged` and the heartbeat's open pull request list read every repository. The first repository's baseline holds the triage, lane, and merged rows.

```bash
.agents/skills/orch/scripts/lane-close --state-dir [OVERSEE_STATE_DIR] [ITEM_KEY]
```

```bash
.agents/skills/orch/scripts/oversee-watch --repeat 60 --state [OVERSEE_STATE] --interval 240 --since [FLEET_SINCE] --repo [ITEMS_REPO] --repo [OTHER_REPO]... -- [FLAGS]
```

`[FLAGS]` are the permission flags this overseer runs under, plus its current model and effort flags. Pass all of them even when `ORCH_OVERSEER_PREFERENCE` is set. The watch records this session. A caller, print or walled succession keeps the flags whole. A named same-harness entry replaces model and effort but keeps the permission words exact. A named cross-harness entry requires one full-bypass mode with an exact equivalent, and no other permission word, and writes the target harness's spelling. Other cross-harness permission modes refuse before launch. The record binds the launch line to the tmux server, pane and window because a dead pane names neither its model nor its account. Start the watch from the overseer's own pane. Missing permission flags can stop a caller-entry successor at a prompt. Missing model or effort flags can relaunch it with harness defaults.

The watch refuses a second start on the same state as `watch-running`, a bare window name no tmux session resolves as `session-unresolved`, and a hosted lane while `lane-host resolve` answers `local` as `hosted-without-host`. After a self-succession the successor's own start takes over the watch `oversee-succeed` restarted and first prints what it reported, under `watch-replayed`: handle those lines as events. `oversee-watch --help` states each rule.

The mail pass reads each lane's mailbox, never a pane, so it runs on every surface and outside tmux.

### Watch delivery

Launch, follow and re-arm the repeat watch as [references/watch-delivery.md](../references/watch-delivery.md) states.

### Bounded lane reads

Use the pane payload that `oversee-watch` prints as the lane state. Each event carries only the lines its own handling reads, taken from below the lane's last user turn and capped by `ORCH_WATCH_TAIL_LINES`, default 12; which lines each kind carries is `oversee-watch --help` § Events. Do not capture the pane again when that payload answers the event. When the payload does not answer it and what you need is the lane's state rather than its text, run `lanes state [WINDOW]`, whose argument is the lane record's `window` as it stands, `SESSION:WINDOW`, and not the `[ITEM]` used elsewhere here, as the `lanes` help says. It prints one of `working`, `idle`, `asking`, `walled`, `exited` or `unjudged` from the same judge the watch and the wake ask, reading the lane's pane as the watch does. `unjudged` means the pane settled nothing, not that a wake would be refused: the wake reads the harness process as well, so it can still answer where this cannot. `idle` is likewise the pane's word alone: the wake also reads the harness process, and it refuses a lane whose process reads busy. A live Codex lane is refused every time, because codex publishes no idle signal: as `working` where its process has a shell under it, and as `unjudged` otherwise. A harness process another user owns, root among them, answers `unjudged` for the whole lane while it runs, and on a host with no `/proc` the wake's process read answers `unjudged` for any lane whose harness has a process on the box. None of that reaches this verb, which makes no process read: its own `unjudged` is the pane's silence, and the refusal table in [lane-reach.md § Wake refusals](../references/lane-reach.md#wake-refusals) keeps the two apart under one row each. What a wake refusal licenses is that table. For a fresh status-file read, use `cp` locally or `lane-host cat` after a successful `lane-host touch` probe on a hosted lane. Run one source line, then the shared filter. Run each line in a separate tool call. The redirection keeps a hosted file out of the overseer until the filter emits its last 40 non-empty lines. A failed probe, source read, or filter stops the event. Never read a lane transcript.

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

Text crosses `--file` ([SKILL.md](../SKILL.md) § Harness-Safe Shell). A directive answers no ask and `--halt` in place of `--directive` halts the lane; the Lane mail rule in [skill-rules.md](../references/skill-rules.md) says when each reaches it, so wake the lane after the send. Keep the lane's tracker, repository, harness, item, `--lane` and `--launch-flags` arguments. The wake resumes the lane's own session with one line that runs `lane-mail inbox`, and reaches only lanes on this host, run from a checkout of the lane's own repository when its `mail_root` is another repository's worktree, because the wake resolves the lane's tree from the caller's own project; it wakes a lane only when the shared judge calls it `idle`, and refuses any other state as `wake-refused reason=[STATE]`. [lane-reach.md § Wake refusals](../references/lane-reach.md#wake-refusals) says what each reason licenses. Never send a lane text by keystroke.

```bash
.agents/skills/orch/scripts/open-terminal --wake --harness [HARNESS] --state-dir [OVERSEE_STATE_DIR] [ISSUE_ID]
```

**A refusal is a state, not a remedy.** Mail reaches a lane only through the hooks the Lane mail rule in [skill-rules.md](../references/skill-rules.md) names, so a halt or an answer lands only while the lane still takes a tool call or ends a turn. Send where the reason allows it, then reach the lane at its pane by the paste below when the refusal does not clear, or relaunch it under § Recovery relaunch.

[references/lane-reach.md](../references/lane-reach.md) holds what each wake refusal reason licenses and, per harness, how a lane is launched, how its state is read and how its harness dialogs are answered.

**Pane paste.** Write harness input to a file with the harness file tool. Run `tmux load-buffer <file>`, then `tmux paste-buffer -p -d -t <pane>`. Before each `Enter`, read `tmux display-message -p -t <pane> '#{pane_in_mode}'`. If it prints `1`, run `tmux send-keys -t <pane> -X cancel` and read the mode again. Send `tmux send-keys -t <pane> Enter` only when the mode reads `0`. Never paste a shell command into a lane pane. Stop a process inside a hosted sandbox through `lane-host stop --item [ITEM] --harness [HARNESS]`. Never type a process-name kill at a prompt that can belong to the control host.

A lane under a session limit still needs its one-line continuation nudge pasted into its pane at the reset through Pane paste above, since a walled harness runs no turn and so reads no mail; the launch brief and a harness dialog's answer reach a pane the same way, and nothing else does.

A lane never arms the shared git hooks from its worktree; a guard-script PR whose new chain refuses the branch under main's installed scripts is a one-time transition the overseer sequences.

**Resuming a dead or walled lane.** Use § 3 Recovery relaunch, which resumes the item's newest session natively per `open-terminal --help` § `--relaunch`; a hosted lane has no local transcript lookup. The resumed command carries the continuation line that re-arms the lane's waiters, so the relaunch is the whole step, except on a hosted codex lane, which § 3 says resumes without the line and takes it by Pane paste afterwards.

## 5. Stop

Queue empty, or the user stops it. Stop a detached repeat watch first, as [references/watch-delivery.md](../references/watch-delivery.md) states, then end the follow, so no pass reports this overseer dead and no successor resumes a stopped fleet. On a hosted fleet, stop only when `lane-host list` has no row but `available`, or name each such host. Report one line per lane: merged SHAs, still-open PRs, items skipped as owned or blocked. That report fills the rows [../references/communication-modes.md](../references/communication-modes.md) § Status report gives: merged SHAs under Landed, still-open PRs and items skipped as owned or blocked under Running, the queue remainder or `none` under Next, open questions or `none` under Waiting on you. Reapply the § 1 handoff-path check before rewriting the overseer handoff file in place for the next session, and delete stale per-session handoff files beside it at that rewrite, never leave them.
