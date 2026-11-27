# Lane launch

Read at [oversee.md § 3](../workflows/oversee.md#3-launch) for each item the overseer launches: § Item Tier, then § Lane directive, whose first launch takes § Shared files, then § Lane record.

- [handoff.md](../workflows/handoff.md) § 2 runs § Lane directive steps 3 and 4.
- A running lane that asks for a path outside its admitted set takes § Shared files.
- A launch refusal, and a relaunch, read [lane-directive.md](lane-directive.md).
- The surfaces named here, the tmux surface and surfaces 2 and 3, are those of [oversee.md § 1](../workflows/oversee.md#1-resolve-the-launch-surface).

## Item Tier

Every selected item takes a tier before it launches:

```bash
.agents/skills/orch/scripts/orch-runtime tier --production [ESTIMATE] --body [ITEM_BODY_FILE] --brief [BRIEF_FILE] --repo [MAIN_REPO_ROOT]
```

1. `[ESTIMATE]` is this session's estimate of the production lines the item adds, from the body read once under § Lane directive step 2.
   - Save that body as `[ITEM_BODY_FILE]`: its Location lines name the paths, and its Expected delta floors the estimate.
   - For a Linear item whose description has no Location line, the body is the description followed by the item's newest comment whose first line is `Triage contract:`, read once with `linear.sh comments list [ID] --format=safe`. Copy that comment's `**Location**:` line into the launch brief, so the launch admission's touched set holds its paths.
   - `orch-runtime tier --help` owns the rule.
2. For a body with no Location, `tier` exits 1 with `orch-runtime: tier cause=no-location route=per-subsystem-split` and no tier. For a Linear item eligible for triage, have the verifier find the Location and [triage step 8](oversee-events.md#triage) write it, in the description or a GitHub-synced item's `Triage contract:` comment, before retrying the launch. Send every other item back to filing for a per-subsystem split.
3. Copy the complete output line into the launch brief once, alone on its line. The line's `brief=` word sets the brief § Lane directive builds:
   - `micro`: `/orch micro [ISSUE_ID]`, which runs [micro.md](../workflows/micro.md): no dev subagent, no review cycle, no QA cycle.
   - `small`: `/orch small [ISSUE_ID]`, which runs [small.md](../workflows/small.md): the standard session under thin review bounds.
   - `start`: `/orch start [ISSUE_ID]`, the `standard` tier.

A tracker item at the `micro` tier launches as a lane like any other, with its tier's brief and the model class and effort [Model class](skill-rules.md#model-class) selects.

- [micro.md](../workflows/micro.md) § Items says where, and on which fleet, the overseer runs micro.md itself from the main checkout.
- Such a run holds the checkout on the item's branch until its § 3 returns it to the base.
- Start it between events, never beside another read of the base checkout.
- Read a micro run's § 5 `Checkout` value: return a main checkout still on the item's branch to the base before the next launch.

An owner-directed small change, keyed `directive-[ID]`, is the overseer's own: [directed-change.md](directed-change.md) § Who makes it states the rule, its host and its checks.

A tracker item's run that ends at [micro.md](../workflows/micro.md) § Escape or [small.md](../workflows/small.md) § Escape comes back as an item to launch at the next class up, on the branch it left. So does a run that stops before an escape, such as on a failed push or create.

`[BASE_BRANCH]` is what `.agents/skills/orch/scripts/resolve-base-branch .` prints in the main checkout.

1. Run `tier` again with `--floor` naming the class above the run's class.
2. Pass only `--floor` when no branch holds a commit past `origin/[BASE_BRANCH]`.
3. Otherwise add `--base origin/[BASE_BRANCH] --head [HEAD_REF] --repo [MAIN_REPO_ROOT]`.
   - `[HEAD_REF]` is `origin/[BRANCH]` once a pushed branch is fetched, else the local `[BRANCH]` every worktree on this host shares.
   - A hosted lane's unpushed branch exists only on its host, so that lane runs the line with its worktree as `--repo`.

A directed change's run comes back as the item [directed-change.md](directed-change.md) § Escape files, tiered from its body with no `--floor`. A directed run that stops before an escape also takes [directed-change.md § Escape](directed-change.md#escape).

## Shared files

- Every first launch judges the files the item touches against the fleet's other lanes.
- On surfaces 2 and 3, judge the same rule yourself.
- The touched set is the item's Location paths, the paths the brief names and the paths the request adds.
- A path the request's `in_scope` names as an append-only addition holds nothing.
- A `read_only` launch touches nothing, and its lane holds nothing ([lane-directive.md § A read-only launch](lane-directive.md#a-read-only-launch)).
- The launch judges a holder by its lane's liveness:

| The holder's lane | The launch |
|---|---|
| Running or preparing, before its review | Applies the eligibility rules in [lane-directive.md § A joined launch](lane-directive.md#a-joined-launch) |
| Running or preparing, in its review | Refuses `launch-overlap` naming the `file` and the `holder` |
| Stopped, parked or gone | Proceeds and records nothing |
| Unreadable | Refuses `holder-unreadable` |

- A joined launch's reply's `.result.report` reads `op` `joined` with the `holder`. Send nothing after it.
- Under `ORCH_DELIVERY=push-base`, a first launch passes a holder in its review.
- A `github` item's own pull request is no holder against it.
- The lane record keeps the set as `touched` and the scope as `in_scope`.
- A local or hosted lane's opening brief carries the record's set as one `Admitted paths:` line, a JSON array, ahead of the closing lines [lane-directive.md § Brief file](lane-directive.md#brief-file) lists. That section's item 1 says which records render the line. A `joined` directive carries the holder's widened set the same way, under the same rule ([lane-directive.md § A joined launch](lane-directive.md#a-joined-launch)). Each dev round the lane delegates carries the set ([dev-start.md § 2](../workflows/dev-start.md#2-delegate)).

A running lane that asks for a path outside its admitted set meets the same judge. One ask lists every path a round needs.

1. Write an `admit-paths` request, `{"item": "[ITEM_KEY]", "paths": ["[PATH]"]}`, with every asked path, with the harness file tool, and run it.
2. The reply's `result.touched` is the widened set, or its `refusal.key` names the refusal.
3. Answer the lane's ask with that result: the whole widened set as a JSON array, or the refusal.

```bash
.agents/skills/orch/scripts/orch-runtime admit --fleet --request [REQUEST_FILE]
```

## Lane directive

A launch on the tmux surface takes these steps in order, locally or on a remote control host.

- [lane-directive.md § Launch gate](lane-directive.md#launch-gate) holds the per-provider rules of a Pi or Copilot launch and every refusal of the launch gate.
- Every other surface launches as [oversee.md § 1](../workflows/oversee.md#1-resolve-the-launch-surface) says, with no inventory or pick.

1. **Inventory.** Read the accounts a lane can launch on. On a hosted fleet the provider's reading of an account can disagree with this machine's.

   ```bash
   .agents/skills/orch/scripts/orch-runtime lane roster
   ```

2. **Model.** Read the item's body once.
   - Judge the approach under the project-management skill's `references/filing.md` § Judge the approach.
     - Record go, change or drop, with the short cause-and-effect answer, in the launch `ruling` ([oversee-events.md § Judgement rules](oversee-events.md#judgement-rules)).
   - Judge whether the design choice is consequential or the approach uncertain, and record it in the same ruling.
     - When either holds, the brief tells the lane to run one one-shot `reviewer-arch` review at launch, before implementing, through [design-review.md § Patch-chain actions](design-review.md#patch-chain-actions), step **Second opinion**.
   - Judge the span. An item goes back to filing under the project-management skill's `references/filing.md` § One landing per subsystem when its Location names more than one subsystem, as the `small` class of [change-scope § Classes](../../change-scope/SKILL.md#classes) defines one. For a missing Location, follow § Item Tier step 2.
     - A body that says why the item cannot land in parts keeps it; record that reason in the same ruling.
   - Select the model class and effort through [Model class](skill-rules.md#model-class), and keep a model the brief names.
     - Read `orch-env ORCH_LANE_PREFERENCE ""` as the program's default.
     - Select the model before the account: an account with plan-wide room can have none left for one model.
     - Never pick a weaker model because an account is near its wall: pick another account.
3. **Choose.** The account judge decides.
   - Where `ORCH_LANE_PREFERENCE` is set and the brief names no model, run the preference walk with your own harness and permission words.
     - Take `.result.chosen` as [lane-directive.md § Lane preference](lane-directive.md#lane-preference) reads it:

       ```bash
       .agents/skills/orch/scripts/orch-runtime lane walk --fleet --source-harness [HARNESS] --source-flags [WORDS]
       ```

   - Otherwise judge the account for the lane's model.
     - Add `--lane [CONFIG_DIR] --projected` for an account named by hand.
     - Take `.result.record.config_dir` where `.result.exit` is 0:

       ```bash
       .agents/skills/orch/scripts/orch-runtime lane pick --fleet --harness [HARNESS] --native-model [MODEL]
       ```

   At exit 3 nothing launches: [lane-directive.md § No lane has room](lane-directive.md#no-lane-has-room) says what to read, wait on and report.

4. **Launch.** Send one request per item.
   - For a lane on this host, first create the item's worktree, the claim [oversee.md § 2](../workflows/oversee.md#2-select-work) step 5 names; it prints its path, the request's `mail_root`.
   - A hosted or `claude-cloud` request names this checkout as `mail_root`; the launch creates the lane's worktree and records its path.
   - Write the brief file under [lane-directive.md § Brief file](lane-directive.md#brief-file), then the request with the harness file tool, and run it:

   ```bash
   .agents/skills/worktree/scripts/worktree create [ITEM_KEY]
   ```

   ```json
   {"op":"launch-lane","item":"[ITEM_KEY]","tracker":"[TRACKER]","repo":"[OWNER/REPO]","harness":"[HARNESS]","mail_root":"[WORKTREE_PATH]","account":"[CONFIG_DIR]","model":"[MODEL]","effort":"[EFFORT]","class":"[CLASS]","class_reason":"[CLASS_REASON]","brief_file":"[BRIEF_PATH]"}
   ```

   ```bash
   .agents/skills/orch/scripts/orch-runtime op --fleet --effect-exit --request [REQUEST_FILE]
   ```

   - `[TRACKER]` is `linear` or `github`; the admission reads the item only where the request names its tracker.
   - `repo` names the GitHub repository. A GitHub item needs it; a hosted lane needs `repo` and `account`.
   - `class` is one of the four class words; `class_reason` states why.
   - A first launch names both. A relaunch names both or neither; one naming neither runs at the record's class.
   - A launch names its model.
   - An item whose attempt below `standard` missed launches at `standard` or above.
   - A request naming an `account` also names its `model` and `effort`, a pick's or a walk's included.
   - A Pi model written `provider/id:level` names the effort.
   - Add, where it applies:
     - `host` for a hosted lane, the provider's path, or `claude-cloud` for a cloud session;
     - `permission` for a permission word other than the `AGENT_RUNTIME_LAUNCH_PERMISSION` posture's, spelled as the harness takes it;
     - `refresh: true` for a refresh lane;
     - `desktop: true` where the brief needs the owner's live display;
     - `read_only: true` where the brief changes no repository file ([lane-directive.md § A read-only launch](lane-directive.md#a-read-only-launch));
     - `in_scope` for the paths the brief names in scope;
     - `judge_account: true` for an account named by hand rather than picked;
     - `over_cap` for a deliberate launch past the cap;
     - and `obligation` for the item's accepted lineage ([lane-directive.md § Obligation lineage](lane-directive.md#obligation-lineage)).
   - Exit 0 confirms the launch. Exit 3 is a failed launch, its cause in `.result.effect.report.intent.observation`. Exit 75 is an intent left open, which its reconcile settles. Exit 1 is a refusal.
   - A refusal whose stderr line names `persisted_intent=` recorded its intent: read that intent as [oversee.md § Controller start and adoption](../workflows/oversee.md#controller-start-and-adoption) says. One without it refused before anything was recorded.
   - A first launch the admission joins exits 0 with no effect, its `.result.report.op` reading `joined`.
   - [lane-directive.md § Launch gate](lane-directive.md#launch-gate) holds each refusal and what it licenses.

**Placement.**

- Through the preference walk, a Claude-class lane takes a Claude cloud entry first while its grant admits it, then the Codex fallback.
- Add no cloud session while the control host's available memory is under 2 GB or its kernel `oom_kill` count has risen, and tell the owner when either holds.
- The overseer reads these measurements itself; the launch does not.
- Each cloud session adds pull-request and stall checks to the watch, takes directives through the session channel, and stays out of the mail pass.
- Once its pull request is approved, it needs one landing lane on the fleet host.
- A Claude cloud review or audit is item work: launch it with `host` `claude-cloud` and its brief file.

Before each launch, read `.agents/skills/orch/scripts/orch-runtime host resolve`: any value but `local` makes a hosted fleet.

- A cloud entry's request names `host` `claude-cloud`; another hosted launch names `host` `[HOST]`.
- An approved cloud pull request's landing lane follows the `land=` word of `orch-runtime host --host [HOST] capabilities`. `land=handoff` launches it on this host, naming no `host`; `land=lane` names `host` `[HOST]`.
- Only `oversee` and `handoff` launch a hosted lane.
- On a hosted fleet every item's work launches as a hosted lane through this directive ([SKILL.md](../SKILL.md) § The Cycle, Item work stays in lanes).
- A session with no tmux surface reports the queue once and names that surface as the route.

**The brief.**

- For an implementation phase, the brief is the one § Item Tier assigned, or its `github [OWNER/REPO]#[N]` spelling. Add `Model class: top` with its reason, or `Model class: fast`, only as [Model class](skill-rules.md#model-class) permits.
- For a `claude-cloud` launch, the brief is the item body and the complete tier line alone, under [skill-rules.md § Coordination](skill-rules.md#coordination) for the session channel; the launch appends the cloud session words.
- `/orch` slash syntax does nothing in Codex.
  - A Codex CLI lane takes the prose form `Read .agents/skills/orch/SKILL.md and execute the orch start workflow for [ITEM]`.
  - A Codex Desktop thread takes `$orch start [ITEM]` ([handoff.md](../workflows/handoff.md) § 2).
  - A Pi lane takes `/skill:orch start [ITEM]`.
  - A Copilot CLI lane takes the Codex CLI prose form, which the launch passes as the value of `-i`.
  - At the `micro` and `small` tiers each form names the tier's `brief=` word in place of `start` ([lane-directive.md § Brief file](lane-directive.md#brief-file)).
- The brief names the implementer [dev § Implementer selection](../../dev/SKILL.md#implementer-selection) selects, and follows [skill-rules.md § Private settings](skill-rules.md#private-settings).
- It names the overseer, the status file `tmp/lane-status-[ISSUE_ID].md` and the mailbox `tmp/lane-mail/[ISSUE_ID]/`, both under the lane's worktree.
- It directs the lane to keep the status file current with:
  - its step on a `Step:` line, which the watch reads for `lane-long`;
  - its blocker;
  - its handoff paths;
  - validation minutes per round;
  - the `Review:` line [review-pr.md](../workflows/review-pr.md) § 1 and § 9 and [submit-pr.md](../workflows/submit-pr.md) § 2 write;
  - and one merge-attempt record. That record holds the attempt's exit, its exact `--expected-head` value and the `merge-route: admin|queue cause=...` line it returned.
- Later rewrites keep the review line and that record.
- The lane follows [skill-rules.md § Coordination](skill-rules.md#coordination) for issue proposals and every ask. It plans without a spawned harness child, as the dev skill's per-harness rows state.
- The brief carries no authorization line. The `stages[].authorization` row of [workflow-state.md § Field Definitions](../schemas/workflow-state.md#field-definitions) states what a round close may name as the overseer's act; [dev-start.md § Close The Round's Stages](../workflows/dev-start.md#close-the-rounds-stages) writes it.
- The launch closes every brief with the texts [lane-directive.md § Brief file](lane-directive.md#brief-file) lists. Write none of them.
- A brief sent through surface 2's own launcher carries the output-mode sentence ([skill-rules.md § Lane Output](skill-rules.md#lane-output)) that `orch-env ORCH_LANE_OUTPUT quiet` selects.

A brief naming design and implementation runs both in one lane.

- A phase boundary is a handoff, never a relaunch.
- A design-only phase exists only where the consumer's design-review trigger names it.
  - Its brief names the outcome, the admitted source and scratch paths, the required artifacts and the acceptance owner.
  - It sends no unstarted design phase through `start`'s implementation preparation.
  - It keeps the status, mailbox, context and admission outputs at their required paths.
- A design-only lane reads its brief and the recorded handoff.
- An opinion that lacks an input says so and nothing more.

## Lane record

[Overseer takeover § Fleet state address](../workflows/oversee-takeover.md#fleet-state-address) gives the fleet state address.

- On the tmux surface the launch records every lane it launches or relaunches as one `lanes[]` entry; write nothing by hand.
- A launch needs the state, which [oversee.md § Controller start and adoption](../workflows/oversee.md#controller-start-and-adoption) step 1 creates.
- [lane-directive.md § Tmux session](lane-directive.md#tmux-session) names the tmux session lane windows open in.

A record's `item` is `[ITEM_KEY]` throughout oversee.md and this reference, as the launch request and the watch name it: the Linear id for a Linear item and `issue-N` for a GitHub item. It is never the `[OWNER/REPO]#[N]` the brief spells.

On surfaces 2 and 3 the overseer's first written record creates the state: a surface-2 lane record below, or a `fleet_log` or `triaged` entry ([oversee-events.md](oversee-events.md)). Before that first write, where `state exists --fleet` answers false, run `state init --fleet`.

On surface 2, record the lane after an item's first launch, with `window` null.

- `[OBLIGATION_OR_NULL]` is the accepted object from [Obligation lineage](lane-directive.md#obligation-lineage), or JSON `null` when unknown.
- `[NOW]` is `date -u +%Y-%m-%dT%H:%M:%SZ`, read before the launch it stamps.

```bash
.agents/skills/orch/scripts/orch-runtime op --fleet --request-json '{"op":"record-surface-lane","step":"create","lane":{"item":"[ITEM_KEY]","tracker":"[TRACKER]","repo":"[OWNER/REPO_OR_NULL]","harness":"[HARNESS]","window":null,"account":null,"host":null,"mail_root":"[LANE_WORKTREE]","surface":"[SURFACE]","model":"[MODEL]","session_id":null,"launched_at":"[NOW]","status":"running","obligation":[OBLIGATION_OR_NULL]}}'
```

For a recorded surface-2 item, write the changed fields to `tmp/lane-merge-[ITEM_KEY].json` with the harness file tool, and merge them.

- Each field the file names replaces the record's.
- Its `obligation` binds once ([lane-directive.md § Obligation lineage](lane-directive.md#obligation-lineage)): state one only from the accepted directive.
- Never append a second record for an item, and never replace a record whole.
- A relaunch and a handoff keep `launched_at`. A fresh launch can renew it, keeping the obligation and the previous cycle.

```bash
.agents/skills/orch/scripts/orch-runtime op --fleet --request-json '{"op":"record-surface-lane","step":"merge","item":"[ITEM_KEY]","file":"tmp/lane-merge-[ITEM_KEY].json"}'
```

```bash
.agents/skills/orch/scripts/orch-runtime state get --fleet /lanes/0/launched_at
```

- `mail_root` is the lane's worktree path as its own host sees it.
- The lane's status file is `[MAIL_ROOT]/tmp/lane-status-[ISSUE_ID].md`.
- A mailbox call for a lane whose record carries `host`, or whose `mail_root` is a worktree of another repository, takes the route of [oversee-lanes.md § Talking to a lane](oversee-lanes.md#talking-to-a-lane).
- A hosted lane's provider reads run as `orch-runtime host --host [HOST] cat` or `touch`. A lane on this host needs neither.
