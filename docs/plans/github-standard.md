# GitHub repository standard

This plan assigns shared GitHub configuration to `github-repository-settings`, which updates it through `kendex refresh`.

## Framing

- KEN-2332 contains only this plan. Owner rulings remove extra owner approval and require package/settings/hook consistency. [issue]
- Reuse existing rendering, adoption, classification, aggregation and settings readers. Add no parser, classifier, registry or policy engine.
- Every piece applies universally or is opt-in. vgs uses settings, not a fork.

## Approach

Choose byte-managed templates with Rust, Bun, Next.js/pnpm and custom presets. Keep the literal required `CI` job in a managed top-level caller. Consumer jobs live in an unmodified-by-refresh local reusable workflow. GitHub supports `workflow_call` and static `needs`; it does not insert caller jobs into a called workflow's dependency list. [G1], [G2], [G3]

| Alternative | Disposition |
| --- | --- |
| Central reusable workflows at pinned release tags | Declined as the shared CI owner. A literal caller reference still needs updates, and reusable-job checks have a distinct name format. A managed caller remains necessary. KEN-2281 also requires rolling refresh to resolve the latest released engine, not a fixed version. Existing reusable catalog checks remain valid. [G1], [G5], [release-first] |
| Byte-managed templates | Selected: extend current `adopt-refresh.sh` writes, edit reports and template-hash inventory. `kendex verify` already compares adopted copies with declared template bytes. [C1], [C2] |
| Edit managed YAML, or poll separate workflows' statuses | Declined: refresh overwrites the first; GitHub's static workflow-call dependencies replace the second. [C1], [G1], [G3] |

### Ownership and transition

**Current owners**: review-gate writes the refresh workflow; bot-instructions renders review files; harness-ci supplies a copied CI template. The following ownership and behavior describe the build target, not capabilities already installed. [C1], [C2], [C4]

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

Use the current repository-effects declaration and `.kendex-generated.json`, not a second ownership list. Adoption previews taking over an existing file. Preserve unrelated files and consumer extensions. Refuse symlinks. A managed hand edit gets the existing first-divergent-line report. [C1], [C5]

### CI and consumer extension

- Start on `pull_request` and `merge_group`, with no workflow path filter. Classify once from the trusted default-branch package. Run standard checks, preset product checks and the consumer workflow call. Final `CI` has `if: always()` and static `needs` for every preceding job. Call `aggregate-needs`; failed/cancelled jobs, failed classification and unauthorized skips fail. A skipped job alone can satisfy GitHub's required-check rule, so the helper is necessary. [G3], [G4], [C2]
- Presets differ in tool installation, lockfiles and cache setup. They run existing `DEV_VALIDATE_CMD` using the existing environment reader. Pass its existing class/docs/path contract; do not infer a test command from the stack name. A missing command fails with its setting name. Tool setup stays unconditional when a standard check needs the tool. [C2], [C9]
- The caller invokes `./.github/workflows/ci-project.yml` as job `project`. Typed inputs carry event, base SHA, head SHA, class, docs verdict and lane verdicts. GitHub's literal local reference uses the caller's commit. A real file always exists; do not assume a condition legalizes a missing reference. No write token or inherited secrets by default. Privileged deployment stays separate. [G1], [G2]
- The custom preset moves repository matrices/selectors into that consumer file in the same adoption PR. Replace a second classifier with caller inputs. Kendex keeps `tools/ci-job-set`, runner legs and `tools/ci-aggregate`; the shared helper remains the skip judge. [C9]
- Keep `CI` outside the reusable workflow and observe actual check-run names on both events. FLT-558 is already live in kendex. Preserve its name and Actions app binding. Adopt existing CI and consumer jobs in one PR, without a temporary context or second check-name migration. The fleet overseer pairs any unfinished old-context rule change with its workflow adoption. [G5], [C10], [audit-kendex]

### Names and settings

The new package entry point exposes `adopt` (preview/take shared files under management), `render` (write selected managed files), `check` (read-only equality/settings check), and `retire` (revoke repository effects). These reuse the current bot/adoption operations. New settings use `[env]` in `kendex.settings.toml`; bot choices retain their existing manifest table.

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

vgs sets local checks, remote bot review off, platform checks off, refresh/dispatch off and no templates unless requested. Its `AGENTS.md` also forbids commit/push gates. Keep commit-guards unarmed and pre-commit disabled, with the reason in its manifest. Run `DEV_VALIDATE_CMD` on the relevant diff without a Git hook. Local harness instruction files may remain; they do not request remote reviews. [A-vgs], [R-vgs]

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

Move canonical `orch/references/finding-disposition.md` to reviewer with all inbound links. Reviewer already owns finding schema/conduct; orch keeps execution, counters and tracker creation. GitHub owns live reads/replies. Rendered instructions cite conduct, not a second copy. [C3], [C13]

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

Each skill owns its `skills/<name>/` source, installed render and declared settings example. Local skills own their declared local source. Each Pi package owns `pi-extensions/<name>/` and its package settings. The table states exceptions and resolves overlaps. Core delivers companion agents/hooks; the hook script owns its check. [C14], [C15], [C7]

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

Each cell is `ok`, `gap` or `waived`, followed by a reason. `ok` means the observed repository meets the stated criterion. It does not mean the proposed package is already installed. `gap` includes missing files, stale declarations and unreadable evidence. `waived` needs explicit owner policy or a documented scope exclusion supported by evidence. Code committed through the contents API cannot prove a local clone has armed its Git hooks. [G7]

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

### Snapshots and evidence

API discovery establishes `vanillagreencom` as each repository's owner. The read-only metadata/contents/rules audit completes at **2026-09-30T23:42:59Z**. Contents use the commits below; rulesets are live observations at request time. drovr is excluded as instructed.

The lane token lists only kendex; `/user` and `/user/repos` return HTTP 403. Ask `1790811326-27142-30894` supplies the other snapshots. Archive SHA-256: `7dbec5ec737c19df2d4da42607316da8ffddbbc55e7d10328687045642b8ae59`. This plan preserves refs, paths and dispositions without session-file links. No clones or secret values enter the audit.

| Repository | Default-branch snapshot | Citation root |
| --- | --- | --- |
| fleet | `0e13585d2a0189fce7ad93508cf96c31e9c48e38` | [Repository paths][A-fleet] |
| kendex | `781eb4cfed71b1900de359476045953f51ccd545` | [Repository paths][A-kendex] |
| vg | `cef891af7bba20ffc0d677a622dad83b1216213b` | [Repository paths][A-vg] |
| talk | `bd93613f9df5937acb570d688defc20a7ac5c862` | [Repository paths][A-talk] |
| vsys | `d80f21ddf0ff827186da3f2c0b5fbd2ba7861cbd` | [Repository paths][A-vsys] |
| kendex-web | `fb712fc1eb1dbec069157b4baec70653ebd92db8` | [Repository paths][A-kendex-web] |
| hyprtrade | `a0782faaa1303aa48c3e36dd16b8fe0506b8a0d6` | [Repository paths][A-hyprtrade] |
| hyprtrade-io | `2f89e44e82e70b1a07223bfedc7885b502ae6dbf` | [Repository paths][A-hyprtrade-io] |
| memsira | `d88f65f38d24788d099dbceb12ee3895aa93c4b8` | [Repository paths][A-memsira] |
| vgs | `c6f8347e05d53b004079db2bd869b715faf94392` | [Repository paths][A-vgs] |

`overview` is `docs/architecture/overview.md`; `index` is `docs/decisions/INDEX.md`; `settings` is `kendex.settings.toml`; workflows are under `.github/workflows/`. Repository citations bind paths to snapshots. `R-*` cites branch rules. A 404 establishes absence only at that snapshot.

Generator markers do not prove byte equality. Adoption runs each owner's checker. The audit lists but does not fetch harness agents/hooks under `.github/`; core owns those, not shared configuration.

### Repository table

| Repository | AGENTS.md shape | Architecture overview and topics | Decision records | Templates | CI workflow shape | Refresh workflow | Review-gate settings | Commit-guards hooks | Bot instructions |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| [fleet][A-fleet] | ok: root map, commands, conventions and conditional Read next | ok: overview boundaries/invariants and covered topics with read conditions | ok: numbered records and index listed | gap: PR/defect templates absent; no opt-out | ok: `ci.yml` has final `CI`, `always()`, both events and shared aggregate; rule names `CI` [R-fleet] | gap: `kendex-refresh.yml` still pins `v1.2.0` and invokes review-gate paths | gap: rule still requires `Review gate`; settings enforce the old engine [R-fleet] | ok: manifest declares package and `pre-commit-check`; committed SKILL present | ok: enabled Codex/Copilot manifest, generated pointer and instructions present |
| [kendex][A-kendex] | ok: root map and local directory read conditions | ok: overview and covered topic index | ok: numbered decisions/index, including D007 and D016 | gap: no shared PR/defect templates or recorded opt-out | ok: `skill-tests.yml` final `CI` covers lanes; PR/merge-group `always()` path; rule requires only Actions `CI` [R-kendex] | waived: consumer template exclusion required by D007; `lock-record.yml` records with main-built binary; dispatch remains | gap: rule has no gate, but settings still list old status keys and obsolete required contexts [R-kendex] | ok: `kendex-local.toml`, `tools/setup`, package and local `tools/guard` route | ok: manifest ownership and generated `.github/instructions/` pointers present; renderer still a separate writer |
| [vg][A-vg] | ok: root map, non-default test/deploy notes and conditional read links | ok: overview plus covered field/hub/store/talk topics | ok: numbered decision listing/index | gap: shared templates absent; no opt-out | gap: `ci.yml` lacks final `CI`; required contexts remain `lint-typecheck`, `build` [R-vg] | gap: refresh pins `v1.2.0` and legacy paths | gap: required `Review gate` and enforcing settings remain [R-vg] | ok: package and enabled pre-commit companion declared; committed SKILL | ok: Codex/Copilot declarations and generated pointers present |
| [talk][A-talk] | gap: root map exists but has no architecture read pointer; architecture is absent | gap: directory and overview return 404 | gap: directory and index return 404 | gap: shared templates absent; no opt-out | gap: final `CI` and both events exist, but ad-hoc jq replaces shared classifier/aggregate; rule already requires Actions `CI` [R-talk] | gap: refresh pins `v1.2.0` and legacy paths | gap: no required gate now, but writer and enforcing old settings remain [R-talk] | ok: package/pre-commit companion declared and SKILL present | ok: enabled Codex/Copilot declarations and generated pointer present |
| [vsys][A-vsys] | ok: root map, Bun/check commands and conditional subsystem links | ok: overview, covered topics and read conditions | ok: numbered decision index/listing | gap: shared templates absent; no opt-out | gap: no final `CI`; rules require Bun, gate-configuration and bot-instructions contexts [R-vsys] | gap: refresh pins `v1.2.0`; review handling uses `--report-only`; reconcile with the retained reporter contract | gap: required `Review gate` and enforcing old settings remain [R-vsys] | ok: package/companion declared, committed SKILL and local settings | ok: declared Codex/Copilot and generated pointer present |
| [kendex-web][A-kendex-web] | ok: short root map and read conditions; Next.js-generated block names its writer | gap: overview has boundaries/invariants but no topic index; no explicit no-topics scope choice | gap: decisions directory/index return 404 | gap: shared templates absent; no opt-out | gap: final `CI` and both events exist, but custom jq judge replaces shared helper; rule already requires Actions `CI` [R-kendex-web] | gap: refresh pins `v1.2.0` and legacy paths; KEN-2281 names this failure | gap: rule has no gate, but enforcing keys and writer remain [R-kendex-web] | ok: workflow bundle declares commit-guards, committed SKILL and `COMMIT_GUARDS_*` present | gap: all bot-render flags are off and no pointer exists, while inherited rule still requests Copilot review; make review policy explicit [R-kendex-web] |
| [hyprtrade][A-hyprtrade] | gap: root `ARCHITECTURE` restates the shared verification-instrument rule before its deeper pointer | gap: overview/topics present, but `code-quality.md` topic has no coverage declaration; route its engineering doctrine to its existing owner | ok: numbered records/index listed | gap: shared templates absent; no opt-out | gap: rule requires `CI Required`; workflow publishes that status through `CI Gate Publisher`, not a literal final `CI` job [R-hyprtrade] | gap: refresh pins `v1.2.0` and legacy paths | gap: required `Review gate` and old engine keys remain [R-hyprtrade] | ok: package and pre-commit companion enabled, committed SKILL | ok: enabled bot manifest and generated pointer/instructions present; preserve non-GitHub bot surfaces when renderer moves |
| [hyprtrade-io][A-hyprtrade-io] | ok: root project map, deployment conventions and conditional subsystem links | ok: overview idea/boundaries plus covered API/licensing/web-app topics | gap: decisions directory/index return 404 | gap: shared templates absent; no opt-out | gap: no final `CI`; rules require `lint-typecheck` and `build` [R-hyprtrade-io] | gap: refresh pins `v1.2.0` and legacy paths | gap: required `Review gate` and old enforcing keys remain [R-hyprtrade-io] | ok: package and pre-commit companion enabled, committed SKILL | ok: Codex/Copilot declarations and generated pointers present |
| [memsira][A-memsira] | ok: root map, repo-specific commands, invariants and conditional deeper links | ok: overview, covered subsystem topics and index | ok: ADR-numbered records and index listed | gap: `.github/PULL_REQUEST_TEMPLATE.md` exists, but defect template/opt-out and refresh ownership are absent | gap: no final `CI`; rules retain Rust/frontend/launcher contexts [R-memsira] | gap: `.github/` workflow listing has no consumer refresh workflow or opt-out | gap: required `Review gate` and old enforcing keys remain [R-memsira] | ok: package and enabled pre-commit companion declared, committed SKILL | ok: Codex/Copilot declarations and generated pointer/instructions present |
| [vgs][A-vgs] | ok: root map states local diff checks and explicit no-gate policy | ok: overview indexes `topics.md`; that index supplies read conditions; subsystem files carry coverage | ok: numbered records/index listed | gap: no shared templates or explicit template opt-out; choose none during adoption | waived: AGENTS explicitly forbids hosted CI/gates; `.github/` lists no workflow directory and branch rules are empty [R-vgs] | waived: local-only/no-workflow owner policy; no refresh workflow observed | waived: `REVIEW_GATE_MODE=off`, no required rules, no gate package; retain local/no-bot policy as settings [R-vgs] | waived: AGENTS forbids arming commit/push gates; pre-commit companion is disabled; package may remain unarmed | waived: remote bot review not required by owner policy; no native review rule. Generated Copilot/Codex files are local harness instructions, not evidence that remote review is enabled [R-vgs] |

### Gap disposition

Every gap feeds the build/adoption steps. Overseers own rollout and platform changes. Adoption checks clone-local arming through commit-guards' `--check` and reads actual PR/merge-group check runs. [C6], [G4]


## Full consistency audit

Owner directive 1790811911 adds package, customization and hook consistency. The following actions apply to the pinned snapshots above. Every kept non-default needs its stated reason as a comment in the repository manifest. An API snapshot cannot establish global Pi extension installation or clone arming; those remain adoption acceptance, never an inferred pass.

### Fit and common actions

Every repository installs the common skill set: `code-quality`, `commit-guards`, `decider`, `deep-research`, `dep-radar`, `dev`, `doc-limits`, `docs-writing`, `github`, `github-repository-settings`, `harness-ci`, `linear`, `orch`, `preflight`, `project-management`, `reviewer`, `second-opinion`, `slack`, `worktree`. These packages support its declared coding, review, research, tracker or overseer work. Slack installation does not enable a channel: setup stays opt-in. `iced-rs` fits only hyprtrade. `price-handling` fits only hyprtrade trading paths. Rust agents fit kendex, hyprtrade and memsira. Other repositories use engineer/generalist agents. Keep each observed repository-owned skill for its named local task; do not import kendex-only deployment skills into consumers. [C14]

Pi extensions are global harness packages, not repository GitHub configuration. For every repository using Pi, retain core-managed carriers and existing Pi packages listed in the package-boundary table; do not add them through a project skill declaration. The API evidence has no global Pi state. Adoption checks it through kendex's existing global package inventory and records any deliberate absence. This is a coverage gap, not a waiver. For other harnesses these Pi packages do not fit.

Enable every catalog hook for each declared harness that supports its native event. Use the hook's shipped harness list and core's existing event capability table, not a new map. Excluding a supported harness requires a manifest comment. Unsupported events remain unsupported, not a shim. `skill-load-check` activation depends on KEN-2337. vgs alone keeps `pre-commit-check` disabled and commit-guards unarmed because its owner forbids commit/push gates. Other disabled hooks turn on. [C7]

**Common exact adoption edits**: in `kendex.settings.toml`, hosted consumers set `GITHUB_STANDARD_CHECK_LOCATION="hosted"`, `GITHUB_STANDARD_REQUIRED_CHECKS="CI"`, `GITHUB_STANDARD_REFRESH="on"`, `GITHUB_STANDARD_PLATFORM_CHECKS="on"` and `GITHUB_STANDARD_DISPATCH="off"`. Enable `GITHUB_STANDARD_BOT_REVIEW="on"` only when native bot review is selected; keep each explicitly enabled bot. In `kendex.toml` (kendex uses `kendex-local.toml`) replace the explicit review-gate/bot-instructions install declarations with the new configuration package after prerequisites and adoption. Remove review-gate from agent skill lists. Add a comment to each kept customization. Do not remove a writer while any required rule still names it.

**Common platform edits**: in the repository required-checks ruleset, replace the old CI contexts with `{context: "CI", integration_id: 15368}` when its paired adoption workflow reports it. Remove `Review gate` through the existing engine rollout before final retirement. Preserve native approval, stale-dismissal, thread-resolution and D016 bypass constraints. The platform opt-in uses existing standard validation; no extra policy engine.

### Per-repository consistency and fix lists

Each row is its repository's fix list. Common actions above and the complete customization dispositions below are part of every row. `install` and `remove` name exact packages. All other fitting installed packages are `keep`. Missing/inactive hooks listed in a row become `enabled=true` with the declared harness set. The snapshot citations above provide the exact current values.

| Repository and route | Packages and agents | Hooks to turn on | Additional exact edits |
| --- | --- | --- | --- |
| fleet; own overseer | install `github-repository-settings`, `slack`; remove `bot-instructions`, `review-gate` | `lane-mail-compact`, `session-end-row`, `session-start-row`, `skill-load-check`, `skill-load-record`, `stop-failure-row` | `GITHUB_STANDARD_STACK="custom"`; preserve `bin/check` and its lane globs in `ci-project.yml`. Add shared templates or set `GITHUB_STANDARD_TEMPLATES=""` with an opt-out comment. |
| kendex; kendex build items | install `github-repository-settings`, `npm-deploy`; remove `bot-instructions`, `iced-rs`, `price-handling`, `review-gate`; remove agent `iced` | `lane-mail-compact`, `lane-mail-prompt`, `lane-mail-start`, `session-end-row`, `session-start-row`, `skill-load-check`, `skill-load-record`, `stop-failure-row` | `GITHUB_STANDARD_STACK="custom"`, `GITHUB_STANDARD_REFRESH="off"`, `GITHUB_STANDARD_DISPATCH="on"`. Keep D007 lock workflow. Correct renamed required checks to `CI`. Remove iced and price-handling instruction/label references with their declarations. Add explicit `npm-deploy` installation for this repository's Pi publish work. |
| vg; own overseer | install `github-repository-settings`, `slack`; remove `bot-instructions`, `review-gate` | `lane-mail-compact`, `lane-mail-prompt`, `lane-mail-start`, `session-end-row`, `session-start-row`, `skill-load-record`, `stop-failure-row` | `GITHUB_STANDARD_STACK="nextjs-pnpm"`. Set `DEV_VALIDATE_CMD="pnpm run lint && pnpm run typecheck && pnpm run test && pnpm run build"`; the runner owns diff classification. Remove `.kendex-lock.json` from `WORKTREE_COPIES`. |
| talk; own overseer | install `github-repository-settings`, `slack`; remove `bot-instructions`, `review-gate`; install agent `engineer` | `lane-mail-compact`, `session-end-row`, `session-start-row`, `skill-load-check`, `skill-load-record`, `stop-failure-row` | `GITHUB_STANDARD_STACK="custom"` for Expo/pnpm, not Next.js. Create `docs/architecture/overview.md` and decision index under their existing formats. Add its architecture read link to `AGENTS.md`. Remove `.kendex-lock.json` from `WORKTREE_COPIES`. |
| vsys; fleet overseer lane | install `github-repository-settings`, `slack`; remove `bot-instructions`, `review-gate`; remove agent `rust`; install agent `engineer` | `lane-mail-compact`, `lane-mail-prompt`, `lane-mail-start`, `session-end-row`, `session-start-row`, `skill-load-record`, `stop-failure-row` | `GITHUB_STANDARD_STACK="bun"`. Set `DEV_VALIDATE_CMD="python3 scripts/ci.py && python3 -m unittest discover -s scripts -p '*_test.py' && .agents/skills/github-repository-settings/scripts/github-repository-settings check"`. Remove `.kendex-lock.json` from `WORKTREE_COPIES`; remove `agent:rust` and `agent:iced` from `LINEAR_AGENT_LABELS`. |
| kendex-web; fleet overseer lane | install `dep-radar`, `github-repository-settings`, `slack`; remove `bot-instructions`, `review-gate` | `command-safety` | `GITHUB_STANDARD_STACK="nextjs-pnpm"`. Add topic index or an explicit no-extra-topic boundary to overview and create decision index. Set `[bot-instructions.bots] codex=true, copilot=true` to match inherited Copilot review, with the generated root pointer. Remove `.kendex-lock.json` from `WORKTREE_COPIES`. Keep website index workflow consumer-owned. |
| hyprtrade; fleet overseer lane | install `github-repository-settings`, `slack`; remove `bot-instructions`, `review-gate` | `command-safety`, `lane-mail-compact`, `lane-mail-prompt`, `lane-mail-start`, `session-end-row`, `session-start-row`, `skill-load-record`, `stop-failure-row` | `GITHUB_STANDARD_STACK="custom"` for Rust plus benchmark/platform jobs. Replace `CI Required` publisher with the paired `CI` aggregate. Remove `.vstack-lock.json` from `WORKTREE_COPIES`. Replace duplicated verification prose with a pointer; put only local instruments in the architecture topic and add its coverage. |
| hyprtrade-io; fleet overseer lane | install `github-repository-settings`, `slack`; remove `bot-instructions`, `review-gate`; remove agent `rust`; install agent `engineer` | `command-safety`, `lane-mail-compact`, `lane-mail-prompt`, `lane-mail-start`, `session-end-row`, `session-start-row`, `skill-load-check`, `skill-load-record`, `stop-failure-row` | `GITHUB_STANDARD_STACK="custom"` for React Router/npm, not Next.js/pnpm. Create decision index. Remove `.vstack-lock.json` from `WORKTREE_COPIES`. Keep npm/Vercel checks and manual deployment policy. |
| memsira; fleet overseer lane | install `github-repository-settings`, `slack`; remove `bot-instructions`, `review-gate`; install agent `engineer`; install agent `tpm` | `command-safety`, `lane-mail-compact`, `lane-mail-prompt`, `lane-mail-start`, `session-end-row`, `session-start-row`, `skill-load-record`, `stop-failure-row` | `GITHUB_STANDARD_STACK="custom"` for Rust/pnpm/iOS jobs. Add refresh, retain ADR naming and immutable migration citations. Remove `.kendex-lock.json` from `WORKTREE_COPIES`. Preserve PR template substance through adoption, then select managed PR/defect templates or record the opt-out. |
| vgs; own overseer | install `dep-radar`, `github-repository-settings`, `slack`; remove `bot-instructions`; install agent `engineer` | `doc-drift-check`, `lane-mail-compact`, `lane-mail-prompt`, `lane-mail-start`, `reviewer-stop-check`, `session-end-row`, `session-start-row`, `skill-load-check`, `skill-load-record`, `stop-failure-row`, `task-completed-check` | Set `GITHUB_STANDARD_CHECK_LOCATION="local"`, `GITHUB_STANDARD_BOT_REVIEW="off"`, `GITHUB_STANDARD_PLATFORM_CHECKS="off"`, `GITHUB_STANDARD_REFRESH="off"`, `GITHUB_STANDARD_DISPATCH="off"`, `GITHUB_STANDARD_TEMPLATES=""`; comment the local-only/no-bot/no-gate reason in `kendex.toml`. Set `DEV_VALIDATE_RANGE_CMD="scripts/validate --changed $DEV_VALIDATE_BASE"`. Keep no workflows/rulesets and no armed Git hooks. |

### Customization dispositions

The settings comparator uses the source packages' declared `kendex.settings.toml.example` values. It does not pretend that examples prove every script fallback. Every observed non-example assignment below has a disposition. All `REVIEW_GATE_*` status keys, including example-equal keys, take KEN-2089 retirement; all `REVIEW_GATE_STANDARD_*` keys take the exact rename table above. Other example-equal settings keep the declared behavior, reason: explicit consumer defaults. They are not a second settings writer. The pinned repository manifests and settings retain exact values and leaf inventories. No private env file was read.

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

The next table names every observed non-example key per repository except `REVIEW_GATE_*`, which follows the rename/removal rules above. The group actions and repository fixes set each disposition. Pinned settings supply current values; absent keys are not added.

| Repository | Observed non-example keys |
| --- | --- |
| fleet | `COMMIT_GUARDS_MD_SCOPE, COMMIT_GUARDS_MD_REFS_PATHS, COMMIT_GUARDS_MD_REFS_SOURCE_PATHS, WORKTREE_BASE_DIR, WORKTREE_DEFAULT_BRANCH, WORKTREE_MKDIRS, WORKTREE_SYMLINKS, DEV_VALIDATE_CMD, DEV_VALIDATE_RANGE_CMD, LINEAR_TEAM, LINEAR_TEAM_PREFIX, LINEAR_AGENT_LABELS, LINEAR_REQUIRE_REACH, PR_REVIEW_GATE, PM_CREATE_AUTONOMY, PR_REVIEW_CHECK, COMMAND_SAFETY_DENY_PATTERN, CI_WAIT_NO_CHECKS_GRACE, ORCH_OVERSEER_LANES, ORCH_LANE_ACCOUNT_CLAIMS, ORCH_LANE_MAX_PCT, ORCH_HANDOFF_HEADROOM_PCT, ORCH_SIZE_TEST_PATHS, ORCH_LANES_CLAUDE_CLIENT_ID, ORCH_OVERSEER_HOST, ORCH_OVERSEER_PREFERENCE, ORCH_OVERSEER_HEADROOM_PCT, SECOND_OPINION_CLAUDE_MODEL, SECOND_OPINION_CLAUDE_CMD, SECOND_OPINION_CODEX_MODEL, SECOND_OPINION_CODEX_CMD, SECOND_OPINION_REVIEW_INSTRUCTIONS, DECISIONS_DIR, GH_ISSUE_PATTERN` |
| kendex | `LINEAR_TEAM, LINEAR_TEAM_PREFIX, LINEAR_AGENT_LABELS, LINEAR_REQUIRE_REACH, COMMAND_SAFETY_DENY_PATTERN, CI_WAIT_NO_CHECKS_GRACE, PM_CREATE_AUTONOMY, ORCH_POST_MERGE_CMD, ORCH_OVERSEER_LANES, ORCH_LANE_MAX_PCT, ORCH_OVERSEER_HEADROOM_PCT, ORCH_HANDOFF_HEADROOM_PCT, SECOND_OPINION_MODELS, SECOND_OPINION_CODEX_ROOM_CMD, SECOND_OPINION_PI_COPILOT_CMD, SECOND_OPINION_PI_COPILOT_MODEL, SECOND_OPINION_PI_COPILOT_ROOM_CMD, SECOND_OPINION_PI_COPILOT_INLINE_DIFF, SECOND_OPINION_REVIEW_INSTRUCTIONS, HARNESS_CI_QUEUE_PATHS, DECISIONS_DIR, DEV_VALIDATE_CMD, GUARD_MIN_FREE_GB, GUARD_EXHAUSTED_FREE_MB, DEV_VALIDATE_RANGE_CMD, GUARD_FULL_CROSS_DOC, COMMIT_GUARDS_PRE_COMMIT_LOCAL, COMMIT_GUARDS_CHANGELOG_REQUIRED_PATHS, COMMIT_GUARDS_MD_SCOPE, GH_ISSUE_PATTERN, WORKTREE_BASE_DIR, WORKTREE_DEFAULT_BRANCH, WORKTREE_MKDIRS, WORKTREE_SYMLINKS, SLACK_MASTER_FILE` |
| vg | `WORKTREE_DEFAULT_BRANCH, WORKTREE_BASE_DIR, WORKTREE_SYMLINKS, WORKTREE_COPIES, WORKTREE_MKDIRS, HARNESS_CI_QUEUE_PATHS, ORCH_OVERSEER_PREFERENCE, PM_CREATE_AUTONOMY, DEV_VALIDATE_CMD, DECISIONS_DIR, LINEAR_TEAM, LINEAR_TEAM_PREFIX, GH_ISSUE_PATTERN, GH_VERIFY_CMD, SECOND_OPINION_CLAUDE_MODEL, SECOND_OPINION_CLAUDE_CMD, SECOND_OPINION_CODEX_MODEL, SECOND_OPINION_CODEX_CMD, SECOND_OPINION_TIMEOUT, SECOND_OPINION_REVIEW_INSTRUCTIONS, COMMIT_GUARDS_MD_SCOPE, WORKTREE_CLI` |
| talk | `WORKTREE_DEFAULT_BRANCH, WORKTREE_BASE_DIR, WORKTREE_SYMLINKS, WORKTREE_COPIES, WORKTREE_MKDIRS, DEV_VALIDATE_CMD, PM_CREATE_AUTONOMY, HARNESS_CI_QUEUE_PATHS, LINEAR_TEAM, LINEAR_TEAM_PREFIX` |
| vsys | `LINEAR_TEAM, LINEAR_TEAM_PREFIX, LINEAR_AGENT_LABELS, LINEAR_REQUIRE_REACH, PR_REVIEW_GATE, PR_REVIEW_CHECK, COMMAND_SAFETY_DENY_PATTERN, CI_WAIT_NO_CHECKS_GRACE, ORCH_OVERSEER_LANES, ORCH_OVERSEER_PREFERENCE, ORCH_OVERSEER_HEADROOM_PCT, ORCH_HANDOFF_HEADROOM_PCT, ORCH_LANE_MAX_PCT, PM_CREATE_AUTONOMY, SECOND_OPINION_REVIEW_INSTRUCTIONS, DECISIONS_DIR, DEV_VALIDATE_CMD, COMMIT_GUARDS_CHANGELOG_REQUIRED_PATHS, COMMIT_GUARDS_MD_SCOPE, GH_ISSUE_PATTERN, WORKTREE_BASE_DIR, WORKTREE_COPIES, WORKTREE_DEFAULT_BRANCH, WORKTREE_MKDIRS, WORKTREE_SYMLINKS` |
| kendex-web | `WORKTREE_DEFAULT_BRANCH, WORKTREE_BASE_DIR, WORKTREE_SYMLINKS, WORKTREE_COPIES, WORKTREE_MKDIRS, ORCH_OVERSEER_PREFERENCE, PM_CREATE_AUTONOMY, PR_REVIEW_GATE, PR_REVIEW_NUDGE_SECS, PR_REVIEW_NUDGE, PR_REVIEW_CHECK, PR_REVIEW_QUORUM, DEV_VALIDATE_CMD, DECISIONS_DIR, LINEAR_TEAM, LINEAR_TEAM_PREFIX, GH_ISSUE_PATTERN, GH_VERIFY_CMD, SECOND_OPINION_CLAUDE_CMD, SECOND_OPINION_TIMEOUT, SECOND_OPINION_REVIEW_INSTRUCTIONS, COMMIT_GUARDS_CHECKS, COMMIT_GUARDS_MD_SCOPE, COMMIT_GUARDS_MD_REFS_PATHS, WORKTREE_CLI, GIT_HOST_CLI` |
| hyprtrade | `BOT_CHECK_NAME, BOT_REVIEWERS, PR_REVIEW_GATE, PR_REVIEW_NUDGE, PR_REVIEW_CHECK, DECISIONS_DIR, GH_ISSUE_PATTERN, GH_VERIFY_CMD, GIT_HOST_CLI, LINEAR_TEAM, LINEAR_TEAM_PREFIX, SECOND_OPINION_CLAUDE_CMD, WORKTREE_BASE_DIR, WORKTREE_CLI, WORKTREE_COPIES, WORKTREE_DEFAULT_BRANCH, WORKTREE_MKDIRS, WORKTREE_SYMLINKS, PR_REVIEW_QUORUM, PR_REVIEW_NUDGE_SECS, REVIEWER_SLOT_BUDGET, ORCH_OVERSEER_LANES, ORCH_OVERSEER_PREFERENCE, ORCH_OVERSEER_HEADROOM_PCT, ORCH_HANDOFF_HEADROOM_PCT, ORCH_LANE_MAX_PCT, PM_CREATE_AUTONOMY, LINEAR_AGENT_LABELS, SECOND_OPINION_REVIEW_INSTRUCTIONS, COMMIT_GUARDS_MD_SCOPE, COMMIT_GUARDS_MD_REFS_PATHS, COMMIT_GUARDS_PROSE_PATHS, DEV_VALIDATE_CMD` |
| hyprtrade-io | `BOT_CHECK_NAME, PR_REVIEW_GATE, PR_REVIEW_NUDGE, PR_REVIEW_CHECK, DECISIONS_DIR, GH_ISSUE_PATTERN, GH_VERIFY_CMD, GIT_HOST_CLI, SECOND_OPINION_CLAUDE_CMD, WORKTREE_BASE_DIR, WORKTREE_CLI, WORKTREE_COPIES, WORKTREE_DEFAULT_BRANCH, WORKTREE_MKDIRS, WORKTREE_SYMLINKS, PR_REVIEW_NUDGE_SECS, LINEAR_TEAM, LINEAR_TEAM_PREFIX, SECOND_OPINION_REVIEW_INSTRUCTIONS, ORCH_OVERSEER_PREFERENCE, PM_CREATE_AUTONOMY, PR_REVIEW_QUORUM, COMMIT_GUARDS_CHECKS, COMMIT_GUARDS_PROSE_PATHS, COMMIT_GUARDS_MD_SCOPE, COMMIT_GUARDS_MD_REFS_PATHS, DEV_VALIDATE_CMD` |
| memsira | `BOT_CHECK_NAME, PR_REVIEW_GATE, PR_REVIEW_NUDGE, PR_REVIEW_CHECK, DECISIONS_DIR, GH_ISSUE_PATTERN, GIT_HOST_CLI, SECOND_OPINION_CLAUDE_CMD, WORKTREE_BASE_DIR, WORKTREE_CLI, WORKTREE_COPIES, WORKTREE_DEFAULT_BRANCH, WORKTREE_MKDIRS, WORKTREE_SYMLINKS, PR_REVIEW_NUDGE_SECS, LINEAR_TEAM, LINEAR_TEAM_PREFIX, LINEAR_AGENT_LABELS, SECOND_OPINION_REVIEW_INSTRUCTIONS, ORCH_OVERSEER_LANES, ORCH_OVERSEER_PREFERENCE, ORCH_OVERSEER_HEADROOM_PCT, ORCH_HANDOFF_HEADROOM_PCT, ORCH_LANE_MAX_PCT, PM_CREATE_AUTONOMY, PR_REVIEW_QUORUM, COMMIT_GUARDS_MD_SCOPE, COMMIT_GUARDS_MD_REFS_PATHS, DEV_VALIDATE_CMD` |
| vgs | `PR_REVIEW_GATE, DECISIONS_DIR, DECISIONS_BASE_REF, GH_ISSUE_PATTERN, ORCH_SIZE_TEST_PATHS, SECOND_OPINION_CLAUDE_MODEL, SECOND_OPINION_CLAUDE_CMD, SECOND_OPINION_CODEX_MODEL, SECOND_OPINION_CODEX_CMD, WORKTREE_BASE_DIR, WORKTREE_DEFAULT_BRANCH, WORKTREE_MKDIRS, WORKTREE_SYMLINKS, PR_REVIEW_CHECK, LINEAR_TEAM, LINEAR_TEAM_PREFIX, LINEAR_AGENT_LABELS, LINEAR_REQUIRE_REACH, ORCH_OVERSEER_LANES, ORCH_OVERSEER_PREFERENCE, ORCH_HANDOFF_HEADROOM_PCT, ORCH_LANE_MAX_PCT, PM_CREATE_AUTONOMY, COMMIT_GUARDS_MD_REFS_PATHS, COMMIT_GUARDS_MD_REFS_SOURCE_PATHS, DEV_VALIDATE_CMD, DEV_VALIDATE_RANGE_CMD, COMMAND_SAFETY_DENY_PATTERN` |

**Manifest customizations**: every observed non-install leaf receives the first applicable action below. Dotted selectors identify TOML tables; `*` means every observed child at the snapshot, not a new runtime registry. Schema/source/install identity stays with core and is not an arbitrary customization.

| Manifest keys/tables | Action and reason |
| --- | --- |
| `commands.*.source` | keep; reason: the repository declares a real reusable command. Source/harness copies remain core-owned. |
| `skill-instructions.all`, `agent-additional-instructions.all` | remove duplicate shared kendex-report instruction. For vgs retain only its local delivery override until new settings replace it; reason: explicit owner policy, not a fork. |
| `skill-instructions.code-quality` in fleet/talk | remove after moving the universally applicable platform-first sentence to shared code-quality; reason: one engineering rule owner. |
| kendex `skill-instructions.code-quality` | keep React-specific facts; move platform-first sentence once to shared code-quality and remove its local copy. Reason: app has React-specific failure paths. |
| `skill-instructions.linear`, `skill-instructions.project-management` | keep tracker/taxonomy/project identity; remove repeated shared filing and disposition procedure. Reason: teams and sync policies differ, conduct does not. |
| hyprtrade `skill-instructions.orch`, `skill-instructions.reviewer` | remove retired review-gate/evidence and local residue-policy branches; cite canonical reviewer conduct. Reason: these explicitly conflict with native approvals and the shared filing bar. |
| memsira `skill-instructions.github`, `skill-instructions.reviewer` | remove retired status-engine/residual and carry-waiver prose; keep issue-link format, privacy focus and upstream-render reporting. Reason: product privacy differs; gate engine no longer exists. |
| memsira `skill-instructions.decider` | keep; reason: ADR identifiers/paths occur in immutable migration citations. Never rename them to DXXX. |
| `skill-instructions.dev`, `skill-instructions.worktree` | keep repository-specific benchmark/build/dependency commands; reason: native suites, remote benchmark host and dependency link trees differ. Do not promote machine paths or run unrequested benchmarks. |
| hyprtrade `skill-instructions.code-quality`, `agent-additional-instructions.*` verification pointers | replace copied verification rule with the shared rule pointer; keep local instruments and Rust/Iced invariants. Reason: no duplicate engineering doctrine. |
| hyprtrade `skill-instructions.iced-rs`, `agent-launch-instructions.*`, `custom-hooks` | keep chart companion, conditional subsystem readings and declared custom hooks; reason: Iced/benchmark source paths are unique here. Core still judges event support. |
| vgs `skill-instructions.code-quality`, `.linear`, `.project-management`, `.reviewer` | keep Quickshell/runtime references, tracker/project identity and optional local-review pointers; remove generic copied procedure. Reason: local-only Quickshell policy and intake-only GitHub tracking. |
| kendex `skill-instructions.orch` | keep; reason: owner time zone and night hours are a communication choice, not a GitHub merge rule. |
| `agent-skills.*` | keep relevant mapping; remove review-gate member and non-fitting Rust/Iced references. Reason: agents load their actual domain skills. Add missing common agents as listed above. |
| `agent-frontmatter.*` | keep native execution permissions, effort, colors and names as deliberate consumer choices; reason: harness-specific session behavior and agent identity. Remove entries for removed non-fitting agents. Add manifest reason comments, and let core reject unsupported fields. |
| `bot-instructions.repo.*`, `.schema`, `.bots.*`, `.cadence.*`, `.tone.*`, `.retention.*` | keep schema, repository identity and deliberate bot choices; reason: native bot settings differ. Apply kendex-web and vgs edits above. No setting itself proves a remote review rule. |
| `bot-instructions.exclusions.*`, `.surface`, `.doctrine.*` | keep product paths, generated/vendor exclusions and product rules; remove retired review-gate/carry/residual policy and duplicated conduct. Reason: renderer owns path-specific native files; reviewer owns conduct. |
| Other observed non-install leaves | none outside the groups above. The archived per-repository leaf lists make the scope checkable; a newly added key needs a disposition at adoption. |

Acceptance: each routed PR attaches its exact manifest/settings diff and package/hook inventory; every kept difference has the stated comment, each remove is absent, each fitting package is installed, and each supported hook covers every declared harness. Use kendex's native preview/verify and the existing package checkers. Re-check this full table on the owner's every-3-days cadence. Changes after these snapshots require a fresh read before mutation. No new periodic scanner is part of this build.


## Ordered build handoff

The parent files these scopes after this plan merges. Every consumer-visible build gets a changelog fragment. Source moves include tracked renders. No issues are filed by this research lane.

1. **Prerequisites**: KEN-2281, then KEN-2089/PR 3264; load KEN-2309 compatibility and KEN-2337 hook activation work. Compare the surviving review-gate tree with the responsibility table. Acceptance: current API proof that consumers drop `Review gate` before final retirement; latest-release catalog checks pass; no second engine deletion.
2. **Runtime and conduct**: move GitHub `pr-watch` and every caller together; move canonical disposition to reviewer with all links; preserve narrow reply checks/controls and automatic-review guidance. Acceptance: watch suites pass; each bad tracking/decline/body disposition fails; native approval does not hide a bad disposition; no active old-path call. Depends on the prerequisite deletion inventory.
3. **Configuration owner**: add `skills/github-repository-settings/`; move surviving refresh/platform/adoption parts and tests; transfer repository effects through the single-source bot-renderer transition. Update core locator, catalog dependencies and commit-guards staged checker. Acceptance: one writer per scope, armed-only effects, disabled pieces write nothing, old settings warn and new settings win, no secret values in reports. Depends on runtime/conduct placement.
4. **Managed CI**: move harness-ci template/guidance; add exact presets, optional templates and consumer-owned scaffold. Extend existing hash/equality machinery. Acceptance: refresh/verify compare all managed copies; extension jobs require no managed edit; failed/cancelled jobs, dead classifier and unauthorized skips fail literal `CI`; authorized skips pass; actual PR/merge-group check names are `CI`; no filter prevents their creation. Controls prove each changed guard rule. Depends on configuration owner.
5. **Routed adoption**: execute each repository's consistency fix list above through its named overseer. Preserve FLT-558 context/app binding in the paired workflow/ruleset PR. Resolve docs/template/package/hook/customization gaps with their existing owners. Acceptance: commented reasons for every kept difference; matching package/harness inventory; local hook arming proved except vgs; one convergent refresh PR; no consumer file rewrite; D007 source lock path unchanged. Depends on the preceding build scopes and KEN-2337 for its hook.
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

Implement these ordered scopes after their prerequisites merge. Use the exact per-repository lists above. Preserve one owner per file and per decision, the three live reply checks and the current classifier/aggregate/renderer interfaces. Attach each scope's acceptance evidence. The parent owns issue creation; named overseers own rollout. This research PR contains only the plan.


## Evidence references

Public GitHub interface sources and pinned repository evidence are separate. The Exa report passes structural validation with a query-metadata warning. Historical Enterprise Server required-workflow sources are excluded.

[issue]: https://linear.app/vanillagreen/issue/KEN-2332
[engine-removal]: https://linear.app/vanillagreen/issue/KEN-2089
[release-first]: https://linear.app/vanillagreen/issue/KEN-2281
[versioning]: https://linear.app/vanillagreen/issue/KEN-2309
[runtime-research]: https://linear.app/vanillagreen/issue/KEN-2334
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
[D007]: ../decisions/D007-lock-record-on-main.md
[D016]: ../decisions/D016-merge-route-reads-bypass.md
[audit-kendex]: https://github.com/vanillagreencom/kendex/rules/24148610
[A-fleet]: https://github.com/vanillagreencom/fleet/tree/0e13585d2a0189fce7ad93508cf96c31e9c48e38
[A-kendex]: https://github.com/vanillagreencom/kendex/tree/781eb4cfed71b1900de359476045953f51ccd545
[A-vg]: https://github.com/vanillagreencom/vg/tree/cef891af7bba20ffc0d677a622dad83b1216213b
[A-talk]: https://github.com/vanillagreencom/talk/tree/bd93613f9df5937acb570d688defc20a7ac5c862
[A-vsys]: https://github.com/vanillagreencom/vsys/tree/d80f21ddf0ff827186da3f2c0b5fbd2ba7861cbd
[A-kendex-web]: https://github.com/vanillagreencom/kendex-web/tree/fb712fc1eb1dbec069157b4baec70653ebd92db8
[A-hyprtrade]: https://github.com/vanillagreencom/hyprtrade/tree/a0782faaa1303aa48c3e36dd16b8fe0506b8a0d6
[A-hyprtrade-io]: https://github.com/vanillagreencom/hyprtrade-io/tree/2f89e44e82e70b1a07223bfedc7885b502ae6dbf
[A-memsira]: https://github.com/vanillagreencom/memsira/tree/d88f65f38d24788d099dbceb12ee3895aa93c4b8
[A-vgs]: https://github.com/vanillagreencom/vgs/tree/c6f8347e05d53b004079db2bd869b715faf94392
[R-fleet]: https://api.github.com/repos/vanillagreencom/fleet/rules/branches/main
[R-kendex]: https://api.github.com/repos/vanillagreencom/kendex/rules/branches/main
[R-vg]: https://api.github.com/repos/vanillagreencom/vg/rules/branches/main
[R-talk]: https://api.github.com/repos/vanillagreencom/talk/rules/branches/main
[R-vsys]: https://api.github.com/repos/vanillagreencom/vsys/rules/branches/main
[R-kendex-web]: https://api.github.com/repos/vanillagreencom/kendex-web/rules/branches/main
[R-hyprtrade]: https://api.github.com/repos/vanillagreencom/hyprtrade/rules/branches/main
[R-hyprtrade-io]: https://api.github.com/repos/vanillagreencom/hyprtrade-io/rules/branches/main
[R-memsira]: https://api.github.com/repos/vanillagreencom/memsira/rules/branches/main
[R-vgs]: https://api.github.com/repos/vanillagreencom/vgs/rules/branches/main
