# GitHub repository standard

This plan assigns shared GitHub configuration to `github-repository-settings`, which updates it through `kendex refresh`.

## Framing

- KEN-2332 contains only this plan. Owner rulings remove extra owner approval and require package/settings/hook consistency. [issue]
- Reuse existing rendering, adoption, classification, aggregation and settings readers. Add no parser, classifier, registry or policy engine.
- Universal or opt-in only; vgs uses settings.

## Approach

Choose byte-managed templates with Rust, Bun, Next.js/pnpm and custom presets. Keep the literal required `CI` job in a managed top-level caller. Consumer jobs live in an unmodified-by-refresh local reusable workflow. GitHub supports `workflow_call` and static `needs`; it does not insert caller jobs into a called workflow's dependency list. [G1], [G2], [G3]

| Alternative | Disposition |
| --- | --- |
| Central reusable workflows at pinned release tags | Declined as the shared CI owner. A literal caller reference still needs updates, and reusable-job checks have a distinct name format. A managed caller remains necessary. KEN-2281 also requires rolling refresh to resolve the latest released engine, not a fixed version. Existing reusable catalog checks remain valid. [G1], [G5], [release-first] |
| Byte-managed templates | Selected: extend current `adopt-refresh.sh` writes, edit reports and template-hash inventory. `kendex verify` already compares adopted copies with declared template bytes. [C1], [C2] |
| Edit managed YAML, or poll separate workflows' statuses | Declined: refresh overwrites the first; GitHub's static workflow-call dependencies replace the second. [C1], [G1], [G3] |

### Ownership and transition

**Current owners**: review-gate writes refresh; bot-instructions renders review files; harness-ci supplies a copied CI template. Below is the build target, not installed behavior. [C1], [C2], [C4]

- `github` remains the PR runtime, with reader-facing title **GitHub pull requests**. It owns threads, replies, live review checks, CI interpretation and merging. `github-repository-settings` owns repository configuration. KEN-2334 can change the runtime without moving configuration back into it. [C3], [runtime-research]
- Fold bot-instructions effects into configuration. During adoption, keep one renderer source in bot-instructions as a temporary library dependency. Revoke the old effect and arm the new effect together. Extend the current core locator to choose the new owner when declared, otherwise the old owner for unadopted scopes. It never runs both. After all consumers switch, move that single source and its schemas/tests into configuration and remove the temporary dependency. No copied renderer or permanent forwarding package. Keep the existing `[bot-instructions]` table. [C4], [C5]
- `harness-ci` keeps classification, lane declarations, proof reuse and `aggregate-needs`; its CI template/adoption guidance move to configuration. It continues to write no workflow. [C2]
- `commit-guards` keeps local Git hooks and commit-chain checks. Hosted CI cannot judge an offline commit before Git writes it. Configuration invokes those checks, not a second implementation. Hooks remain opt-in and must be armed in each clone. [C6]

| Written paths | Owner and behavior |
| --- | --- |
| `.github/workflows/ci.yml` | Configuration: exact selected preset, final top-level `CI`. |
| `.github/workflows/kendex-refresh.yml` | Configuration: exact template, opt-in consumer refresh. |
| `.github/workflows/kendex-dispatch.yml` | Configuration: exact template, opt-in source publisher only. |
| `.github/PULL_REQUEST_TEMPLATE.md`, `.github/ISSUE_TEMPLATE/bug-report.yml` | Configuration: optional managed PR/defect templates. |
| `.github/copilot-instructions.md`, `.github/instructions/code-review.md`, enabled `.github/instructions/*.instructions.md` | Configuration through the existing bot renderer; retain markers, schema and one doctrine. |
| Enabled `.coderabbit.yaml`, `.pr_agent.toml`, `best_practices.md`, `REVIEW.md`, `.macroscope/`, `AGENTS.md` review-pointer region | Move with the renderer, despite living outside `.github/`. [C4] |
| `.github/workflows/ci-project.yml` | Consumer-owned `workflow_call`; create a no-op scaffold only if absent. Refresh never replaces it. |
| `.github/ci-lanes.conf`; release/publish/deploy workflows | Consumer-owned unless explicitly adopted. Preserve repository dependency and credential knowledge. |
| Harness `.github/agents/`, `.github/hooks/`; architecture, decisions and instruction files | Existing core harness delivery or consumer-authored substance, not shared config templates. [C7], [C8] |

Use repository-effects and `.kendex-generated.json` as the sole ownership inventory. Preview adoption, preserve unrelated files/extensions, refuse symlinks and report hand edits through the existing first-divergent-line check. [C1], [C5]

### CI and consumer extension

- Start on `pull_request` and `merge_group`, with no workflow path filter. Classify once from the trusted default-branch package. Run standard checks, preset product checks and the consumer workflow call. Final `CI` has `if: always()` and static `needs` for every preceding job. Call `aggregate-needs`; failed/cancelled jobs, failed classification and unauthorized skips fail. A skipped job alone can satisfy GitHub's required-check rule, so the helper is necessary. [G3], [G4], [C2]
- Presets differ in tool installation, lockfiles and cache setup. They run existing `DEV_VALIDATE_CMD` using the existing environment reader. Pass its existing class/docs/path contract; do not infer a test command from the stack name. A missing command fails with its setting name. Tool setup stays unconditional when a standard check needs the tool. [C2], [C9]
- The caller invokes `./.github/workflows/ci-project.yml` as job `project`. Typed inputs carry event, base SHA, head SHA, class, docs verdict and lane verdicts. GitHub's literal local reference uses the caller's commit. A real file always exists; do not assume a condition legalizes a missing reference. No write token or inherited secrets by default. Privileged deployment stays separate. [G1], [G2]
- The custom preset moves repository matrices/selectors into that consumer file in the same adoption PR. Replace a second classifier with caller inputs. Kendex keeps `tools/ci-job-set`, runner legs and `tools/ci-aggregate`; the shared helper remains the skip judge. [C9]
- Keep `CI` outside the reusable workflow and observe actual check-run names on both events. Kendex's literal `CI` context is already live. Preserve its name and Actions app binding. Adopt existing CI and consumer jobs in one PR, without a temporary context or second check-name migration. The fleet overseer pairs any unfinished old-context rule change with its workflow adoption. [G5], [C10], [audit-kendex]

### Names and settings

Package commands reuse bot/adoption operations: `adopt` previews/takes ownership, `render` writes managed files, `check` reads equality/settings, `retire` revokes effects. New settings use `kendex.settings.toml` `[env]`; bot choices retain their manifest table.

| Key | Meaning and default |
| --- | --- |
| `GITHUB_STANDARD_CHECK_LOCATION` | `hosted` or `local`; installation asks, never silently arms hosted CI. |
| `GITHUB_STANDARD_STACK` | `rust`, `bun`, `nextjs-pnpm`, `custom`; required for hosted CI. |
| `GITHUB_STANDARD_BOT_REVIEW` | Remote review enablement: `off` by default, `on` by choice. Local harness instruction pointers do not enable remote review. |
| `GITHUB_STANDARD_REFRESH` | Consumer refresh: `off` by default, optional `on`. |
| `GITHUB_STANDARD_DISPATCH` | Source-publisher dispatch: `off` by default, optional `on`. |
| `GITHUB_STANDARD_PLATFORM_CHECKS` | Organization/app/environment standard: `off` by default, optional `on` with declared values. |
| `GITHUB_STANDARD_TEMPLATES` | Selected PR/defect templates; empty by default. |
| `GITHUB_STANDARD_APP` | App installation; replaces `REVIEW_GATE_STANDARD_APP`. |
| `GITHUB_STANDARD_ENVIRONMENT` | Refresh environment; replaces `REVIEW_GATE_STANDARD_ENVIRONMENT`. |
| `GITHUB_STANDARD_SECRET_NAMES` | Secret names only; replaces `REVIEW_GATE_STANDARD_SECRETS`. |
| `GITHUB_STANDARD_REQUIRED_CHECKS` | Declared checks; replaces `REVIEW_GATE_STANDARD_CONTEXTS`; hosted target `CI`. |
| `GITHUB_STANDARD_QUEUE_BYPASS_ACTORS` | Actors on a queue-only rule; replaces `REVIEW_GATE_STANDARD_QUEUE_BYPASS`. |
| `GITHUB_STANDARD_CHECK_BYPASS_ACTORS` | Actors on a checks-only rule; replaces `REVIEW_GATE_STANDARD_CHECKS_BYPASS`. |

Retain `DEV_VALIDATE_CMD`, `HARNESS_CI_QUEUE_PATHS`, commit-guard keys and bot keys under their current owners. The moved settings reader reads a new name first, then an absent new key's old name with one warning naming the replacement. Keep the old read for at least one minor release. Removed writer/predicate keys get an ignored-setting warning and changelog, not a fallback. No rename command or registry exists; this is the existing-reader transition confirmed by lane-mail answer 1790811460-32876-10717 and KEN-2309's merged compatibility rule. [C2], [C6], [versioning]

vgs's routed fix list sets local-only/no-bot policy: no armed Git hooks; diff checks run through `DEV_VALIDATE_CMD`. Local harness instructions do not enable remote review. [A-vgs], [R-vgs]

### Refresh path

`kendex refresh` updates the declared configuration package. The current armed automatic-render mechanism invokes its effect; do not run arbitrary package installers automatically. Adoption selects exact template bytes and records hashes, while the moved bot renderer writes its existing outputs and reports owned paths/regions. `kendex verify` compares template copies; the bot checker re-renders non-verbatim outputs. Settings select templates rather than generating YAML fragments that the verifier cannot compare. [C1], [C4], [C5]

The consumer workflow installs the latest release under KEN-2281, refreshes and owns its rolling PR, concurrency and report. App/CLI do not open consumer PRs. `refresh-reviews.sh` still uses `kendex report`, replies only after successful filing and leaves unfiled threads open. Keep kendex excluded: D007's main-built `lock-record.yml`/`tools/lock-record` remain source-specific. No lane writes its lock. [release-first], [C7], [C11], [D007]

## Review-gate retirement

KEN-2089/PR 3264 owns engine deletion and is frozen behind KEN-2281. Build after those merge; inspect the surviving files. Do not delete the engine again or restore its evidence/carry reducer. Final retirement waits until every consumer stops requiring `Review gate`. [engine-removal], [release-first]

| Current review-gate files/responsibility | Placement |
| --- | --- |
| `kendex-refresh.yml`, `adopt-refresh.sh`, `refresh-consumer.sh`, `dispatch-refresh.sh`, `refresh-report.py`; refresh reports/fixtures/tests | Configuration, with `.github/workflows/kendex-dispatch.yml`. |
| `refresh-reviews.sh` | Configuration: refresh-job lifetime, using GitHub runtime and existing reporter. |
| `validate-standard.sh`, `provision-environment.sh`, `lib/standard.sh`, `standard.json` | Configuration: opt-in standard; preserve D016 bypass semantics. |
| `validate.sh`, `validate-workflow.sh` | Retained installation/settings/equality checks move to configuration; review-depth choice to reviewer. Engine/carry portions are KEN-2089 deletions. |
| `pr-watch.sh`, tests and fixtures | GitHub runtime. Move orch `oversee-watch`, `lane-close`, `lib/pr-watch-pass.sh` and github `pr-merge.sh` callers in one commit. |
| `review-policy` | KEN-2089 deletes engine implementation. Preserve depth intent once as `reviewer review-depth`, never as an approval exemption; use harness-ci. |
| `references/automatic-review.md` | GitHub runtime, ruleset-based discovery; orch retains its sole waiter. Remove fixed org IDs from universal guidance. |
| `lib/review-findings.sh` | Move narrow disposition/body definitions to GitHub; automatic-author definition stays with refresh. One grammar per check. |
| `lib/settings.sh`, `lib/diagnostics.sh` | Retained callers' owners; no copied settings parser. Remove dead engine messages after prerequisites. |
| `lib/waiver.sh`, writer/predicate scripts/templates/self-tests and `tests/lib/predicate-selftest/` | KEN-2089 deletions. Preserve the narrow live disposition checks before their extractor would disappear. |
| Vendored-path instruction template/reference/tests | Configuration bot renderer for retained review scope; no carry waiver survives. |
| SKILL/README/DEVELOPMENT/settings example/adoption/settings references and remaining tests/helpers | Move retained contracts/tests with their mechanism. Remove entry points/source/render trees only after consumers switch. Inventory all tracked callers before removing a helper. |

### Rule preservation

Move `orch/references/finding-disposition.md` to reviewer with inbound links. Orch keeps execution/counters/tracker creation; GitHub owns live reads/replies. Renders cite reviewer conduct. [C3], [C13]

| Rule | New file/section and treatment |
| --- | --- |
| Verification prerequisite, ordered decision flow, introduced/armed defects, exclusions, scope restraint | `reviewer/references/finding-disposition.md`: Verification prerequisite and Decision flow; moved without weakening. |
| Round cap, recurrence/freeze, filing bar, duplicate-open-PR check, creation ownership | Same file: Decision flow, Recurrence, Filing bar, Review pipeline; moved. Orch owns counters; project-management owns creation bar. |
| Fixed/Tracked/Declined reply contract | Same file: Decision flow/Recurrence; moved, with current GitHub reply API. |
| `untracked-claim`: tracking must name an issue | `github/scripts/check-review-replies`, tracking check; move existing extractor and must-fail control. |
| `unreasoned-decline`: decline must give a real reason | Same script, decline check; move existing extractor/control; reviewer owns reason definition. |
| `suppressed-findings`: body-only findings need head-bound dispositions | Same script, body check; move current heading/details grammar, count and head-bound matching controls. Missing/unreadable/mismatched evidence fails. |
| Class selects review depth | `reviewer/scripts/review-depth`: merge depth intent with reviewer; no new classifier or native-approval waiver. |
| Render exclusions/policy-changing approval | Configuration's existing bot schema/doctrine: merged with current rule, not another copy. |
| Automatic reviewer targeting and unfiled refresh findings | GitHub automatic-review reference and configuration refresh reference respectively; moved with existing wait/report owners. |

The three narrow reply checks run in CI's standard job for every PR head and as a live read in `pr-merge`/orch's final review step, because replies can change without a push. GitHub approval/thread rules cannot prove their content. They run read-only through the PR API, never execute PR scripts with write credentials and publish no replacement review status. Prove that a native-approved PR with a bad disposition fails the live merge check. [G6], [C3], [C13]

## Package catalog boundaries

Skills own source, render and settings examples; local skills own local sources. Pi packages own their extension directories/settings. Core delivers companion agents/hooks; hooks own checks. The table resolves exceptions. [C14], [C15], [C7]

| Package | Scope and boundary |
| --- | --- |
| `github-repository-settings` | Shared `.github/`/bot files, refresh, templates and opt-in platform standard; no PR runtime. |
| `bot-instructions` | Current renderer/schema/validators; temporary single-source library, then folded into configuration. |
| `review-gate` | Engine deletion is KEN-2089; every survivor is placed in the retirement table. |
| `github` | PR API reads/replies/check interpretation/merge; takes watch and narrow reply validation. KEN-2334 owns runtime value research. |
| `harness-ci` | Classifier, proof reuse, lane verdicts and aggregate helper; template moves, no `.github/` writer. |
| `commit-guards` | Git hook installation and commit checks; configuration invokes them, never owns them. |
| `reviewer` | Review conduct, finding schema, QA and depth; takes canonical disposition, not orchestration counters. |
| `orch` | Delegation, state, waiters and fleets; calls GitHub runtime/reviewer conduct rather than duplicating them. |
| `dev` | Implement/fix rounds and validation receipts; calls gates, does not classify or file independently. |
| `project-management` | Planning/audit/decomposition and tracker creation; owns creation bar, reviewer cites it. |
| `code-quality` | Engineering rules; other instructions cite, not copy. |
| `docs-writing` | Document formats; architecture substance stays consumer-owned. |
| `decider` | Decision format/index/search; configuration does not parse decisions again. |
| `deep-research` | Exa report procedure/validation; web tools supply requests only. |
| `dep-radar` | Dependency sweeps/upgrades; native Dependabot settings are configuration, not another sweep. |
| `doc-limits` | Byte ceilings/exceptions; commit/CI call its classifier. |
| `preflight` | Diff-scoped deterministic checks; no replacement in configuration. |
| `linear` | Tracker API/cache; reporter keeps `kendex report`, no second tracker route. |
| `iced-rs` | Iced reference; installs only where Iced work exists. |
| `price-handling` | Trading price rules; no non-trading installation. |
| `second-opinion` | External model invocation; reviewer owns dispositions. |
| `slack` | Mailbox/channel transport; orch owns mail state. |
| `worktree` | Worktree lifecycle/links/leases; commit-guards owns hook arming. |
| Local `app-deploy`, `npm-deploy`, `pi-update`, `kendex-issues` | Respectively kendex release, Pi publish, Pi compatibility and kendex issue cycle. Each retains that separate local scope; no universal release workflow. |
| `pi-agents-tmux` | Pi agent sessions; orch owns rounds. |
| `pi-background-tasks` | Harness background tasks; orch owns its job units. |
| `pi-caveman` | Session communication mode; prose rules stay docs-writing. |
| `pi-claude-bridge` | Claude provider transport; no config writer. |
| `pi-codex-minimal-tools` | Native image/patch operations; renderer displays them. |
| `pi-extension-manager` | Package/settings inventory; skills and sessions have their own managers. |
| `pi-hooks` | Dispatch core-rendered hook events; hook scripts own decisions. |
| `pi-nested-agents-md` | Nested instruction context; core owns instruction shims. |
| `pi-output-policy` | Output bounds/spills; tool renderer does not repeat limits. |
| `pi-prompt-stash` | Prompt stash; not session lifecycle. |
| `pi-qol` | Prompt/status/notification/handoff UI; bridge owns transport, task panel owns tasks. |
| `pi-questions` | Inline questions; delegated asks remain lane-mail. |
| `pi-session-bridge` | Session-control transport; session manager owns UI. |
| `pi-session-manager` | Session browsing/resume/removal; not package/skill ownership. |
| `pi-skills-manager` | Skill browsing/editing; package install stays extension manager, catalog renders stay core. |
| `pi-task-panel` | Conversation tasks; Linear owns tracked work. |
| `pi-tool-renderer` | Results/diffs; output policy owns bounds. |
| `pi-web-tools` | Provider requests/content retrieval; research skill owns reports. |


## Adoption audit

### Criteria

Cells use `ok` (meets criterion, not package installation), `gap` (missing/stale/unreadable) or `waived` (evidenced owner policy/scope exclusion), plus a reason. Contents API evidence cannot prove clone-local hook arming. [G7]

| Column | Criterion |
| --- | --- |
| AGENTS.md | Root project/commands/conventions map and conditional deeper readings. [C8] |
| Architecture | Overview boundaries/enforced invariants plus conditional topic index; topics name coverage. [C8] |
| Decisions | Readable numbered-record listing/index; no semantic re-review. |
| Templates | Declared shared PR/defect templates or explicit opt-out. |
| CI | Final literal `CI`, PR/merge-group events, authorized skips and matching required context. |
| Refresh | Managed consumer workflow/current engine route, or evidenced opt-out/source exclusion. |
| Review-gate | Native approval route, no retired required context/settings after rollout. |
| Commit-guards | Declared package/companion/setup ownership; clone arming remains unobserved. |
| Bot instructions | Declared enabled files/pointers or explicit bot opt-out; marker is not byte proof. |
| LINEAR_AGENT_LABELS | Present in `settings` `[env]`: B plus stack-supported specialists declared in `[agents.<name>]`. Values remain provisional until KEN-2239 and the master's published global list. |
| Label taxonomy shape | Manifest `[skill-instructions].project-management`, `### Project taxonomy`: required-category sentence, team-label Scope with “all other labels in this taxonomy have workspace scope”, shared owner citing Linear's Shared label maintenance, and the `labels.md` JSON contract with agent `{"match":{"prefix":"agent:"}}` and set declared by `LINEAR_AGENT_LABELS`; no local agent table or `agent:*` in team Scope. [C16] |

`B` means `agent:generalist,agent:researcher,agent:multi,agent:human`; `+engineer` adds `agent:engineer`, and other suffixes expand the same way. Cells compare sets, not ordering. Installed/unlabelled and labelled/uninstalled compare generalist, researcher and specialists, not planner/reviewer/scout/tpm roles; multi/human are routing labels, not agent definitions. `engineer` covers shell/Python/non-UI TypeScript, `frontend` TypeScript/React UI, `rust` Rust and `iced` Iced. Frontend becomes available only after KEN-2239 merges and the master publishes its list; missing only frontend is `gap: pending KEN-2239`. The plan PR does not wait. [agent-catalog], [C17]

The existing `issues create` guard enforces declared agent-label membership and presence, except deliberate `--no-agent-label`, and `kendex refresh` renders `[skill-instructions]`; neither proves stack suitability, installed-agent fit or taxonomy Scope, which remain adoption checks under this owner standard. [C17], [C18]

### Snapshots and evidence

API discovery establishes `vanillagreencom` as each repository's owner. The read-only metadata/contents/rules audit completes at **2026-09-30T23:42:59Z**. Contents use the commits below; rulesets are live observations at request time.

The lane token lists only kendex; `/user` and `/user/repos` return HTTP 403. Ask `1790811326-27142-30894` supplies the other snapshots. Archive SHA-256: `7dbec5ec737c19df2d4da42607316da8ffddbbc55e7d10328687045642b8ae59`. This plan preserves refs, paths and dispositions without session-file links. No clones or secrets enter the audit.

| Repository | Default-branch snapshot | Citation root |
| --- | --- | --- |
| kendex | `781eb4cfed71b1900de359476045953f51ccd545` | [Repository paths][A-kendex] |
| vsys | `d80f21ddf0ff827186da3f2c0b5fbd2ba7861cbd` | [Repository paths][A-vsys] |
| vgs | `c6f8347e05d53b004079db2bd869b715faf94392` | [Repository paths][A-vgs] |

Per-repository records were removed from this public repository (KEN-2602).

`overview` is `docs/architecture/overview.md`; `index` is `docs/decisions/INDEX.md`; `settings` is `kendex.settings.toml`; workflows are under `.github/workflows/`. Repository citations bind paths to snapshots. `R-*` cites branch rules. A 404 establishes absence only at that snapshot.

Generator markers do not prove byte equality. Adoption runs each owner's checker. Core owns the listed harness agents/hooks under `.github/`; this audit does not fetch them.

Label cells use pinned `settings`, manifest `[agents]` and project-management instructions from the same bundle. Stack evidence is `AGENTS.md`/overview. Additional overseer contents evidence at the vsys snapshot lists `src/ui/App.tsx` and screen components; `package.json` declares React and OpenTUI. Its actual TypeScript UI meets the optional frontend condition. [A-vsys]

### Repository table

| Repository | AGENTS.md shape | Architecture overview and topics | Decision records | Templates | CI workflow shape | Refresh workflow | Review-gate settings | Commit-guards hooks | Bot instructions | LINEAR_AGENT_LABELS | Label taxonomy shape |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| [kendex][A-kendex] | ok: root map and local directory read conditions | ok: overview and covered topic index | ok: numbered decisions/index, including D007 and D016 | gap: templates absent, no opt-out | ok: `skill-tests.yml` final `CI` covers lanes; PR/merge-group `always()` path; rule requires only Actions `CI` [R-kendex] | waived: consumer template exclusion required by D007; `lock-record.yml` records with main-built binary; dispatch remains | gap: rule has no gate, but settings still list old status keys and obsolete required contexts [R-kendex] | ok: `kendex-local.toml`, `tools/setup`, package and local `tools/guard` route | ok: manifest ownership and generated `.github/instructions/` pointers present; renderer still a separate writer | gap: pending KEN-2239; current B+engineer,rust,iced; provisional B+engineer,rust,iced,frontend. Both mismatch sets empty. Rust/Tauri/React and shell/TypeScript tools; iced installed but no Iced app, owner target defers removal to KEN-2239. | ok: contract; required agent/surface, Scope names cli/harness/skills, workspace remainder, shared owner/procedure and agent prefix/set declaration. Release-label scope migration needs separate approval. |
| [vsys][A-vsys] | ok: root map, Bun/check commands and conditional subsystem links | ok: overview, covered topics and read conditions | ok: numbered decision index/listing | gap: templates absent, no opt-out | gap: no final `CI`; rules require Bun, gate-configuration and bot-instructions contexts [R-vsys] | gap: refresh pins `v1.2.0`; review handling uses `--report-only`; reconcile with the retained reporter contract | gap: required `Review gate` and enforcing old settings remain [R-vsys] | ok: package/companion declared, committed SKILL and local settings | ok: declared Codex/Copilot and generated pointer present | gap: current B+rust,iced; provisional B+engineer,frontend. Installed/unlabelled: none; labelled/uninstalled: iced. Bun runtime/warden plus React/OpenTUI src/ui/*.tsx meets optional frontend condition; no Rust/Iced code. | gap: absent; no project-management taxonomy block. |
| [vgs][A-vgs] | ok: root map states local diff checks and explicit no-gate policy | ok: overview indexes `topics.md`; that index supplies read conditions; subsystem files carry coverage | ok: numbered records/index listed | gap: templates absent; adoption selects explicit opt-out | waived: AGENTS explicitly forbids hosted CI/gates; `.github/` lists no workflow directory and branch rules are empty [R-vgs] | waived: local-only/no-workflow owner policy; no refresh workflow observed | waived: `REVIEW_GATE_MODE=off`, no required rules, no gate package; retain local/no-bot policy as settings [R-vgs] | waived: AGENTS forbids arming commit/push gates; pre-commit companion is disabled; package may remain unarmed | waived: remote bot review not required by owner policy; no native review rule. Generated Copilot/Codex files are local harness instructions, not evidence that remote review is enabled [R-vgs] | gap: current B; provisional B+engineer. Both mismatch sets empty; engineer missing install/label. Quickshell with Go/shell helpers, not Rust/Iced/React. | gap: table; required-agent prose/local agent table, no team/workspace Scope, shared owner/procedure or JSON prefix/set declaration. |

Per-repository records were removed from this public repository (KEN-2602).

### Gap disposition

Overseers route gaps to build/adoption. Adoption reads PR/merge-group checks and clone-local arming through commit-guards' `--check`. [C6], [G4]


## Full consistency audit

Directive 1790811911 adds package/customization/hook consistency at the pinned snapshots. Comment kept non-defaults with reasons in manifests. Global Pi installation and clone arming need adoption proof, not an API inference.

### Fit and common actions

Every repository installs the common skill set: `code-quality`, `commit-guards`, `decider`, `deep-research`, `dep-radar`, `dev`, `doc-limits`, `docs-writing`, `github`, `github-repository-settings`, `harness-ci`, `linear`, `orch`, `preflight`, `project-management`, `reviewer`, `second-opinion`, `slack`, `worktree`. Slack channel setup remains opt-in. `iced-rs` fits only a repository with Iced work; kendex's exception is deferred in its row. `price-handling` fits only trading paths. Agent targets and stack evidence follow the adoption audit; KEN-2239 settles specialist installs/removals and final values. Keep observed local skills for local tasks, not kendex-only deployment work. [C14]

Pi extensions are global harness packages, not repository GitHub configuration. For every repository using Pi, retain core-managed carriers and existing Pi packages listed in the package-boundary table; do not add them through a project skill declaration. API evidence lacks global Pi state: adoption checks the native global inventory and records deliberate absence. Until then this is a gap. Pi packages do not fit other harnesses.

Enable every catalog hook for each declared harness that supports its native event. Use the hook's shipped harness list and core's existing event capability table, not a new map. Excluding a supported harness requires a manifest comment. Unsupported events remain unsupported, not a shim. `skill-load-check` activation depends on KEN-2337. vgs alone keeps `pre-commit-check` disabled and commit-guards unarmed because its owner forbids commit/push gates. Other disabled hooks turn on. [C7]

**Common exact adoption edits**: in `kendex.settings.toml`, hosted consumers set `GITHUB_STANDARD_CHECK_LOCATION="hosted"`, `GITHUB_STANDARD_REQUIRED_CHECKS="CI"`, `GITHUB_STANDARD_REFRESH="on"`, `GITHUB_STANDARD_PLATFORM_CHECKS="on"` and `GITHUB_STANDARD_DISPATCH="off"`. Enable `GITHUB_STANDARD_BOT_REVIEW="on"` only when native bot review is selected; keep each explicitly enabled bot. In `kendex.toml` (kendex uses `kendex-local.toml`) replace the explicit review-gate/bot-instructions install declarations with the new configuration package after prerequisites and adoption. Remove review-gate from agent skill lists. Add a comment to each kept customization. Do not remove a writer while any required rule still names it.

**Common platform edits**: in the repository required-checks ruleset, replace the old CI contexts with `{context: "CI", integration_id: 15368}` when its paired adoption workflow reports it. Remove `Review gate` through the existing engine rollout before final retirement. Preserve native approval, stale-dismissal, thread-resolution and D016 bypass constraints. The platform opt-in uses existing standard validation; no extra policy engine.

### Per-repository consistency and fix lists

Each row is its repository's fix list. Agent names and scope choices follow [agent-catalog]; the audit cells above retain their observed identities. Common actions above and the complete customization dispositions below are part of every row. `install` and `remove` name exact packages. All other fitting installed packages are `keep`. All rows enable `lane-mail-compact`, `session-end-row`, `session-start-row`, `skill-load-record`, `stop-failure-row`. Other missing/inactive hooks below become `enabled=true` with the declared harness set. The snapshot citations provide current values. Every route corrects `settings` `[env].LINEAR_AGENT_LABELS`, routing-agent installs and manifest project-management taxonomy from its audit cells; KEN-2239 and the master settle final values. Compare Scope with that list; agent labels have workspace scope. Create, rename or move no label here. Owner update 1790815109 already confirms workspace `feature`, `docs`, `ci-nightly`, `needs-ownership-check`: replace team `enhancement`/`documentation` spellings with `feature`/`docs` and remove their team Scope claims. Apply this to each consumer's project-management or linear instructions in `kendex.toml`; vsys has no such block at this snapshot. Kendex already matches.

| Repository and route | Packages and agents | Hooks to turn on | Additional exact edits |
| --- | --- | --- | --- |
| kendex; kendex build items | install `github-repository-settings`, `npm-deploy`; remove `bot-instructions`, `price-handling`, `review-gate`; defer `iced-rs` and agent `iced` removal to KEN-2239 | `lane-mail-prompt`, `lane-mail-start`, `skill-load-check` | `GITHUB_STANDARD_STACK="custom"`, `GITHUB_STANDARD_REFRESH="off"`, `GITHUB_STANDARD_DISPATCH="on"`. Keep D007 lock workflow. Correct renamed required checks to `CI`. Remove price-handling references; defer iced instruction/label changes to KEN-2239 because the owner-provisional target retains iced despite the React stack. Add explicit `npm-deploy` installation for this repository's Pi publish work. |
| vsys; fleet overseer lane | install `github-repository-settings`, `slack`; remove `bot-instructions`, `review-gate`; runtime/frontend installs and rust removal follow the approved agent catalog | `lane-mail-prompt`, `lane-mail-start` | `GITHUB_STANDARD_STACK="bun"`. Set `DEV_VALIDATE_CMD="python3 scripts/ci.py && python3 -m unittest discover -s scripts -p '*_test.py' && .agents/skills/github-repository-settings/scripts/github-repository-settings check"`. Remove `.kendex-lock.json` from `WORKTREE_COPIES`; rust/iced label removals follow KEN-2239 final values. |
| vgs; own overseer | install `dep-radar`, `github-repository-settings`, `slack`; remove `bot-instructions`; runtime/frontend follow the approved agent catalog for Go and Quickshell QML/JavaScript | `doc-drift-check`, `lane-mail-prompt`, `lane-mail-start`, `reviewer-stop-check`, `skill-load-check`, `task-completed-check` | Set `GITHUB_STANDARD_CHECK_LOCATION="local"`, `GITHUB_STANDARD_BOT_REVIEW="off"`, `GITHUB_STANDARD_PLATFORM_CHECKS="off"`, `GITHUB_STANDARD_REFRESH="off"`, `GITHUB_STANDARD_DISPATCH="off"`, `GITHUB_STANDARD_TEMPLATES=""`; comment the local-only/no-bot/no-gate reason in `kendex.toml`. Set `DEV_VALIDATE_RANGE_CMD="scripts/validate --changed $DEV_VALIDATE_BASE"`. Keep no workflows/rulesets and no armed Git hooks. |

Per-repository records were removed from this public repository (KEN-2602).

### Customization dispositions

The comparator reads package settings examples, not all script fallbacks. Every non-example assignment below has a disposition. All `REVIEW_GATE_*` status keys, including example-equal keys, take KEN-2089 retirement; all `REVIEW_GATE_STANDARD_*` keys take the exact rename table above. Other example-equal settings keep the declared behavior, reason: explicit consumer defaults. Pinned manifests/settings retain values and leaf inventories. No private env file was read.

| Setting group | Action and reason |
| --- | --- |
| identity | keep current value; reason: repository tracker, issue spelling and decision path differ by repository. |
| validation | keep current value except the exact command edits above; reason: repository product suites differ. One existing runner owns classification. |
| worktree | keep layout, links and scratch settings; reason: repository source/dependency layout. Remove copied lock paths as listed above; Git owns tracked files. |
| guards | keep current selection/path values; reason: repository language, source and document coverage. All catalog hooks still apply where supported. |
| capacity | keep current configured budgets/providers/test globs; reason: repository overseer capacity and lane environment. Document this choice; it is not a measured performance claim. |
| second | keep configured review providers and read paths; reason: repository-selected reviewers. Check executable availability at adoption. vgs deliberately uses its local Copilot route. |
| platform | rename through the new-name table; reason: refresh credentials and permitted bypass actors are organization/repository configuration. Required contexts become CI. |
| engine | remove through KEN-2089 and consumer retirement; reason: native review replaces the deleted writer/predicate. Do not delete the engine twice. |
| old | remove; reason: current package runtime has no reader for these retired bot/gate/router keys. |
| safety | keep current value; reason: the consumer's command-safety policy disallows unbounded process-memory overrides. |
| publish | keep current value; reason: kendex alone rebuilds its CLI after merged engine changes and owns the Slack mailbox path. |

The inventory below groups identical key selections; pinned settings hold their values. `PREFIX{A,B}` means `PREFIXA` and `PREFIXB`. `LINEAR_AGENT_LABELS` follows the adoption audit, not identity’s keep rule.

| Repositories | Observed non-example keys |
| --- | --- |
| kendex,vsys,vgs | `DEV_VALIDATE_CMD; LINEAR_{TEAM,TEAM_PREFIX}; PM_CREATE_AUTONOMY; WORKTREE_{BASE_DIR,DEFAULT_BRANCH,MKDIRS,SYMLINKS}; DECISIONS_DIR; GH_ISSUE_PATTERN; LINEAR_AGENT_LABELS; ORCH_{HANDOFF_HEADROOM_PCT,LANE_MAX_PCT,OVERSEER_LANES}; COMMAND_SAFETY_DENY_PATTERN; LINEAR_REQUIRE_REACH` |
| kendex,vsys | `COMMIT_GUARDS_MD_SCOPE; SECOND_OPINION_REVIEW_INSTRUCTIONS; ORCH_OVERSEER_HEADROOM_PCT; CI_WAIT_NO_CHECKS_GRACE; COMMIT_GUARDS_CHANGELOG_REQUIRED_PATHS` |
| vsys,vgs | `ORCH_OVERSEER_PREFERENCE; PR_REVIEW_{CHECK,GATE}` |
| kendex,vgs | `DEV_VALIDATE_RANGE_CMD` |
| kendex | `HARNESS_CI_QUEUE_PATHS; COMMIT_GUARDS_PRE_COMMIT_LOCAL; GUARD_EXHAUSTED_FREE_MB,GUARD_FULL_CROSS_DOC,GUARD_MIN_FREE_GB,SLACK_MASTER_FILE; ORCH_POST_MERGE_CMD; SECOND_OPINION_{CODEX_ROOM_CMD,MODELS,PI_COPILOT_CMD,PI_COPILOT_INLINE_DIFF,PI_COPILOT_MODEL,PI_COPILOT_ROOM_CMD}` |
| vsys | `WORKTREE_COPIES` |
| vgs | `SECOND_OPINION_CLAUDE_CMD; COMMIT_GUARDS_MD_REFS_PATHS; SECOND_OPINION_{CLAUDE_MODEL,CODEX_CMD,CODEX_MODEL}; COMMIT_GUARDS_MD_REFS_SOURCE_PATHS; ORCH_SIZE_TEST_PATHS; DECISIONS_BASE_REF` |

Per-repository records were removed from this public repository (KEN-2602).

**Manifest customizations**: every observed non-install leaf receives the first applicable action below. Dotted selectors identify TOML tables; `*` means every observed child at the snapshot, not a new runtime registry. Schema/source/install identity stays with core and is not an arbitrary customization.

| Manifest keys/tables | Action and reason |
| --- | --- |
| `commands.*.source` | keep; reason: the repository declares a real reusable command. Source/harness copies remain core-owned. |
| `skill-instructions.all`, `agent-additional-instructions.all` | remove duplicate shared kendex-report instruction. For vgs retain only its local delivery override until new settings replace it; reason: explicit owner policy, not a fork. |
| consumer `skill-instructions.code-quality` copies of the platform-first sentence | remove after moving the universally applicable platform-first sentence to shared code-quality; reason: one engineering rule owner. |
| kendex `skill-instructions.code-quality` | keep React-specific facts; move platform-first sentence once to shared code-quality and remove its local copy. Reason: app has React-specific failure paths. |
| `skill-instructions.linear`, `skill-instructions.project-management` | keep tracker/project identity; correct taxonomy to the audit contract; remove repeated shared filing/disposition procedure. Reason: teams and sync policies differ, conduct does not. |
| `skill-instructions.dev`, `skill-instructions.worktree` | keep repository-specific benchmark/build/dependency commands; reason: native suites, remote benchmark host and dependency link trees differ. Do not promote machine paths or run unrequested benchmarks. |
| vgs `skill-instructions.code-quality`, `.linear`, `.project-management`, `.reviewer` | keep Quickshell/runtime references, tracker/project identity and optional local-review pointers; remove generic copied procedure. Reason: local-only Quickshell policy and intake-only GitHub tracking. |
| kendex `skill-instructions.orch` | keep; reason: owner time zone and night hours are a communication choice, not a GitHub merge rule. |
| `agent-skills.*` | keep relevant mapping; remove review-gate member; defer specialist references to KEN-2239 targets. Reason: agents load their actual domain skills. Add missing common agents as listed above. |
| `agent-frontmatter.*` | keep native execution permissions, effort, colors and names as deliberate consumer choices; reason: harness-specific session behavior and agent identity. Remove specialist entries only when KEN-2239 confirms their removal. Add manifest reason comments, and let core reject unsupported fields. |
| `bot-instructions.repo.*`, `.schema`, `.bots.*`, `.cadence.*`, `.tone.*`, `.retention.*` | keep schema, repository identity and deliberate bot choices; reason: native bot settings differ. Apply the vgs edits above. No setting itself proves a remote review rule. |
| `bot-instructions.exclusions.*`, `.surface`, `.doctrine.*` | keep product paths, generated/vendor exclusions and product rules; remove retired review-gate/carry/residual policy and duplicated conduct. Reason: renderer owns path-specific native files; reviewer owns conduct. |
| Other observed non-install leaves | none outside the groups above. The archived per-repository leaf lists make the scope checkable; a newly added key needs a disposition at adoption. |

Acceptance: routed PRs attach manifest/settings diffs and package/hook inventories. Kept differences have reason comments; removals are absent; fitting packages and supported hooks cover declared harnesses. Use native preview/verify and package checkers. The owner re-checks every 3 days. Read changes after these snapshots before mutation; add no scanner.


## Ordered build handoff

The parent files these scopes after the plan merges. New/renamed package items state: “Held until the owner signs off on the package proposal (owner ruling 1790814905)”. Consumer-visible builds ship changelog fragments; source moves include renders.

1. **Prerequisites**: KEN-2281, then KEN-2089/PR 3264; load KEN-2309 compatibility and KEN-2337 hook activation work. Compare the surviving review-gate tree with the responsibility table. Acceptance: current API proof that consumers drop `Review gate` before final retirement; latest-release catalog checks pass; no second engine deletion.
2. **Runtime and conduct**: move GitHub `pr-watch` and every caller together; move canonical disposition to reviewer with all links; preserve narrow reply checks/controls and automatic-review guidance. Acceptance: watch suites pass; each bad tracking/decline/body disposition fails; native approval does not hide a bad disposition; no active old-path call. Depends on the prerequisite deletion inventory.
3. **Configuration owner**: add `skills/github-repository-settings/`; move surviving refresh/platform/adoption parts and tests; transfer repository effects through the single-source bot-renderer transition. Update core locator, catalog dependencies and commit-guards staged checker. Acceptance: one writer per scope, armed-only effects, disabled pieces write nothing, old settings warn and new settings win, no secret values in reports. Depends on runtime/conduct placement.
4. **Managed CI**: move harness-ci template/guidance; add exact presets, optional templates and consumer-owned scaffold. Extend existing hash/equality machinery. Acceptance: refresh/verify compare all managed copies; extension jobs require no managed edit; failed/cancelled jobs, dead classifier and unauthorized skips fail literal `CI`; authorized skips pass; actual PR/merge-group check names are `CI`; no filter prevents their creation. Controls prove each changed guard rule. Depends on configuration owner.
5. **Routed adoption**: execute each row of § Per-repository consistency and fix lists through the route that row names. Preserve kendex's `CI` context/app binding in the paired workflow/ruleset PR. Resolve docs/template/package/hook/customization gaps with their existing owners. Acceptance: commented reasons for every kept difference; matching package/harness inventory; local hook arming proved except vgs; one convergent refresh PR; no consumer file rewrite; D007 source lock path unchanged. Depends on preceding scopes and KEN-2337 for its hook; specialist/label changes take KEN-2239 and the master’s final list. Acceptance also checks both label columns, rendered taxonomy, and unchanged shared-label definitions.
6. **Retirement and guidance**: after all scopes switch, move the one remaining bot renderer source into configuration; remove old package/dependency declarations and dead source/render/tests. Do not expire renamed-key reads before their minor-release window. Make one cursory pass across skills, agents, hooks and repository docs for conflicting/repeated guidance. Fix scoped hits; parent files only a real unrelated defect that clears the existing filing bar. Acceptance: every retained rule has its table destination; no retired live caller, second classifier/filing rule/renderer or contradictory package owner remains.

**Critical files**: `skills/review-gate/scripts/adopt-refresh.sh`, `skills/harness-ci/templates/ci.yml`, `skills/harness-ci/scripts/aggregate-needs`, `crates/core/src/bot_instructions.rs`, `tools/ci-aggregate`.

**Documentation updates in the matching build commits**: `docs/architecture/merge-rail.md`, `bot-instructions.md`, `generated-paths.md`, `.github/AGENTS.md`, affected package READMEs/DEVELOPMENT/settings examples and inbound conduct links. New source files are the configuration package/presets and the narrow runtime checker. Consumers own their extension workflows. Historical decisions remain historical; preserve D007 and D016. Create no new decision record here.

### Risks and rollback

- Managed hand edit: refresh replaces it only when the consumer edits outside the extension file. Report its divergence in the refresh PR. [C1]
- Incomplete workflow/rule adoption: merge waits for missing old contexts. Pair the changes; preserve literal `CI` and inspect live checks. [C10], [G4]
- Reply changes without push: prior green CI can become stale. Read dispositions live at merge; publish no cached review attestation.
- Premature package/source removal: old consumers lose refresh or a review-body check. Use the staged single-source transition and block retirement on the rule table.
- Catalog uses released consumer refresh: wrong engine records its lock. Keep the D007 exclusion/main-built workflow. [D007]

Rollback reverts the adoption PR's managed files/settings through a normal PR. Keep `CI` and native review rules; never restore the deleted gate requirement/engine. Fix configuration at its source and deliver through refresh. Restore incorrectly moved consumer jobs from Git history. No rollback writes a lane's install record.

### Handoff prompt

Implement these ordered scopes after their prerequisites merge. Use the exact per-repository lists above. Preserve one owner per file and per decision, the three live reply checks and the current classifier/aggregate/renderer interfaces. Attach each scope's acceptance evidence. The parent owns issue creation; named overseers own rollout. Preparation candidates are not build instructions; the parent refreshes them from this final plan.


## Evidence references

Public GitHub interface sources and pinned repository evidence are separate. The Exa report passes structural validation with a query-metadata warning. Historical Enterprise Server required-workflow sources are excluded.

[issue]: https://linear.app/vanillagreen/issue/KEN-2332
[engine-removal]: https://linear.app/vanillagreen/issue/KEN-2089
[release-first]: https://linear.app/vanillagreen/issue/KEN-2281
[versioning]: https://linear.app/vanillagreen/issue/KEN-2309
[runtime-research]: https://linear.app/vanillagreen/issue/KEN-2334
[agent-catalog]: https://linear.app/vanillagreen/issue/KEN-2239
[G1]: https://docs.github.com/en/actions/how-tos/reuse-automations/reuse-workflows
[G2]: https://docs.github.com/en/actions/reference/workflows-and-actions/reusing-workflow-configurations
[G3]: https://docs.github.com/en/actions/reference/workflow-syntax-for-github-actions
[G4]: https://docs.github.com/en/pull-requests/how-tos/merge-and-close-pull-requests/troubleshooting-required-status-checks
[G5]: https://docs.github.com/en/enterprise-cloud@latest/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/troubleshooting-rules
[G6]: https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-protected-branches/about-protected-branches
[G7]: https://docs.github.com/en/rest/repos/contents
[C1]: ../../skills/review-gate/scripts/adopt-refresh.sh
[C2]: ../../skills/harness-ci/SKILL.md
[C3]: ../../skills/github/SKILL.md
[C4]: ../../skills/bot-instructions/SKILL.md
[C5]: ../../crates/core/src/bot_instructions.rs
[C6]: ../../skills/commit-guards/scripts/install-git-hooks
[C7]: ../architecture/overview.md
[C8]: ../../skills/docs-writing/SKILL.md
[C9]: ../architecture/merge-rail.md
[C10]: ../../skills/review-gate/references/adoption.md
[C11]: ../../skills/review-gate/scripts/refresh-reviews.sh
[C12]: ../../skills/review-gate/README.md
[C13]: ../../skills/orch/references/finding-disposition.md
[C14]: ../../kendex.toml
[C15]: https://github.com/vanillagreencom/kendex/tree/781eb4cfed71b1900de359476045953f51ccd545/pi-extensions
[C16]: ../../skills/project-management/references/labels.md
[C17]: ../../skills/linear/scripts/commands/issues.sh
[C18]: ../../crates/core/src/render/skill.rs
[D007]: ../decisions/D007-lock-record-on-main.md
[D016]: ../decisions/D016-merge-route-reads-bypass.md
[audit-kendex]: https://github.com/vanillagreencom/kendex/rules/24148610
[A-kendex]: https://github.com/vanillagreencom/kendex/tree/781eb4cfed71b1900de359476045953f51ccd545
[A-vsys]: https://github.com/vanillagreencom/vsys/tree/d80f21ddf0ff827186da3f2c0b5fbd2ba7861cbd
[A-vgs]: https://github.com/vanillagreencom/vgs/tree/c6f8347e05d53b004079db2bd869b715faf94392
[R-kendex]: https://api.github.com/repos/vanillagreencom/kendex/rules/branches/main
[R-vsys]: https://api.github.com/repos/vanillagreencom/vsys/rules/branches/main
[R-vgs]: https://api.github.com/repos/vanillagreencom/vgs/rules/branches/main
