# Claude cloud launch research

No documented CLI flag or setting forces a Claude cloud session to clone GitHub instead of bundling. `claude --cloud` clones when the Claude GitHub App covers the repository, and bundles when it does not. A saved routine fired by HTTP POST attaches its saved repositories with no per-run click, after a one-time setup on claude.ai. No documented setting pre-approves the add-repo tool. Codex cloud has no CLI or API route that sends a follow-up into a task; its CLI returns a diff and opens no pull request.

Research metadata: first pass 2026-10-01 on Claude Code 2.1.287. Second pass 2026-10-02: re-read the code.claude.com pages `claude-code-on-the-web`, `routines`, `web-quickstart`, `cloud-environments` and `costs` (Markdown twins, `<page>.md`), the issues #76248 and #81776, the Codex docs linked below, and `codex cloud --help` on codex-cli 0.160.0. Sources are code.claude.com pages unless stated. Nothing was launched, sent or spent. Raw page copies are under `tmp/ken-2589-research/`, untracked.

## Routes with the repository attached

| Route | Repository source | Click needed | Source |
|---|---|---|---|
| `claude --cloud "task"` | Clones the current directory's GitHub remote when the App covers it. Bundles otherwise. | None documented | [claude-code-on-the-web](https://code.claude.com/docs/en/claude-code-on-the-web#from-terminal-to-cloud) |
| Routine API trigger: `POST https://api.anthropic.com/v1/claude_code/routines/<trig_id>/fire`, headers `Authorization: Bearer` and `anthropic-beta: experimental-cc-routine-2026-04-01` | Repositories saved in the routine, cloned each run from the default branch | One time: create the routine and token on the web. The CLI cannot create or revoke tokens. | [routines](https://code.claude.com/docs/en/routines#add-an-api-trigger) |
| Managed Agents `POST /v1/sessions` with `resources: [{type: github_repository, url, authorization_token}]` | Your GitHub token mounts the repository | None | [GitHub page](https://platform.claude.com/docs/en/managed-agents/github) |
| Browser URL `claude.ai/code?repositories=owner/repo&prompt=...` | Preselects the repository | Yes, submit in the browser | [web-quickstart](https://code.claude.com/docs/en/web-quickstart#pre-fill-sessions) |

- Local `claude --help` shows `--cloud [description|session_id|url]` and `--environment <id>`. `--environment` targets a self-hosted environment only. No flag selects the repository source.
- `claude -p "msg" --cloud <session-id>` queues one message into a running session and exits. It takes a `session_...` or `cse_...` id or a `claude.ai/code/<id>` URL. `--output-format json` prints `{ok, session_id, url}` ([source](https://code.claude.com/docs/en/claude-code-on-the-web#send-follow-ups-from-the-cli)).
- The only source override is `CCR_FORCE_BUNDLE=1`, which forces a bundle. No opposite switch is documented ([source](https://code.claude.com/docs/en/claude-code-on-the-web#send-local-repositories-without-github)).
- Correction (2026-10-02): the routines page no longer says `claude/` branches "are always accepted". It says Claude pushes to a `claude/`-prefixed branch unless the prompt names another, and GitHub branch rules apply to the connected GitHub access ([routines](https://code.claude.com/docs/en/routines#repositories-and-branch-permissions)).
- The `/fire` body takes only an optional `text` field. The text arrives wrapped in a `<routine-fire-payload>` block as untrusted data, so the saved prompt must opt in to act on it. The endpoint is claude.ai only, in research preview, and may change. API fires are capped at 30 per hour per routine and 100 per hour per account ([routines](https://code.claude.com/docs/en/routines#trigger-a-routine)).
- Managed Agents is a different product. Its examples use `x-api-key` (Console API billing) and a GitHub token that the caller passes. Whether the plan credit applies to it is unconfirmed.
- GitHub Action and Agent SDK routes: not checked. Unconfirmed.

## Add-repo and push pre-approval

- No docs page names an add-repo tool, a permission rule for it, or an environment setting for it.
- Issue #76248 quotes the proxy error "Use `add_repo` to request access" and says the sandbox has no such tool. It is open on 2026-10-02 ([issue](https://github.com/anthropics/claude-code/issues/76248)).
- Owner probes, 2026-10-02 (owner note 1790975476): a `claude --cloud` session got a bundled clone with no git remote where its account had no access to the repository yet. The session called its `add_repo` tool, and claude.ai showed two permission cards: add the repository with push access, and register the repository root. After Allow once on both, the 2claude probe pushed `dfc12ac` to vgs. The 3claude probe showed no card.
- The GitHub proxy limits "GitHub API and release-asset requests" to "repositories attached to the session". Correction (2026-10-02): the page no longer limits `git push` to the current working branch. The proxy rejects branch deletions and non-branch pushes, and "doesn't limit which branches a push can update" ([cloud-environments](https://code.claude.com/docs/en/cloud-environments#github-proxy)).
- A bundled session can push to a GitHub remote only when the GitHub connection has push access to it ([source](https://code.claude.com/docs/en/claude-code-on-the-web#send-local-repositories-without-github)).
- Cloud sessions offer Accept edits, Plan and Auto. They offer no Manual and no Bypass ([web-quickstart](https://code.claude.com/docs/en/web-quickstart#start-a-task)).
- A one-repository session loads the repository `CLAUDE.md`, `.claude/settings.json` hooks and permission rules, `.mcp.json`, `.claude/skills/`, `.claude/agents/` and server-managed settings. It loads no `~/.claude/` user files, and installs no plugins that repository settings turn on ([cloud-environments](https://code.claude.com/docs/en/cloud-environments)).

## Bundle cause after the App install

Docs rule: bundle when there is no git remote, or when a github.com repository lacks the Claude GitHub App. This holds "even if you connected GitHub with `/web-setup`" ([source](https://code.claude.com/docs/en/claude-code-on-the-web#send-local-repositories-without-github)).

What the observation may have missed (each unconfirmed until checked):

- The App must be installed on the account that owns vsys, with vsys inside the installation's selected repositories. An organization install may need owner approval ([web-quickstart](https://code.claude.com/docs/en/web-quickstart#connect-github)).
- The remote must be a github.com URL. `--teleport` asks for a confirmation on a host alias such as `git@work:owner/repo.git`. Whether `--cloud` shares that limit is unconfirmed.
- `CCR_FORCE_BUNDLE=1` in the shell or in a settings `env` block forces a bundle.
- `/web-setup` replaces an earlier browser GitHub connection. The docs do not say whether the App check reads that connection.
- Open bug #81776 matches the symptom: 7 of 7 CLI sessions bundled despite the App ([#81776](https://github.com/anthropics/claude-code/issues/81776)). If the install is correct, treat a bundle as that bug.

## Cost after the plan week

- claude.ai Settings > Usage on the ai4 account, read by the owner's operator session on 2026-10-02: "Cloud session credits: Applies automatically to cloud sessions. After it's used or expires, your plan's regular usage applies. Included credit, expires 11:59 PM PST November 4, $241 of $250 left", with "This week 100% used". Four probe sessions ran and answered on that account while the week read 100% used.
- Docs: "There is no separate compute charge for the cloud VM." Cloud sessions share rate limits with all other Claude usage on the account ([limitations](https://code.claude.com/docs/en/claude-code-on-the-web#limitations)). Correction (2026-10-02): the docs pages say nothing about the cloud credit. The order credit, then plan usage, comes from the claude.ai text above only.
- Past the plan limit, usage credits let work continue ([costs](https://code.claude.com/docs/en/costs#add-usage-credits-to-your-subscription)). Routines also run on metered overage when usage credits are on ([routines](https://code.claude.com/docs/en/routines)). The official pages name no rate. A third-party article says "at API rates" ([madrobot](https://madrobot.blog/2026/09/27/claude-code-cloud-session-pricing-cost-vs-local/)).
- No per-session price is documented or measured.

## Fit with orch

A cloud session cannot be a lane-host provider. The protocol needs an SSH target, a worktree path, and `cat`, `put`, `append`, `status` and `stop` against host files ([lane-host.md](../../skills/orch/schemas/lane-host.md)). The docs show no SSH or file access into a cloud session. It can serve as a launch surface for self-contained work: `claude --cloud` or a routine fire starts it, and `claude -p "msg" --cloud <session-id>` queues a follow-up. Lane mail, markers and `oversee-watch` reads would need another channel, such as the pushed branch.

## Acceptance test

1. In `~/dev/vsys`, run `env | grep CCR` (expect nothing) and `git remote -v` (expect a github.com URL).
2. Confirm the App lists vsys among the owner's installed repositories.
3. Run `claude --cloud "Create branch claude/accept-test, add tmp/accept.txt, commit, push. Then print git remote -v."`
4. Pass: the session shows a GitHub remote, `git ls-remote origin claude/accept-test` returns a commit, and no one clicked Allow. Fail: an empty remote (a bundle) or a push refusal.
5. On failure, run the same task through a saved routine and `/fire`, to separate the CLI path from the account setup.

Cost: one short session on the included credit, then plan usage, then usage credits. Set a monthly usage-credit limit first.

## Codex cloud tasks

The developers.openai.com/codex URLs redirect to learn.chatgpt.com/docs on 2026-10-02; the links below are the redirect targets. The docs split Codex Cloud (web, mobile and desktop app) from Codex Cloud (Legacy). Legacy "continues to support Code Review and the Linear and GitHub integrations", and OpenAI plans to deprecate it ([cloud-environments](https://learn.chatgpt.com/docs/environments/cloud-environments)).

- **CLI verbs** (`codex cloud --help` and each subcommand's `--help`, codex-cli 0.160.0, marked EXPERIMENTAL): `exec --env ENV_ID [--branch BRANCH] [--attempts N] [QUERY]`, with the branch defaulting to the current branch and attempts to 1; `status TASK_ID`; `list [--env ENV_ID] [--limit 1-20] [--cursor C] [--json]`; `diff TASK_ID [--attempt N]`; `apply TASK_ID [--attempt N]`. Bare `codex cloud` opens an interactive picker ([developer-commands](https://learn.chatgpt.com/docs/developer-commands#codex-cloud)).
- **Status read-back**: `list --json` prints `tasks[]` with `id`, `url`, `title`, `status`, `updated_at`, `environment_id`, `environment_label`, `summary`, `is_review` and `attempt_total`, plus `cursor` ([developer-commands](https://learn.chatgpt.com/docs/developer-commands#codex-cloud-list)). The client's task states are `Pending`, `Ready`, `Applied` and `Error`. Its attempt states are `Pending`, `InProgress`, `Completed`, `Failed`, `Cancelled` and `Unknown` ([api.rs at rust-v0.160.0](https://github.com/openai/codex/blob/rust-v0.160.0/codex-rs/cloud-tasks-client/src/api.rs)). The output form of `status` is not documented. Unconfirmed.
- **Follow-up**: the CLI client trait has `create_task`, list, summary, diff, messages, text, sibling attempts and apply, and no method that sends a message into a task ([api.rs](https://github.com/openai/codex/blob/rust-v0.160.0/codex-rs/cloud-tasks-client/src/api.rs)). The web, mobile and desktop app reopen a task to "request follow-up changes" ([cloud](https://learn.chatgpt.com/docs/cloud)). Slack and Teams follow-ups work from the same connected account, in Enterprise workspaces with Cloud delegation ([cloud-environments](https://learn.chatgpt.com/docs/environments/cloud-environments#start-tasks-from-slack-or-microsoft-teams)). A pull-request comment `@codex <text>` starts a new legacy cloud chat with the pull request as context, not a follow-up to an earlier task ([GitHub](https://learn.chatgpt.com/docs/third-party/github#give-codex-other-tasks)). No public API route is documented. Unconfirmed.
- **Pull request and push**: the CLI opens no pull request; `diff` and `apply` bring the result to a local checkout. The web flow lets the user "commit or open a pull request when ready" ([cloud](https://learn.chatgpt.com/docs/cloud)). `@codex fix ...` on a pull request "can push a fix back to the branch when it has permission to do so" ([GitHub](https://learn.chatgpt.com/docs/third-party/github#act-on-review-findings)). The GitHub identity that commits land under is not documented. Unconfirmed.
- **Repository and egress**: an environment names GitHub repositories, and Codex asks to connect GitHub when needed ([cloud-environments](https://learn.chatgpt.com/docs/environments/cloud-environments#create-and-publish-an-environment)). Agent internet access stays off until the environment turns on "Allow Codex to access internet", with Package managers, Custom domains only or All (unrestricted) ([connect-to-services](https://learn.chatgpt.com/docs/environments/cloud-environments#connect-to-services)). The legacy page says "By default, Codex blocks internet access during the agent phase" ([internet-access](https://learn.chatgpt.com/docs/cloud/internet-access)). Network secrets reach only allowed HTTPS hosts through a proxy. `api.linear.app` is in no preset list read. Pro VMs have 4 vCPUs, 16 GiB memory and 32 GiB disk.
- **AGENTS.md and config**: the legacy agent uses a repository `AGENTS.md` to find lint and test commands ([legacy](https://learn.chatgpt.com/docs/environments/cloud-environment)). Repository skills load; personal skills from the local computer do not sync ([cloud-environments](https://learn.chatgpt.com/docs/environments/cloud-environments#current-limitations)). Whether a repository `.codex/config.toml` or the user `~/.codex/config.toml` loads in a cloud task is not documented. Unconfirmed.
- **Approval and sandbox**: the docs describe cloud tasks as isolated OpenAI-managed containers, with network set per environment ([agent-approvals-security](https://learn.chatgpt.com/docs/agent-approvals-security)). They name no approval policy or sandbox mode for a cloud task, and no full-access or bypass switch. Unconfirmed.
- **Billing**: "Local messages and cloud chats share your plan's usage allowance. Weekly limits may also apply." Cloud tasks "may use more of your allowance than local messages". Pro plans have no five-hour limit. Plus and Pro users past their limit can buy credits ([pricing](https://learn.chatgpt.com/docs/pricing)). The remaining figure is on the usage dashboard, `chatgpt.com/codex/settings/usage`, and in `/status` inside a CLI session ([pricing](https://learn.chatgpt.com/docs/pricing#where-can-i-see-my-current-usage-limits)). No documented CLI command or API prints it. `lanes` reads the undocumented `https://chatgpt.com/backend-api/wham/usage` (`skills/orch/scripts/lanes:3371`), parses `rate_limit.primary_window` and `secondary_window` (`:1302`), and carries a `credits` object (`:2298`).

## Subscription period end source

- `lanes` calls `https://api.anthropic.com/api/oauth/usage` (`CLAUDE_USAGE_URL`, `skills/orch/scripts/lanes:3368`) with `Authorization: Bearer <access token>` and `anthropic-beta: oauth-2025-04-20` (`:1202` to `:1205`, `:3370`).
- Claude Code 2.1.287 (`~/.local/share/claude/versions/2.1.287`, read with `strings`) reads the field from `GET ${BASE_API_URL}/api/oauth/profile`, with `BASE_API_URL` set to `https://api.anthropic.com`. It sends `Authorization: Bearer <OAuth access token>`, `Content-Type: application/json` and `Cache-Control: no-cache`, and no `anthropic-beta` header. The JSON path is `.organization.subscription_created_at`. The CLI stores it as `oauthAccount.subscriptionCreatedAt`.
- Other `/api/oauth/` paths in that binary: `profile`, `usage`, `validate`, `account/settings`, `account/grove_notice_viewed`, `claude_cli/create_api_key`, `claude_cli/roles`, `organizations/...` (code repos, GitHub sync, `claude_code/pro_trial`), `files/`, `file_upload`, `cri` and `local_pairing`.
- Renewal: the CLI reads `organization.organization_type`, `rate_limit_tier`, `seat_tier`, `has_extra_usage_enabled`, `billing_type`, `claude_code_trial_ends_at` and `claude_code_trial_duration_days`. The binary holds none of the strings `will_renew`, `auto_renew`, `cancel_at`, `canceled_at`, `current_period_end`, `period_end`, `subscription_status` or `subscription_end`. The CLI keeps the whole body as `rawProfile`, so the body can hold fields the CLI does not name. A renewal field is unconfirmed. No request was sent.

## Daytona compute and Copilot pool room

`lanes` reads Copilot CLI room from `GET https://api.github.com/copilot_internal/user` with the account's stored login (`skills/orch/scripts/lib/copilot-credits.sh:86`), into the record that `skills/orch/schemas/copilot-credits.md` defines. A Pi root's Copilot pool comes from the provider `accounts` verb's `harness=pi` rows, `monthly-pct=` and `monthly-resets=`, else from the `ORCH_LANE_COPILOT_POOL` override. With neither, `lanes pick --harness pi` refuses `copilot-pool-unstated` (`skills/orch/schemas/lane-host.md:21` and `:31`, `lanes --help` § `--harness`). The `accounts` row has no compute field. No file under `skills/` or `docs/` reads Daytona compute room or `cost_usd`. Daytona appears only as a provider's `stop-sandbox` and `start` pair (`lane-host.md:18`, `docs/plans/park-and-resume.md` § Failure 3).
