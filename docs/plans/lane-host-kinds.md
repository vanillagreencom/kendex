# Lane host kinds

**Status**: design only. The build waits for the owner's approval of KEN-2589. Nothing in this document is built.

Every place an orch lane runs becomes a host kind. A kind declares its capabilities in one line, and every caller acts on a declared capability, never on a host or provider name. `open-terminal` stays the only launcher, the fleet lane record stays the only record, and `lanes pick` stays the only account pick. The decision is [D020](https://github.com/vanillagreencom/kendex/blob/main/docs/decisions/D020-lane-host-kinds.md). Provider facts come from the [research report](claude-cloud-launch-research.md) and the pages it links. Fleet facts come from FLT-551, quoted in KEN-2589.

## Host kinds

| Kind | Where the lane runs | Launch | What it offers | Source |
|---|---|---|---|---|
| `local` | A tmux window on this machine | `open-terminal` opens the window and types the start command | A mailbox file, the worktree on this disk, pane and process status, a window kill, a native resume | `skills/orch/scripts/open-terminal` (`open_tmux`, `start_cmd`) |
| `ssh`, static | A machine in the `lane-host-ssh` inventory | `lane-host create`, then an SSH session in a tmux window | Every verb of `schemas/lane-host.md` § Provider protocol except `accounts` and the `stop-sandbox` and `start` pair | `skills/orch/schemas/lane-host.md` § Static SSH implementation |
| `ssh`, Daytona | A fleet Daytona sandbox | The same route, through `bin/lane-host-daytona` | The same verbs plus `accounts` and the `stop-sandbox` and `start` pair (park) | KEN-2494 (`lane-host-daytona accounts`); [research § Daytona compute and Copilot pool room](claude-cloud-launch-research.md#daytona-compute-and-copilot-pool-room) |
| `claude-cloud` | An Anthropic-hosted Claude Code cloud session | `claude --cloud "task"` from a checkout | A clone of the checkout's GitHub remote at its current branch, a push through the GitHub proxy, a queued follow-up through `claude -p "msg" --cloud <session-id>`. No SSH, no file access, no stop verb | [claude-code-on-the-web § From terminal to cloud](https://code.claude.com/docs/en/claude-code-on-the-web#from-terminal-to-cloud); [research § Fit with orch](claude-cloud-launch-research.md#fit-with-orch) |
| `codex-cloud` | An OpenAI-managed Codex cloud task | `codex cloud exec --env ENV_ID [--branch BRANCH] QUERY` | Task status through `codex cloud list --json`, the result as `diff` and `apply`. No follow-up into a task, no pull request from the CLI | [research § Codex cloud tasks](claude-cloud-launch-research.md#codex-cloud-tasks) |

A managed cloud is a kind, not a lane-host provider. The provider protocol needs `ssh-target=`, `path=` and `remote-prefix=` from `create`, and `cat`, `put` and `append` against host files (`schemas/lane-host.md` § Provider protocol). A cloud session offers none of them ([research § Fit with orch](claude-cloud-launch-research.md#fit-with-orch)).

## One lane model and one launch entry point

### The capability line

`lane-host capabilities` prints one tab-separated `key=value` line for the kind that `ORCH_LANE_HOST` names. Each key takes one value from a closed set, and each caller matches the value exhaustively. An unknown value refuses as `capability-invalid key=KEY value=VALUE`.

| Key | Values | Caller that matches on it |
|---|---|---|
| `kind` | `local`, `ssh`, `claude-cloud`, `codex-cloud` | `open-terminal` writes it into the lane record. Fleet reads it. No caller branches on it. |
| `launch` | `window`, `ssh`, `cloud-session`, `cloud-task` | `open-terminal` |
| `channel` | `mailbox`, `session`, `task` | `lane-mail`, `oversee-watch` mail pass, `lane-close` ask check |
| `files` | `local`, `verb`, `none` | `open-terminal` marker check, `oversee-watch` status-file and workflow-state reads |
| `status` | `pane`, `verb`, `task`, `none` | `oversee-watch` lane judgement |
| `stop` | `window`, `verb`, `none` | `lane-close` |
| `relaunch` | `resume`, `fresh` | `open-terminal --relaunch` |
| `park` | `verb`, `none` | `lane-close --park` |
| `accounts` | `verb`, `none` | `lanes` (`host_account_rows`) |
| `pool` | `plan`, `cloud-credit` | `lanes pick` (§ [One account and room pick](#one-account-and-room-pick)) |
| `land` | `lane`, `handoff` | The overseer at review convergence (§ [The managed-cloud channel](#the-managed-cloud-channel)) |

`channel` is the issue's mailbox capability. `files` is its file access. The declared lines:

| Kind | `launch` | `channel` | `files` | `status` | `stop` | `relaunch` | `park` | `accounts` | `pool` | `land` |
|---|---|---|---|---|---|---|---|---|---|---|
| `local` | `window` | `mailbox` | `local` | `pane` | `window` | `resume` | `none` | `none` | `plan` | `lane` |
| `ssh`, static | `ssh` | `mailbox` | `verb` | `verb` | `verb` | `resume` | `none` | `none` | `plan` | `lane` |
| `ssh`, Daytona | `ssh` | `mailbox` | `verb` | `verb` | `verb` | `resume` | `verb` | `verb` | `plan` | `lane` |
| `claude-cloud` | `cloud-session` | `session` | `none` | `none` | `none` | `fresh` | `none` | `none` | `cloud-credit` | `handoff` |
| `codex-cloud` | `cloud-task` | `task` | `none` | `task` | `none` | `fresh` | `none` | `none` | `plan` | `handoff` |

### Where the declaration lives

- The `lane-host` dispatcher answers `capabilities` itself for `local`, `claude-cloud` and `codex-cloud`. kendex owns those kinds, because each runs a harness CLI's own cloud interface and no provider script stands between.
- For a provider path, the dispatcher passes `capabilities` to the provider, which declares its own line. `lane-host-ssh` declares the static line. Fleet's `bin/lane-host-daytona` declares the Daytona line (proposed FLT item 2).
- `schemas/lane-host.md` gains § Host kinds with the two tables above. The dispatcher is the one executable form.
- The `ORCH_LANE_HOST` and `--host SPEC` grammar gains the words `claude-cloud` and `codex-cloud` beside `local` and a script path. `lane-host resolve` prints the word as it does `local`.
- Provider verbs under a cloud kind refuse as `host-kind-verb kind=KIND verb=VERB` with exit 2, the status `host-local` uses (`skills/orch/scripts/lane-host`). A caller that matched its capability never meets it.

### Absent-verb probing (KEN-1553)

The declaration replaces probing. A caller reads the line once per operation and calls only the verbs its capability names. Three probes go: `lane-close --park`'s `stop-sandbox --check` read, `lanes`' exit-2 read of `accounts`, and `oversee-watch`'s pane fallback on `status` exit 2. KEN-1553's optional verbs (`--class`, `walled`) become declared keys when they land, not probed verbs. A declared verb that exits 2 is a provider fault, reported under the caller's host-failure key.

A provider that does not answer `capabilities` yet exits 2. Until fleet ships FLT item 2, the dispatcher answers the static `ssh` line for it with `park=check`, which sends `lane-close --park` to today's `stop-sandbox --check` read. This compatibility arm serves providers older than the build and goes when FLT item 2 merges.

### One record, one launcher

- `open-terminal` matches `launch`. `window` and `ssh` are today's arms. `cloud-session` is the new arm in § [The smallest first build](#the-smallest-first-build). `cloud-task` refuses as `kind-unbuilt kind=codex-cloud` until the owner asks for it.
- The lane record keeps its fields (`open-terminal` `lane_record_write`). A cloud lane records `host` as the kind word, `kind` from the line, `account`, `session_id` as the cloud session id or Codex task id, and no `window`. No new store holds the session id.
- `oversee-watch`, `lane-mail` and `lane-close` read each record's `host` and run `lane-host` under `ORCH_LANE_HOST` set to it. `lane-close` does this today (`close_host`). `oversee-watch` does not: `LANE_ROWS_FILTER` reduces `host` to `local` or `hosted`, and `check_lane_host` holds one `LANE_HOST_SPEC` for the whole fleet. The rows carry the record's `host` instead, so one fleet holds lanes of several kinds.
- `open-terminal` tests `LANE_HOST` against `local` in 18 places. Each test becomes a match on the capability that the test stands for (§ [What it deletes or folds in](#what-it-deletes-or-folds-in)).

## The lane-host.md split

| Verb or rule in `schemas/lane-host.md` | Verdict | Notes |
|---|---|---|
| `create` | Stays | Every kind that launches through a provider runs it. A cloud kind has no provider and launches through its CLI (`launch`). |
| `create` line: `ssh-target=`, `path=`, `remote-prefix=` | SSH-only | `launch=ssh` |
| `create` line: `state=preparing` | Stays | Any provider may accept early ([D002](https://github.com/vanillagreencom/kendex/blob/main/docs/decisions/D002-hosted-launch-handoff.md)). This design does not change `create`. |
| `create` line: `pi-root=` | SSH-only | A cloud kind runs only its own harness. |
| `wait` | Stays | It pairs with `state=preparing`. |
| `cat`, `put` | Becomes a capability | `files=verb` |
| `append` | Becomes a capability | `channel=mailbox` on `files=verb`. The append-not-put rule and the mailbox symlink guard stay with it. |
| `touch` | SSH-only | It keeps a host alive or probes a static host. |
| `status` | Becomes a capability | `status=verb` |
| `close` | Stays | Its render patch, archive and `--merged` rules are SSH-only. A `stop=none` kind has nothing to close. |
| `stop` | Becomes a capability | `stop=verb` |
| `stop-sandbox` and `start` | Becomes a capability | `park=verb`. `--check` goes (§ [Absent-verb probing](#absent-verb-probing-ken-1553)). |
| `list` | SSH-only | Inventory hosts |
| `accounts` | Becomes a capability | `accounts=verb`. The one reader in `lanes` stays. |
| Dispatcher statuses, `69` slot cap, `host-unavailable` | Stays | |
| Launch record and marker verification | SSH-only | `files=verb`. A local lane writes its marker itself. A `files=none` kind writes none: its record's `session_id` is its launch record. |
| Pre-approval and folder trust | SSH-only | A cloud kind takes § [The permission route](#the-permission-route) instead. |
| Hosted worktree path | SSH-only | |
| Credential copy and `--account` re-seed | SSH-only | A cloud kind runs under the account's own login on this machine. |
| Base-tip tree, no `kendex refresh` in `create` | Stays | `open-terminal` pushes the item branch from the base tip before a cloud launch. |
| Pi rules, Copilot rules | SSH-only | |
| Codex hook approval | SSH-only | Whether a Codex cloud task runs repository hooks is not documented (§ [Open questions](#open-questions)). |

## The managed-cloud channel

### Directives

- `claude-cloud` (`channel=session`): `lane-mail send --directive --state-dir STATE` reads the item's record, as `lane-close` does, and runs `claude -p --cloud <session_id> --output-format json` under the record's account, the text on stdin. `{ok: true}` is delivery. The CLI queues the message and exits ([claude-code-on-the-web § Send follow-ups from the CLI](https://code.claude.com/docs/en/claude-code-on-the-web#send-follow-ups-from-the-cli)). There is no read receipt, so the watch's `directive-read` and `directive-unread` do not apply. `{ok: false}` for an archived session refuses as `session-archived`.
- `codex-cloud` (`channel=task`): no CLI verb or API sends into a task ([research § Codex cloud tasks](claude-cloud-launch-research.md#codex-cloud-tasks)). The consequence: a Codex cloud brief is complete at launch, and a review fix is a new `codex cloud exec --branch <item branch>` task with the finding in its query. `lane-mail send --directive` to it refuses as `channel-task`.
- `--re` and `--halt` to a `session` or `task` channel refuse. Such a lane never asks (§ [The lane-mail rule](#the-lane-mail-rule)), so there is nothing to answer. A halt has no enforcing hook there, so a stop goes to the owner (§ [What a cloud lane cannot do](#what-a-cloud-lane-cannot-do)).

### Reports

- `claude-cloud`: the session pushes the item branch and opens a draft pull request as its first step. The pull request body holds the lane status under `## Lane status`, in place of `tmp/lane-status-ITEM.md`. The overseer reads the body with `gh pr view` where it reads a status file for other kinds (`skills/orch/workflows/oversee.md` § Bounded lane reads).
- `oversee-watch` reads what it reads today. `pr-watch` covers the pull request and `check_merged` finds the merge by branch name. The start-stall check reads an open pull request on the branch for a `files=none` kind in place of the status file (`check_start_stall`).
- `codex-cloud`: `codex cloud list --json` gives `status` per task. The diff is the report.

### Landing

Work lands by branch push, then the repository's normal pull request, review and merge route. A `land=handoff` lane does not merge. At review convergence the overseer relaunches the item on a `land=lane` kind with a fresh brief for `skills/orch/workflows/merge-pr.md` § 5. That lane merges under the lanes app identity (§ [The GitHub App](#the-github-app)) and writes the completion. A `codex-cloud` result reaches a pull request the same way: the landing lane runs `codex cloud apply TASK_ID` in the item worktree, then `submit-pr.md`.

Review fixes on a `claude-cloud` pull request reach the session as directives carrying the `pr-watch` line. Claude's own auto-fix ([claude-code-on-the-web § Auto-fix pull requests](https://code.claude.com/docs/en/claude-code-on-the-web#auto-fix-pull-requests)) is not used, because its fixes skip the dispositions of `skills/orch/references/finding-disposition.md`.

### The lane-mail rule

`skills/orch/references/skill-rules.md` § Coordination says a lane reaches its overseer through `scripts/lane-mail` "and nothing else". The build restates it once, by `channel`:

- `mailbox`: as today.
- `session`: the lane reaches its overseer through its branch and pull request and nothing else: commits, the `## Lane status` body, and a pull request comment that names a blocker. It never asks. A step that needs an answer is a step the kind never takes, so the lane names the blocker in the pull request and ends its turn.
- `task`: the lane reaches its overseer through its task status and diff and nothing else.

The same section requires every brief to close on `LAUNCH_UNATTENDED_TEXT`, which tells the lane to use `lane-mail ask`. A `session` brief closes on a second constant beside it in `scripts/lib/lane-launch.sh` that states the `session` rule above. No kind or provider carries its own copy.

### What a cloud lane cannot do

| It cannot | Why | Who does it instead |
|---|---|---|
| Read or write Linear | `api.linear.app` is not in the Trusted egress list (FLT-551, quoted in KEN-2589). Codex egress is off by default ([research § Codex cloud tasks](claude-cloud-launch-research.md#codex-cloud-tasks)). | The overseer reads the issue live and puts its text in the brief. The overseer writes the activation. The landing lane writes the completion. |
| Use lane mail | No mailbox and no file access | The `session` and `task` rules above |
| Run the hooks that need the mailbox | The lane-mail hooks pass a session that is no launched lane (`hooks/lane-mail-halt.sh` description). A cloud clone holds no launch record (`schemas/lane-host.md`, launch record rule), so they stay silent. | Nothing replaces them. The pull request is the turn-end report. |
| Stop or park | No stop verb is documented. Archive is a claude.ai sidebar action ([claude-code-on-the-web § Archive sessions](https://code.claude.com/docs/en/claude-code-on-the-web#archive-sessions)). | `lane-close` closes the record and the local worktree and prints `host-kept kind=KIND session=ID`. The owner archives the session. |
| Merge under the lanes identity | Commits land under the connected GitHub user (§ [The GitHub App](#the-github-app)) | The landing lane |
| Hand off at a context mark | The handoff needs the mailbox | A cloud lane keeps Claude's automatic compaction on. |

An item whose repository exceeds the cloud VM takes no cloud kind. FLT-551 records that hyprtrade exceeds 16 GB RAM and 30 GB disk.

## The permission route

- A cloud session offers Accept edits, Plan and Auto, and no Bypass ([research § Add-repo and push pre-approval](claude-cloud-launch-research.md#add-repo-and-push-pre-approval)). A lane brief written for `--dangerously-skip-permissions` (`LAUNCH_CHOICE_FLAGS` in `skills/orch/scripts/lib/lane-launch.sh`) runs in Auto.
- The `session` brief names the steps the kind never takes: `linear.sh`, `lane-mail`, `pr-merge`, a background wake, `tools/setup` and git hook arming, and any wait on a person.
- A step that Auto still holds for approval gets an allow rule in the repository's `.claude/settings.json`, which a cloud session loads ([research § Add-repo and push pre-approval](claude-cloud-launch-research.md#add-repo-and-push-pre-approval)). The build adds no rule in advance. The acceptance run lists each approval the session asked for, and each becomes an allow rule or a step the kind never takes.
- A repository deny rule for `AskUserQuestion` and `EnterPlanMode` is rejected: it binds the owner's own sessions in that repository too. The brief carries the unattended words, and an unanswered question leaves the session idle, which the start-stall check reports.

User-level settings do not reach a cloud session ([research § Add-repo and push pre-approval](claude-cloud-launch-research.md#add-repo-and-push-pre-approval)). Their replacements:

| Local lane setting | Cloud replacement |
|---|---|
| `CLAUDE_CODE_EFFORT_LEVEL=high`, `CLAUDE_CODE_SUBAGENT_MODEL` | Environment variables on the account's cloud environment ([cloud-environments](https://code.claude.com/docs/en/cloud-environments#set-environment-variables)). FLT-551 names both. |
| Hooks, agents, skills, `CLAUDE.md` | The repository's `.claude/` and `CLAUDE.md`, which load in a one-repository session. The base branch commits that render (`schemas/lane-host.md`, base-tip rule). |
| Plugins | None. A cloud session installs no plugin that repository settings turn on. |
| `--disallowedTools`, `DISABLE_AUTO_COMPACT` | Whether `claude --cloud` carries local flags is unconfirmed (§ [Open questions](#open-questions)). Compaction stays on (§ [What a cloud lane cannot do](#what-a-cloud-lane-cannot-do)). |

## The GitHub App

- **Coverage.** The owner extended the Claude GitHub App installation on vanillagreencom to kendex, fleet, vgs and vsys and read it back (owner note 1790968643). The overseer token gets HTTP 403 on organization installations, so the record rests on that read-back.
- **Bundle check.** `claude --cloud` clones only when the App covers the repository, and bundles otherwise ([research § Bundle cause after the App install](claude-cloud-launch-research.md#bundle-cause-after-the-app-install)). The check is the [research acceptance test](claude-cloud-launch-research.md#acceptance-test). Before each launch `open-terminal` refuses `cloud-bundle-risk` when `CCR_FORCE_BUNDLE` is set or the remote is not a github.com URL, the two causes a launcher can read.
- **Commit identity.** Cloud commits and pull requests land under the GitHub user connected to the Claude account (FLT-551, quoted in KEN-2589). The lanes-app identity rule says a lane pushes and merges under the lanes app's installation token ([D003](https://github.com/vanillagreencom/kendex/blob/main/docs/decisions/D003-one-merge-path.md) § Context; `skills/orch/workflows/merge-pr.md` § 5 step 1, "Who acts"). A cloud lane breaks that rule, so it is `land=handoff`. The connected user's pull request still counts as fleet work, because the outside-contribution check admits `OWNER`, `MEMBER` and `COLLABORATOR` authors (`skills/orch/workflows/oversee.md` § Outside contributions). GitHub's approval rule still holds ([D018](https://github.com/vanillagreencom/kendex/blob/main/docs/decisions/D018-platform-review-requirements.md)).

## One account and room pick

### Pools

| Pool | Reading | Expires or resets |
|---|---|---|
| Claude weekly and 5-hour windows | `lanes` `parse_claude_usage` | Refills at each reset |
| Claude cloud credit | `usage.iguana_necktie`: `limit_dollars`, `used_dollars`, `remaining_dollars`, `resets_at`, `locked_reason` (KEN-2589 correction 3). `parse_claude_usage` ignores it today. | Expires at E below. It does not refill. |
| Codex windows | `parse_codex_usage` | Refill. Codex cloud tasks share them ([research § Codex cloud tasks](claude-cloud-launch-research.md#codex-cloud-tasks)). |
| Codex credits | The `credits` object (KEN-2494) | No expiry |
| Copilot pool | `lib/copilot-credits.sh`, or a provider's `harness=pi` row | Refills monthly |
| Daytona compute | No reader in kendex ([research § Daytona compute and Copilot pool room](claude-cloud-launch-research.md#daytona-compute-and-copilot-pool-room)) | Metered. It is the host's cost, not an account's allowance. |

`parse_claude_usage` returns the cloud credit as a `credits` object with `unit: "usd"`. `emit_lane` carries it into the record as it carries the Copilot pool and the KEN-2494 Codex balance.

### The expires-first rule

`lanes pick` spends the allowance that expires first. This rule is stated once, in `lanes --help` § pick, and judged once, in the sort key of `lane_selection` in `skills/orch/scripts/lib/lane-model.sh`. Its authority is owner note 1790967939 and [D020](https://github.com/vanillagreencom/kendex/blob/main/docs/decisions/D020-lane-host-kinds.md). No `authority.md` exists (KEN-2589 correction 6).

Each candidate with room gets a tier from the pool the launch spends first:

- **Tier 0**: a grant that expires and does not refill. The Claude cloud credit is tier 0 when the kind declares `pool=cloud-credit`, `remaining_dollars` is above 0, `locked_reason` is null and E is ahead. Its verdict is `room` whatever the plan windows read: four probe sessions ran on a week at 100 percent ([research § Cost after the plan week](claude-cloud-launch-research.md#cost-after-the-plan-week)).
- **Tier 1**: a window that refills. This is every account today.
- **Tier 2**: a balance with no expiry. KEN-2494's credit-backed Codex account is tier 2.

The chooser sorts the room candidates by:

```text
key = [tier, E, -S, claims, -projected_headroom_pct, wall]
S   = H * (1 + 1 / (1 + T))
```

- E is the epoch of the effective expiry for tier 0, and 0 for tiers 1 and 2.
- S is today's `selection_score` (`with_lane_selection_score`). For tier 0, H is `100 * remaining_dollars / limit_dollars` and T is the hours to E. For tier 1, H and T are unchanged. For tier 2, S is the balance, which keeps KEN-2494's larger-balance-first order.
- `claims`, `projected_headroom_pct` and `wall` are today's keys after S.

KEN-2494's leading key, plan room before credits, is the tier 1 to tier 2 step of this key. The pick extends it and keeps no second copy. Within tier 1 the order is unchanged. When the credit is spent or past E, the account falls to tier 1 on its plan windows, which cloud sessions share ([research § Cost after the plan week](claude-cloud-launch-research.md#cost-after-the-plan-week)).

The kind is the overseer's choice per item. `lanes pick` ranks accounts for that kind. `lanes list` shows each account's credit and E, so the overseer sends cloud-fit items to `claude-cloud` while any account holds credit.

### Effective expiry and its readers

- E is the earlier of `iguana_necktie.resets_at` and, for a subscription that will not renew, its period end.
- The period end is the next monthly anniversary of `organization.subscription_created_at` after now.
- The one reader of `subscription_created_at` is `lanes` `measure_lane`. It sends `GET https://api.anthropic.com/api/oauth/profile` with the account's bearer token and reads `.organization.subscription_created_at` ([research § Subscription period end source](claude-cloud-launch-research.md#subscription-period-end-source)). It reads only an account that will not renew, and it caches the answer with the usage body.
- The renewal source is `ORCH_LANE_RETIRE`, the owner's lapse list in setting form. A `<name>=<YYYY-MM-DD>` entry says the account is not the fleet's from that date (`skills/orch/scripts/lanes` header). The profile body names no renewal field ([research § Subscription period end source](claude-cloud-launch-research.md#subscription-period-end-source)). An account the setting does not name renews.
- A failed profile read leaves the retire date standing in for the period end, with the keyed note `lanes: period-end-unread account=NAME`.

## What fleet records

| Kind | Host kind (beside `machine_kind`) | Account | Session id | Cost source |
|---|---|---|---|---|
| `local` | `local` | Record `account` | Record `session_id` (harness session) | Model cost from tokens |
| `ssh`, static | `ssh` | Record `account` | Record `session_id` | Model cost from tokens |
| `ssh`, Daytona | `ssh` | Record `account` | Record `session_id` | Daytona `cost_usd` plus model cost from tokens |
| `claude-cloud` | `claude-cloud` | Record `account` | Cloud session id; the URL is `claude.ai/code/<id>` | `used_dollars` delta between launch and close, from `lanes list --json` |
| `codex-cloud` | `codex-cloud` | Record `account` | Codex task id | Codex credit balance delta past the plan windows, else a plan-window share |

A `used_dollars` delta is per account. It is exact for a lane only while that lane is the account's one cloud session.

Proposed FLT items. This item files none:

1. The hub lane table gains `host_kind`, `session_ref` and `cost_source` beside `machine_kind`, read from the lane record's `kind`, `session_id` and `account`.
2. `bin/lane-host-daytona` answers `capabilities` with the Daytona line. kendex then deletes the `park=check` arm.
3. Cost per cloud lane: the `used_dollars` delta for `claude-cloud` and the Codex credit delta for `codex-cloud`, read from `lanes list --json`.
4. If Daytona holds an expiring compute grant, its `accounts` row carries it as a pool with an expiry, and it joins tier 0 with no kendex rule change.

## What it deletes or folds in

- **No second launcher, picker or record.** `open-terminal`, `lanes pick` and the lane record take the cloud kinds.
- **By-hand cloud sessions.** The `Nclaude --cloud` sessions that vgs and vsys start by hand become `open-terminal --host claude-cloud` launches. They gain a record, a pick and a watch. Sessions started before the build finish by hand.
- **KEN-1553's absent-verb probing.** The capability line replaces it (§ [Absent-verb probing](#absent-verb-probing-ken-1553)). KEN-1553 keeps its verbs and loses its probe rule.
- **Probes deleted.** The `stop-sandbox --check` read in `lane-close --park` (after FLT item 2), the exit-2 `accounts` read in `lanes`, and the exit-2 pane fallback for `status` in `oversee-watch`.
- **Host-name branches.** The 18 `LANE_HOST` tests against `local` in `open-terminal`, the `local` or `hosted` reduction in `oversee-watch`, and the `host` emptiness tests in `lane-close` become capability matches.
- **Per-kind exceptions.** None. The lane-mail rule is restated per `channel`, never per kind or provider.

## The smallest first build

The first build spends Claude cloud credit through this design before the 2claude lapse on 2026-10-08. All 11 accounts' credit expires at 2026-11-05T07:59Z (KEN-2589 correction 3). It builds `claude-cloud` only. `codex-cloud` adds no expiring pool, so it waits for the owner.

| File | Change | Lines |
|---|---|---|
| `skills/orch/scripts/lane-host` | `capabilities` verb: built-in lines for `local` and `claude-cloud`, the provider pass-through, the `park=check` compatibility arm, `host-kind-verb` | 35 |
| `skills/orch/scripts/open-terminal` | `launch=cloud-session` arm: `cloud-bundle-risk` check, `worktree create`, push of the item branch, `claude -p --cloud` under the account in that worktree, session id read, record write with `host`, `kind`, `session_id` and no window | 90 |
| `skills/orch/scripts/lib/lane-launch.sh` | The `session` brief constant | 15 |
| `skills/orch/scripts/lane-mail` | `send --directive` reads the record and matches `channel`: `session` sends through `claude -p --cloud`; `--re` and `--halt` refuse there | 45 |
| `skills/orch/scripts/oversee-watch` | Rows carry the record's `host`; the mail pass reads only `channel=mailbox`; start-stall reads the pull request for `files=none` | 35 |
| `skills/orch/scripts/lane-close` | `stop=none` arm: close the record and the local worktree, print `host-kept` | 20 |
| `skills/orch/scripts/lanes`, `lib/lane-model.sh` | `iguana_necktie` into `credits`, the tier 0 verdict and the tier key, with the retire date standing in for the period end | 45 |
| `schemas/lane-host.md`, `references/skill-rules.md`, `references/oversee-lanes.md`, `lanes --help` | § Host kinds, the lane-mail rule per `channel`, the directive row, the expires-first rule | 35 |
| `skills/orch/tests/` | Rows for each changed surface against a `claude` stub and the `tests/fixtures/lane-host` stub, each with its must-fail control | 170 |

That is about 285 production lines, 35 doc lines and 170 test lines, with a changelog fragment and the `.agents/skills/orch/` renders in the same commit. The second build, before 2026-11-05, adds the `subscription_created_at` reader, the credit column in `lanes list`, and the capability matches that replace the host-name branches.

Acceptance test:

1. The [research acceptance test](claude-cloud-launch-research.md#acceptance-test), steps 1 to 5, on vsys and on kendex.
2. `open-terminal --host claude-cloud --state-dir STATE ITEM` for one small item picks 2claude through the tier key while `ORCH_LANE_RETIRE` names it. The record shows `host=claude-cloud`, `kind`, `session_id` and no window.
3. One directive: `lane-mail send --directive` answers `{ok: true}`, and the session's next push or `## Lane status` shows that it acted on it.
4. One pull request landed through the normal route: the session opens it, Copilot reviews it, a landing lane merges it under `merge-pr.md` § 5, `oversee-watch` reports `merged`, and `lane-close` closes the record.
5. 2claude's `used_dollars` rises across the run. Each approval the session asked for is recorded as an allow rule or a step the kind never takes.

## Open questions

| Question | Source that left it open | Who answers |
|---|---|---|
| Does `claude -p --cloud "task" --output-format json` create a session and print its id? The docs show JSON only for a follow-up. If it does not, the build stops at that step and asks the owner; no pane read stands in. | [claude-code-on-the-web § Send follow-ups from the CLI](https://code.claude.com/docs/en/claude-code-on-the-web#send-follow-ups-from-the-cli) | The build lane, in acceptance step 2 |
| Does a follow-up reach a session whose VM was reclaimed but which is not archived? | [claude-code-on-the-web § Environment expired](https://code.claude.com/docs/en/claude-code-on-the-web#environment-expired) | The build lane, in the acceptance run |
| Which permission mode does a `claude --cloud` session start in, and does it carry local flags such as `--disallowedTools`? | [research § Add-repo and push pre-approval](claude-cloud-launch-research.md#add-repo-and-push-pre-approval) | The build lane, in the acceptance run |
| Does the cloud credit apply while the 5-hour window is walled? The probe covered the weekly window only. | [research § Cost after the plan week](claude-cloud-launch-research.md#cost-after-the-plan-week) | The owner, from claude.ai Settings > Usage during the run |
| Does the profile body carry a renewal field? | [research § Subscription period end source](claude-cloud-launch-research.md#subscription-period-end-source) | The build lane, from one profile read |
| What is the anniversary on a month that lacks the start day? | Not documented | The owner, from Anthropic billing |
| Which GitHub user did each of the 11 accounts connect? | FLT-551, quoted in KEN-2589 | The owner |
| Does a bundle after a correct App install come from bug #81776? | [research § Bundle cause after the App install](claude-cloud-launch-research.md#bundle-cause-after-the-app-install) | The acceptance test, step 5 |
| Is there a CLI or API read of a cloud session's state? | No source documents one | Anthropic docs, read again at the second build |
| For `codex-cloud`: the output of `status`, repository config and hook loading, approval policy and commit identity | [research § Codex cloud tasks](claude-cloud-launch-research.md#codex-cloud-tasks) | The lane that builds `codex-cloud`, from OpenAI docs |
| Does Daytona hold an expiring compute grant? | [research § Daytona compute and Copilot pool room](claude-cloud-launch-research.md#daytona-compute-and-copilot-pool-room) | Fleet (FLT item 4) |
