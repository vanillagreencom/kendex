# Agent catalog proposal

The proposal retains separate maintenance and runtime scopes, renames `generalist` to `maintainer` and `engineer` to `runtime`, and adds `frontend` for declarative UI, including TypeScript/React and Quickshell QML/JavaScript. Runtime also covers non-UI Go.

## Phase boundary

- This records the Phase 1 proposal for [KEN-2239](https://linear.app/vanillagreen/issue/KEN-2239). KEN-2400 implements the bounded catalog change. Workspace labels and other repositories remain separate work.
- Both owner ruling sections govern this proposal. Phase 1 may merge as documentation. Phase 2 implements Requirements 4 to 6 in a separate PR after owner sign-off on new and renamed agents.
- The baseline sections retain the research evidence. The decision table and shared scope choice carry the owner-approved KEN-2400 scope.
- Evidence combines source inspection at `62c95bb1eeef084a1269e19d7a462d5e21c1626b`, first-party documentation retrieved on 2026-10-01, and the overseer's read-only control-host measurement. The historical limits below govern every use claim.

## Baseline selection and launch

This section records the inspected routes before the catalog change. Removed agent names in the measurement and refusal sections are historical identities. The Catalog decisions table defines the approved routes.

| Route | Current evidence | Meaning |
| --- | --- | --- |
| Initial implementer | [dev § Implementer selection](../../skills/dev/SKILL.md#implementer-selection); [dev-start § Determine Agent](../../skills/orch/workflows/dev-start.md#1-determine-agent) | `agent:X` selects X. Only an absent label enables the Location/work fallback. Rust under `crates/` selects `rust`; Iced selects `iced`; web UI selects the missing `frontend`; non-UI shell/Python/TypeScript selects `engineer`; reading-based maintenance selects `generalist`. Multi-domain work splits by domain. |
| Start and handoff | [start § Continue In Worktree](../../skills/orch/workflows/start.md); [handoff § Launch](../../skills/orch/workflows/handoff.md); [start-worktree § Implement](../../skills/orch/workflows/start-worktree.md); [dev-start § Delegate](../../skills/orch/workflows/dev-start.md#2-delegate) | Start enters the worktree workflow. Handoff launches orch there. Implementation enters dev-start. These instructions do not define another classifier that overrides a present label. Dev-start stores canonical role, runtime type, session ID, and fallback reason separately in `child_sessions`. |
| Fix continuity | [dev-fix § Delegate](../../skills/orch/workflows/dev-fix.md#2-delegate) | The supplied `dev_agent` wins, then workflow-state `.agent`, then issue label or component paths. A changed label alone need not replace a live fix worker. |
| Scope refusal | [generalist § Scope and Discipline](../../agents/maintainer.md#scope); [engineer § Scope](../../agents/runtime.md#scope) | Generalist accepts only changes settled by reading. For non-UI runtime work it returns `generalist: runtime-owner=engineer` before editing. Selection can succeed and the selected worker can then refuse. |
| Activation and issue reads | [issue commands](../../skills/linear/scripts/commands/issues.sh)::`activate_issue`; [formatters](../../skills/linear/scripts/lib/formatters.sh)::`format_issues_list`; [cache query](../../skills/linear/scripts/commands/cache-query.sh)::`cache_get_issue` | `activate --agent X` removes other `agent:*` labels and adds X. It preserves other labels and an existing human assignee. Safe/compact `.agent` comes from the first `agent:*` label, not a Linear delegate. Reads do not establish exclusivity. |
| Research | [research-issue § Delegate to the Researcher](../../skills/project-management/workflows/research-issue.md#4-delegate-to-the-researcher); [researcher § Scope](../../agents/researcher.md#scope) | Research-issue prepares assets and delegates to `researcher` when `auto_execute` is true. False leaves a labelled research issue ready. Generic dev-start is not this execution route. |
| Scout | [scout § Report-Only Contract](../../agents/scout.md#report-only-contract); [Pi tool registration](../../pi-extensions/pi-agents-tmux/extensions/subagent/index.ts), `delegate_subagent` | A child with a configured `allowed-subagents` entry can request the installed scout through restricted exploratory delegation. This returns context, not implementation. Primary callers can also request discovery. |
| Planner | [planner § Scope and Plan Artifacts](../../agents/planner.md#scope); [roadmap-plan § Inputs](../../skills/project-management/workflows/roadmap-plan.md#inputs) | Planner defines technical plans and permitted artifacts. Roadmap-plan consumes a finished planner handoff and explicitly does not launch planner. The inspected orch workflows supply no automatic technical-planner launch rule. |
| Technical program manager (`tpm`) | [audit-issues § TPM Analysis](../../skills/project-management/workflows/audit-issues.md#4-tpm-analysis); [roadmap-plan § TPM Analysis](../../skills/project-management/workflows/roadmap-plan.md); [oversee-events § Judgement rules](../../skills/orch/references/oversee-events.md#judgement-rules); [tpm § Scope](../../agents/tpm.md#scope) | Audit and roadmap workflows delegate analysis to TPM. Overseer proposal batches use canonical `tpm`. The caller performs tracker writes. |
| Every reviewer | [review-pr § Prepare Reviewers and Launch And Delegate](../../skills/orch/workflows/review-pr.md#2-prepare-reviewers); [review-codebase § Delegate](../../skills/orch/workflows/review-codebase.md#2-delegate); [QA review](../../skills/reviewer/workflows/qa-review.md) | Review-pr launches the caller panel, or installed reviewers relevant to the diff and Done-when. It always includes installed `reviewer-error` for subprocess, transport, or teardown work. It reuses exact-name live reviewers or uses bounded waves. Codebase review selects every installed `reviewer-*`. QA follows the requested review domain. Individual domains are in the decision table. |
| Missing installed name | [dev § Implementer selection](../../skills/dev/SKILL.md#implementer-selection); [Pi dispatch](../../pi-extensions/pi-agents-tmux/extensions/subagent/dispatch.ts)::`validateAgentInventory`, `formatInventoryValidationError` | Dev requires reporting a missing agent, not replacing it with generalist. Pi validates exact requested names before dispatch. This is not proof of an equivalent check in every harness. |

### Root cause

- The reading-only generalist scope explains the recorded runtime refusals. The label-first source rule does not authorize skipping generalist because it matches no code type.
- KEN-2189 and a consumer item launched generalist and then hit its scope boundary, including after an explicit scope waiver. This supports a scope-conflict cause, not an initial-selection cause.
- KEN-2309 carried the current engineer label but first launched generalist, then switched after its keyed refusal. Only a current label is available, so the record does not prove the label at that first selection.
- The evidence confirms refusals, ad hoc workers, and caller reroutes. It does not confirm that orch **often** silently ignored a launch-time generalist label across the requested period.
- Activation can erase the earlier label choice after a different worker is selected. Fix routing can preserve an earlier worker despite a later label. These are concrete mechanisms to constrain in Phase 2, not historical frequency measurements.

## Fleet measurement

### Bounds, sources, and units

Requested trailing window: **2026-09-17T00:51:20Z to 2026-10-01T00:51:20Z**. Effective lane coverage is **2026-09-26 to 2026-10-01**. Only 6 retained lanes predate 09-26. Earlier lane records were pruned. KEN-2239 launched at 2026-10-01T00:48:01Z. Totals include this running proposal lane; historical conclusions exclude it.

The tables carry the supplied results so the proposal does not depend on session scratch links. Sources were the control host's lane and fleet records, fleet-log history, per-item state archives, worker records (`child_sessions`, dev-round and dev-return files), lane mail and briefs, and the Linear caches, for kendex and the other fleet repositories. Counting rules:

- 617 distinct repo/item lanes, 315 of them kendex's. A relaunch overwrites `launched_at`; fleet logs retain 5 relaunch and 2 launch-failed events. These are not all historical launch attempts, and logs do not restore the missing earlier lane census.
- 854 per-item archives from 09-25 onward. State exists for 419 lanes. The other 198 comprise 35 running, 156 stub archives, and 7 unarchived lanes. Exclude 36 archived items without a lane record from the lane census.
- Deduplicate worker calls by repo + item + `agent_id` across archived copies. `child_sessions` keeps the latest session per role key; repeat calls can disappear. Dev-round files cover 107 items and 568 rounds. Dev-return covers 127 items; 531 fix returns omit agent identity.
- Scope refusals and reroutes come from text, states, and logs. Briefs exist for 94 items; 7 name an implementer. Missing evidence is unknown, not no refusal.
- Labels are current, not historical, read from caches synced 2026-10-01. 616 lanes resolve to an issue. Only 19 filing/launch log snapshots exist; all match current labels.
- No complete transcript census exists. Selection is reconstructed from state, artifacts, and mail.

Per-repository records were removed from this public repository (KEN-2602).

Repo identity comes from the lane, then archive, then overseer. Outcome counting uses repo + item, not sessions or rounds. Outcome evidence combines lane status, cycle merge stamps, merge/close logs, and current tracker state.

### Items and recorded worker calls

| Current lane label | Distinct items |
| --- | ---: |
| `agent:generalist` | 531 |
| `agent:engineer` | 33 |
| `agent:rust` | 39 |
| `agent:frontend` | 2 |
| `agent:researcher` | 3 |
| No label | 8 |
| Not an issue | 1 |
| Total | 617 |

| Logical implementer | Kendex | Other repositories | Retained calls |
| --- | ---: | ---: | ---: |
| generalist | 175 | 123 | 298 |
| rust | 21 | 0 | 21 |
| engineer | 16 | 4 | 20 |
| frontend, lane-local | 0 | 1 | 1 |
| ci-fix/qafix variants | 2 | 0 | 2 |
| Non-catalog roles | 1 | 6 | 7 |
| Total | 215 | 134 | 349 |

- Generalist runtime identities: 290 generalist, 4 null, 2 worker, and 2 `pi -p` one-shots. Engineer identities: 18 engineer and 2 null. Non-catalog identities include dev, proof_controller, and slack-runtime.
- There are 13 items with more than one implementer agent. There are 568 retained round records, not 568 complete agent-labelled calls. Implement-round names include generalist 113, rust 13, `dev-rust-r2` 1, engineer 1, `dev-generalist*` variants 9, other dev labels 5, worker 1, and unnamed 1.
- Of 85 `agent_type_fallback` records, 74 change the launch mechanism because tmux is absent or the run is headless. The same agent runs as a one-shot. Only 11 are agent-selection fallbacks. Neither category equals the anomaly-item total below.
- No retained Iced implementer call appears. This is a result of this collection, not proof of no Iced use in missing records.

| Other role | Retained evidence | Limit |
| --- | --- | --- |
| Reviewers | 8 `child_sessions` calls; 13 `review_agent_ids`; deduplicated artifacts: kendex 1,020, other repositories 240 | Artifact counts are reviews, not unique launches. Kendex artifacts classify correctness 284, test 200, doc 197, error 148, and other 191. Arch, perf, quality, safety, and security have no separate supplied count. |
| Planner | 2 sessions | Overwritten/missing records remain unknown. |
| Researcher | 1 session | Not interchangeable with the 3 currently researcher-labelled lanes. |
| Scout | 1 session | Not a census of all nested exploratory calls. |
| TPM | No lane session; 66 fleet-log mentions | TPM runs in overseers. Mentions are not launches. |
| QA | No session record; 19 `qa-*` artifacts | Missing session records are not zero QA execution. |

### Outcomes

| Recorded implementer set per item | Merged | Running | Stopped | Canceled | Unknown | Total |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Generalist only | 276 | 0 | 0 | 3 | 5 | 284 |
| Engineer only | 15 | 0 | 0 | 0 | 0 | 15 |
| Rust only | 17 | 0 | 0 | 0 | 0 | 17 |
| Engineer + generalist | 5 | 0 | 0 | 0 | 0 | 5 |
| Rust + generalist | 4 | 0 | 0 | 0 | 0 | 4 |
| Frontend + generalist | 1 | 0 | 0 | 0 | 0 | 1 |
| Generalist + non-catalog | 3 | 0 | 0 | 0 | 0 | 3 |
| Non-catalog only | 1 | 0 | 0 | 0 | 2 | 3 |
| State, no implementer recorded | 80 | 0 | 0 | 2 | 5 | 87 |
| No per-item state | 131 | 35 | 3 | 2 | 27 | 198 |
| Total | 533 | 35 | 3 | 7 | 39 | 617 |

No lane remains parked; 28 were parked and resumed. No item ended terminally failed/refused in the supplied classification. Every found refusal eventually led to a merge after a reroute or scope override. This does not mean the initial worker succeeded. Of 39 unknown merge outcomes, 34 currently read Done in Linear. Done alone is not merge evidence.

Child-session statuses are closed 273, active 63, idle 9, done 2, retired 1, and null 1. They describe session lifecycle, not successful task results. Do not derive agent success rates from them.

### Reroutes, refusals, and missing agents

| Item | Recorded event | Source member or log |
| --- | --- | --- |
| KEN-2189 | Current generalist label; two maintenance-only refusals, including a waiver, then rust. | `kendex/KEN-2189/tmp-20260930-205442.admin.tgz`, lane mail |
| KEN-2248 | Current generalist label; scope refusal, then authorized issue-local slack-runtime. | `kendex/KEN-2248/tmp-20260930-105243.admin.tgz` |
| KEN-2309 | Current engineer label; first generalist, keyed runtime refusal, then engineer automatically. | `kendex/KEN-2309/tmp-20260930-235036.admin.tgz` |
| KEN-2255 | Missing catalog frontend led to an engineer choice in a one-item overseer ruling. | kendex fleet log 15:51:45Z, ruling 1790783492 |
| KEN-1779 | Generalist scope refusal followed by a worker identity. | Item archive, fallback fields |
| KEN-2191; KEN-2276, KEN-2293 | Generalist-to-engineer mismatch with no reason; rust/generalist split rounds with no reason. | Item states; splits are not proven fallbacks |

Items in other repositories show the same classes: generalist refusals followed by a lane-local frontend or session-local engineer, a missing catalog frontend leading to engineer choices, an engineer missing after a runtime refusal so the overseer re-delegated generalist, automatic fallback notes that name no dev type, a missing engineer install reported while the generalist label was honoured, and a frontend label set only at activation.

Per-repository records were removed from this public repository (KEN-2602).

Reconciliation of the supplied totals:

- The 23 anomaly items comprise 9 explicit overseer interventions, 10 automatic-handling records, and 4 with no recorded reason. No explicit owner override of implementer identity was found; recorded owner rulings concerned model or scope.
- The supplied term “automatic overrides” is too broad. An item that honours the generalist label while reporting a missing engineer is not an override. The “no dev type” items show runtime fallback, not proven override of a historical label. A label set at activation records timing. KEN-2276 and KEN-2293 are split rounds. Keep all in the anomaly set, but do not call all silent label overrides.
- Of 531 currently generalist-labelled lanes, 279 retain only the generalist logical key, 11 retain another agent, 73 retain state without an implementer, and 168 lack state. The proposal lane is in the last group and is excluded from historical conclusions. “Generalist only” includes items, KEN-1779 among them, that ran on worker runtimes after a refusal. It does not mean all executions used native generalist identity.
- Four of the 11 other-agent generalist-labelled items are kendex's: KEN-2189, KEN-2248, KEN-2255 and KEN-2191. Some first launched generalist. This is not a count of skipped initial generalist launches.
- A catalog gap differs from install drift. Frontend is absent from [agents/](../../agents/) despite dev's route. Engineer landed in KEN-2275; earlier refusals can predate it, and some consumers lacked its install or render when they refused.

## Current harness practice

Official documentation defines task roles and permits stack-specific instructions. It does not require an agent per framework. Keep shared task roles and add a stack worker only for an evidenced uncovered scope. Sources below describe current documented interfaces, not cross-harness execution tests.

| Harness and first-party source | Scope and launch | Model/effort | Native write boundary |
| --- | --- | --- | --- |
| [Claude Code subagents](https://code.claude.com/docs/en/sub-agents) | Markdown agents have separate context, instructions, and a description for delegation. Project/user files are native inputs. | `model` and `effort`; effort otherwise inherits. | `tools` and `disallowedTools` restrict capabilities. A Read/Grep/Glob-only reviewer lacks shell and edit tools. `permissionMode: plan` gives read-only exploration, but parent bypassPermissions/acceptEdits/auto can override it. Plugin agents ignore permissionMode. |
| [OpenAI Codex subagents](https://developers.openai.com/codex/subagents) | Project/user TOML agents define `name`, `description`, and `developer_instructions`. Explicit requests and applicable instructions guide delegation. | `model`, `model_reasoning_effort`; explicit custom-file values beat previously resolved defaults. | Official reviewer examples use `sandbox_mode = "read-only"`. Parent live permission overrides still apply to children. The cited page does not define a universal per-agent built-in tool allowlist. |
| [GitHub Copilot configuration](https://docs.github.com/en/copilot/reference/custom-agents-configuration) | Markdown profiles define jobs. Automatic invocation and user selection have separate native controls. Filename resolves profile conflicts. | `model`, otherwise inherited. This reference documents no effort field. | `tools` is an allowlist; omission enables all available tools, including configured remote tools. A read/search-only profile excludes edit/execute. The reference documents no per-agent sandbox/approval field. |
| [OpenCode agents](https://opencode.ai/docs/agents/) | Primary agents and subagents have separate modes. Description-based delegation and named user invocation coexist. | `model`; additional options reach the provider, including provider-specific `reasoningEffort`. | `permission` permits allow/ask/deny. Edit permission gates write/edit/apply-patch; shell is separate. Review examples deny edits and restrict shell. Plan asks for writes by default, not an unconditional write ban. |

### Kendex permissions today

- Catalog `role`, `tags`, and Markdown are logical source fields, not a universal native permission format. Harness rendering changes their representation.
- The inspected correctness reviewer [Claude render](../../.claude/agents/reviewer-correctness.md) denies Agent and AskUserQuestion, not write tools. Its [Pi render](../../.pi/agents/reviewer-correctness.md) denies delegation, questions, and task-panel tools, not file edits.
- The [Codex render](../../.codex/agents/reviewer-correctness.toml) sets `sandbox_mode = "workspace-write"`. The [Copilot render](../../.github/agents/reviewer-correctness.agent.md) omits `tools`. Under [Copilot's documented rule](https://docs.github.com/en/copilot/reference/custom-agents-configuration#tools), that omission enables all tools.
- [Reviewer § Ethos and Output Contract](../../skills/reviewer/SKILL.md#ethos) permits the review artifact and authorised controls on copies. [Reviewer-read-only](../../hooks/reviewer-read-only.sh) denies named edit tools, limits repository Write calls to review JSON, and rejects named Git mutation commands. Its harness declaration excludes Codex and Copilot. Its shell branch does not prevent every filesystem mutation.
- A prompt or a partial shell-command check is not native read-only enforcement. A retained shell or remote mutation tool can bypass a file-tool restriction. The impact is an altered reviewed tree or remote state; likelihood is not measured. This PR does not repair reviewer permissions.

## Linear routing

Retain exclusive workspace role labels as the local specialist selector. Use a human assignee for ownership. Linear app delegation can later add visible progress, but it is not a replacement selector through today's kendex path.

| Method | First-party evidence | Decision |
| --- | --- | --- |
| Local role label | [dev selection](../../skills/dev/SKILL.md#implementer-selection) and [Linear formatters](../../skills/linear/scripts/lib/formatters.sh) already consume it. | Recommend it. It selects the specialist without a webhook service. Validate exclusive label and installed agent. |
| OAuth app user | [Linear agents](https://linear.app/developers/agents) and [actor authorization](https://linear.app/developers/oauth-actor-authorization) document `actor=app`, admin installation, and app-attributed mutations. | Identity answers who acts in Linear, not which local role runs. One installation has a workspace app ID. The cited interface does not expose separate selectable kendex specialists within that ID. |
| Human assignee + app delegate | [Linear agents](https://linear.app/developers/agents) says app assignment sets delegate rather than assignee. The [published schema](https://raw.githubusercontent.com/linear/linear/refs/heads/master/packages/sdk/src/schema.graphql), `Issue`, `IssueCreateInput`, and `IssueUpdateInput`, separates assignee/delegate and exposes `delegateId`. | Use for ownership and app execution if a later integration supplies it. Do not replace a human assignee with a specialist display name. |
| Sessions and actor history | [Agent interaction](https://linear.app/developers/agent-interaction); [schema](https://raw.githubusercontent.com/linear/linear/refs/heads/master/packages/sdk/src/schema.graphql), `AgentSession.appUser`, `creator`, `AgentActivity.user` | Mention/delegation creates a session. Activities expose thoughts, actions, responses, input requests, and errors. Actor history identifies the app/session user, not an inferred catalog specialist. |
| Display attribution | [Actor authorization](https://linear.app/developers/oauth-actor-authorization), `createAsUser`, `displayIconUrl` | “User (via Application)” changes display attribution. It does not document creation of another selectable delegate identity. |

[Linear agents](https://linear.app/developers/agents) requires `app:assignable` for delegation and `app:mentionable` for mentions. Admins can change or revoke team access. An app installation cannot request admin scope. [OAuth authentication](https://linear.app/developers/oauth-2-0-authentication) supplies read/write scopes; create-only scopes do not establish general update access. [Agent interaction](https://linear.app/developers/agent-interaction) requires enabled session webhooks, a receiver response within 5 seconds, and activity or an external URL within 10 seconds after a created event. Granted assignable scope, webhook readiness, and end-to-end delegation remain unverified here.

### Read-only feasibility evidence

The control-session reads identify Brad Mahaffey (`cebb266f-005a-461c-a877-134ba5186008`) as the personal-key viewer and admin. API `owner=false` for every user does not confirm workspace ownership. The existing active app user is “vanillagreen agents” (`f9755405-2f06-46a6-b706-1f552ff74bef`). App-credential `auth-check` reported `credential=app`, `writes_enabled=true`. Current caches already show that app as assignee on 72 kendex issues and on issues in other repositories. Those assignments do not prove delegate/session support.

The research sidecar records `linear.sh issues --help`, source inspection, and a no-match search for `delegateId|\.delegate\b|--delegate|appUser|agentSession` across `skills/linear` and `skills/orch`. The help was also read in this worktree. Relevant exact help output:

```text
activate       Claim issue: set "In Progress" (--agent applies agent:<name> label).
--assignee <name|me|email|id>  Change assignee (matched as on create)
```

No `--delegate` option appears. This lane's separate authentication read returned:

```json
{"ok":true,"team":"kendex","credential":"api-key","actor":{"kind":"user","id":"cebb266f-005a-461c-a877-134ba5186008","name":"Brad Mahaffey"},"writes_enabled":true,"warnings":[]}
```

This is an excerpt of the auth result, not evidence that app delegation is authorised. The live feasibility test stops at the missing delegate option, as the overseer confirms. **No disposable issue, delegation mutation, or raw API workaround was made.** This lane separately activates KEN-2239 under its existing generalist label and posts its Phase 1 summary; those authorised workflow writes are not a delegation proof.

| Next proof step | Blocking current code | Required later change |
| --- | --- | --- |
| Delegate existing issue while keeping the human | [issue commands](../../skills/linear/scripts/commands/issues.sh)::`update_issue` parses assignee, not delegate; unknown options refuse. | Add a delegate-aware update using `delegateId` without replacing `assigneeId`. |
| Read back delegate independently | Same file::`get_issue` omits delegate; [formatters](../../skills/linear/scripts/lib/formatters.sh) and [cache query](../../skills/linear/scripts/commands/cache-query.sh)::`cache_get_issue` omit it. | Select delegate in live/cache queries and preserve it in safe/compact/bundle formats. |
| Launch from delegate | [dev-start](../../skills/orch/workflows/dev-start.md#1-determine-agent) reads label-derived `.agent`; orch has no delegate/session route. | Define app-to-worker mapping and supported launch route. One app ID alone does not choose maintainer versus runtime. |
| Show app progress | Current CLI/orch have no agent-session integration; [Linear skill](../../skills/linear/SKILL.md#team-target) fixes OAuth scope to read/write. | Verify installation/team access and assignable scope; add session webhook/activity handling before claiming visibility. |

## Catalog decisions

Use lowercase names for a duty or implementation domain. Use `reviewer-<domain>` for review jobs. Keep established concrete names, including `tpm` for technical program management. Remove the generic profession name `engineer`; Rust and Iced workers are engineers too. Match source filename, native identity, routing reference, and label to the canonical name where the harness supports it. Internal `role: engineer` remains a render category, not a competing agent name.

The admission column applies the proposed rule below to every row. Each row supplies a distinct scope, evidence, and exact launch rule. Retained scopes cover work no other retained agent owns. Owner admission review remains required before implementation. Rename/add rows additionally require explicit sign-off. No row proposes a merge; merging maintenance into runtime would remove the evidenced scope boundary. The owner approves the names and scopes for KEN-2400, including the shared scope choice below.

| Existing → proposed; action | One-line scope | Why/evidence | Replaces | Exact Phase 2 launch/routing rule | Admission |
| --- | --- | --- | --- | --- | --- |
| generalist → maintainer; rename | Documentation, references, links, and file/configuration organization settled by reading. | [generalist § Scope](../../agents/maintainer.md#scope) and recorded refusals show a maintenance role, not a runtime catch-all. | Only generalist name, labels, and references; preserve scope. | `agent:maintainer` launches maintainer through dev-start. An unlabelled legacy item with only this scope may be classified for explicit labelling, never launched without a label. | Existing distinct boundary and route; rename needs sign-off. |
| engineer → runtime; rename | Non-UI shell, Python, TypeScript, and Go runtime implementation. | [engineer § Scope](../../agents/runtime.md#scope); runtime refusal records and existing dev route. | Engineer name, labels, and references; add non-UI Go to the shared runtime scope. | `agent:runtime` launches runtime through dev-start. Exclude UI and Rust; split mixed scopes. | Existing runtime gap outside maintainer; rename needs sign-off. |
| rust → rust; keep and align scope | Non-Iced Rust implementation, with project-defined hot-path rules where applicable. | [rust § Scope](../../agents/rust.md#scope) is performance-focused; dev already routes broader `crates/` work to it. | No agent; align description with current route. | `agent:rust` launches rust for Rust domain logic, systems work, and non-Iced implementation. Iced view work selects iced instead, even under `crates/`. | Distinct stack and existing route; approve scope alignment, not another Rust agent. |
| iced → iced; keep | Iced widgets, rendering, layout, theming, subscriptions, and UI messages. | [iced § Scope](../../agents/iced.md#scope); Iced consumer evidence below. | Nothing. | `agent:iced` launches iced for the Iced view layer and its messages. Rust data/domain/persistence work goes to rust. | Distinct UI boundary and current dev route; retention review. |
| Absent → frontend; add | Declarative view layers and UI messages: TypeScript/React web, mobile, and terminal UI; Quickshell QML/JavaScript. | Dev names an absent agent; a consumer's lane-local bridge, refusals and consumer UI inventory show the gap. Vgs QML/JavaScript and human-routed lanes establish the declarative UI addition. | Lane-local frontend bridges and UI overrides, not runtime or iced. | `agent:frontend` launches frontend through dev-start for declarative UI, including Next.js, React Native/Expo, React terminal UI, and Quickshell QML/JavaScript. Follow consumer Tailwind/shadcn on Base UI or Radix. Exclude Iced and non-UI runtime/data/persistence. | Distinct uncovered UI scope, failures, and existing route; addition needs sign-off. |
| researcher → researcher; keep | Provider-backed research and evidence-cited reports. | [researcher § Scope](../../agents/researcher.md#scope); current research-issue execution. | Nothing. | `agent:researcher` issues execute through research-issue's researcher route, not dev implementation; resume prepared assets when picked up later. Direct research requests delegate by name. | Distinct external-evidence scope and real execution route; retention review. |
| scout → scout; keep | Read-only local discovery and compressed cited context. | [scout § Report-Only Contract](../../agents/scout.md#report-only-contract); existing restricted Pi delegation. | Nothing. | The caller requests local discovery and delegates to installed scout. Child Pi calls require its configured allowed-subagents entry. No issue-owner label. | Local discovery differs from provider research; existing consumer and route; retention review. |
| planner → planner; keep with explicit planning route | Ordered technical implementation plans and requested plan artifacts. | [planner § Scope](../../agents/planner.md#scope); roadmap-plan consumes but does not launch it. | Nothing. | Add to orch's primary planning instructions: when the caller requests a technical implementation plan, delegate to installed planner, then pass its TPM handoff through the caller if needed. Do not invoke planner from roadmap-plan. No issue-owner label. | Distinct technical planning output; proposed route closes a current launch gap; retention review. |
| tpm → tpm; keep | Backlog, cycle, roadmap, dependency, and tracked-work organization recommendations. | [tpm § Scope](../../agents/tpm.md#scope); audit/roadmap/overseer analysis consumers. | Nothing. | Audit-issues, roadmap-plan, and overseer proposal batches delegate analysis to tpm. The caller owns approval and mutations. No issue-owner label. | Distinct program planning scope and current routes; retention review. |
| reviewer-arch → reviewer-arch; keep | Documented architecture boundaries, integration rules, and proposal design. | [reviewer-arch § Scope](../../agents/reviewer-arch.md#scope). | Nothing. | Review-pr includes it when Done-when/diff touches architecture, integration, or a proposal; codebase review includes it when installed. | Adopted architecture policy differs from local quality; current panel route; retention review. |
| reviewer-correctness → reviewer-correctness; keep | Behavior, boundary cases, API contracts, state, and cross-component regressions. | [reviewer-correctness § Scope](../../agents/reviewer-correctness.md#scope); separately counted artifacts. | Nothing. | Review-pr includes it for changed behavior/contracts/state; codebase review includes it when installed. | Behavior defects differ from missing tests and error cause; current panel route; retention review. |
| reviewer-doc → reviewer-doc; keep | Documentation claims, values, and citations checked against source. | [reviewer-doc § Probes](../../agents/reviewer-doc.md#probes); separately counted artifacts. | Nothing. | Review-pr includes it for changed doc claims/references; codebase review includes it when installed. | Verifies author output rather than writing maintenance changes; current panel route; retention review. |
| reviewer-error → reviewer-error; keep | Silent failures, wrong-cause errors, and failure propagation. | [reviewer-error § Scope](../../agents/reviewer-error.md#scope); required subprocess/transport/teardown panel rule. | Nothing. | Review-pr includes it for error/fallback work and always for subprocess, transport, or teardown; codebase review includes it when installed. | Error causation differs from general behavior; current mandatory route; retention review. |
| reviewer-perf → reviewer-perf; keep | Measured regressions, hot-path costs, and project-defined budgets. | [reviewer-perf § Scope](../../agents/reviewer-perf.md#scope); QA benchmark contract. Separate launch frequency is unknown. | Nothing. | Review-pr includes it for performance scope; needs-perf-test QA selects it. Run only authorised controls on copies. Codebase review includes it when installed. | Measurement differs from implementation or style; current review/QA route; retention review. |
| reviewer-quality → reviewer-quality; keep | Maintainability, decomposition, type boundaries, duplication, and complexity. | [reviewer-quality § Scope](../../agents/reviewer-quality.md#scope). | Nothing. | Review-pr includes it for implementation structure/quality; codebase review includes it when installed. | Local structure differs from adopted architecture policy; current panel route; retention review. |
| reviewer-safety → reviewer-safety; keep | Memory, thread, lock-free, file, and process concurrency safety. | [reviewer-safety § Scope](../../agents/reviewer-safety.md#scope). | Nothing. | Review-pr includes it for unsafe/concurrency/process/file races; needs-safety-audit QA selects it. Codebase review includes it when installed. | Concurrency differs from authorization security; current panel/QA route; retention review. |
| reviewer-security → reviewer-security; keep | Authorization, injection, trust boundaries, containment, and secrets. | [reviewer-security § Scope](../../agents/reviewer-security.md#scope). | Nothing. | Review-pr includes it for security/trust/ownership changes; codebase review includes it when installed. | Exploitability differs from memory safety; current panel route; retention review. |
| reviewer-test → reviewer-test; keep | Coverage, test validity, controls, assertions, and test wiring. | [reviewer-test § Scope](../../agents/reviewer-test.md#scope); separately counted artifacts. | Nothing. | Review-pr includes it for changed tested behavior or tests; codebase review includes it when installed. | Test evidence differs from product correctness; current panel route; retention review. |

### Shared scope choice

The owner authorizes frontend to cover declarative UI, including Quickshell QML and its JavaScript, and runtime to cover non-UI Go beside shell, Python and TypeScript. Vgs has these product layers. Human routing stops its unattended lanes. The existing view-layer versus non-UI runtime boundary assigns each layer without vgs-local agents. The vgs label row includes both owners.

### Deferred gaps

- Swift application work routes to `agent:swift` through [swift](../../agents/swift.md). Non-UI runtime and persistence stay with their owners. Maintainer remains limited to changes settled by reading.
- Do not add separate Next.js, Expo, Tailwind, Base UI, Radix, or React-terminal agents. The same view-layer boundary and frontend route cover those consumers. Consumer instructions select framework versions and test tools.

## Source structure and permissions proposal

| Field | Required | Logical meaning |
| --- | --- | --- |
| `name` | Yes | Canonical lowercase duty/domain name; matches source filename. |
| `description` | Yes | Short scope and delegation condition. |
| `model` | Yes | `inherit` unless an approved consumer override selects a model. |
| `role` | Yes | Existing renderer category: engineer, analyst, planner, manager, or reviewer. |
| `effort` | Yes | Explicit effort preference, currently high across the catalog; native mapping can differ. |
| `color` | Yes | Display preference, not authority. |
| `tags` | Yes | Shared discovery metadata as a list. |
| `tracked-outputs` | When the agent declares tracked artifact patterns | Existing artifact declaration consumed by verification; not file-write permission. Preserve planner's declared plan and research paths. |

Use one source file, `agents/<name>.md`, with YAML frontmatter, one title, and the required top-level sections `Scope`, `Discipline`, and `Output`. Put role probes and thoroughness rules under Discipline. Put artifact rules under Output. Keep planner's canonical `Plan Artifacts` as a named subsection and update references to it; do not duplicate its default-path rule elsewhere. Add no wrapper, registry, or new classifier.

Propose a **5 KiB source-file ceiling**, measured in bytes including frontmatter. The largest inspected source is reviewer-correctness at 4,753 bytes. Adopt the bound through the existing [doc-limits policy](../../skills/doc-limits/references/policy.md#path-classes), with source class `agents/*.md=5k` in this catalog's `kendex.settings.toml`. Harness renders remain governed by the generated-inventory exemption. Detailed procedures remain in owning skills/references with real consumers, not extra files written only to evade a ceiling.

Preserve [planner § Plan Artifacts](../../agents/planner.md#plan-artifacts) semantics: write only when asked; a caller's path wins; otherwise tracked plans use `docs/plans/<slug>.md` and research uses `docs/plans/<slug>-research.md`. The files never share a path and never become ignored session state. Roadmaps remain in the project-management flow under `docs/roadmaps/`. Progress/handoffs remain orch session state. Preserve both declared tracked outputs and the verification warning/strict-failure contract for ignored outputs. Planner still changes no source, tests, configuration, migrations, generated assets, unrelated docs, dependencies, or locks.

Logical source fields do not carry harness-native permissions. Native `tools`, `disallowedTools`, `permissionMode`, `sandbox_mode`, and `permission` belong in effective harness render/launch configuration. Inspect effective parent overrides, not just source intent. Phase 2 must give reviewers read-only access to the product tree without losing output or authorised QA:

- Use native read-only/tool restrictions for product inspection. No product-file edit capability, broad shell, or remote mutation capability is granted merely to produce a report.
- Where native controls cannot permit only the artifact path, the reviewer returns the schema-defined JSON and orch writes/checks the existing review artifact. Update [reviewer § Output Contract](../../skills/reviewer/SKILL.md#output-contract) and its launch/acceptance consumers together. Do not claim today's direct-write contract already supports this route.
- Authorised QA uses isolated copies and dedicated scratch output. Use the existing [mutation-stability control](../../skills/reviewer/scripts/mutation-stability) and [performance QA rules](../../skills/reviewer/references/perf-qa.md). Where native controls cannot isolate those writes, the caller runs the control and passes its output to the reviewer. The reviewed product checkout stays read-only.
- Prove both boundaries on installed harness versions: the artifact/control succeeds and a product-file write refuses. No permission relaxation or new output wrapper substitutes for that proof.

### Admission rule text

Proposed short section for [docs/DEVELOPMENT.md](../DEVELOPMENT.md), Phase 2 only:

> A catalog agent needs a distinct scope no existing agent covers, a routing rule that launches it, evidence of the gap, and the owner's sign-off. A rename or retained scope change follows the same review. Removal follows the same path: identify who covers the removed scope, update its launch routes, provide evidence, and obtain owner sign-off. Retention records the distinct scope, active or proposed launch route, and evidence during a catalog review. A name or framework alone is not evidence of a gap.

## Labels and repository handoff

Proposed workspace implementer labels: `agent:maintainer`, `agent:runtime`, `agent:rust`, `agent:iced`, `agent:frontend`, `agent:swift`. Keep `agent:researcher` for its separate executable research path. Keep `agent:multi` and `agent:human` as coordination markers, not catalog agents. No labels for scout, planner, TPM, or reviewers without an issue execution route.

- Every repository labels every issue at creation, with no exception. An implementation issue has exactly one installed implementer label. Research uses its one research-role label. Containers use multi; human work uses human. All occupy the exclusive workspace Agent group, but multi/human never become specialist launch identities.
- Preserve present-label priority. No code-path inference replaces a valid label. Classify an unlabelled legacy item only to propose its explicit label before launch. Reject multiple role labels rather than choosing the first.
- A scope conflict stops work and reports evidence plus a reroute request. Only an explicit authorised reroute changes the worker and routing label together. A missing installed agent stops dispatch. Fix rounds retain the selected worker unless explicitly rerouted.
- Activation must verify that its requested worker matches the routing choice. It must not silently rewrite a different label. A stale live-worker/label disagreement stops for reconciliation.
- [Current creation guard](../../skills/linear/scripts/commands/issues.sh)::`require_agent_routing_label` is disabled by an empty declaration and permits `--no-agent-label`. A non-empty setting alone therefore does not implement the no-exception rule. Phase 2 changes that existing guard and callers, rather than adding another classifier.
- [Label reference § Preflight and Creating Labels](../../skills/project-management/references/labels.md#preflight) requires scope/ID checks and an existing definition/taxonomy before creating an agent label. The master coordinates workspace migrations after signed-off definitions exist. Duplicate team frontend labels need a reviewed replace/relabel plan if scope cannot move. [Shared label maintenance](../../skills/linear/SKILL.md#shared-label-maintenance) governs authority and affected repositories.

### KEN-2332 values

These are final proposed values for [KEN-2332](https://linear.app/vanillagreen/issue/KEN-2332), not settings changed here. Each listed repository's item installs the canonical names in its row and renders them before the audit marks the row `ok`. Re-check control-host findings at the repository commit used by that item. Shared base B is exactly `agent:maintainer, agent:researcher, agent:multi, agent:human`.

| Repository | Proposed `LINEAR_AGENT_LABELS` | Evidence and later repository action |
| --- | --- | --- |
| kendex | `agent:maintainer, agent:researcher, agent:multi, agent:human, agent:runtime, agent:rust, agent:iced, agent:frontend, agent:swift` | React/Tauri UI, Rust core, runtime scripts/extensions. Keep iced and swift for maintained catalog work, not a claim that the desktop app uses Iced or Swift. Rename maintenance/runtime installs; add frontend and swift. |
| vgs | `agent:maintainer, agent:researcher, agent:multi, agent:human, agent:runtime, agent:frontend` | Quickshell QML/JavaScript views go to frontend. Go product code and the 59 Python and 46 shell helpers go to runtime. Install both shared owners; replace the generalist-for-QML/Go fallback and human implementation routing. |
| vsys | `agent:maintainer, agent:researcher, agent:multi, agent:human, agent:runtime, agent:frontend` | Bun/OpenTUI React terminal UI: 96 TS, 26 TSX, no Rust in tree or history. Frontend explicitly includes this view layer. Runtime owns non-UI TS. Drop rust/iced labels and the unused rust subscription; install runtime/frontend. |

Per-repository records were removed from this public repository (KEN-2602).

Evidence is the supplied read-only control-host repository census on 2026-09-30, updated by the 2026-10-01 install measurement. It reads each repository's `kendex.toml` (`kendex-local.toml` for kendex), `kendex.settings.toml`, tracked product paths, and rendered agent directories. It is not a claim that this checkout contains those other repositories. Initial provisional frontend entries are resolved above.

KEN-2332's consistency table needs two cells per repository: label declaration and taxonomy shape. Each cell records current value, expected value, `ok`/`gap`/`waived`, and reason. Taxonomy belongs in manifest `[skill-instructions].project-management`, not the settings file. Use kendex's `### Project taxonomy` contract, a team Scope line excluding all agent labels, and the shared-label owner reference. Declare the agent set once through `LINEAR_AGENT_LABELS`; remove duplicated per-agent scope tables. A missing Phase 2 agent is a gap, not available because this proposal merged.

## Phase 2 change map

| Area | Sources and consumers | Required signed-off change |
| --- | --- | --- |
| Agent catalog | [agents/](../../agents/); [local manifest](../../kendex-local.toml), agent subscriptions and frontmatter; [render rule](../../skills/AGENTS.md) | Rename maintainer/runtime, add frontend, align Rust scope, and apply the common schema/sections/ceiling. Update every tracked harness render and generated inventory in the same commit as its source. Render from the main checkout, not a worktree. |
| Implementation and fix routing | [dev selection](../../skills/dev/SKILL.md#implementer-selection); [dev-start](../../skills/orch/workflows/dev-start.md); [dev-fix](../../skills/orch/workflows/dev-fix.md); [dev-implement](../../skills/dev/workflows/dev-implement.md); [start](../../skills/orch/workflows/start.md), [handoff](../../skills/orch/workflows/handoff.md), [start-worktree](../../skills/orch/workflows/start-worktree.md); [orch skill](../../skills/orch/SKILL.md) | Update every old-name reference. Preserve label priority and explicit fix continuity. Add the technical-planner launch condition in primary instructions. Route prepared research issues to their researcher workflow. Stop at missing installed agent or scope conflict. |
| Label mutation and creation | [issue commands](../../skills/linear/scripts/commands/issues.sh)::`activate_issue`, `require_agent_routing_label`; [label resolver](../../skills/linear/scripts/lib/common.sh)::`resolve_label_id`; [labels reference](../../skills/project-management/references/labels.md) | Prevent activation from rewriting another route without authorisation. Remove bare-create escape from the owner's no-exception path and update intake callers. Require exclusive workspace agent labels. The resolver currently takes the first same-name match without team scope; duplicate-name resolution needs a separate runtime-owner correction, including non-agent duplicates. |
| Reviewer permissions | [reviewer contract](../../skills/reviewer/SKILL.md); [review-pr](../../skills/orch/workflows/review-pr.md), [review-codebase](../../skills/orch/workflows/review-codebase.md), [QA](../../skills/reviewer/workflows/qa-review.md); [read-only hook](../../hooks/reviewer-read-only.sh); manifest native frontmatter | Apply effective native product-read-only controls. Preserve artifact acceptance and copy-based QA through caller materialisation/execution where needed. Test effective restrictions per harness. This needs implementation-owner review, not just agent prose edits. |
| Settings and taxonomy | [settings](../../kendex.settings.toml), `LINEAR_AGENT_LABELS`; [local manifest](../../kendex-local.toml), project-management taxonomy | Apply the kendex value above and one contract shape. Master coordinates workspace group/label migration with repository maintainers; lanes do not mutate shared definitions. |
| Admission and listing | [DEVELOPMENT](../DEVELOPMENT.md); [README](../../README.md); existing doc-limits configuration | Add the exact admission section, current catalog listing, and common source ceiling. Planner keeps the one home of Plan Artifacts. No parallel catalog registry. |
| Consumer release note | [changelog.d policy](../../changelog.d/README.md) | Add a consumer-facing fragment for signed-off names, scope/routing changes, and required subscription migration. Phase 1 ships no agent feature fragment. |
| Per-repository follow-ups | KEN-2332 table above | Each later repository item changes subscriptions, effective renders, non-empty setting, taxonomy, and creation policy together. Reconcile existing issue labels only under authorised migration. |
| Routed-agent drift | [KEN-2346](https://linear.app/vanillagreen/issue/KEN-2346) | Add an audit row for each open issue whose role label names an agent absent from that repository's effective install. Distinguish missing declaration, missing render, and missing catalog definition. Multi/human are coordination markers. If KEN-2346 has merged, Phase 2 adds this row there. |
| Migration completion | Source, render, workflow, manifest, tracker inventory, and consumer subscriptions | Search the changed consumers for removed generalist/engineer identities. Verify installed-name refusals, labelled creation, explicit reroute, fix continuity, and permitted reviewer output. Roll back names/routes/labels together if effective launch fails. |

Linear delegate/session integration is separate follow-up work. It does not gate this label-based Phase 2 and does not count as implemented by a raw API experiment or this proposal.
