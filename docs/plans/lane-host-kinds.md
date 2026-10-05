# Lane host kinds

**Status**: the first build of § [The smallest first build](#the-smallest-first-build) is built (KEN-2609): `claude-cloud` only, its acceptance run still to come. `codex-cloud`, the second build and the FLT items are not built.

Every place an orch lane runs becomes a host kind. A kind declares its capabilities in one line, and every caller acts on a declared capability, never on a host or provider name. `open-terminal` stays the only launcher, the fleet lane record stays the only record, and `lanes pick` stays the only account pick. The decision is [D020](https://github.com/vanillagreencom/kendex/blob/main/docs/decisions/D020-lane-host-kinds.md). Provider facts come from the [research report](claude-cloud-launch-research.md) and the pages it links. Fleet facts come from FLT-551, quoted in KEN-2589.

## Host kinds

| Kind | Where the lane runs | Launch | What it offers | Source |
|---|---|---|---|---|
| `local` | A tmux window on this machine | `open-terminal` opens the window and types the start command | A mailbox file, the worktree on this disk, pane and process status, a window kill, a native resume | `skills/orch/scripts/open-terminal` (`open_tmux`, `start_cmd`) |
| `ssh`, static | A machine in the `lane-host-ssh` inventory | `lane-host create`, then an SSH session in a tmux window | Every verb of `schemas/lane-host.md` § Provider protocol except `accounts`, `wait` and the `stop-sandbox` and `start` pair. Its `create` completes before it returns. `wait` applies only where `create` returns `state=preparing` | `skills/orch/schemas/lane-host.md` § Static SSH implementation |
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
| `launch` | `window`, `ssh`, `cloud-session`, `cloud-task` | `open-terminal`; `lanes pick` for repository access (§ [The GitHub App](#the-github-app)) |
| `channel` | `mailbox`, `session`, `task` | `lane-mail`, `oversee-watch` mail pass, `lane-close` ask check |
| `files` | `local`, `verb`, `none` | `open-terminal` marker check, `oversee-watch` status-file and workflow-state reads |
| `status` | `pane`, `verb`, `task`, `none` | `oversee-watch` lane judgement |
| `stop` | `window`, `verb`, `none` | `lane-close` |
| `relaunch` | `resume`, `fresh` | `open-terminal --relaunch` |
| `park` | `verb`, `none` | `lane-close --park`, from FLT item 2 (§ [Absent-verb probing](#absent-verb-probing-ken-1553)) |
| `accounts` | `verb`, `none` | `lanes` `host_accounts_answer`, whose rows `host_account_rows` parses, from FLT item 2 |
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
- For a provider path, the dispatcher passes `capabilities` to the provider, which declares its own line. § [Absent-verb probing](#absent-verb-probing-ken-1553) says which providers answer it and from when.
- `schemas/lane-host.md` gains § Host kinds with the two tables above. The dispatcher is the one executable form.
- The `ORCH_LANE_HOST` and `--host SPEC` grammar gains the words `claude-cloud` and `codex-cloud` beside `local` and a script path. `lane-host resolve` prints the word as it does `local`.
- Provider verbs under a cloud kind refuse as `host-kind-verb kind=KIND verb=VERB` with exit 2, the status `host-local` uses (`skills/orch/scripts/lane-host`). A caller that matched its capability never meets it.

### Absent-verb probing (KEN-1553)

The declaration replaces probing. A caller reads the line once per operation and calls only the verbs its capability names. Three probes go: `oversee-watch`'s pane fallback on `status` exit 2 in the first build, then `lane-close --park`'s `stop-sandbox --check` read and `lanes`' exit-2 read of `accounts` in `host_accounts_answer` when FLT item 2 merges. KEN-1553's optional verbs (`--class`, `walled`) become declared keys when they land, not probed verbs. A declared verb that exits 2 is a provider fault, reported under the caller's host-failure key.

Every provider kendex ships answers `capabilities` itself from the first build: `lane-host-ssh` gains the verb and prints the static line. A provider that does not answer it gives one of two absent answers: exit 2, or exit 64 with a `verb-unsupported verb=capabilities` line on stderr. For such a provider the dispatcher answers the static `ssh` line. This compatibility arm covers only providers kendex does not ship, which today is fleet's `bin/lane-host-daytona`, whose answer is the exit 64. That line says `park=none` and `accounts=none`, which is wrong for Daytona, so no caller reads those two keys until FLT item 2 merges. Until then `lane-close --park` keeps its `stop-sandbox --check` read, and `lanes` `host_accounts_answer` keeps its exit-2 `accounts` read. Daytona's `accounts` rows, the KEN-2494 host rows and the `harness=pi` Copilot pool rows among them, then still reach `lanes`. The arm and both probes go when FLT item 2 merges.

### One record, one launcher

- `open-terminal` matches `launch`. `window` and `ssh` are today's arms. `cloud-session` is the new arm in § [The smallest first build](#the-smallest-first-build). `cloud-task` refuses as `kind-unbuilt kind=codex-cloud` until the owner asks for it.
- The lane record gains one field, `kind`, written for every kind, and keeps the rest (`open-terminal` `lane_record_write`). A local lane writes `host` null and `kind` `local`. A cloud lane records `host` as the kind word, `kind` from the line, `account` and `session_id`. A `claude-cloud` lane's `session_id` is the cloud session id, and its `window` is the item's window, whose pane runs the session's local client, or holds the session URL with no client where the CLI printed it and exited. A `codex-cloud` lane, unbuilt, would record the Codex task id and no `window`. No new store holds the session id.
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

- `claude-cloud` (`channel=session`): `lane-mail send --directive --state-dir STATE` reads the item's record, as `lane-close` does, and runs `claude -p --cloud <session_id> --output-format json` under the record's account, the text on stdin. `{ok: true}` is delivery. The CLI queues the message and exits ([claude-code-on-the-web § Send follow-ups from the CLI](https://code.claude.com/docs/en/claude-code-on-the-web#send-follow-ups-from-the-cli)). There is no read receipt, so `directive-read` and `directive-unread` stay mailbox events. A directive the session does not act on shows as `lane-stalled` (§ [Reports](#reports)). `{ok: false}` for an archived session refuses as `session-archived`.
- `codex-cloud` (`channel=task`): no CLI verb or API sends into a task ([research § Codex cloud tasks](claude-cloud-launch-research.md#codex-cloud-tasks)). The consequence: a Codex cloud brief is complete at launch, and a review fix is a new `codex cloud exec --branch <item branch>` task with the finding in its query. `lane-mail send --directive` to it refuses as `channel-task`.
- `--re` and `--halt` to a `session` or `task` channel refuse. Such a lane never asks (§ [The lane-mail rule](#the-lane-mail-rule)), so there is nothing to answer. A halt has no enforcing hook there, so a stop goes to the operator (§ [What a cloud lane cannot do](#what-a-cloud-lane-cannot-do)).

### Reports

- `claude-cloud`: the session pushes the item branch and opens a draft pull request as its first step. The pull request body holds the lane status under `## Lane status`, in place of `tmp/lane-status-ITEM.md`. The overseer reads the body with `gh pr view` where it reads a status file for other kinds (`skills/orch/workflows/oversee.md` § Bounded lane reads).
- `pr-watch` covers the pull request, and `check_merged` finds the merge by branch name. The start-stall check reads an open pull request on the branch for a `files=none` kind in place of the status file (`check_start_stall`). After that, `oversee-watch` reports `lane-stalled ITEM age=SECONDS` for a `status=none` lane whose record is `running` and whose pull request is open, when neither the item branch head nor the `## Lane status` body has changed for `ORCH_WATCH_LANE_STALL_SECS`. Each pass runs one `gh pr view --json headRefOid,body` per such lane, and the watch state keeps the last head and a body digest. No directive needs to be outstanding, so the event reports a session that stops on an Auto-mode question, loses its VM or spends its credit at any point of its work. The acceptance run sets the default.
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
| Stop or park | No stop verb is documented. Archive is a claude.ai sidebar action ([claude-code-on-the-web § Archive sessions](https://code.claude.com/docs/en/claude-code-on-the-web#archive-sessions)). | `lane-close` closes the record and the local worktree and prints `host-kept kind=KIND session=ID`. The operator (§ [The GitHub App](#the-github-app)) archives the session. |
| Merge under the lanes identity | Commits land under the connected GitHub user (§ [The GitHub App](#the-github-app)) | The landing lane |
| Hand off at a context mark | The handoff needs the mailbox | A cloud lane keeps Claude's automatic compaction on. |

An item whose repository exceeds the cloud VM takes no cloud kind. FLT-551 records that hyprtrade exceeds 16 GB RAM and 30 GB disk.

## The permission route

- A cloud session offers Accept edits, Plan and Auto, and no Bypass ([research § Add-repo and push pre-approval](claude-cloud-launch-research.md#add-repo-and-push-pre-approval)). A lane brief written for `--dangerously-skip-permissions` (`LAUNCH_CHOICE_FLAGS` in `skills/orch/scripts/lib/lane-launch.sh`) runs in Auto.
- The `session` brief names the steps the kind never takes: `linear.sh`, `lane-mail`, `pr-merge`, a background wake, and any wait on a person.
- The repository's `.claude/hooks/pre-commit-check.sh` loads in the cloud session and refuses every commit where the commit-guards hooks are not armed. The cloud machine has no kendex, so on vsys the kendex commit hook refused every commit (owner note 1790975476).
- kendex reaches the cloud machine through the platform's own setup mechanism, not through a kendex-side shim. The account's cloud environment holds a setup script: `curl -fsSL https://raw.githubusercontent.com/vanillagreencom/kendex/main/install.sh | sh -s -- --cli-only`. A setup script runs as root in each new session before Claude Code launches, and must exit zero ([cloud-environments § Setup scripts](https://code.claude.com/docs/en/cloud-environments#setup-scripts)). The environment cache keeps what it installed for later sessions ([§ Environment caching](https://code.claude.com/docs/en/cloud-environments#environment-caching)). An environment belongs to one account ([§ Configure your environment](https://code.claude.com/docs/en/cloud-environments#configure-your-environment)), so the operator sets the script once per account.
- The `session` brief makes no arming step mandatory. A cloud session with no kendex and no `tools/setup` stopped before its first commit to ask how to arm one. Where the checkout carries the commit-guards skill's `install-git-hooks`, the brief arms the hooks with it, which needs no kendex. Where it does not, the session commits anyway: the pull request's CI, the review gate and the second-opinion gate hold the merge.
- A step that Auto still holds for approval gets an allow rule in the repository's `.claude/settings.json`, which a cloud session loads ([research § Add-repo and push pre-approval](claude-cloud-launch-research.md#add-repo-and-push-pre-approval)). The build adds no rule in advance. The acceptance run lists each approval the session asked for, and each becomes an allow rule or a step the kind never takes.
- A repository deny rule for `AskUserQuestion` and `EnterPlanMode` is rejected: it binds the owner's own sessions in that repository too. The brief carries the unattended words. An unanswered question leaves the session idle. Before the pull request opens, the start-stall check reports it, and after that `lane-stalled` does (§ [Reports](#reports)).

User-level settings do not reach a cloud session ([research § Add-repo and push pre-approval](claude-cloud-launch-research.md#add-repo-and-push-pre-approval)). Their replacements:

| Local lane setting | Cloud replacement |
|---|---|
| `CLAUDE_CODE_EFFORT_LEVEL=high`, `CLAUDE_CODE_SUBAGENT_MODEL` | Environment variables on the account's cloud environment ([cloud-environments](https://code.claude.com/docs/en/cloud-environments#set-environment-variables)). FLT-551 names both. |
| Hooks, agents, skills, `CLAUDE.md` | The repository's `.claude/` and `CLAUDE.md`, which load in a one-repository session. The base branch commits that render (`schemas/lane-host.md`, base-tip rule). |
| Plugins | None. A cloud session installs no plugin that repository settings turn on. |
| `--disallowedTools`, `DISABLE_AUTO_COMPACT` | Whether `claude --cloud` carries local flags is unconfirmed (§ [Open questions](#open-questions)). Compaction stays on (§ [What a cloud lane cannot do](#what-a-cloud-lane-cannot-do)). |

## The GitHub App

- **Coverage.** The owner extended the Claude GitHub App installation on vanillagreencom to kendex, fleet, vgs and vsys and read it back (owner note 1790968643). The overseer token gets HTTP 403 on organization installations, so the record rests on that read-back.
- **Repository access.** App coverage alone gives no clone. A session on an account without access to the repository gets a bundled clone with no git remote. Its `add_repo` tool then raises two claude.ai cards: add the repository with push access, and register the repository root. After Allow once on both, the push worked (owner note 1790975476; [research § Add-repo and push pre-approval](claude-cloud-launch-research.md#add-repo-and-push-pre-approval)). A card waits on a person, so it blocks an unattended lane. The rule: each account gains access to each repository once, before any lane, when the operator approves both cards in one session of that account on that repository. The operator is the master session, which does every owner-side step. It answers the two cards with the master skill's `scripts/cloud-approve`, which answers only those two cards, only for vanillagreencom, and refuses any other (owner answer 1790993661). The operator records that access in `ORCH_LANE_CLOUD_REPOS`, one `<name>=<owner>/<repo>` entry per account and repository, beside `ORCH_LANE_RETIRE` in the lane policy settings (`LANE_POLICY_SETTINGS` in `skills/orch/scripts/lanes`). For `launch=cloud-session`, `lanes pick` keeps an account as a candidate only where an entry names the `owner/repo` of the checkout's github.com remote. Any other account takes the verdict `cloud-repo-unset`, so no lane session meets a card.
- **Bundle check.** `claude --cloud` clones only when the App covers the repository and the account has access to it, and bundles otherwise ([research § Bundle cause after the App install](claude-cloud-launch-research.md#bundle-cause-after-the-app-install)). The check is the [research acceptance test](claude-cloud-launch-research.md#acceptance-test). Before each launch `open-terminal` refuses `cloud-bundle-risk` on either cause a launcher can read and cannot clear: `CCR_FORCE_BUNDLE=1` in the `env` block of the account's `settings.json` under its `CLAUDE_CONFIG_DIR` or of the repository's `.claude/settings.json`, or a remote that is not a github.com URL. `CCR_FORCE_BUNDLE` in the environment the CLI starts with, the tmux server's, is cleared on the launch line.
- **Commit identity.** Cloud commits and pull requests land under the GitHub user connected to the Claude account (FLT-551, quoted in KEN-2589). All 11 accounts connected through `/web-setup` to the fine-grained personal access token "Claude cloud - vgs vsys push". That token reads as user bmethod, holds the repositories vgs and vsys only, and grants Contents and Workflows write (owner answer 1790993661). So cloud commits and pull requests on vgs and vsys land under bmethod. kendex is outside the token, so a kendex session needs the GitHub App route of the bullets above. The lanes-app identity rule says a lane pushes and merges under the lanes app's installation token ([D003](https://github.com/vanillagreencom/kendex/blob/main/docs/decisions/D003-one-merge-path.md) § Context; `skills/orch/workflows/merge-pr.md` § 5 step 1, "Who acts"). A cloud lane breaks that rule, so it is `land=handoff`. The outside-contribution check admits `OWNER`, `MEMBER` and `COLLABORATOR` authors (`skills/orch/workflows/oversee.md` § Outside contributions). The user bmethod is an organization owner, so the check admits its pull requests. Copilot review is the second party. GitHub's approval rule still holds ([D018](https://github.com/vanillagreencom/kendex/blob/main/docs/decisions/D018-platform-review-requirements.md)).

## One account and room pick

### Pools

| Pool | Reading | Expires or resets |
|---|---|---|
| Claude weekly and 5-hour windows | `parse_claude_usage` in `skills/orch/scripts/lib/lane-usage.sh` (KEN-2494) | Refills at each reset |
| Claude cloud credit | `usage.iguana_necktie`: `limit_dollars`, `used_dollars`, `remaining_dollars`, `resets_at`, `locked_reason` (KEN-2589 correction 3). `parse_claude_usage` ignores it today. | Expires at E below. It does not refill. |
| Codex windows | `parse_codex_usage` | Refill. Codex cloud tasks share them ([research § Codex cloud tasks](claude-cloud-launch-research.md#codex-cloud-tasks)). |
| Codex credits | The `credits` object (KEN-2494) | No expiry |
| Copilot pool | `lib/copilot-credits.sh`, or a provider's `harness=pi` row | Refills monthly |
| Daytona compute | No reader in kendex ([research § Daytona compute and Copilot pool room](claude-cloud-launch-research.md#daytona-compute-and-copilot-pool-room)) | Metered. It is the host's cost, not an account's allowance. |

`parse_claude_usage` returns the cloud credit as a `credits` object with `unit: "usd"`. `emit_lane` carries it into the record as it carries the Copilot pool and the KEN-2494 Codex balance.

`usage.iguana_necktie` is no documented interface. The credit's only documented surface is claude.ai Settings > Usage, a web page with no API. `lanes` already depends on `api/oauth/usage` for the plan windows. A body without `iguana_necktie` reads as no tier 0, with the keyed note `lanes: cloud-credit-unread account=NAME`, never a silent drop.

### The expires-first rule

`lanes pick` spends the allowance that expires first. This rule is stated once, in `lanes --help` § pick, and judged once, in the sort key of `lane_selection` in `skills/orch/scripts/lib/lane-model.sh`. Its authority is owner note 1790967939 and [D020](https://github.com/vanillagreencom/kendex/blob/main/docs/decisions/D020-lane-host-kinds.md). No `authority.md` exists (KEN-2589 correction 6).

Each candidate with room gets a tier from the pool the launch spends first:

- **Tier 0**: a grant that expires and does not refill. The Claude cloud credit is tier 0 when the kind declares `pool=cloud-credit`, `remaining_dollars` is above `ORCH_LANE_CLOUD_CREDIT_FLOOR`, `locked_reason` is null and E is ahead. At or below the floor the account takes its plan-window verdict, so a nearly spent credit does not drop a lane onto a walled week. The floor is in dollars, beside KEN-2494's `ORCH_LANE_CODEX_CREDIT_FLOOR`, and `lanes --help` § pick names it. The acceptance run's `used_dollars` rise for one lane sets its default. Its verdict is `room` whatever the plan windows read: four probe sessions ran on a week at 100 percent ([research § Cost after the plan week](claude-cloud-launch-research.md#cost-after-the-plan-week)).
- **Tier 1**: a window that refills. This is every account today.
- **Tier 2**: a balance with no expiry. KEN-2494's credit-backed Codex account is tier 2.

The chooser sorts the room candidates by:

```text
key = [tier, E, -S, claims, -projected_headroom_pct, wall]
S   = H * (1 + 1 / (1 + T))
```

- E is the epoch of the effective expiry for tier 0, and 0 for tiers 1 and 2.
- S is today's `selection_score` (`with_lane_selection_score`). For tier 0, H is `100 * remaining_dollars / limit_dollars` and T is the hours to E. For tier 1, H and T are unchanged. For tier 2, S is the balance.
- `claims`, `projected_headroom_pct` and `wall` are today's keys after S.

The tier key replaces KEN-2494's second `sort_by` pass in `lane_selection`, `sort_by([(.binding_bucket == "credits"), credit_rank])`. Its `binding_bucket == "credits"` element, plan room before credits, becomes the tier 1 to tier 2 step. Its `credit_rank`, larger balance and then fewer claims among the credit accounts, becomes the tier 2 order by S and `claims`. The pick keeps no second copy. Within tier 1 the order is unchanged. When the credit is spent or past E, the account falls to tier 1 on its plan windows, which cloud sessions share ([research § Cost after the plan week](claude-cloud-launch-research.md#cost-after-the-plan-week)).

The kind is the overseer's choice per item. `lanes pick` ranks accounts for that kind. `open-terminal --host claude-cloud` runs the pick under `ORCH_LANE_HOST=claude-cloud`, as `pick_auto_lane` and `named_lane_judge` pass the resolved host today. `lanes pick` reads `pool` and `launch` from `lane-host capabilities` once per pick. `lanes list` shows each account's credit and E, so the overseer sends cloud-fit items to `claude-cloud` while any account holds credit.

### Other pick rules beside the tier key

Five other items change the same pick. Owner note 1790974374 sets how each one composes with the tier key. Owner answer 1790993661 sets the build order.

- **Expiry, not credit.** The tier keys on when an allowance expires, not on whether it is credit. Claude cloud credit expires, so it is tier 0 and ranks first. KEN-2494's Codex credit never expires, so it is tier 2 and ranks last.
- **Harness order.** One `lanes pick` judges one harness (`lanes --help`, `--harness`), so the tier key ranks only the accounts of that harness. KEN-2497's harness order, Claude, then Codex, then Copilot, stays as it is. No part of this design changes it.
- **Model class.** KEN-2466's class resolver chooses the model that the pick judges, the `$model` of `lane_selection`. The tier key ranks accounts for that model and chooses no model.
- **Reserved seats.** A KEN-2012 reserved seat leaves the candidates before any tier is set, as the KEN-1990 overseer seats do today in `cmd_pick` (`overseer_seats`, then `collect_lanes`). The tier key never ranks it.
- **Last resort.** KEN-1504's last-resort rank becomes the first element of the key, before `tier`. A last-resort account sorts behind every other room candidate of its harness, whatever its tier.
- **Build order.** The first build of this design follows KEN-2494 alone, which is Done. KEN-2497 is in Backlog and KEN-2466 is In Progress on 2026-10-03. The two bullets above make both independent of the tier key, so each one adds its rule at its place above when it lands. KEN-1504 and KEN-2012 do the same. The target is the first build merged by 2026-10-07, because the 2claude credit lapses on 2026-10-08. Owner answer 1790993661 sets this order and replaces the order of owner note 1790974374 for this build.

### Effective expiry and its readers

- E is the earliest of `iguana_necktie.resets_at`, the period end of a subscription that will not renew, and the account's `ORCH_LANE_RETIRE` date. `lanes` stops picking an account from its retire date, so a later credit or period end cannot sort it ahead of an account whose E comes first.
- The period end is the next monthly anniversary of `organization.subscription_created_at` after now.
- The one reader of `subscription_created_at` is `lanes` `measure_lane`. It sends `GET https://api.anthropic.com/api/oauth/profile` with the account's bearer token and reads `.organization.subscription_created_at` ([research § Subscription period end source](claude-cloud-launch-research.md#subscription-period-end-source)). It reads only an account that will not renew, and it caches the answer with the usage body.
- The profile field is no documented interface. The period end's only documented surface is Anthropic billing, which has no API. A failed profile read or a body without `subscription_created_at` reads as no period end, with the keyed note `lanes: period-end-unread account=NAME`, never a silent drop.
- The renewal source is `ORCH_LANE_RETIRE`, the owner's lapse list in setting form. A `<name>=<YYYY-MM-DD>` entry says the account is not the fleet's from that date (`skills/orch/scripts/lanes` header). The profile body names no renewal field ([research § Subscription period end source](claude-cloud-launch-research.md#subscription-period-end-source)). An account the setting does not name renews.
- The first build reads no period end, so its E is the earlier of `resets_at` and the retire date. Where the retire date is the lapse date, as for 2claude, that equals the full rule.

## What fleet records

| Kind | Host kind (beside `machine_kind`) | Account | Session id | Credit spent |
|---|---|---|---|---|
| `local` | `local` | Record `account` | Record `session_id` (harness session) | None |
| `ssh`, static | `ssh` | Record `account` | Record `session_id` | None |
| `ssh`, Daytona | `ssh` | Record `account` | Record `session_id` | None. Daytona `cost_usd` is the host's cost. |
| `claude-cloud` | `claude-cloud` | Record `account` | Cloud session id; the URL is `claude.ai/code/<id>` | `used_dollars` delta between launch and close, from `lanes list --json` |
| `codex-cloud` | `codex-cloud` | Record `account` | Codex task id | Codex credit balance delta, from `lanes list --json` |

The cost rule: model cost is the lane's tokens at published API rates, never a credit pool (the owner's Spending principle, owner answer 1790993661). Each lane records model cost and credit spent in separate fields. Where a cloud session's tokens cannot be read, model cost reads as unread, never as the credit delta. A credit delta is per account. It is exact for a lane only while that lane is the account's one cloud session.

Proposed FLT items. This item files none:

1. The hub lane table gains `host_kind` and `session_ref` beside `machine_kind`, read from the lane record's `kind` and `session_id`.
2. `bin/lane-host-daytona` answers `capabilities` with the Daytona line. kendex then deletes the compatibility arm and the two probes it keeps (§ [Absent-verb probing](#absent-verb-probing-ken-1553)), and `lane-close --park` and `lanes` match `park` and `accounts`.
3. Cost per lane: `model_cost` and `credit_spent` fields, by the cost rule above, with `credit_spent` read from `lanes list --json` for the record's `account`.
4. If Daytona holds an expiring compute grant, its `accounts` row carries it as a pool with an expiry, and it joins tier 0 with no kendex rule change.

## What it deletes or folds in

- **No second launcher, picker or record.** `open-terminal`, `lanes pick` and the lane record take the cloud kinds.
- **By-hand cloud sessions.** The `Nclaude --cloud` sessions that vgs and vsys start by hand become `open-terminal --host claude-cloud` launches. They gain a record, a pick and a watch. Sessions started before the build finish by hand.
- **KEN-1553's absent-verb probing.** The capability line replaces it (§ [Absent-verb probing](#absent-verb-probing-ken-1553)). KEN-1553 keeps its verbs and loses its probe rule.
- **Probes deleted.** The exit-2 pane fallback for `status` in `oversee-watch`. After FLT item 2 merges, the `stop-sandbox --check` read in `lane-close --park` and the exit-2 `accounts` read in `lanes` `host_accounts_answer`.
- **Host-name branches.** The 18 `LANE_HOST` tests against `local` in `open-terminal`, the `local` or `hosted` reduction in `oversee-watch`, and the `host` emptiness tests in `lane-close` become capability matches.
- **Per-kind exceptions.** None. The lane-mail rule is restated per `channel`, never per kind or provider.

## The smallest first build

The first build spends Claude cloud credit through this design before the 2claude lapse on 2026-10-08. All 11 accounts' credit expires at 2026-11-05T07:59Z (KEN-2589 correction 3). It builds `claude-cloud` only. `codex-cloud` adds no expiring pool, so it waits for the owner. It follows KEN-2494 alone, in the build order of § [Other pick rules beside the tier key](#other-pick-rules-beside-the-tier-key). KEN-2494 ([PR #3514](https://github.com/vanillagreencom/kendex/pull/3514), merged) supplies the second `sort_by` pass (§ [The expires-first rule](#the-expires-first-rule)), the Codex `credits` object and the tier 2 rows that the tier key builds on. It also moved `parse_claude_usage` to `skills/orch/scripts/lib/lane-usage.sh`.

| File | Change | Lines |
|---|---|---|
| `skills/orch/scripts/lane-host`, `lane-host-ssh` | `capabilities` verb: built-in lines for `local` and `claude-cloud`, the provider pass-through, the compatibility arm, `host-kind-verb`, and the static line in `lane-host-ssh`. `lane-close --park` and `lanes` keep their probes until FLT item 2 | 40 |
| `skills/orch/scripts/open-terminal` | `launch=cloud-session` arm: `cloud-bundle-risk` check, `worktree create`, push of the item branch, the item's tmux window running `claude --model MODEL --cloud="$(cat -- PROMPT_FILE)"` interactively under the account in that worktree, the brief closed by the session words as the `--cloud` description, which the pane's shell reads from the worktree's git directory, session id read from the pane, attached or after the CLI exits, record write with `kind` for every kind, and `host`, `session_id` and the window for a cloud lane | 90 |
| `skills/orch/scripts/lib/lane-launch.sh` | The `session` brief constant, with the commit-chain arming step before the first commit | 15 |
| `skills/orch/scripts/lane-mail` | `send --directive` reads the record and matches `channel`: `session` sends through `claude -p --cloud`; `--re` and `--halt` refuse there | 45 |
| `skills/orch/scripts/oversee-watch` | Rows carry the record's `host`; the mail pass reads only `channel=mailbox`; start-stall reads the pull request for `files=none`; `lane-stalled` for `status=none` with `ORCH_WATCH_LANE_STALL_SECS` | 45 |
| `skills/orch/scripts/lane-close` | `stop=none` arm: close the record and the local worktree, print `host-kept` | 20 |
| `skills/orch/scripts/lanes`, `lib/lane-usage.sh`, `lib/lane-model.sh` | `iguana_necktie` into `credits` in `parse_claude_usage`, the tier 0 verdict with `ORCH_LANE_CLOUD_CREDIT_FLOOR`, the tier key in place of the second `sort_by` pass, the pick's `pool` and `launch` read, and the `ORCH_LANE_CLOUD_REPOS` read with its `cloud-repo-unset` verdict | 65 |
| `schemas/lane-host.md`, `references/skill-rules.md`, `references/oversee-lanes.md`, `references/oversee-events.md`, `lib/oversee-watch-text.sh`, `lanes --help` | § Host kinds, the lane-mail rule per `channel`, the directive row, the `lane-stalled` event and its setting, the expires-first rule, the repository access setting and the one-time account setup | 45 |
| `skills/orch/tests/` | Rows for each changed surface against a `claude` stub and the `tests/fixtures/lane-host` stub, each with its must-fail control, among them `lane-stalled` for a session lane whose head and body do not change, and none for one whose body changes, and `cloud-repo-unset` for an account with no entry for the checkout's repository | 190 |

The operator's one-time setup per account is no build change: the setup script on the account's cloud environment, and access to each repository with its `ORCH_LANE_CLOUD_REPOS` entry (§ [The permission route](#the-permission-route), § [The GitHub App](#the-github-app)).

That is about 320 production lines, 45 doc lines and 190 test lines, with a changelog fragment and the `.agents/skills/orch/` renders in the same commit. The second build, before 2026-11-05, adds the `subscription_created_at` reader, the credit column in `lanes list`, and the capability matches that replace the host-name branches.

Acceptance test:

1. The operator's one-time setup for 2claude, then the [research acceptance test](claude-cloud-launch-research.md#acceptance-test), steps 1 to 5, on vsys and on vgs only. Both take the token route of § [The GitHub App](#the-github-app), Commit identity. Its pass in step 4 proves that access: a push from an account that has it, with no card shown.
2. `open-terminal --host claude-cloud --state-dir STATE ITEM` for one small item picks 2claude through the tier key while `ORCH_LANE_RETIRE` names it. The record shows `host=claude-cloud`, `kind`, `session_id` and the item's window.
3. One directive: `lane-mail send --directive` answers `{ok: true}`, and the session's next push or `## Lane status` shows that it acted on it.
4. One pull request landed through the normal route: the session opens it, Copilot reviews it, a landing lane merges it under `merge-pr.md` § 5, `oversee-watch` reports `merged`, and `lane-close` closes the record.
5. 2claude's `used_dollars` rises across the run. The run records its minutes and the session's tokens, which answers the token question in § [Open questions](#open-questions). Each approval the session asked for is recorded as an allow rule or a step the kind never takes. The session ran on a cloud machine with no kendex before its setup script. The `## Lane status` body quotes the arming command's report, and the session's first commit passed through the armed pre-commit and commit-msg chain.
6. A separate step, after steps 1 to 5: the research acceptance test on kendex proves the GitHub App route there. No kendex item takes `claude-cloud` before it passes.

## Open questions

| Question | Source that left it open | Who answers |
|---|---|---|
| Does `claude -p --cloud "task" --output-format json` create a session and print its id? Answered: no. Claude CLI 2.1.288 refuses `--print` where `--cloud` starts a new session, as interactive only. The follow-up form `lane-mail` sends, `claude -p --cloud SESSION`, is measured by the live proof the pull request records. Owner ruling 1791151144: the session starts interactively in the item's window, the brief goes in as its first prompt, and its id is read from the session URL the pane shows. Claude Code 2.1.288 refuses `--cloud` with no description, and 2.1.289 has no `--ref` option, so the brief is the `--cloud=` description, which the CLI sends as the first message, and the session clones the worktree's current branch, the pushed item branch. | [claude-code-on-the-web § Send follow-ups from the CLI](https://code.claude.com/docs/en/claude-code-on-the-web#send-follow-ups-from-the-cli) | Answered on vsys, 2026-10-04 |
| Does a follow-up reach a session whose VM was reclaimed but which is not archived? | [claude-code-on-the-web § Environment expired](https://code.claude.com/docs/en/claude-code-on-the-web#environment-expired) | The build lane, in the acceptance run |
| Which permission mode does a `claude --cloud` session start in, and does it carry local flags such as `--disallowedTools`? | [research § Add-repo and push pre-approval](claude-cloud-launch-research.md#add-repo-and-push-pre-approval) | The build lane, in the acceptance run |
| Does the cloud credit apply while the 5-hour window is walled? The probe covered the weekly window only. | [research § Cost after the plan week](claude-cloud-launch-research.md#cost-after-the-plan-week) | The owner, from claude.ai Settings > Usage during the run |
| Does the profile body carry a renewal field? | [research § Subscription period end source](claude-cloud-launch-research.md#subscription-period-end-source) | The build lane, from one profile read |
| What is the anniversary on a month that lacks the start day? | Not documented | The owner, from Anthropic billing |
| Does a bundle on an account with repository access come from bug #81776? | [research § Bundle cause after the App install](claude-cloud-launch-research.md#bundle-cause-after-the-app-install) | The acceptance test, step 5 |
| Does the setup script's install reach the kendex release assets in a session that does not attach kendex? The GitHub proxy serves release assets only for attached repositories. If it does not, the build stops at that step and asks the owner. | [cloud-environments § GitHub proxy](https://code.claude.com/docs/en/cloud-environments#github-proxy) | The build lane, in acceptance step 1 on vsys |
| Can a lane read a cloud session's tokens? If not, model cost reads as unread (§ [What fleet records](#what-fleet-records)). | No source documents a read | The build lane, in the acceptance run |
| Is there a CLI or API read of a cloud session's state? | No source documents one | Anthropic docs, read again at the second build |
| For `codex-cloud`: the output of `status`, repository config and hook loading, approval policy and commit identity | [research § Codex cloud tasks](claude-cloud-launch-research.md#codex-cloud-tasks) | The lane that builds `codex-cloud`, from OpenAI docs |
| Does Daytona hold an expiring compute grant? | [research § Daytona compute and Copilot pool room](claude-cloud-launch-research.md#daytona-compute-and-copilot-pool-room) | Fleet (FLT item 4) |
