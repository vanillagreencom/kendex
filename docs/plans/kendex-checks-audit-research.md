# Kendex checks audit

The inventory judges each check's harm and repair owner.

## Contract

- KEN-2320 is report only. No check/runtime/render/record change remains. One report fits the existing 65536-byte cap without exemption or appendix.
- Sources: revision `8d95c78d7bcf144dfab70a2958ea5e5dc6646268`, repository reads, dated command logs. Reached-by cells state risk conditions, not measured frequency. Live reads: `tmp/KEN-2320-live.json`, `tmp/KEN-2320-related-live.json`.
- [D007](../decisions/D007-lock-record-on-main.md) assigns main record repair. [D003](../decisions/D003-one-merge-path.md) retains consumer pull/org governance; [D013](../decisions/D013-admin-merge-green-prs.md)/[D016](../decisions/D016-merge-route-reads-bypass.md) supersede merge/bypass routes. Native protection/app authority and D016 exact-head/queue-only proof stay.
- KEN-1981 owns cost/selection/rewrite. KEN-2298 owns consumer md-refs warnings. KEN-2309 major-bump/KEN-2299 lane CLI refusal are planned, absent here. KEN-2127 smoke proof is implemented. Other bindings stay in rows.
- Parent files unbound change/remove scopes from Reach/Action. No lane issue creation or Done state.

## Legend

- A: package/catalog author. C: consumer, owns manifest/settings/forks, not renders/upstream. L: item lane, no shared base/main record repair. F: refresh/install owner, main record under D007. O: qualified machine/repo/service/org operator/admin.
- b: block; w: warning. Refuse/nonzero/pending/hold deny the named operation; item refusal can coexist with overall success. Post-write refusal is not rollback. Planned means absent.
- Repair Y: actor owns input and can fix it. `no: X`: X owns repair, not actor. Split cells separate own input from upstream/host failure. `no fix needed`: safe fallback works.
- keep/K: retain named check for harm. change: retain safety, change scope/evidence/severity/owner. remove: delete isolated `none`-harm refusal and ceremony-only tests. U: source check to A, C gets safe skip/warning/report/choices, no render edit or unsafe install. E: unavailable host/service/config, not bad source; unexercised/no verdict, O provisions/retries before admission. Row text narrows shared actions; IDs remain independent.
- Source prefix/file keys expand by the tables. `::` names function/check/diagnostic, not line number. No anchor means file-level rule. Proposal sources are proposed owners, not implemented checks.

|Prefix|Repository directory|
|---|---|
|T/|`tools/`|
|CG/|`skills/commit-guards/scripts/`|
|PF/|`skills/preflight/scripts/`|
|DL/|`skills/doc-limits/scripts/`|
|RG/|`skills/review-gate/scripts/`|
|HC/|`skills/harness-ci/scripts/`|
|OR/|`skills/orch/scripts/`|
|H/|`hooks/`|
|CLI/|`crates/cli/src/commands/`|
|CORE/|`crates/core/src/`|
|W/|`.github/workflows/`|
|ACT/|`.github/actions/`|

|File key|Source (prefixes above)|
|---|---|
|g|T/guard|
|pf|PF/preflight|
|rs|RG/validate-standard.sh|
|rv|RG/validate.sh|
|hm|H/lane-mail-check.sh|
|rp|RG/review-predicate.sh|
|pn|T/publish-npm|
|st|W/skill-tests.yml|
|at|CORE/attest.rs|
|v|CLI/verify.rs|
|ce|CG/changelog-entries|
|ra|CORE/render/validate/agent.rs|
|hd|H/doc-drift-check.sh|
|ds|CORE/drift/report/scope.rs|
|up|CLI/update.rs|
|rw|RG/validate-workflow.sh|
|ww|W/review-gate-writer.yml|
|hc|HC/change-class|
|hp|H/pre-commit-check.sh|
|hr|H/reviewer-stop-check.sh|
|rf|CLI/refresh.rs|
|lr|T/lock-record|
|pa|T/publish-aur|
|rel|W/release.yml|

## Totals

370 rows: keep 175, change 170, remove 25. Count first-cell `[A-Z][0-9]+` IDs once, by Verdict; exclude evidence tables. Records: `tmp/KEN-2320-report-rows.tsv`, `tmp/KEN-2320-counts.json`, `tmp/KEN-2320-coverage.md`.

## Inventory

IDs: G repository guard, C commit guards, P preflight, D doc limits, R review gate, I CI/workflows, H hooks, V verify/drift, A apply/refresh/update, X shipping/validation.

Review evidence/thread terms run only when class policy reaches them. Class none returns approved first; thread mode off skips dispositions. Native protection remains separate.

|ID|Check source|Reached by|Prevented harm|Effect/actor|Repair|Verdict|Action/boundary|
|---|---|---|---|---|---|---|---|
|G01|g::bot-instructions|Full validation|Unselected review rules|b A|Y|keep|K|
|G02|g::decision-ids|Concurrent decision merge|Duplicate IDs misdirect citations|b A|Y|keep|K; unknown base G36|
|G03|g::shipped-decision-link|Bare decision ID in catalog prose|Consumer resolves unrelated local decision|b A|Y|keep|K|
|G04|g::homebrew-formula|Formula named Kendex|CLI replaces intended desktop install|b A|Y|keep|K|
|G05|g::catalog-fs-read|Raw catalog read|Host secrets or outside-root bytes copied|b A|Y|keep|K; scan not all call sites|
|G06|g::ui-tauri-import|Direct Tauri import outside bindings|Untyped API call breaks UI|b A|Y|keep|K|
|G07|g::ui-color-literal|Color literal|none|b A|Y|remove|Delete gate; theme review only|
|G08|g::command_safety_policy|Bad/unreadable/changed deny policy|Dangerous command allowed or valid command denied|b A|Y|keep|K; loader/allow/refuse controls per policy|
|G09|g::ci-correlation-copy|Second correlation reducer|Old failure counted or current failure missed|b A|Y|keep|K|
|G10|g::raw-command-new|Raw external launch|Inherited environment alters tool; child hangs|b A|Y|keep|K|
|G11|g::cli-raw-output|Raw terminal output outside UI|Foreign text controls terminal|b A|Y|keep|K|
|G12|g::fixture-home|Fixture HOME without sandbox opt-out|Test uses developer sandbox|b A|Y|keep|K|
|G13|g::binary-home|CLI test without isolated home|Test mutates real packages/registry|b A|Y|keep|K|
|G14|T/test-roster|Test absent from module/target roster|Green suite never runs new test|b A|Y|keep|K|
|G15|g::unrooted-fixture|Noncanonical Rust fixture root|macOS aliases cause false failures|b A|Y|keep|K|
|G16|T/bash32-lint|Unsupported Bash syntax|Script fails on macOS Bash|b A|Y|keep|K; not complete parsing|
|G17|T/bash32-parse|Full Bash 3.2 parse|Script cannot start on supported macOS|b A/L|source Y; runtime O|change|E; retain CI parsing, no prose block|
|G18|g::missing-skill-instructions|Missing instruction delimiters|Agent misses project requirements|b A|Y|keep|K|
|G19|g::require_render|Source changed without tracked render|Own checkout runs old catalog rule|b A|Y|keep|K; source/render pair, no lane lock|
|G20|g::tauri-dependency|Core depends on Tauri|CLI needs desktop runtime|b A|Y|keep|K|
|G21|g::crate-lints|Crate skips workspace lints|Correctness/security lints stop applying|b A|Y|keep|K|
|G22|g::clippy|Rust compile/lint|Compile/correctness errors ship|b A/L|source Y; host O|change|E; applicable errors only, style advisory|
|G23|g::cargo-fmt|Rust formatting|none|b A|Y|remove|Delete refusal; formatter optional|
|G24|g::cargo-space-free|Low free-space admission|Build fills shared disk|b L|no: O|change|E: host build admission|
|G25|g::cargo-space-start|Low free plus reusable target space|Cold build fills shared disk|b L|no: O|change|E: host build admission|
|G26|g::cargo-space-end|Low/unreadable end space|Next writer exhausts disk; capacity unknown|b L|no: O|change|E: capacity separate from suite|
|G27|g::cross-check|Cross-target compile|Platform compile errors ship|b A/L|source Y; targets O|change|E; retain platform CI|
|G28|g::cargo-doc|Workspace docs build|Broken doc links/compile ship|b A|Y|keep|K; docs, not runtime proof|
|G29|g::cargo-test|Test fails/cannot run|Regression ships or result unknown|b A/L|source Y; host O|change|E; signal classification G39 exists|
|G30|g::suite|Skill/hook/tool/Pi suite|Script behavior regresses|b A/L|source Y; peers O|change|E: peers provisioned before lane|
|G31|g::ui-check|UI type check|Bad API/store types break page|b A|Y|keep|K|
|G32|ui/package.json::check:lint|UI lint|Behavior errors ship; style has no runtime harm|b A|Y|change|Behavior gate; style advisory|
|G33|ui/package.json::test|UI tests|Compiled UI interactions fail|b A|Y|keep|K|
|G34|g::refuse|Bad args/class/range/selection|Wrong tree checked or checks skipped|b L|input Y; reader A|change|No-verdict/full-set fallback; U reader|
|G35|g::scan|Read/grep failure in scan|Unread source reported clean|no finding A|Y|change|Propagate scan error, not true; unrun case|
|G36|g::decision-ids|Cannot fetch/read decision base|Collision check unknown|b A/L|no: O|change|E; not a duplicate ID|
|G37|g::whole_setting|Bad/missing capacity setting|No valid admission bound|refuse L|no: O|change|E; config gap distinct from exhaustion|
|G38|g::cargo-target-unreadable|Unreadable start space/target|Capacity unknown|w L; continues|no: O|keep|K; no measured space claim; end G26|
|G39|g::test-binary-signal|Test binary dies by signal|Artifact has no test verdict|b A/L|artifact rebuild; host O|change|E; signal distinct from assertion|
|C01|CG/todo-ban|TODO/FIXME/HACK/XXX marker|none|b A/C|own Y; render A|remove|Delete marker gate|
|C02|CG/byte-ceiling|General byte cap/baseline|none|b A/C|own Y; vendor A|remove|Delete size gate and ratchet|
|C03|CG/byte-ceiling|Size warning percentage|none|w A/C|own Y|remove|Delete warning with cap|
|C04|CG/suppression-ban|Blanket lint suppression|Correctness/security checks disabled|b A/C|own Y; upstream A|change|Own suppression gate; U upstream|
|C05|CG/suppression-ban|Dead-code/unused count ratchet|none|b A/C|own Y|remove|Delete spelling/count gate|
|C06|CG/conflict-markers|Merge markers in index|Unresolved content ships|b A/C|own Y; render A|change|Own introduced markers gate; U render|
|C07|ce|Bad/missing fragment placement|Release omits visible change|b A/C|Y|keep|K|
|C08|ce|Binary/link/empty/multi-item fragment|Release record unreadable|b A/C|Y|keep|K|
|C09|ce|Fragment character cap|none|b A/C|Y|remove|Delete cap; migration text may be long|
|C10|ce|Collate dirty tree/no consent|Fragments deleted or pending work lost|b A release|Y|keep|K|
|C11|ce|Ambiguous section/bad fences|Entry lands in wrong release/section|b A release|Y|keep|K|
|C12|CG/prose|Date/issue token in loaded Markdown|none|b A/C|own Y; render A|remove|Delete history-token ban|
|C13|CG/md-format|Wrap/spacing/CRLF format|none|b A/C|own Y; render A|remove|Delete style gate; reflow optional|
|C14|CG/md-format|Unclosed fence/header/comment|Scan incomplete|b A/C|own Y; upstream A|change|Own malformed gate; U incomplete scan|
|C15|CG/md-reflow|Unsafe path/text/block rewrite|Rewrite loses foreign/misparsed content|refuse A|Y|keep|K; optional rewrite tool, not gate|
|C16|CG/md-refs|Dead own link/path/symbol/decision|Reader follows missing rule|b A/C|Y|keep|K; rendered targets included|
|C17|CG/md-refs|Dead reference in managed render|Consumer follows missing instruction|b C|no: A|change|U: installed-layout links; KEN-2298|
|C18|CG/md-refs|Unread carrier/target/comment grammar|Unread references reported checked|b A/C|own Y; scanner A|change|Unjudged scanner; U upstream|
|C19|CG/py-names|Undefined Python name/bad syntax|NameError or script cannot start|b A/C|own Y|keep|K; generated paths excluded|
|C20|CG/py-names|Missing/bad ruff/pyflakes/result|Name check unexercised|b L/C|host O|change|E: provision before gate install|
|C21|CG/comments|Comment history tokens|none|audit nonzero A|Y|remove|Delete optional refusal, no new gate|
|C22|CG/commit-msg|Commit header grammar/length|none|b A/C|Y|remove|Delete style gate; no release dependency|
|C23|CG/commit-msg|Product change without note/opt-out|Users miss change disclosure|b A/C|Y|keep|K; explicit no-changelog allowed|
|C24|CG/pre-push|Pushed ref/index differs from HEAD|Gate checks wrong bytes|b A/C|Y|keep|K; malformed refs refuse|
|C25|CG/pre-commit|Missing/unrunnable gate lane|Promised check silently omitted|b C/L|config Y; package A|change|U: package completeness at setup|
|C26|CG/install-git-hooks|Arm hooks in linked worktree|All branches use disposable scripts|b L|no: F|change|Main-owner setup request/unarmed notice|
|C27|CG/install-git-hooks|Foreign/link/disabled hook or bad interpreter|User hook lost or gate cannot run|refuse C setup|Y|keep|K|
|C28|CG/install-git-hooks|Empty/foreign hooksPath|Gate disabled or unknown|w/refuse C setup|policy O|change|Warn/owner route; no hooksPath takeover|
|C29|CG/commit-guards|Bad selection/policy/baseline/scan|Enabled checks omitted|b A/C|config Y; package A|change|Own config refusal; U package errors|
|C30|CORE/check_catalog.rs|Planned dropped/catalog link check|Render points at unshipped maintainer file|planned finding A|Y|keep|K planned; KEN-2184, KEN-2298 boundary|
|P01|pf::shell-syntax|Changed unparsable shell|Script cannot start|b A/C|own Y; render A|change|Own syntax gate; U managed source|
|P02|pf::shellcheck-errors|Changed shellcheck error|Invalid shell behavior|b A/C|own Y; render A|change|Own error gate; U managed source|
|P03|pf::masked-returns|Declaration masks child status|Failed command read as success|b A/C|Y|keep|K; installed trees stand down|
|P04|pf::fail-open|Unchecked temp/status/strict mode|Failure produces false pass|b A/C|Y|keep|K; not complete proof|
|P05|pf::early-close-pipe|pipefail plus early-closing reader|SIGPIPE abort/false match|b A/C|Y|keep|K; suites included|
|P06|pf::unwired-suite|Suite absent from known runner|Regression test never runs|b A/C|Y|change|Support real runner config; unknown != unwired|
|P07|pf::mktemp-trap|New scratch script lacks EXIT cleanup|Repeated runs fill storage|b A/C|Y|keep|K|
|P08|pf::hardcoded-temp-path|Fixed temporary directory creation|Concurrent overwrite/planted path|b A/C|own Y; render A|change|Own unique scratch; U render|
|P09|pf::docs-cited-paths|Added dead path citation|Reader acts on missing path|b A/C|own Y; managed A|change|Use generated ownership; U managed prose|
|P10|pf::applied-migration-edited|Edit/delete/rename checksum migration|Upgrade rejects recorded checksum|b A/C|Y|keep|K; checksum runners only|
|P11|pf::data-syntax|Changed invalid JSON/TOML|Config cannot load|b A/C|own Y; render A|change|Own syntax gate; U render, preserve JSONC|
|P12|pf::not-run|Optional checker missing|Check unexercised|w L/C|O|keep|K; skipped != checked|
|P13|pf::env_error|Unread git/base/settings/diff|Wrong/incomplete change checked|b caller|input Y; host O|change|E; no verdict|
|P14|OR/branch-size-check::DELTA_GRAMMAR|Report-only/zero allowance|Production growth escapes scope|b L exit 3|no: parent|change|Accept zero/report scope; KEN-2319 recurrence|
|D01|DL/doc-limits::SHIPPED_CLASS_ROWS|Class byte cap exceeded|Loaded prose consumes context; reference cap harm unproved|b A/C|own Y; managed F|change|Load-point notice; reference budgets advisory|
|D02|DL/doc-limits::MARGIN_PCT|Growth in margin below cap|none|b A/C|own Y|remove|Delete near-cap growth gate|
|D03|DL/doc-limits::parse_classes|Bad class/exclusion/margin/settings|Wrong/incomplete size result|b caller|policy Y; package A|change|Own policy errors; U package/E host|
|D04|CG/lib/generated-paths.sh|Unread/bad generated inventory|Own code skipped or consumer blocked on render|b C/L|no: F|change|Upstream/F inventory proof; warn C|
|P15|pf::guard_tests_var|Bare assignment before status test|errexit prevents intended handler|b A|Y|keep|K; deliberate fatal assignment passes|
|R01|rv::runtime|Engine missing/untracked/link/bad mode/parse|CI lacks runnable gate|b A/C install|own vendoring Y; source A|change|U: install readiness; own vendoring gate|
|R02|rv::scan_settings_source|Settings untracked/link/unreadable/type|CI reads different trust policy|b O repo|Y|keep|K|
|R03|rv::settings-unknown|Unknown key/wrong setting layer|Chosen policy ignored|b O repo|Y|keep|K|
|R04|rv::settings-outside-env|Outside env/bad header/BOM|Defaults replace intended policy|b O repo|Y|keep|K|
|R05|rv::settings-key-shape|REVIEW_GATE_ in valid string|none|b O repo|Y|remove|Parse assignments, delete mention ban|
|R06|rv::settings-mode-source|Mode/writer in skipped local layer|Wrong policy runs|b O repo|Y|keep|K|
|R07|rp::--check-config|Bad trust/mode/limit/pattern/enum|Wrong actor trusted/evidence misread|b O repo|Y|keep|K|
|R08|rv::settings-writer|Bad writer/lock-kendex value|Writer refuses every PR|b O repo|Y|keep|K|
|R09|rv::class-policy-undecided|Custom/off policy lacks decision file|none|b O repo|Y|remove|Delete prose-record gate; judge policy|
|R10|rv::carry-unmatched|Carry glob matches nothing|Misspelling carries old review to risky path|b O repo|Y|change|Warn unmatched; planned != bad, no ledger|
|R11|rv::carry-universal|Carry exclusion matches all|none|b O repo|Y|remove|Delete refusal; no carry conservative|
|R12|rv::carry-declaration|Prophylactic declaration absent/stale|none|b O repo|Y|remove|Delete duplicate declaration gate|
|R13|rv::workflow-no-verdict|Peer verdict missing/malformed/status mismatch|Unchecked copy reported green|b A/C|producer A|change|No verdict; U producer protocol|
|R14|rw|Writer absent/untracked/link/byte mismatch|Token code unsafe or gate absent|b O workflow|own YAML Y; template A|change|Trust gate; harmless bytes warn; U template|
|R15|rp::awaiting|Required review evidence absent|Unreviewed change merges|pending A/L|request Y; service O|change|Server approval; reviewer outage to O|
|R16|rp::changes-requested|Standing reviewer objection|Known defect merges|b A|Y|keep|K; outage override cannot clear objection|
|R17|rp::threads-open|Enforced unresolved thread|Unaddressed finding merges|pending A|Y|keep|K where platform cannot enforce resolution|
|R18|rp::untracked-claim|Tracked claim without issue|Deferred defect lacks record|b A|Y|keep|K; ID alone proves no issue existence|
|R19|rp::unreasoned-decline|Decline has labels/filler only|Defect dismissed without assessable reason|b A|Y|keep|K; reviewer judges reason semantics|
|R20|rp::suppressed-findings|Bot findings lack head-bound answers|Unpublished finding disappears|b A|Y|keep|K; per-entry answer, not vocabulary|
|R21|rp::unmeasured|Active class unmeasured|Unearned review waiver|pending C/L|classifier A/O|change|No waiver; ordinary review; U/E classifier|
|R22|rp::class-unresolved|Class preparation/policy fails|Wrong class grants waiver|pending head; writer fails|no: A/O|change|No new waiver; ordinary review; E/U; R43|
|R23|rp::exit 2|API/config/evidence read fails|Unknown turns green/objection erased|unchanged O|API O|keep|K; no-action/retry, not source rejection|
|R24|RG/review-writer.sh|Stale success/head write race|Old evaluation reopens gate|defer writer|O retry|keep|K|
|R25|ww::merge-group|Queue green without predicate|Thread opens after entry, defect merges|success queue|A answers; O checks|change|Queue-head objections/threads; KEN-2017|
|R26|ww::DEFAULT_BRANCH|Missing default branch checkout|Write token runs PR-controlled code|b O writer|Y|keep|K|
|R27|ww::request-converge|Dispatch/fork relay/rate-limit failure|Gate stale until schedule|w O|no for A; O|keep|K; scheduled retry, not source failure|
|R28|ww::Escalate sustained writer failure|Incident API read/write fails|Owner misses sustained outage|w O|O|keep|K; failed lookup never duplicates incident|
|R29|rs::standard-ruleset-source|Different ruleset source|Protection can be weakened; harmless placement also fails|audit nonzero C/O|no C; O|change|Org audit/effective authority; D003/D013|
|R30|rs::standard-merge-queue|Queue not required|Concurrent changes merge untested|audit nonzero O|Y|keep|K; admin audit, not C commit gate|
|R31|rs::standard-required-contexts|Required contexts differ/extra gate|Tests omitted or merges wrongly blocked|audit nonzero O|Y|change|Needed effective contexts, not exact set|
|R32|rs::standard-required-approvals|No independent approval|Unreviewed source merges|audit nonzero O|Y|keep|K|
|R33|rs::standard-stale-dismissal|Old approval survives new head|Unreviewed new bytes merge|audit nonzero O|Y|keep|K|
|R34|rs::standard-conversation-resolution|Thread resolution optional|Open findings merge|audit nonzero O|Y|keep|K|
|R35|rs::standard-copilot-review|No auto Copilot request|none|audit nonzero O|Y|remove|Delete vendor rule; independent review stays|
|R36|rs::standard-bypass-actors|Bypass actor outside allowed scope|Approval/tests bypassed|audit nonzero O|Y|keep|K; unread actor distinct|
|R37|rs::standard-classic-protection|Classic protection beside rulesets|none|audit nonzero O|Y|remove|Delete presence audit; D016 queue rule stays|
|R38|rs::standard-ci-context|CI absent on PR/queue legs|Untested combined tree merges|audit nonzero O|Y|keep|K; unread API != absent job|
|R39|rs::standard-app|App missing in any org repo|Repo cannot refresh; unrelated repo also fails|audit nonzero C/O|no C; O|change|Org inventory to O; local authority only|
|R40|rs::standard-environment|Env absent/non-default policy|PR reads write tokens|audit nonzero O|Y|keep|K|
|R41|rs::standard-environment-secrets|Required secret absent|Refresh cannot authenticate|audit nonzero O|Y|keep|K; no C commit block|
|R42|rs::standard-secrets-outside|Privileged secret outside protected env|Untrusted workflow gets write authority|audit nonzero O|Y|keep|K; denied reads unexercised|
|R43|RG/review-writer.sh::writer-class-unresolved-kept|Class fails with exact-head success|Transient failure revokes valid state|notice; no post; pass fails|A/O|keep|K; not newly measured approval|
|R44|rw::workflow-reference-count|Multiple executable engine references|Writers overwrite state|b O workflow|own Y; parser A|change|Executable references only; U parser|
|R45|rw::workflow-opt-in|Partial check_run opt-in|Review relay does not run|b O workflow|Y|keep|K; harmless order R14|
|R46|rw::workflow-absent-mode|Active required writer absent|Required status never appears|b O repo|Y|keep|K; optional/off/no execution passes|
|R47|RG/adopt-refresh.sh::refresh-warning=workflow-edited|Adopt edited refresh YAML|User workflow overwritten|w + replacement C|restore Y; loss occurred|change|Preserve edited YAML; replacement consent|
|R48|RG/adopt-refresh.sh::workflow-symlink|Refresh destination symlink|Replacement writes foreign target|refuse C|Y|keep|K|
|R49|RG/provision-environment.sh|Partial app selection/org enumeration|Whole-org provisioning falsely complete|refuse O org|Y|keep|K; owner-only, unrun here|
|R50|RG/provision-environment.sh::secret|Live secret value absent|Provisioned refresh cannot authenticate|refuse O org|Y|keep|K; secret name not value proof|
|R51|RG/provision-environment.sh::protection|Policy switch drops protection|Review/wait protection lost|refuse O org|Y|keep|K|
|I01|hc|Missing event/refs/contract/ownership|Wrong diff gets test/review waiver|fallback/refuse caller|input Y; engine A|change|Standard/unmeasured; U/E; full route|
|I02|hc::render|Bad render/provenance/foreign-key proof|Authored code disguised as generated|standard fallback A|review Y; record F|keep|K; exact head, no unread waiver|
|I03|hc::trivial|Large docs delta/instruction/config path|Policy misclassified as harmless prose|wider checks A|Y|keep|K; no label override|
|I04|hc::queue-only|Queue list absent/unreadable/sensitive path|Direct merge skips combined proof|queue A|Y|keep|K; queue route, no unknown-source repair|
|I05|T/ci-job-set::event-parity|PR/queue selection differs|PR green omits queue tests|b O workflow|Y|keep|K|
|I06|T/ci-job-set::PROOF_RECORD|Bad prior proof selection|Untested lane skipped|w + run O|no fix needed|keep|K; invalid proof runs lane; identity I25|
|I07|T/ci-job-set::die|Bad class/event/docs/source read|Selector drops jobs|b A/C workflow|config Y; selector A|change|U selector; full-set fallback|
|I08|HC/aggregate-needs|Classifier absent/failed or job not green|Failed/cancelled/unauthorized skip turns green|b A/L|source Y; host O|change|E; keep unauthorized-skip refusal|
|I09|T/ci-aggregate|Bad/duplicate selection/missing result/helper|Malformed wrapper permits skip|b A/C workflow|wiring Y; helper A|change|U: selector/helper protocol|
|I10|st::shard names agree with the matrix|Shard absent/unused/unread roster|Shard never runs|b O workflow|Y|keep|K|
|I11|st::executable bits|Missing executable mode|CI/install cannot start script|b A|Y|keep|K; libraries excluded|
|I12|st::the interpreter is Bash 3.2|macOS probe uses wrong runtime|False portability attestation|b O CI|Y|keep|K; inverse probe, no other-OS proof|
|I13|st::crate matrix agrees|Crate matrix misses member|Crate tests never run|b O workflow|Y|keep|K|
|I14|st::platform-gated tests|File-wide platform cfg|Platform feature untested|w A|Y|keep|K; portable counterpart when needed|
|I15|st::the verify document|Bad built verify JSON/version|Classifier cannot prove ownership|b A|Y|keep|K; producer/consumer fixture|
|I16|st::pi-claude-bridge bundle|Bundle differs from clean-lock build|Published bytes differ from reviewed source|b A|Y|keep|K|
|I17|T/installer-pin::--check|Installer SHA/tag mismatch|Token workflow runs wrong script|b A|Y|keep|K|
|I18|W/catalog-check.yml::Validate the catalog|Catalog grammar fails|Harness cannot load shipped package|b A|Y|keep|K|
|I19|W/catalog-check.yml::strict|Strict escalates all advisory|Ignored/lost output ships; harmless metadata blocks|b A|source Y; severity A|change|Harm-specific I22-I24; other advisory warns|
|I20|W/own-catalog.yml::real-CLI round trip|CLI absent/emitted tree rejected|Renderer green but harness loads nothing|b A/L|renderer A; runtime O|change|E; retain real-CLI proof, no zero coverage|
|I21|st::CI|CI timeout/install/assertion failure|Regression ships or proof unavailable|b A/L|source Y; host O|change|E; retain commands/budgets; KEN-1981 cost|
|I22|CORE/check_catalog.rs::tracked_outputs|Declared tracked output ignored|Report absent in clone/review|strict finding A|Y|keep|K; consumer strict V07|
|I23|CORE/render/validate/skill.rs::findings|Source skill lacks description|Harness cannot select skill|advisory A|Y|keep|K; advisory not blanket breakage|
|I24|CORE/check_catalog/settings.rs::findings|Unreadable seeded settings|Loader ignores/refuses shipped settings|strict finding A|Y|keep|K|
|I25|ACT/change-class/proof::answer|Bad prior run/tree/event/artifact identity|Wrong/failed proof skips tests|reuse=false O|no fix needed|keep|K; no-reuse, selector I06|
|I26|ACT/change-class/classify::lanes-from-judged-tree|Declaration checkout is judged tree|PR edits own declaration to skip tests|refuse caller|Y|keep|K|
|I27|ACT/change-class/classify::declaration|Trusted declaration bad/absent|Unknown authorizes test skip|w; no lane verdict O|no A; O|keep|K; no PR defect inferred|
|I28|ACT/change-class/classify::wiring-error|Protocol/helper/output/write fails|False/incomplete lane selection|b caller|wiring Y; package/host A/O|change|No selection; U/E; full-check route|
|H01|H/block-argv-kill.sh::KILL_RE|pkill/killall in shell text|Unrelated lanes killed by name|b L|Y|change|Executable kill only; allow quotes/heredoc|
|H02|H/block-bare-cd.sh|Bare cd in persistent Claude shell|Later call uses wrong checkout|b L|Y|keep|K; persistent-shell delivery only|
|H03|H/block-bare-cd.sh|Bare cd in per-call Codex/Pi shell|none|b L|Y|remove|Delete per-call-shell delivery|
|H04|H/block-repo-copy.sh::BLOCK_RE|Copy .git/target to scratch|Shared temp storage filled|b L|Y|change|Executable copy only; name proves no size|
|H05|H/block-unsafe-rm.sh::UNSAFE_RE|rm with possibly empty variable|Unintended files deleted|b L|Y|change|Actual rm only; allow prose/git rm --cached|
|H06|H/block-worktree-refresh.sh::verb_kind|Inherited main manifest project write|Lane mutates shared base install|b L|target Y; base F|change|Target proof; shared write to F|
|H07|H/block-worktree-refresh.sh|Any project update-pi in worktree|Shared/duplicate package update|b L|no even own project|change|Actual target ownership/consent, not blanket ban|
|H08|H/command-safety.sh::COMMAND_SAFETY_DENY_PATTERN|Configured regex matches shell text|User-selected danger runs|b C/L|command Y; policy O|change|Executable match or disclose lexical opt-in|
|H09|hp::git_commit_call|Commit with unarmed checks|Unconsented repo code/checks absent|b A/C/L|setup O/F|change|Consent/main-owner setup route|
|H10|hp::flag_read|Bypass token in command text|Checks skipped|b A/C|Y|change|Actual bypass only, not message/git data|
|H11|hp::elsewhere_notice|Cross-repo -C/cd/env|Cwd gate cannot attest target|w A/C|target O|keep|K; no cross-repo enforcement claim|
|H12|hd::covering_docs|Code changes without doc edit|Stale doc misdirects work|b once A/L|Y; doc may be correct|change|Advisory/confirmation, no meaningless doc edit|
|H13|hd::tree_paths|Covers matches no path|Topic cites missing code|b once A/L|own Y; inherited A|change|Own introduced dead citation gate; U inherited|
|H14|hd|No covering topic|none|b once A/L|Y|remove|Delete map-presence refusal|
|H15|H/reviewer-read-only.sh|Reviewer edits/writes outside reports|Reviewer changes judged bytes|b reviewer|Y|keep|K; Edit everywhere, Write repo; shell partial|
|H16|H/reviewer-read-only.sh::GIT_DISCARD|Reviewer git commit/push/discard text|Author work/branch changed|b reviewer|Y|change|Actual write only; allow data/stash list|
|H17|hr::artifact|Stop lacks artifact path|Caller gets no result|b once reviewer|Y|change|Readable artifact, not transcript mention|
|H18|hr::WORKTREE|Any dirty reviewed file|Reviewer leftovers affect later tests|b once reviewer|no for prior A edits|change|Attribute new dirty paths against start tree|
|H19|H/task-completed-check.sh::clippy|Changed Rust full workspace lint|Compile/correctness defect reported done|b A/L|own Y; inherited/host A/O|change|Affected inputs; E; style advisory|
|H20|H/skill-load-check.sh::judge_loaded|No skill-load transcript proof|none|b L|Y|remove|Delete read ritual, behavior checks remain|
|H21|H/skill-load-record.sh|Load ledger fails|H20 falsely blocks loaded skill|w session|no: A/O|remove|Delete recorder with H20|
|H22|hm::mail_check|Fresh lead stop with unread mail|Owner directive missed|b lead stop|Y|keep|K; ack after delivery, continued escape|
|H23|hm::halt|Unread halt before tool call|Work continues after owner stop|b L|lead ack; child stop/report|keep|K; exact acknowledgement route|
|H24|hm::question_tool_check|Harness question tool in lane|Answer goes to wrong session|b L|Y|keep|K|
|H25|hm::idle_check|Lead ends without new status|Overseer cannot tell idle from busy|b once lead|Y; may be needless|change|Idle notice from incomplete/undelivered work|
|H26|hm::idle-record|Mail/status recording fails|Progress/idle unknown|w L|no: O|keep|K; unknown, no repeated hold|
|H27|hm::refuse_handoff|Measured session limit reached|Work context/access lost|b lead|Y|keep|K; existing handoff clears first|
|H28|hm::overseer_marks|Measured overseer limit reached|Root loses lane decisions|b overseer|Y|keep|K; no forced credential edit|
|H29|hm::handoff-unanswered|Untrusted/missing handoff state/tools|Unknown capacity read as free|w session|no: A/O|keep|K; unknown, no infinite hold|
|H30|hm::transcript|Unknown usage triggers handoff block|Work lost without capacity proof|b session|only with writer|change|Reachable handoff or O warning|
|H31|H/lane-mail-deliver.sh|Post-tool context/judge fails|Directive/tool result lost|post-tool refusal/report L|no: A/O|change|Keep tool result; extra notice, mail unread|
|H32|H/lane-mail-start.sh|Start/prompt delivery fails|Owner mail missed|w session|no: A/O|keep|K; prompt wrapper included, retry unread|
|H33|H/lane-mail-compact.sh|Compaction record fails|Later stop reads stale room|post-event w O|no session repair|keep|K; discard stale usage; event not undone|
|H34|H/session-start-row.sh|Start/end/failure writer absent|Fleet cannot establish termination|w session|no: A/O|keep|K; shared end/failure judge|
|H35|H/block-argv-kill.sh::missing-tools|Missing/bad payload/tools|Name kill unknown|b all shell|no: A/O|change|U/E adapter; reachable context/O route|
|H36|H/block-bare-cd.sh::missing-tools|Missing/bad payload/tools|Persistent cwd move unknown|b shell|no: A/O|change|U/E adapter; contextual warning|
|H37|H/block-repo-copy.sh::missing-tools|Missing/bad payload/tools|Scratch copy unknown|b shell|no: A/O|change|U/E copy adapter, as H35|
|H38|H/block-unsafe-rm.sh::missing-tools|Missing/bad payload/tools|Deletion unknown|b shell|no: A/O|change|U/E adapter; reachable repair|
|H39|H/block-worktree-refresh.sh::missing-library|Missing library/git/payload/cwd|Write ownership unknown|b shell|cwd Y; package A|change|Own cwd fix; U/E package prerequisites|
|H40|H/command-safety.sh::settings|Loader/payload/unrelated setting fails|Deny policy unknown|b all shell|policy O; package A|change|Own deny refusal; remove unrelated all-shell trap|
|H41|hp::missing-tools|Payload reader fails|Commit arming/bypass unknown|b shell|no: A/O|change|U/E adapter; no own-repair block|
|H42|hd::refuse|Inventory/git/session/hash/marker fails|Doc comparison unknown|b fresh stop; continued passes|no: A/O/F|change|E unknown/continued escape; payload H50|
|H43|H/reviewer-read-only.sh::missing-tools|Payload/path/git read fails|Write boundary unknown|b reviewer|no: A/O|change|Platform allowlist; U/E adapter gap|
|H44|hr::refuse|Transcript/id/git/marker fails|Review result/cleanup unknown|b fresh stop; continued passes|no: A/O|change|E unknown/continued escape; payload H51|
|H45|H/skill-load-check.sh::refuse|Load rule/transcript/payload unreadable|none|b session|no: A/O|remove|Delete traps with H20|
|H46|hm::stall|Mail/fleet/marker/read trust fails|Directive/halt unknown|b fresh; w continued|no: A/O|change|Untrusted code refused; gap/safe stop, not empty|
|H47|H/lane-mail-halt.sh|Halt judge absent|Stop authority unavailable|b all tools|no: A/O|change|U/E companion; safe session end|
|H48|hm::missing-tools|jq/cat/payload before retry read|Owner mail unknown|b every stop/tool|no: A/O|change|U/E adapter; nonlooping unknown before hold|
|H49|docs/plans/kendex-backlog-vision.md::KEN-1482|Planned bare git/gh owned-verb check|Wrong route bypasses protection/shared ownership|planned b L|owned route Y; repair varies|change|KEN-1482 planned; writes with harm only|
|H50|hd::payload|Doc payload read fails|Comparison/stop escape unknown|b even continued|no: A/O|change|U/E adapter; nonlooping unknown stop|
|H51|hr::payload|Review payload read fails|Stop/escape state unknown|b even continued|no: A/O|change|U/E adapter; nonlooping stop, no false result|
|H52|H/task-completed-check.sh::git_paths|Git changed-set read fails|Unchecked completion claimed|b session|no: O|change|E: selection separate from lint|
|H53|H/task-completed-check.sh::cargo|Rust changed, cargo missing|Rust check unexercised|b L|no: O|change|E: compiler before lane|
|V01|v::check_scope|Unread manifest/record/scope|False verification agreement|nonzero C/L|manifest Y; record F|change|Keep unjudged; record to F, no unrelated gate|
|V02|v::say_row|Missing/stale/conflicting/orphan files|Setup differs from declaration|nonzero C/L|local Y; render/record F|change|Measure local vs upstream/main separately|
|V03|v::declaration_rows|Declaration lacks record row|Omission hides unchecked package|nonzero C/L|no lane; F|change|Keep gap; main record F, no lane apply|
|V04|v::failed_hook_delivery_rows|Unsupported hook event|User thinks undelivered guard active|nonzero C|selection Y; source A|change|U: event proof; supported/removal choices|
|V05|CORE/engine/instruction_shims.rs::ShimStanding|Missing/stale/obstructed shim|No shared instructions or user prose lost|nonzero/item refusal C|obstruction Y; generated F|change|No-clobber; own migration vs F shim repair|
|V06|CLI/repo_effects.rs::say_lapsed|Armed setup lapsed/unknown|User thinks checks active|nonzero verify; w refresh C|setup O; package A|change|State notice; U script, O re-arm|
|V07|v::tracked_output_rows|Tracked output ignored|Report absent in clone/review|w; strict nonzero C/L|ignore O|change|Default warning; strict only at repair owner|
|V08|at::inventory|Bad/missing ownership inventory|Own code skipped/consumer wrongly blocked|nonzero C/L|no: F|change|Trust proof stays; blocker to A/F|
|V09|at::inventory|Layout-only inventory mismatch|none|nonzero C/L|no: F|remove|Delete layout failure; schema/membership stays|
|V10|at::record|Record not canonical serialized form|Unknown data lost; whitespace also fails|nonzero C/L|no: A/F|change|Protect dropped data before layout-only removal|
|V11|at::differs|Record field/key/source/bundle differs|False ownership/origin attestation|nonzero C/L|no lane; F|change|Trust proof stays; main record F|
|V12|at::history_problem|Bad/off-history/unavailable pin|Unreviewed source authorized|nonzero C/L|pin/cache Y; history A|change|No trust waiver; unavailable mirror != tamper|
|V13|at::held_problem|Before comparison floor/base unreadable|Render waiver permits rollback|nonzero proof caller|base/fetch Y; history A|keep|K; advancing tip alone notice|
|V14|at::adopted_workflows|Adopted workflow differs|Wrong trust/policy executes|nonzero O workflow|own YAML Y; template A|change|Trust gate; harmless bytes warn; U template|
|V15|at::foreign_since|Foreign shared keys changed/unknown|Waiver hides own permissions/config|proof rejection caller|review Y|keep|K; foreign unknown not general failure|
|V16|v::print_left_out|Hook excludes all chosen harnesses|Intentional skip mistaken for broken install|notice C|selection Y; support A|keep|K; omission not gap|
|V17|H/session-drift-check.sh::notice|Drift CLI/payload/check unavailable|Session assumes current setup|w session|no: A/O|keep|K; no project record write fallback|
|V18|H/session-drift-check.sh::report|Linked/lane shared drift|Lane refreshes shared state|w L|no: F/parent|keep|K; count/no lane refresh|
|V19|ds::manifest_lines|Bad manifest/old hook/missing ref|Session follows incomplete setup|w C|manifest Y; source A|change|Own manifest fix; U hook/reference|
|V20|ds::pi_shadow_scan|Pi duplicate/shadow/stale/missing|Wrong copy runs/double registration|w C|Y|keep|K; never delete foreign copy|
|V21|ds::unrecorded_lines|Unrecorded/unowned source/files|Wrong package called managed|w C/L|local Y; record F|keep|K; main record F|
|V22|ds::snapshot_lines|Missing fetch/snapshot/edits/removal/update|Unknown comparison called current|w C|network/edits Y; source A|keep|K; held/ignored quiet|
|V23|CLI/check/commit_hooks.rs::fold_commit_hooks|Commit gate unarmed/stale/unknown|Session thinks protection active|w C|consent O; source A|change|Consent notice; U script/hooksPath to O|
|V24|ds::snapshot_lines|Healed fetch retains bad snapshot note|False unresolved warning persists|w C/L|no: A|change|KEN-2140: digest-bound rederive on fetch|
|V25|CORE/settings_seed.rs|Planned orphan settings comment|Removed setting still advised|planned w/offer C|own Y; provenance unknown|change|KEN-1729 planned; warn/preserve sans consent|
|V26|v::check_scope|Unread manifest and empty/absent record|Unchecked setup exits clean|refusal may exit 0 C|manifest Y; exit A|change|Unread manifest always nonclean; unrun case|
|A01|CORE/manifest/file.rs::parse_text|Bad/incompatible manifest schema|Wrong install intent|refuse C|Y|keep|K; no partial writes|
|A02|CORE/manifest/validate.rs|Unknown keys/bad declaration shapes|Ignored setting/wrong target|refuse C|Y|keep|K; catalog manifests upstream|
|A03|CORE/manifest/validate/items.rs|Bad name/rev/env/fork/plugin/dependency|Path escape/bad data/lost identity|refuse C|Y|keep|K|
|A04|CORE/engine/desired_source.rs::resolve_source|Unread/pending/absent source or item|Requested package not installed|skip/w; refresh may fail C|path/network Y; source A|change|U upstream absence; preserve safe copy|
|A05|CORE/source_read.rs::contained|Traversal/symlink/unsafe catalog entry|Host secrets copied|item refusal C|no: A; reject source|change|U: safe catalog reads|
|A06|CORE/source_read.rs::TREE_BOUND|File/tree/depth/count bound exceeded|Memory/traversal exhaustion|item refusal C|no: A|change|U: resource bounds stay|
|A07|CORE/engine/catalog.rs::Collisions|Distinct names collapse|Package replaces another|item refusal A/C|selection Y; names A|change|U names; own selection choices|
|A08|CORE/engine/item_plan.rs::rebound|Source rebind without fork|Wrong origin overwrites package|item refusal C|Y|keep|K|
|A09|CORE/engine/holds.rs::hold_rev_conflict|Incompatible dependency pins|Wrong dependency version|item refusal C|own pins Y; upstream A|change|No ambiguity; name pin owners; U clash|
|A10|CORE/engine/holds.rs::hold_local_edit|Edited artifact/unknown old hash|Refresh erases user work|item refusal C|Y|keep|K; honest unknown, fork/discard consent|
|A11|CORE/engine/file_plan.rs|Unowned target occupant|User content overwritten|item refusal C|Y|keep|K; deliberate adopt/preserve/remove|
|A12|CORE/engine/tree_plan.rs|Foreign link/bad shape/unreadable tree|Outside write/unknown content lost|item refusal C|layout Y; permissions O|keep|K; no blanket unknown-content delete|
|A13|CORE/engine/removal.rs::edit_holds|Remove edits/unreadable/required dependency|User work/judge lost|item hold C|edits Y; companion A|change|Data hold stays; U companion|
|A14|CORE/engine/deps.rs::withhold_requirers|Hook companion unavailable|Every tool call denied by wrapper|item withheld C|no: A|change|Withhold unsafe wrapper; U delivery proof|
|A15|CORE/engine/deps.rs::warn|Skill dependency missing/ambiguous|Skill lacks required tool/rule|w C|selection Y; source A|change|Route by declaration owner; U upstream|
|A16|CORE/engine/desired_kinds.rs::desired_hook|Bad hook event/header/payload/exclusion|Guard cannot deliver|refuse/exclude C|custom Y; source A|change|U delivery; intentional exclusion distinct|
|A17|CORE/engine/desired_custom_hooks.rs|Scoped custom hook becomes prose|Advisory mistaken for safety guard|w C|Y|keep|K; advisory not enforced safety|
|A18|CORE/engine/desired_agent.rs::render_or_refuse|Pi cannot express denied tool set|Agent gets unauthorized tools|item refusal C|override Y; source A|change|Never widen; U adapter, supported choices|
|A19|CORE/render/validate/mod.rs::segment_findings|Bad item name/loader grammar|Path escape/item not loaded|item refusal C|rename Y; source A|change|Containment stays; U names, own override|
|A20|CORE/render/validate/mod.rs::frontmatter_map|Bad/missing frontmatter|Harness cannot load item|item refusal C|no: A|change|U: required frontmatter|
|A21|ra::codex|Bad Codex fields/sandbox/model/effort|Agent unavailable/wrong permissions|item refusal C|override Y; adapter A|change|U: Codex contract; own override choices|
|A22|ra::opencode|Bad OpenCode mode/permission|Access rule cannot load|item refusal C|override Y; adapter A|change|U: invalid access contract|
|A23|ra::claude|Bad Claude agent name|Agent absent/wrong identity|item refusal C|no: A|change|U: source/render name|
|A24|ra::gemini|Bad Gemini metadata/model/effort|Agent absent/wrong selection|item refusal C|model Y; metadata A|change|U: loader metadata; own model choices|
|A25|ra::antigravity|Bad Antigravity metadata/tier|Agent cannot delegate|item refusal C|no: A|change|U: loader metadata/tier|
|A26|ra::copilot|Bad Copilot description/name|Agent absent/wrong name|item refusal C|no: A|change|U: loader description/name|
|A27|CORE/render/validate/skill.rs::findings|Missing skill/name/mismatch/long Codex description|Skill absent/wrong call name|item refusal C|rename partly; metadata A|change|U: loader naming/metadata; own rename|
|A28|CORE/render/validate/command.rs::gemini|Bad/missing Gemini command prompt/TOML|Command cannot load/run|item refusal C|no: A|change|U: emitted Gemini command|
|A29|CORE/render/validate/skill.rs::findings|Missing description/ignored syntax/key|Item cannot trigger or ignores behavior|w C|no: A|change|U source disclosure; advisory not strict|
|A30|CORE/engine/desired_mcp.rs::refusal|Bad MCP transport/env/literal secret|Connection fails/secret tracked|item refusal C|own Y; catalog A|change|Secret/transport stays; U catalog|
|A31|CORE/engine/desired_kinds.rs::desired_plugins|Unsupported plugin delivery/config|User thinks inactive plugin runs|item skip/refuse C|selection Y; adapter A|change|U adapter; supported choices|
|A32|CORE/engine/desired_command.rs::emitted_name|Fallback command names occupied|Callable replaced|item refusal C|Y|keep|K; emitted-name notice|
|A33|CORE/engine/settings_write.rs::settle|Settings target linked/bad shape/env|Foreign settings lost/keys ignored|item refuse/w C|Y|keep|K; preserve user values|
|A34|CORE/engine/settings_write.rs::declarations|Seed sensitivity conflicts|Secret enters public layer|refuse C|no: A|change|No secret write; U metadata|
|A35|CORE/engine/copilot.rs::agent_notices|Copilot disable/model/MCP policy|Installed item inactive|w C|personal Y; org O|keep|K; org policy to O|
|A36|CORE/engine/gemini.rs::overridden|Gemini system/enableAgents/server policy|Project item ineffective|w C|local Y; machine O|keep|K; project cannot override machine policy|
|A37|CORE/engine/antigravity.rs::hook|Matcher translation fails|Hook matches nothing|w C|no: A|change|U adapter; Gemini/Copilot too|
|A38|CORE/engine/scoring.rs::run|Safety scoring flags package|Risky/broad behavior undisclosed|w C|choice Y; source A|keep|K; score not enforced safety|
|A39|CLI/mod.rs::resolve_scopes_at|Ambiguous target/home-as-project/bad root|Install wrong scope|refuse caller|Y|keep|K; no silent scope fallback|
|A40|CLI/project.rs::registrable|Register temporary project|Fixture remains in real registry|refuse caller|Y|keep|K; own-catalog already isolated|
|A41|CLI/engine_common.rs::ask_before_writing|No write/noninteractive consent|Unapproved file change|refuse C/L|Y|keep|K|
|A42|rf::prepare_scopes|Refresh changes installed set|Unapproved additions/removals|refuse C|Y|keep|K|
|A43|CORE/apply/mod.rs::lock_scope|Concurrent scope writer|Interleaved corrupt install|refuse caller|wait/replan|keep|K; wait/replan, no manual shared lock clear|
|A44|CORE/apply/pre.rs::check|Inputs/targets/root changed|Concurrent work erased|refuse caller|Y|keep|K; replan after concurrent change|
|A45|CORE/apply/landing.rs::landed_within|Target outside canonical scope|Foreign files written|refuse caller|filesystem Y; path A|change|Containment stays; U generated path|
|A46|CORE/apply/transaction.rs::run_journaled|Write/rollback/recovery fails|Partial install/concurrent work loss|partial refusal C|disk O; engine A|change|Exact partial paths; E/U engine/admin|
|A47|CORE/engine/recovery.rs::plan_record_existing|Recovery cannot prove existing installs|False current ownership|refuse caller|local Y; main F|change|Exact equality; tracked recovery F|
|A48|CLI/repo_effects.rs::confirm|Effects lack separate consent|Repo code changes gates/settings unapproved|skip effects C|Y|keep|K|
|A49|CORE/bot_instructions.rs::protocol_error|Renderer fails/bad output paths|Ownership/commit offer includes foreign files|post-write nonzero C|no: A|change|No foreign path; U protocol; post-write stated|
|A50|rf::record_snapshots|Snapshot/trash pass fails|Future comparison absent/old trash left|w C|disk O; derivation A|keep|K; bookkeeping not rollback|
|A51|rf::run|Sync/source/Pi proof failure aggregate|Partial refresh called complete|nonzero C|network Y; upstream A|change|Exact partial state; U safe upstream skips|
|A52|CLI/commit_offer.rs::hold|Unarmed/stale/unvouched commit package|Commit skips checks/uses old policy|selected refusal C|setup O; source A|change|Consent/action gap; U package; reviewed route|
|A53|CORE/commit_offer/mod.rs::Unavailable|Remote/gh/PR route unavailable|Push wrong repo/bypass rules|choice unavailable C|route Y; auth O|keep|K; local install/leave available|
|A54|CLI/commit_offer.rs::refused|Chosen commit/push/PR fails/times out|Requested action incomplete|nonzero C|message/route Y; gate O/A|change|Partial install/action gap; E/U gate outage|
|A55|CLI/project.rs::register_target|Registry fails after install|Installed project absent from app|post-write error C|registry Y; core A|change|Partial registry outcome; U core|
|A56|CLI/updates_cmd.rs::run_with|Apply with mute/unmute/bad selection|Wrong scope/action|refuse C|Y|keep|K|
|A57|CLI/update_pi.rs::install_rows|Duplicate package/origin across scopes|Double registration/wrong origin|update refusal C|Y|keep|K; no foreign shadow deletion|
|A58|CORE/pi_ext/mod.rs|Bad Pi metadata/path/bin/source|Wrong code/path escape|refuse C|local Y; catalog A|change|Containment stays; U catalog|
|A59|CORE/pi_ext/mod.rs::npm_install|npm/settings/foreign bin failure|Incomplete extension/user files lost|post-copy refusal C|local Y; shipped build A|change|No foreign overwrite; E/U build|
|A60|CORE/pi_ext/mod.rs::link_bins|Declared executable not shipped|Installed command unavailable|w C|no: A publisher|change|U publisher; no consumer build demand|
|A61|up::run_on_with_source|Managed/sidecar/unknown updater owner|Other manager's install overwritten|notice/refuse C|own updater; unknown O|keep|K; no privileged overwrite advice|
|A62|CORE/update_feed.rs::validate|Bad/large/untrusted update feed|Wrong/untrusted release installed|refuse C|no: A publisher|change|No unverified update; U feed|
|A63|up::VersionRelation|Downgrade without supported force|Rollback loses behavior/compatibility|refuse C|Y|keep|K|
|A64|up::install_main_fallback|No target artifact/signed main identity|False release/build identity|notice/refuse C|build O; asset A|change|Auth stays; E/U asset, no assumed local build|
|A65|CORE/release_digests.rs::verify_command|Signature/identity/digest mismatch|Tampered/wrong app installed|refuse C|no: A publisher|change|Trust stays; U publisher incident, no bypass|
|A66|up::command_failure|App/CLI replacement fails|Halves disagree/update incomplete|refuse C|own writable Y; foreign O|change|Partial state/retry; install-owner permissions|
|A67|up::record_command_on|Cannot record command path|Desktop cannot later update CLI|w C|path/permission Y; core A|keep|K; current update continues|
|A68|rf::run|Planned marked-lane mutation refusal|Shared install enters item branch|planned b L|authorized route; base F|change|KEN-2299 planned: shared writes/authority only|
|A69|T/harness-smoke::BUILD_INPUTS|Installed commit lacks renderer proof|Live smoke blames another build|refuse proof O|rebuild Y; lane authority varies|keep|K; KEN-2127 ancestry/build inputs, allow-stale|
|A70|T/harness-smoke::refuse|Smoke runtime/repo/fixture/coverage absent|Proof with nothing exercised|unexercised/refuse O|host O; coverage A|keep|K; failed != unanswered, no lane mutation|
|A71|ce|Planned major bump lacks Breaking note|Incompatible release lacks migration|planned b A release|Y|keep|K planned; KEN-2309, consent not extra gate|
|A72|CORE/engine/takeover.rs::refuse_unsettled_takeover|Takeover matches nothing/unsettled position|Old/foreign copy wins after claimed takeover|refuse C|Y|keep|K|
|A73|CORE/apply/op.rs::refuse_unless_ignored|Credential path not ignored|Secret committed|refuse C|Y|keep|K|
|A74|CORE/apply/op.rs::refuse_unless_ignored|Git ignore query unreadable|Unverified secret exposure|refuse C/L|no: O|change|No private write; E query != unignored path|
|A75|CORE/lock/file.rs::parse_versioned|Corrupt/old/too-new install record|Mutation ownership unknown|refuse C/L write|local recovery; main F|change|No unsafe write; compatible recovery at owner|
|A76|CORE/lock/roots.rs::read_against|Absolute/empty/traversing record path|Other checkout overwritten/deleted|refuse C/L write|no: A/F|change|Containment stays; U producer/F recovery|
|A77|CORE/lock/file.rs::machine_state|Incompatible/corrupt machine cache|Optional cache wrongly blocks install|cache absent C|no fix needed|keep|K; durable refusal A75|
|A78|CORE/lock/file.rs::machine_state|Machine cache read fails|Delivery/cache unknown|read error refuses C/L|no: O|change|E cache; retain record, no unread overwrite|
|A79|CORE/engine/posture.rs::ignores_committed|gitignore hides setup/record|Teammate clone misses setup|w C|repo O|keep|K; preserve foreign ignores sans consent|
|A80|CORE/engine/posture.rs::plan_posture|info/exclude hides render|Changed render never committed|w clone O|Y|keep|K; local remedy, pull cannot fix|
|A81|CORE/engine/posture.rs::managed_block|Bad managed ignore delimiters|Ambiguous user ignore content overwritten|refuse C|Y|keep|K|
|A82|CLI/update_pi.rs::settleable; CORE/pi_ext/record.rs::record_matching; CLI/engine_common.rs::refresh_failures|npm-dependent stale Pi package in global refresh|Fetched lifecycle code must not execute on refresh consent|nonzero C/timer|update-pi Y; refresh cannot settle|change|KEN-2330: notice/update-pi; refresh no npm. Other failures stay|
|X01|OR/dev-validate-run::DEV_VALIDATE_CMD|Bad/absent validation command/dependency|Completion falsely claims checks|refuse L|input Y; config O|change|No pass; E config, no substitute command|
|X02|OR/dev-validate-run::state=lost|Runner killed/lost/timeout/bad receipt|Incomplete validation called complete|hold L|no: O|change|No pass; E/no-verdict; KEN-1981 cost/bound|
|X03|T/catalog-release-check|Release strict catalog escalation|Unusable package ships|b A release|Y|change|I18/I22/I24 breakage; advisory escalation I19|
|X04|T/release-installer-check::missing|Missing/ambiguous installer/command|App-only/wrong build installed|b A release|Y|keep|K|
|X05|T/release-installer-check::signature|Bad/absent signed macOS sidecar signature|Notarized app cannot run command|b O release|Y|keep|K; unsigned notice not signed proof|
|X06|T/release-installer-check.ps1|Windows install/uninstall/PATH test fails|CLI unusable/unwanted PATH left|b O release|Y|keep|K; Linux unexercised|
|X07|T/release-installer-check::tool|Missing installer proof tooling|Behavior unknown|b L release|no: O|change|No release attestation; E native tools|
|X08|T/release-channel-point::pointer-version|Bad feed/version/build/signature|Channel mixes wrong/untrusted release|b A publisher|Y|keep|K|
|X09|T/release-channel-point::hold|Candidate not newer|Channel downgrades|notice/no write A|Y|keep|K|
|X10|T/release-channel-point::releases|Release read/pointer upload fails|Channel partial/unknown|b O publisher|Y|keep|K; partial/no-write, not source failure|
|X11|T/check-aur-sync::require_fields|Recipe/source-info/parser mismatch|Arch wrong version/deps/missing patch|b A packaging|Y|keep|K|
|X12|T/check-aur-sync::AUR_REMOTE|Remote AUR mismatch/unreadable|Users get unreviewed recipe|b O publisher|publish O; network O|keep|K; local run not published proof|
|X13|lr|Main refresh verify/record landing fails|False committed attestation|b F|Y|keep|K; D007, lane mutations unrun|
|X14|lr::dirty|Dirty default checkout|Refresh loses pending work/records wrong tree|refuse F|Y|keep|K|
|X15|W/lock-record.yml::The app credentials are set|Record job lacks app secrets|Green job leaves main stale|b F job/L|no: O|change|E credentials; no fake pass|
|X16|lr::arm|Pushed head not visible|Older head armed|w; exit 0 unarmed F|later F/O retry|keep|K; already pushed/unarmed, not rollback|
|X17|lr::head-read|PR head unreadable|Unknown head armed|nonzero F/O|retry/auth O|keep|K; no arm, already pushed|
|X18|pn::guard off-main|Bad/missing/off-main tag|Wrong/unreviewed release published|refuse A release|Y|keep|K|
|X19|pn::guard name|Tag/package/name/version mismatch|Wrong package/version downloaded|refuse A release|Y|keep|K|
|X20|pn::guard moved|Tagged tree differs from publish tree|Provenance names wrong bytes|refuse A release|Y|keep|K; tree not version alone|
|X21|pn::guard npm|Old npm/scratch unavailable|Authentication/proof unexercised|refuse L publish|no: O|change|No publish; E runtime/scratch|
|X22|pn::guard first-release|First package publish required|Trusted publisher cannot initialize|refuse A/L release|no: npm O|change|npm admin initialization, not version fix|
|X23|pn::guard lookup|Registry error other than E404|Unknown treated absent/duplicate publish|refuse O|Y|keep|K|
|X24|pn::guard served|Exact version already served|Immutable duplicate publish|notice; exit 0 A|no fix needed|keep|K|
|X25|pn::unconfirmed|Publish succeeds, serving unconfirmed|Availability falsely claimed/retry duplicates|post-publish nonzero O|confirmation O|keep|K; possible-write, no rollback/no-write claim|
|X26|pn::publish|Extract/build/prepack/publish fails|Wrong/incomplete package or unavailable publish|nonzero A/L|build A; host/service O|change|Partial npm; E vs source build|
|X27|T/publish-homebrew::placeholder guard|Homebrew zero pin|Invalid download offered|w; defer recipe A|Y|keep|K; all-deferred no clone|
|X28|W/publish-homebrew.yml::The tap credentials are set|Tap app/PUBLISH_TOKEN absent|Stale tap under green publish|refuse L job|no: O|change|E credentials, not recipe|
|X29|T/publish-homebrew::clone|Tap clone/commit/push fails|Recipe not delivered|nonzero O publisher|auth/service O|change|E service, no source-edit advice|
|X30|W/publish-aur.yml::AUR_SSH_KNOWN_HOSTS|Missing SSH secret/host trust|Untrusted host/no authentication|refuse L job|no: O|change|No guessed trust; E credentials|
|X31|pa::check_key|Bad/unregistered key/account/login unknown|Wrong/unknown identity publishes|refuse O publisher|Y|keep|K; unknown != rejected login|
|X32|pa::sources_current|AUR placeholder/absent asset/bad checksum|Recipe download invalid|w; defer package A|Y|keep|K; defer != published, others proceed|
|X33|pa::unreachable|Request/read/checksum tool unknown|Network treated pending, publication stale|nonzero O publisher|no source fix; O|change|Unknown/no readiness; E host/service|
|X34|pa::publish_one|Partial AUR clone/push/compare failure|Some recipes stale/wrong published bytes|partial nonzero O|service O; recipe A|change|Partial subset/continue/verify; E vs recipe|
|X35|rel::Stage macOS signing environment|Partial Apple secrets|Signed unnotarized app cannot run|refuse L release|no: O|change|O signing admission; all absent unsigned|
|X36|rel::Stage the command for the bundle|Unsupported command overlay runner|CLI absent/wrong sidecar|refuse A release|Y|keep|K|
|X37|rel::Classify the tag|Built version/tag/run/commit mismatch|Release misidentifies source|refuse A/O release|Y|keep|K|
|X38|rel::Write the signed update manifest|Required signed platform asset absent|Feed offers nonexistent download|refuse A/O release|Y|keep|K|
|X39|RG/dispatch-refresh.sh::installation-read|Installation enumeration fails/empty|Dispatch falsely complete|nonzero L/job|no: O|change|E enumeration; failed read != empty|
|X40|RG/dispatch-refresh.sh::refresh-error=dispatch|Some repository dispatches fail|Some consumers miss refresh|partial nonzero O|no C; O|change|Partial repo retry; D007 exclusion stays|
|X41|skills/linear/scripts/lib/common.sh::linear_require_team_target/::linear_guard_write_action/::graphql_query; skills/linear/scripts/commands/comments.sh|Existing-issue write, e.g. comments create, with no LINEAR_TEAM|none|refuse C/L before API|team config possible but unnecessary|remove|Delete issue-addressed team refusal in dispatcher/wire only|
|X42|skills/linear/scripts/lib/common.sh::linear_require_team_target; skills/linear/scripts/commands/issues.sh, projects.sh, cycles.sh, labels.sh create|Named team-scoped issues/projects/cycles/labels create without target|Guessed team sends new object to wrong project tracker|refuse C/L|Y: own LINEAR_TEAM or --team|keep|K; explicit team on named creates, not X41|

## Owner evidence

- X41: owner note 1790807555 reports issue-addressed `linear.sh comments create` refusing `No Linear team configured` without LINEAR_TEAM. Directive 1790807880-3255129-1763 removes only this refusal. X42 preserves named team-scoped creates. Dispatcher/wire repeat the gate.
- A82/KEN-2330: owner note 1790809446 reports kendex 1.3.0 `refresh --global --yes` exit 1 for pi-claude-bridge, pi-codex-minimal-tools and pi-web-tools. The timer never reaches update-pi. Directive 1790809600-3921083-27997 requires notice/update-pi, not npm install in refresh. This is owner evidence, not lane measurement. settleable excludes dependencies to avoid fetched lifecycle scripts; record_matching emits Stale/update-pi detail; refresh_failures counts nonorphan Pi drift. This change verdict excludes unreadable, duplicate/origin/edit/trust and other install failures.

## Lane size-gate evidence

P14: exit 3 for report-only `0 production lines; one audit report, then change and remove items` and authorized `0 lines`. DELTA_GRAMMAR rejects zero. Parent removes optional Expected delta; allowance_missing passes. No inflated allowance; zero production contract stays. KEN-2319 recurrence reported by parent. Evidence: `tmp/KEN-2320-preflight-ask.md`, `tmp/KEN-2320-zero-delta-ask.md`.

## Own-check evidence

No audit reruns. Log keys expand to `tmp/KEN-2320-<key>.log`; logs retain UTC date/revision/command, manifests exit/cwd/environment. Green does not prove omitted coverage. G35/V26 are unplanted source-read cases.

|Command|Exit|Result; log key; verdict|
|---|---|---|
|`tools/guard --full`|0|Workspace/UI/cross-target pass; Bash 3.2 container, not native macOS/Windows. guard-full; G01-G34.|
|`kendex verify --strict`|1|222 checked, 174 OK, 48 stale/sourceHash mismatches; engineer gap. No ignored-output failure. verify-strict; V02/V03/V11 change, F repair under D007. PATH version `1.2.0+main.498.56b28ff4d377dc4b2295710d74a06dad125d7017`: binary-version.|
|`cargo build --release --locked -p kendex-cli`|0|Catalog build. catalog-build; I18.|
|`target/release/kendex check --catalog . --strict`|0|63 packages; breakage/advisory/safety all 0. No live/installed-layout link proof. catalog-strict; I18/I19/C17/C30.|
|`cargo test -p kendex-cli --test cli_smoke -- --nocapture`, KENDEX_CLI_SMOKE=1|0|Isolated Codex/Copilot proof/inverse controls. 5 uncovered: OpenCode/Gemini absent, Claude/Pi/Cursor no offline reader. cli-smoke; I20 change.|
|`skills/doc-limits/scripts/doc-limits --staged`, original report|1|96641 bytes vs 65536, no content defect. audit-report-cap; D01 change. Prior exclusion unauthorized, now removed; single report compressed.|

verify-strict names each stale package/harness. D007 assigns record repair to F. Unmanaged notices are not failures. Catalog/smoke use checkout-built CLI.

### Workflow commands

- `tmp/KEN-2320-workflow-results.json`: 339 commands, all exit 0. `tmp/KEN-2320-platform-results.json`: 29, 22 exit 0, 7 nonzero/incomplete. `tmp/KEN-2320-inline-results.json`: 3, all exit 0.
- Loops/shard filters/inline checks stay unchanged; cargo keeps locked/no-fail-fast/conditions. Passing commands remain in manifests; ceremony passing does not justify keep.

Every nonzero workflow result maps to G30/I21 change:

|Command; cwd under pi-extensions/|Exit|Diagnostic; log key|
|---|---|---|
|`npm test`; pi-caveman|1|tsx absent; platform-13.|
|`npm run typecheck`; pi-codex-minimal-tools|127|tsc absent; platform-14.|
|`npm test`; pi-codex-minimal-tools|127|tsx absent; platform-15.|
|`npm test`; pi-extension-manager|1|Mock child 143 after own timeout. Bun 1.4.2 vs workflow 1.3.14; platform-16.|
|`npm test`; pi-skills-manager|1|Pi SDK peers absent; platform-24.|
|`npm test`; pi-tool-renderer|1|Pi SDK peers absent; platform-26.|
|`npm test`; pi-web-tools|127|tsx absent; platform-27.|

Missing dependencies are unexercised environment. Bootstrap fails locally, cause unresolved; runtime owner judges before filing. No rerun/timer change.

### Unexercised and validation

- `tmp/KEN-2320-not-exercised.json` retains command/date/revision/null exit/category/diagnostic/rows. Native platforms unavailable; live harness/writer/incidents/preparation/record writes unauthorized, no provided fixture. No fabricated CI result.
- No shared UI reinstall or Pi peer/build install. Bridge bundle comparison exits 0 without clean-lock rebuild, so I16 is not proved. pi-hooks dependency-installing test is not read-only exercised.
- No worktree/base refresh/apply/update, lock change or worktree TMPDIR. Existing smoke uses authorized isolated home, not lane bypass.
- Report-only branch restores pre-audit exclusions. Installed preflight/doc-limits and dev-validate-run validate this fix; artifact records result/bytes and corrects prior exception claim. Historical evidence stays.
- Parent files unbound scopes; C reports upstream via kendex report, not render edits. KEN-1981 receives harm, not another cost audit.
