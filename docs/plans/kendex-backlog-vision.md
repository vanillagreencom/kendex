# Kendex backlog vision and active-issue audit

This plan records the audit KEN-1916 asked for: every nonterminal KEN issue judged once, the end-to-end vision each area serves, the issue that owns each piece of it, and the code duplication the audit verified with the issue that removes it. Tracker facts are as of 2026-09-27. Code facts are verified against the kendex tree at commit fa2c538d. The tracker corrections the audit applied are already live in Linear; this file is the record a reader consults before picking work.

Read this file before selecting implementation work from the KEN backlog. Pick from the ranked areas in § Owner ranking. Do not reopen a canceled issue named here without a new symptom.

## Scope and method

- The active set was every KEN issue in Triage, Backlog, Todo, In Progress and In Review on 2026-09-27: 126 issues (86 Backlog, 22 Triage, 9 In Progress, 7 In Review, 2 Todo).
- The audit ran the project-management audit workflow twice: a team-mode TPM run over the 104 Backlog, Todo, In Progress and In Review issues, and an issue-mode run over the 22 Triage issues. Both compared titles and bodies against the 1890-row comparison set of Done and Canceled issues.
- The comparison read comments for all 104 team-mode issues from the Linear cache in one pass.
- A separate code scout verified six duplication leads against the source tree and its tests. Its verdicts are in § Code and package duplication.
- The overseer applied the resulting tracker changes under `PM_CREATE_AUTONOMY=auto`. Live fleet lanes and owner-held items were excluded from cancellation. Pending owner decisions were treated as not approved.
- A Codex second opinion was unavailable on the audit host. It is recorded and was not waited on.

## Owner ranking

The owner ranked the work on 2026-09-27. Every disposition below was judged under this order. Live lanes are the overseer's to end; the audit never cancels one.

1. **Control plane**: KEN-1661 (In Review, PR #2961 needs a rebase), KEN-1921 (live lane), KEN-1925 (after KEN-1921), KEN-1931 (after KEN-1661 merges).
2. **Copilot**: KEN-1934 container with KEN-1935 (live lane), KEN-1936 (after KEN-1935) and KEN-1937 (live lane). KEN-1779 propagation delivery sits here under an owner reporting hold. KEN-1930 rollout is Done.
3. **Code-quality diet**: KEN-1899 is Done. KEN-1903, KEN-1904, KEN-1905 and KEN-1822 are Canceled, folded into it. No active issue remains in the area.
4. **CI and tests**: KEN-1922 (live lane) then KEN-1928 and KEN-1923; KEN-1932 (live lane); KEN-1902 (live lane); the test diet KEN-1820 with KEN-1826 and KEN-1827; the consumer rollout KEN-1906, whose next child KEN-1908 waits on KEN-1922.
5. **Owner channel and T3**: KEN-1843 container, then KEN-1844, KEN-1845, KEN-1848 and KEN-1931.

Four P1 rulings predate the ranking and were re-judged under it:

| Issue | Before | Ruling | Reason |
|---|---|---|---|
| KEN-787 | In Review, P1 | keep, P2, owner-held | The remaining steps are owner channel steps after KEN-1719 and KEN-1720: publish the AUR package, verify channels, delete v5.0.1. Outside ranks 1 to 5. |
| KEN-1765 | In Review, P1 | keep, P1 | The default class policy sits behind the KEN-1779 delivery chain in rank 2. PR #2884 needs a rebase. |
| KEN-1504 | Backlog, P1 | keep, P2 | Headroom weighting in `lanes pick` is outside ranks 1 to 5 and waits on the owner-held PR #2801 (KEN-1493). |
| KEN-1659 | Backlog, P1, container | keep, P1 container | Rank 1 owns KEN-1661 only. KEN-1659 keeps P1 as its parent and now also parents KEN-1921 and KEN-1925. Its remaining children run after KEN-1661 lands. |

## Vision and owning issues by area

Each area states the end state the open issues build toward, then the issues that own it. Issue counts per area are in § Dispositions.

### Orch control plane

End state: one lane-to-overseer protocol. A lane's state is read from harness signals, records, files and commands, never from a terminal pane. A lane hands off before it runs out of context, records what it started, and stops it at close. The overseer succeeds itself through the same records.

- **Handoff and succession**: KEN-1661 hands a lane off at 400000 used tokens or before the compaction safety limit. The owner rule of 2026-09-27 binds it: read harness, account, model and effort from the fleet launch record; read token and context use from the exact owned harness files through the adapter (the Codex rollout under `CODEX_HOME`, the Claude transcript); use status-line judgment only as a documented fallback. The compaction-risk hold stands. KEN-1921 records the current overseer's launch identity. KEN-1925 binds the exact native transcript to the overseer session. KEN-1931 routes overseer inspection and succession through the shared adapter and unblocks the T3 host. KEN-1939 duplicates part of KEN-1661's branch and is held (§ Proposals relayed to the owner). KEN-1940 gives `oversee-succeed` the successor brief as an option once KEN-1931 settles its home.
- **Separate headroom mechanisms**: KEN-1504 (account ordering and last-resort weighting), KEN-1623 (durable handoff reserve), KEN-1885 (Done: overseer headroom 5 percent, wall notice 20 minutes), KEN-1895 (Canceled, § Owner directions), KEN-1661 (token and compaction floor) and KEN-1902 (post-green parking) are six mechanisms by owner direction. None is combined with another on a shared threshold. KEN-1570 keeps the overseer handoff a current snapshot with a bounded resume.
- **Launch**: KEN-1653 sizes the model by the cycle with a per-harness model floor and absorbs KEN-1559 by scope: KEN-1653 now carries the requirement that a successor launch with no model and no effort is refused, recorded on the issue with a reconciliation note of 2026-09-27. No such refusal exists today. `launch_choice_write` in `skills/orch/scripts/lib/lane-launch.sh` returns empty with status 0 for an empty model, a contract the caller-entry branch of `oversee-succeed` relies on, so KEN-1653 sites the refusal where `oversee-succeed` assembles a successor's flags, not inside the writer. KEN-1527 decides resume or fresh brief in one function. KEN-1534 sends a wake through the provider; its Done-when is reworded to the event judge when KEN-1659 files the typed-events child. KEN-1861 adds `open-terminal --class`, the shippable slice KEN-1553 then trims to the setting and label source after KEN-1902 merges. KEN-1927 uses shipped bypass defaults without duplicate launcher flags. KEN-1489 names the overseer stance in one key and waits on KEN-1493.
- **Watch routes**: KEN-1649 gives the watch the usage-limit route. KEN-1654 runs the dead-overseer relaunch proof on the control VM after PR #2961 merges. KEN-1538 lets an overseer hold a running lane's merge through the mailbox. KEN-1546 carries peer mail through the provider. KEN-1682 leads every human-read text with the owner's time zone. KEN-1525 reads harness processes without `/proc` and skips other users. KEN-1738 measures the lane-mail wait by a counter.
- **Close**: the KEN-1873 owner update splits into two owned issues. KEN-1511 records what a lane starts outside its process tree and stops it by launch identity. KEN-1811 closes a local lane whose close-out removed its worktree, with the order fixed: end the harness, then remove the worktree.
- **Parking**: KEN-1902 parks hosted lanes during green merge waits under the owner park rule (§ Owner directions). Its stop-sandbox and start verbs supersede the stop/start half of KEN-1553.
- **Validation and job units**: KEN-1806, KEN-1809 and KEN-1857 fix `dev-validate-run` ranges, run directories and lane selection for skill-markdown diffs. KEN-1858 gives `job-unit.sh` a synchronous `--wait` mode so the control VM's `fleet-run` can drop its own runner copy. KEN-1808 holds hook scripts across a paused restack. KEN-1863 and KEN-1864 fix `branch-size-check` grammar and the micro workflow's class admission.
- **Package audit**: KEN-1496 audits the orch package last, after KEN-1511, KEN-1504 and KEN-1489 land. Its scope is distinct from this audit and is preserved.

### Orch merge route

End state: one merge path (decision D003). A PR is armed for auto-merge at creation, waits on the queue, and every red check is named with whether the base branch requires it.

- KEN-1581 arms auto-merge right after PR creation. KEN-1676 gives `ci-wait` and `pr-merge` one red-check reader and removes the inline copies § Code and package duplication names. KEN-1853 makes `queue-wait` read progress from an armed PR awaiting required checks, not only from a merge-group head.

### Review gate

End state: every adopting repository runs one review policy, on by default, with change classes named by the evidence they need.

- KEN-1765 turns the class policy on by default (blocked by KEN-1779, PR #2884 needs a rebase). KEN-1766 names classes by review evidence and waits on KEN-1765. KEN-1874 fails the whole writer pass on a policy-unmeasured class. KEN-1852 ends the stale `action_required` a Copilot-submitted review leaves in the writer. KEN-1562 needs owner evidence for kendex-web's gate reaching SUCCESS only by timeout.

### Harness CI and CI

End state: one change-class action decides which CI lanes run, a docs-only diff runs no lane, and a tree a passing run already tested is not tested again.

- KEN-1922 (live lane, PR #3004 open) makes the change-class action own the lanes verdict and blocks the consumer rollout. KEN-1928 has each lane declare the paths it reads. KEN-1923 stands lanes down on a tree a passing run already tested. KEN-1929 names high-risk paths that always classify standard. KEN-1924 moves the catalog check and CLI round trip under the CI aggregate. KEN-1807 needs a decider entry or the needs-research label before pickup. KEN-1680 brings the macOS render-lint leg under the ten-minute ceiling. KEN-1692 stays In Review until the hosted negative-setup proof completes. KEN-1502 runs harness-smoke live rows on claude, codex and pi; Copilot rows belong to KEN-1937. KEN-1735 isolates the homebrew publish test from the host git configuration; its file is `tools/tests/publish-homebrew.test.sh`.

### Linear

End state: the workflow scripts read the cache in one process per question and print one format per result type.

- KEN-1932 (live lane) reads cached comparison comments for many issues in one process; its completion summary is posted and the change is not on main yet. KEN-1900 defines output formats per result type and accepts ids on issue workflow actions.

### Code quality, preflight and commit guards

End state: the code-quality skill states each rule once, and the guards that enforce the rules read parsed shell syntax rather than word scans.

- The code-quality guidance diet is complete: KEN-1899 Done, KEN-1903, KEN-1904, KEN-1905 and KEN-1822 Canceled into it. KEN-1897 declares sourced shell fragments in preflight. KEN-1668 reads a backslash continuation as one logical line. KEN-1919 stops preflight judging an unquoted `.md` argument a citation. KEN-1898 reads the commit and its bypass flags from parsed shell syntax in the pre-commit check. KEN-1288 fixes `git-diff-summary` scoping of a root-level `tests/` directory. KEN-1702 is canceled: the one BSD-argv slip was fixed in its own PR and the macOS shard already catches a new one.

### Tests program

End state: the orch test battery reads time through a virtual clock, runs launches as table rows, and keeps every suite file at or under 64 KB.

- KEN-1820 is the container. Families A, B and C (KEN-1823, KEN-1824, KEN-1825) are Done. KEN-1826 (family D, virtual clock and table-driven launches) is ready. KEN-1827 (family E, file size) follows it; seven files under `skills/orch/tests/` stand over 64 KB at fa2c538d, `lib/lane-host-ssh-tests.py` among them. KEN-1856 fixes the rendered workflow-state suite reading hooks from a path that does not exist.

### Propagation

End state: consumers pull kendex renders through a workflow shipped in the render, on a rolling branch with one rolling PR and auto-merge. The consumer train, its manual steps and `ORCH_CONSUMER_REPOS` are retired.

- KEN-1779 (live lane, P1, owner reporting hold) owns delivery; the D007 lock-record exclusion was folded into it on 2026-09-27. KEN-1563 cancels once KEN-1779 stage 2 retires `skills/orch/workflows/consumer-train.md` on main; the file is still tracked at fa2c538d. KEN-1688's reader of the consumer list changes with the same retirement.
- Rendered copies under `.agents/`, `.claude/`, `.codex/`, `.pi/` and consumer repositories are generated outputs of `skills/`, `hooks/` and `agents/`. They are never removable duplication.

### Slack and owner channel

End state: the overseer mailbox is the owner channel, with typed fields and one resolve, and one package relays a mailbox to one private Slack channel by polling.

- KEN-1843 is the Todo container (rank 5). KEN-1844 [K2] ships the typed mailbox fields; it was In Review with PR #2963 at the audit read and merged to main as ac62981e afterwards. KEN-1845 [K1] is the Slack relay package and waits on KEN-1844.

### T3

End state: a T3 overseer host with a durable delivery position, a state reader and a release contract test.

- KEN-1848 [K-T3-2] owns it, blocked by KEN-1931 and the fleet item F-T3-1.

### Copilot

End state: Copilot is a first-class local and fleet harness with working coordination, recovery and succession.

- KEN-1934 is the container (rank 2). KEN-1935 (live lane) launches the first Copilot lane with working coordination. KEN-1936 recovers and succeeds Copilot overseer sessions after KEN-1935. KEN-1937 (live lane) proves package compatibility; by the overseer ruling of 2026-09-27 it ships one PR under Refs and the issue stays open. The Agent Harness Integrations project is now blocked by Skills & Agents Library because the Copilot children consume KEN-1661, KEN-1921, KEN-1925 and KEN-1931.

### CLI terminal design

End state: one terminal design system (colour tokens, symbols, spacing, keyed choices and links) and every verb's output built from it. Every error, conflict or choice is one guided decision, the same in the CLI and the app.

- KEN-1724 is the owner-held container with its Sub-Issues list rebuilt; every child ships behind the owner pilot approval. KEN-1887, KEN-1888, KEN-1890 and KEN-1893 are ready. KEN-1891 and KEN-1892 follow KEN-1888. KEN-1889 renders KEN-1723 decisions and waits on a core Attention and Choice child of KEN-1723 that is not filed yet; file it at the plan gate. KEN-1723 holds the guided-decision design; KEN-1590 is its Pi update prompt child.

### Consumer rollout

End state: nine consumer repositories run CI and merge rules under one aggregate CI check per the D003 standard.

- KEN-1906 is the owner-gated container, blocked by KEN-1922. KEN-1907 is Done as vgs PR 422. KEN-1908 (vsys) is next; KEN-1909 (kendex-web), KEN-1910 (review-gate-sandbox), KEN-1911 (vg), KEN-1912 (hyprtrade-io), KEN-1913 (hyprtrade), KEN-1914 (drovr) and KEN-1915 (memsira) follow. VGS cannot read the KEN team; the primary proxies its tracker writes. The work is not duplicated under another team.

### CLI and core

End state: every refusal is typed, every settings comment block is a plain explainer, and a no-op refresh costs one hash per tree.

- KEN-1493 (In Review, PR #2801 owner-held, raised to P2) rewrites settings comment blocks and is the only open blocker of KEN-1504 and KEN-1489. KEN-1729 reports orphan comment blocks. KEN-1688 lets a settings key declare same-everywhere or project-own. KEN-1722 (live lane, PR #2971 merged) stays In Review for the owner's manual vgs v2 validation. KEN-1818 relays the D003 standard check per row in `kendex check`, widened to every row unreadable under the credential in use. KEN-1866 keeps a hook another tool still requests when the edited-orphan remedy removes it. KEN-1926 recovers a version 10 lock in one command. KEN-1859 and KEN-1860 (relabeled agent:rust, bug) remove per-package and per-harness re-hashing (§ Code and package duplication). KEN-1272, KEN-1273, KEN-1696, KEN-1711, KEN-1879 and KEN-1636 are P3 and P4 defects that pass the creation bar as filed. KEN-1277 (moved to CLI & Distribution) has all 22 children Done or Canceled and waits only on the owner design approval after 1.0.0. KEN-1783 is canceled: KEN-1832 shipped the in-place contract (`docs/architecture/in-place.md`).

### Pi extensions and hooks

- KEN-1658 (In Progress, moved to Agent Harness Integrations) builds the Pi Codex bridge; no PR and no lane artifact were found on the audit host, so the overseer decides the stale marker. KEN-1622 reuses the Codex account through one refresh authority after it. KEN-1519 and KEN-1801 are Pi panel and prompt-stash defects. KEN-1482 (ready) makes the owned-verb-check hook refuse bare git and gh writes at command position. KEN-1774 is canceled: KEN-1832 changed `hooks/block-worktree-refresh.sh` so help forms pass and the refusal names `--project-path` only where listed.

### Release, docs and skill tooling

- KEN-787 (P2, owner-held) removes the 5.0.1 release once the owner runs the channel steps. KEN-1567 (doc-limits excludes row), KEN-1568 (docs-writing enumeration rule, moved to Skills & Agents Library), KEN-1854 and KEN-1855 (decider record bar and Retired status, a deliberate split across two tools) and KEN-1736 (second-opinion codex exit; main already classifies it as `EXIT_CLI_FAILED=5`, so the body narrows to the round count and the stderr-after-prompt case) stay. KEN-1916 is this audit; it closes when this file merges.

## Owner directions

The directions the owner gave during the audit window, as applied.

- **KEN-1661** (rule 1790459908): succession prefers records, files or commands over panes. Harness, account, model and effort come from the fleet launch record. Token and context use come from exact owned harness files through the adapter. Status-line judgment is a documented fallback only. The compaction-risk hold remains. A pending decision is not approval.
- **KEN-1885** (Done): overseer headroom 5 percent, wall notice 20 minutes. KEN-1504, KEN-1623, KEN-1885, KEN-1895, KEN-1661 and KEN-1902 are separate mechanisms and are never combined on shared thresholds.
- **KEN-1902** park rule: park only at exact head with all required checks green, the gate met and zero open threads. Never park while CI or gate checks wait after a push. Parked lanes keep ownership and PR watch records and do not count against launch capacity. The trial measures event-to-first-action and missed events over one day. The round 2 completion summary of 2026-09-27 adds stop-sandbox and start verbs to the lane-host protocol.
- **KEN-1886** (Done): proposal sweeps run by a local overseer subagent, with no state change during the sweep.
- **KEN-1906** and children KEN-1907 to KEN-1915: nine real independent consumer deliveries. KEN-1907 is Done. The work is not duplicated under another team.
- **KEN-1895** (directive OWNER1790460199): the audit found no concrete case of a memory mark firing before the KEN-1661 handoff. Fleet readings of 1005 MB root RSS and 1950M slice anonymous memory sit below the 1300 MB and 2100M marks. The issue was Canceled on 2026-09-26 by the audit outcome comment. Commit 174b400a on branch ken-1895 is preserved: never pushed, merged or discarded. Nothing further is due.
- **KEN-1894** (Done): Codex shell approval rules are described per launch mode.
- **KEN-1873** (Done, merged as fa2c538d in PR #2962): the merged fix narrowed to the stale-wall judge, and the hosted stop returned to its standing-worktree contract; the removed-worktree cwd match was dropped in review. The owner update says close and stop act on launch identity (process, pane, sandbox), never on the current directory, and the harness ends before the worktree is removed. Verdict: the order change plus the merged wall judge covers the observed failure class. The launch-identity read belongs to KEN-1511 and the local removed-worktree close to KEN-1811. No reopen.
- **Owner-held PRs and items**: PR #2837 (perf/tool-renderer), PR #2801 (KEN-1493), KEN-1779, KEN-1722, the KEN-1724 children KEN-1887 to KEN-1893, KEN-1764 with PR #2861, KEN-1769 with PR #2863, KEN-1770 and kendex-web PR 43. Pending owner decisions are not approvals.
- **Live fleet lanes at the audit read**: KEN-1844, KEN-1722, KEN-1902, KEN-1922, KEN-1921, KEN-1935, KEN-1937, KEN-1932, KEN-1661, KEN-1779.

## Code and package duplication

The scout verified each lead against the tree at fa2c538d and its tests. A verdict of "report only" means the audit files no removal issue; the copy is recorded here for the owner of the next change in that file.

| Finding | Where | Verdict | Removing issue |
|---|---|---|---|
| Red-check predicate copied inline | `skills/github/scripts/lib/ci-run-correlation.sh` defines `red` once. `skills/orch/scripts/ci-wait` copies its body inline twice (the failed-link select and the `failed:` list) and `ci-run-correlation.sh` once more inside `scope_current_run`. The `tools/guard` rule against a second `def` copy matches `def` lines only, so inline copies pass. | Concrete duplicate: three copies can drift from `red`. | KEN-1676 |
| `check_id_token` defined three times | `skills/orch/scripts/dev-return-write`, `dev-round-write` and `dev-artifact-check` each define it with the same grammar. `dev-return-write` already differs: it dies with `option=` and `value=` fields where the other two pass the raw arguments. Each script has its own traversal test. | Trust-boundary triplet: each script validates its own inputs independently, and a fold proposal already failed the filing bar under KEN-1824. Report only. | none |
| Second date parser in orch | `skills/orch/scripts/reconcile-work-items` parses ISO stamps with its own GNU-then-BSD `date` fallback. `skills/orch/scripts/lib/date-ladder.sh` already has `to_epoch`, which also rejects a normalized date. | Concrete duplicate in one skill. Report only. | none |
| Same date parser in review-gate | `skills/review-gate/scripts/pr-watch.sh` carries the GNU-then-BSD parse three times. | A different skill cannot source orch's library without a vendored copy. Report only. | none |
| ISO-stamp jq expression twice | The `sub` and `fromdateiso8601` expression appears in `skills/orch/scripts/lib/lane-state.sh` and in `skills/orch/scripts/oversee-watch`. | Small concrete duplicate. Report only. | none |
| Synchronous systemd runner | `job_unit_launch` in `skills/orch/scripts/lib/job-unit.sh` starts a detached unit and has no `--wait` mode. The synchronous runner is the control VM's `fleet-run`, outside this repository. | Not a duplicate inside kendex. KEN-1858 adds `--wait` so the fleet can drop its runner copy. | KEN-1858 |
| Checkout hash per harness | `installation_hash` in `crates/core/src/hash.rs` is called once per harness from `desired_skill.rs`, `desired_agent.rs` and `desired_kinds.rs`. Each call collects and hashes the source tree again. On a CRLF checkout `checkout_hash` runs one `git ls-files --eol` per file. | Concrete repeat: 111 git calls and 43.990 seconds observed. | KEN-1860 |
| Catalog checksum per package | `tree_signature` in `crates/core/src/remote/store/signature.rs` walks and hashes the mirror checkout on every call from `remote/store.rs`. Git is not involved; it is distinct from `checkout_hash`. | Concrete repeat: 48 calls and 7.3 seconds observed on a no-op refresh. | KEN-1859 |

Leads the scout judged not duplication:

- **Four readers of branch protection**: `required_contexts` and `merge_gate_gap` in `skills/github/scripts/commands/pr-merge.sh`, the CI probe in `ci-wait`, and the ruleset audit in `skills/review-gate/scripts/validate-standard.sh` each answer a different question. `merge_gate_gap` errs toward caution on a read-only token.
- **Two context measures**: `skills/orch/scripts/lib/lane-context.sh` reads the pane status line and multiplies the used percentage by the window size. `transcript_tokens` in `hooks/lane-mail-check.sh` sums the harness's own usage counters. Both compare against `ORCH_HANDOFF_CONTEXT_TOKENS`; they read different sources by design. `pi-extensions/pi-qol/extensions/qol/context-usage.ts` is the pi-qol extension's own reader of Pi's transcript, a third source beside the pane line and the hook, tracked in this repository and outside the orch scripts' scope.
- **`json_or_default`**: the GitHub copy prints the error and returns non-zero; the Linear copy drops errors and returns zero. Same name, different contract. A reader can pick the wrong one. Report only.
- **Vendored `kendex-env.sh`**: seven byte-identical copies under `skills/*/scripts/lib/`, held equal by `tools/tests/vendored-settings-libs.test.sh`. The POSIX `gg_git_path` copy in the commit-guards helper is deliberate; a git hook helper cannot source anything.
- **Rendered copies**: § Propagation.

## Proposals relayed to the owner

These were held, not executed. Each waits on the event named.

- **KEN-1939**: duplicate of KEN-1661's PR #2961, which deletes the status-line parser that refuses an overseer line with no account address. Cancel after that PR merges and a token-launched overseer registers. If the refusal survives, re-scope to the KEN-1921 record read.
- **KEN-1563**: cancel once KEN-1779 stage 2 retires `consumer-train.md` on main.
- **KEN-1553**: re-scope after KEN-1902 merges. The stop/start half is KEN-1902's; the class bullet reduces to the setting and label source on top of KEN-1861. The relation and comment are recorded; the scope is unchanged.
- **KEN-1897, KEN-1898, KEN-1900**: the GitHub-synced filings still lack a Reached by line. The verification comments of 2026-09-26 hold the vgs evidence. Priority P3 and agent:generalist are set; the line is the owner's to add from those comments.
- **KEN-1723**: the core Attention and Choice child is not filed. File it at the plan gate and block KEN-1889 on it.
- **KEN-1277**: no owner-gated label marks the hold; adding one would make it visible in listings.
- **KEN-1534**: reword the Done-when to the event judge when KEN-1659 files the typed-events child.
- **KEN-1736**: update the body to the residual (round count, stderr after the echoed prompt).
- **Triage estimates**: 12 of the 22 Triage rows carry estimate 0. Size them at activation.

## Tracker corrections applied

The overseer applied these in the KEN-1916 lane. Every re-fetched row matched the approved action.

| Outcome | Count | Items |
|---|---|---|
| Created | 0 | none |
| Canceled | 4 | KEN-1783 (obsolete, KEN-1832 shipped the in-place contract), KEN-1774 (obsolete, KEN-1832 changed `block-worktree-refresh.sh`), KEN-1702 (below the creation bar), KEN-1559 (absorbed into KEN-1653) |
| Held | 1 | KEN-1939 until PR #2961 merges |
| Corrections | 53 | 8 priorities, 6 agent labels, 9 label sets, 20 relations, 2 reparents, 3 Sub-Issues rebuilds, 4 project moves, 1 project dependency. The breakdown counts corrections, not issues: KEN-1859, KEN-1860 and KEN-1919 each carry an agent-label and a label-set correction. |
| Bodies updated | 4 | KEN-1818, KEN-1857, KEN-1861, KEN-1919; KEN-1735's Location corrected |
| Declined | 4 | Pi compaction check at hosted launch (covered by the proposal route after PR #2961), per-issue comment reads in the proposal sweep (KEN-1932), `oversee-watch` stood at 91 percent of the 200 KB byte-ceiling lane at fa2c538d, past its 90 percent near-ceiling mark; ac62981e (KEN-1844) reduced the file to 151073 bytes, 74 percent, so no near-ceiling record binds the next change on the tree this report ships in, KEN-1736 residual round counting (covered by KEN-1736) |
| Ready to schedule | 15 | KEN-787, KEN-1779, KEN-1493, KEN-1887, KEN-1888, KEN-1890, KEN-1893, KEN-1581, KEN-1538, KEN-1649, KEN-1636, KEN-1482, KEN-1653, KEN-1818, KEN-1826 |

Notable structural corrections: KEN-1921 and KEN-1925 moved from KEN-1661 to KEN-1659 (a leaf In Review cannot carry open children). KEN-1826 and KEN-1827 were found already parented under KEN-1820 at execution time, so no reparent was needed. KEN-1922 blocks KEN-1906. KEN-1861 blocks KEN-1553. Agent Harness Integrations is blocked by Skills & Agents Library.

## Dispositions

| Disposition | Count |
|---|---|
| keep | 121 |
| cancel | 4 |
| hold | 1 |
| total | 126 |

State and priority are as read on 2026-09-27 before the corrections. A disposition names the change the audit applied (a priority move, a label, a project move, a re-scope) beside the keep. "Ready" means every blocker is Done.

### Orch control plane (37)

| Issue | State | Disposition | Reason | Title |
|---|---|---|---|---|
| KEN-1489 | Backlog P3 | keep | ORCH_OVERSEER_AUTONOMY one-key stance; blocked by KEN-1493 (owner-held PR #2801) | orch: ORCH_OVERSEER_AUTONOMY names the overseer stance in one key; ask means merge confirm, issue-creation confirm and blocker flag before continuing |
| KEN-1496 | Backlog P3 | keep | the narrower orch package audit runs last by owner ordering; blocked by KEN-1511, 1504, 1489; distinct from this audit | orch: package audit after the open orch issues land: stale guidance, tooling and assumptions pruned, every markdown file held to docs-writing, SKILL.md The Cycle and MODE SWITCH judged sentence by sentence |
| KEN-1504 | Backlog P1 | keep, P1→P2 | lanes pick headroom weighting; outside ranks 1-5, waits on KEN-1493 | orch: lanes pick weighs headroom and treats the bare claude and codex accounts as lanes of last resort |
| KEN-1511 | Backlog P3 | keep | a lane records what it starts outside its process tree and stops it at close; owns the launch-identity half of the KEN-1873 owner update | orch: a lane records what it starts outside its process tree and stops it at merge, handoff and close |
| KEN-1525 | Backlog P3 | keep | wake harness-process read skips other users, no /proc cwd; pane-free reads belong to the KEN-1659 design | orch: the wake's harness-process read skips processes another user owns and reads the cwd without /proc |
| KEN-1527 | Backlog P2 | keep | open-terminal --relaunch resume-or-fresh in one function; no covering, duplicate or superseding issue in the 1890-row comparison set; passes the creation bar as filed | orch: open-terminal --relaunch decides resume or fresh brief from the session and the handoff record, in one function |
| KEN-1534 | Backlog P2 | keep, reword later | --wake through the provider; its Done-when still names a pane-read judge, to be reworded when KEN-1659 files the typed-events child | orch: open-terminal --wake reaches a hosted lane through the provider, so no wake is a pane paste |
| KEN-1538 | Backlog P3 | keep, ready | mailbox hold read by the arm step; blockers complete | orch: an overseer holds a running lane's merge after launch through a mailbox hold the arm step reads, without halting the lane |
| KEN-1546 | Backlog P3 | keep | peer mail through the provider; no covering, duplicate or superseding issue in the 1890-row comparison set; passes the creation bar as filed | orch: peer mail reaches an overseer on another host through the provider, so a peer's note is a peer-note and never an owner directive |
| KEN-1553 | Backlog P3 | keep, re-scope after KEN-1902 | stop/start half superseded by KEN-1902 stop-sandbox/start verbs; class bullet reduces to the setting and label source on top of KEN-1861; blocked by KEN-1861 | orch lane-host protocol: optional lifecycle verbs and notices (class, stop/start, walled, reaped, clone-less close) under one absent-verb rule |
| KEN-1559 | Backlog P2 | cancel (absorbed into KEN-1653) | absorbed by scope: KEN-1653 carries the no-model-no-effort refusal requirement, sited in the oversee-succeed caller-entry branch; no refusal exists in the code today | orch: oversee-succeed refuses a successor launch carrying no model and no effort |
| KEN-1570 | Backlog P2 | keep | overseer handoff snapshot and bounded resume; distinct from KEN-1661 thresholds | orch: the overseer handoff is a current snapshot and the resume after a succession is bounded |
| KEN-1623 | Backlog P3 | keep | durable handoff reserve; a separate mechanism from KEN-1504, 1885, 1661, 1902 by owner direction | orch: measure and reserve enough account headroom for durable concurrent lane handoffs |
| KEN-1649 | Backlog P2 | keep, ready | usage-limit route owned by the watch; related to KEN-1902 (provider stop verb now stop-sandbox); blockers complete | orch: the watch owns the usage-limit route: relaunch on a qualifying account, else keep or hand off by time to reset |
| KEN-1653 | Backlog P3 | keep, absorbs KEN-1559 | per-harness model floor plus the no-model-no-effort refusal, to be added where oversee-succeed assembles a successor's flags; launch_choice_write keeps its empty-model success | orch: the cycle sizes the model, not the diff; a per-harness model floor setting refuses a launch below it |
| KEN-1654 | Backlog P2 | keep | live proof of dead-overseer relaunch on the control VM; run after PR #2961 merges (related KEN-1661) | orch: run the KEN-1603 live proof on main: a dead overseer is relaunched by the watch on the control VM, evidence recorded |
| KEN-1659 | Backlog P1 | keep, P1 container | lane-to-overseer protocol; now parents KEN-1921 and KEN-1925 beside KEN-1661; the typed activity judge (final-prompt control) stays here | orch: one lane-to-overseer protocol, and lane state read from harness signals, never from a pane |
| KEN-1661 | In Review P1 | keep, live lane, rank 1 | PR #2961 DIRTY needs a rebase; owner rule 1790459908 (records over panes) and the compaction-risk hold stand | orch: hand off at 400000 used tokens or before the compaction safety limit |
| KEN-1682 | Backlog P3 | keep | owner time zone in every human-read text; no covering, duplicate or superseding issue in the 1890-row comparison set; passes the creation bar as filed | orch: every text a person reads leads with the owner's time zone from one setting, and every machine record stays UTC |
| KEN-1738 | Backlog P3 | keep | lane-mail wait counter timing; no covering, duplicate or superseding issue in the 1890-row comparison set; passes the creation bar as filed | orch: the lane-mail wait timing control measures the sleep by a counter, not by wall clock under load |
| KEN-1806 | Backlog P3 | keep | dev-validate-run rebase-round range; no covering, duplicate or superseding issue in the 1890-row comparison set; passes the creation bar as filed | orch: dev-validate-run measures a rebase round's range from the rebased branch, not the round's pre-rebase base |
| KEN-1808 | Backlog P2 | keep | paused restack holds hook scripts; no covering, duplicate or superseding issue in the 1890-row comparison set; passes the creation bar as filed | worktree: a paused restack holds the scripts a declared hook executes, as it holds the libraries a hook sources |
| KEN-1809 | Backlog P3 | keep | scoped validation run directory for dev-return-write; no covering, duplicate or superseding issue in the 1890-row comparison set; passes the creation bar as filed | orch: a scoped validation run produces the run directory dev-return-write binds a fix round's receipt to |
| KEN-1811 | Backlog P3 | keep | lane-close for a local lane whose close-out removed the worktree; owns the order half (end harness, then remove tree) of the KEN-1873 owner update | orch: lane-close closes a finished local lane whose worktree its own close-out removed, as the hosted path does |
| KEN-1857 | Triage P3 | keep, rescoped | ci-job-set lane selection for skill markdown and --range selection; the docs class inside dev-validate-run contradicted KEN-1639 | orch: a docs-only skills diff (markdown plus renders) is classed standard, so dev-validate-run and tools/guard run the whole orch suite past the timeout with no verdict |
| KEN-1858 | Triage P3 | keep, feature label | job-unit.sh --wait; the duplicate synchronous runner is the control VM fleet-run, outside this repository; this issue is what lets the fleet drop it | orch: job-unit.sh launch takes --wait, a synchronous mode that pipes output and propagates the exit code and signal under the same memory bound and lifetime, so fleet-run can drop its own runner copy |
| KEN-1861 | Triage P3 | keep, updated, blocks KEN-1553 | the shippable --class slice; schema wording aligned with KEN-1553 | orch: open-terminal takes --class LANE_CLASS, passed to the host create as --class and recorded in the lane record beside model and account; refused where the host is local |
| KEN-1863 | Triage P3 | keep | branch-size-check zero-plural grammar; no covering, duplicate or superseding issue in the 1890-row comparison set; passes the creation bar as filed | orch: branch-size-check accepts 0 with the plural (0 test lines) as a stated zero and says so in its help, so a filing agent's natural line is not refused |
| KEN-1864 | Triage P3 | keep | micro.md admits every policy-none class; related to KEN-1766 | orch: micro.md section 4 admits every class whose policy row is none (trivial and micro), so a documentation-only micro item measuring trivial no longer escapes to an ask |
| KEN-1902 | In Progress P2 | keep, live lane, rank 4 | park hosted lanes during green merge waits; owner park rule preserved; round 2 completion summary posted | orch: park hosted lanes during green merge waits |
| KEN-1921 | In Progress P1 | keep, live lane, rank 1, reparented to KEN-1659 | overseer launch identity record; related to KEN-1661 | orch: record the current overseer's launch identity for succession |
| KEN-1925 | Backlog P1 | keep, rank 1, reparented to KEN-1659 | exact native transcript binding; blocked by KEN-1921 | orch: bind the exact native transcript to the current overseer session |
| KEN-1927 | Backlog P2 | keep | shipped bypass defaults without duplicate launcher flags; no covering, duplicate or superseding issue in the 1890-row comparison set; passes the creation bar as filed | orch: use shipped bypass defaults without duplicate launcher permission flags |
| KEN-1931 | Backlog P2 | keep, rank 1 and 5 | shared adapter for overseer inspection and succession; after KEN-1661 merges; blocks KEN-1848 | Route overseer inspection and succession through the shared adapter |
| KEN-1938 | Backlog P3 | keep | drop cached usage bodies for excluded accounts; no covering, duplicate or superseding issue in the 1890-row comparison set; passes the creation bar as filed | orch: remove cached usage bodies for excluded accounts |
| KEN-1939 | Backlog P1 | hold, cancel after PR #2961 merges | duplicate of KEN-1661: the branch deletes the status-line parser that refuses overseer-line-missing; re-scope to KEN-1921 record read if the refusal survives | orch: the overseer launch line accepts a status line with no account address |
| KEN-1940 | Backlog P3 | keep | oversee-succeed successor brief option; related to KEN-1931 (option home after the launcher move) | orch: oversee-succeed takes the successor brief as an option |

### Orch merge route (3)

| Issue | State | Disposition | Reason | Title |
|---|---|---|---|---|
| KEN-1581 | Backlog P2 | keep, ready | arm auto-merge after PR creation on the D003 queue route; related to KEN-1902 (one merge state for park and arm) | orch: arm auto-merge right after PR creation, not after CI |
| KEN-1676 | Backlog P2 | keep | one red-check reader: the scout found three inline copies of the red predicate (ci-wait ×2, ci-run-correlation.sh) the guard does not catch; this issue removes them | one red-check classification: ci-wait and pr-merge read the required set through one reader, and every red check is named with whether the base requires it directly |
| KEN-1853 | Triage P2 | keep | queue-wait reads progress only from a merge-group head; related to KEN-1581 and KEN-1676 | orch: queue-wait reads progress only from a merge-queue entry head, so an armed PR awaiting required checks before enqueue always reads progress_unobservable and merge-pr spends recovery cycles on nothing |

### Review gate (5)

| Issue | State | Disposition | Reason | Title |
|---|---|---|---|---|
| KEN-1562 | Backlog P2 | keep | kendex-web gate reaches SUCCESS only by timeout; agent:human, owner evidence needed; no covering, duplicate or superseding issue in the 1890-row comparison set; passes the creation bar as filed | review-gate: kendex-web reaches gate SUCCESS only by the review timeout, never by evidence |
| KEN-1765 | In Review P1 | keep, P1, In Review | class policy active by default; blocked by KEN-1779 (rank 2 delivery chain, D003); PR #2884 DIRTY | review-gate: the class policy is active by default, so every adopting repository runs one review policy |
| KEN-1766 | Backlog P2 | keep | classes named by review evidence; blocked by KEN-1765; related to KEN-1864 | change classes are named by the review evidence they need, not by size adjectives, and the README table leads with what each class needs |
| KEN-1852 | Triage P3 | keep | Copilot-submitted review leaves action_required stale in the writer; queue delay, not a block | review-gate: the writer's pull_request_review relay leg ends action_required for a Copilot-submitted review, so the gate converges only by the reducer's heal dispatch |
| KEN-1874 | Backlog P3 | keep | policy-unmeasured for any cause fails the whole writer pass; no covering, duplicate or superseding issue in the 1890-row comparison set; passes the creation bar as filed | review-gate: a change class answered policy-unmeasured for any cause fails the whole writer pass instead of posting a non-success row, reopening the rolling incident |

### Harness CI and CI (10)

| Issue | State | Disposition | Reason | Title |
|---|---|---|---|---|
| KEN-1502 | Backlog P3 | keep | harness-smoke live rows on claude, codex and pi once an account is open; Copilot rows go to KEN-1937 | tools: harness-smoke runs the lane-mail halt row and one real arm row green on claude, codex and pi once an account is open |
| KEN-1680 | Backlog P3 | keep | render lint installs one catalog copy per harness; macOS leg over the ten-minute ceiling | CI: the render lint test installs one whole-catalog copy per harness, so the macOS leg it owns stands above the ten-minute ceiling on every pull request |
| KEN-1692 | In Review P2 | keep, In Review | PR #2789 merged; the hosted negative-setup proof (repo-setup-failed) is still incomplete; not stale | kendex: a tracked `.fleet-setup` makes a lane's clone ready, so a hosted lane runs `tools/guard --full` green with no install step |
| KEN-1735 | Backlog P3 | keep, relabeled ci-infra, moved to Review Gate & CI | file is tools/tests/publish-homebrew.test.sh; sets no GIT_CONFIG_GLOBAL | app-deploy: publish-homebrew.test.sh isolates its sandbox tap from the host's global git configuration |
| KEN-1807 | Backlog P3 | keep | crate tests declare a read set; needs a decider entry or needs-research before pickup; related to KEN-1924 | test: crate tests declare and check a bounded read set so the cargo test legs can stand down per crate |
| KEN-1922 | In Progress P3 | keep, live lane, rank 4, P3→P2 | change-class action owns the lanes verdict; now In Review with PR #3004; blocks KEN-1906 | harness-ci: the change-class action owns the lanes verdict, and a docs-only diff runs no lane at any size |
| KEN-1923 | Triage P3 | keep | lanes stand down on a passing run of the same tree; blocked by KEN-1922 and KEN-1928 | harness-ci: the change-class action stands lanes down when a passing run already tested the same tree (merge group, main push) |
| KEN-1924 | Triage P3 | keep | catalog check and CLI round trip under the CI aggregate; related to KEN-1807 and KEN-1928 | kendex CI: the catalog check and real-CLI round trip move under the CI aggregate, and they and the review-gate decision-table job follow the change class |
| KEN-1928 | Triage P3 | keep | per-lane path declarations and verdicts; blocked by KEN-1922; related to KEN-1924 | harness-ci: each lane declares the paths it reads, and the change-class action emits one verdict per lane |
| KEN-1929 | Triage P3 | keep | high-risk paths always classify standard; related to KEN-1922 | harness-ci: a repository names high-risk paths that always classify standard, so the shared class policy keeps full review there |

### Linear (2)

| Issue | State | Disposition | Reason | Title |
|---|---|---|---|---|
| KEN-1900 | Backlog P0 | keep, P3, agent:generalist | linear workflow result formats and ids; Reached by line still missing | Define output formats per result type and accept ids on issue workflow actions |
| KEN-1932 | In Progress P2 | keep, live lane, rank 4 | bulk-list comment reader; completion summary posted, not on main yet | Read cached comparison comments for multiple issues in one process |

### Code quality, preflight and commit guards (6)

| Issue | State | Disposition | Reason | Title |
|---|---|---|---|---|
| KEN-1288 | Backlog P4 | keep | git-diff-summary tests/ scoping defect; no covering, duplicate or superseding issue in the 1890-row comparison set; passes the creation bar as filed | git-diff-summary: a root-level tests/ dir is production scope but a test panic path |
| KEN-1668 | Backlog P3 | keep | preflight backslash-continuation logical line; related to KEN-1897 | preflight: the bare-assignment fail-open lane reads a backslash continuation as one logical line, so a guard on the next line is not missed |
| KEN-1702 | Backlog P4 | cancel (below bar) | one slip fixed in the same PR and already caught by the macOS shard | tools: one scan names a `--` standing after a utility's mode or script operand, over the roster bash32-parse covers, so a BSD-argv slip reds in the guard instead of on the macOS shard |
| KEN-1897 | Backlog P0 | keep, P3, agent:generalist | declared sourced fragments in preflight; related to KEN-1668; Reached by line still missing | Declare sourced shell fragments instead of inferring them from one fixed path |
| KEN-1898 | Backlog P0 | keep, P3, agent:generalist | parsed shell syntax in pre-commit-check; related to KEN-1482; Reached by line still missing | Read the commit and its bypass flags from parsed shell syntax, not a word scan |
| KEN-1919 | Triage P0 | keep, updated, P3, agent:generalist, bug | preflight judges an unquoted .md argument a citation; title, Reached by and Expected delta added; agent label and bug label set | Restrict source document citations to documentation text |

### Tests program (4)

| Issue | State | Disposition | Reason | Title |
|---|---|---|---|---|
| KEN-1820 | Triage P2 | keep, container | orch test diet; families A-C Done (1823, 1824, 1825), D and E open as children | orch: the orch test diet under code-quality section Tests, one PR per family, deleting first, with lines and seconds reported before and after |
| KEN-1826 | Triage P2 | keep, ready | family D: virtual clock and table-driven launches; KEN-1825 Done | orch tests: the five slowest suites read time through lib/virtual-clock.sh and run per-value launches as table-driven rows |
| KEN-1827 | Triage P3 | keep | family E: files at or under 64 KB; blocked by KEN-1826; seven files over at fa2c538d, `lib/lane-host-ssh-tests.py` among them | orch tests: every file under skills/orch/tests/ is at or under 64 KB, split at surface seams after the diet |
| KEN-1856 | Triage P3 | keep | rendered suite reads hooks from a nonexistent .agents/hooks; four-line fix | orch tests: the rendered workflow-state-handoff-standing suite reads hooks/lane-mail-check.sh from the work tree top level, so it passes under .agents as the source copy does |

### Propagation (2)

| Issue | State | Disposition | Reason | Title |
|---|---|---|---|---|
| KEN-1563 | Backlog P3 | keep, conditional cancel | cancels once KEN-1779 stage 2 retires consumer-train.md on main (still tracked at fa2c538d) | orch: a hosted train lane appends its own consumer_train record |
| KEN-1779 | In Progress P1 | keep, live lane, rank 2, owner hold | consumer render propagation; D007 exclusion folded in 2026-09-27; owner reporting hold stands | propagation: consumers pull kendex renders through a workflow shipped in the render (rolling branch, one rolling PR, auto-merge with the app); the consumer train, its manual steps and ORCH_CONSUMER_REPOS are retired |

### Slack and owner channel (3)

| Issue | State | Disposition | Reason | Title |
|---|---|---|---|---|
| KEN-1843 | Todo P2 | keep, Todo container, rank 5 | owner channel and T3; Sub-Issues list gains KEN-1931 | Owner channel and T3 overseer runtime (fleet plans of 2026-09-26) |
| KEN-1844 | In Review P2 | keep, live lane, In Review | [K2] typed mailbox fields; PR #2963 | [K2] orch: typed mailbox fields, one resolve, the report notice and ORCH_QUESTION_TOOL off by default |
| KEN-1845 | Backlog P2 | keep | [K1] slack relay package; blocked by KEN-1844 | [K1] slack: the package that relays one overseer mailbox to one private Slack channel by polling |

### T3 (1)

| Issue | State | Disposition | Reason | Title |
|---|---|---|---|---|
| KEN-1848 | Backlog P2 | keep | [K-T3-2] t3 overseer host; blocked by KEN-1931 and the fleet F-T3-1 | [K-T3-2] orch: the t3 overseer host, the durable delivery position, the state reader and the release contract test |

### Copilot (4)

| Issue | State | Disposition | Reason | Title |
|---|---|---|---|---|
| KEN-1934 | Backlog P1 | keep, container, rank 2 | Copilot as a first-class harness; project now blocked by Skills & Agents Library (KEN-1661, 1921, 1925, 1931) | Copilot as a first-class local and fleet harness |
| KEN-1935 | In Progress P1 | keep, live lane, rank 2 | first Copilot lane with working coordination | Launch the first Copilot lane with working coordination |
| KEN-1936 | Backlog P1 | keep, rank 2 | Copilot overseer recovery and succession; blocked by KEN-1935 | Recover and succeed Copilot overseer sessions |
| KEN-1937 | In Progress P1 | keep, live lane, rank 2 | Copilot package compatibility; one PR under Refs, issue stays open (overseer ruling 2026-09-27) | Prove Copilot package compatibility and enable early review work |

### CLI terminal design (8)

| Issue | State | Disposition | Reason | Title |
|---|---|---|---|---|
| KEN-1724 | Backlog P2 | keep, owner-held container | Sub-Issues list rebuilt; each child ships behind the owner pilot approval | cli: one terminal design system — colour tokens, symbols, spacing, keyed choices and links — and every verb's output built from it |
| KEN-1887 | Backlog P2 | keep, owner-held, ready | KEN-1724 child; refresh and apply report lines | cli: finish refresh and apply report lines with the terminal components |
| KEN-1888 | Backlog P2 | keep, owner-held, ready | KEN-1724 child; keyed choices replace legacy prompts | cli: replace legacy prompts and commit-offer text with keyed choices |
| KEN-1889 | Backlog P2 | keep, owner-held | KEN-1724 child; blocked by KEN-1888 and the unfiled KEN-1723 core-model child | cli: render KEN-1723 decisions through one terminal callout |
| KEN-1890 | Backlog P2 | keep, owner-held, ready | KEN-1724 child; package inspection verbs and drift banner | cli: convert package inspection verbs and the drift banner to the terminal components |
| KEN-1891 | Backlog P2 | keep, owner-held | KEN-1724 child; blocked by KEN-1888 | cli: convert remove and update flows to the terminal components |
| KEN-1892 | Backlog P2 | keep, owner-held | KEN-1724 child; blocked by KEN-1888 | cli: convert project and marketplace flows to the terminal components |
| KEN-1893 | Backlog P2 | keep, owner-held, ready | KEN-1724 child; init, login, report, plain-language help | cli: convert init, login and report, and write plain-language help |

### Consumer rollout (9)

| Issue | State | Disposition | Reason | Title |
|---|---|---|---|---|
| KEN-1906 | Backlog P2 | keep, owner-gated container, blocked by KEN-1922 | nine consumer rollouts; KEN-1907 Done (vgs PR422); next KEN-1908 | Roll out CI and merge rules to nine consumers |
| KEN-1908 | Backlog P2 | keep | vsys aggregate CI; after KEN-1922 | vsys: Add one aggregate CI check |
| KEN-1909 | Backlog P2 | keep | kendex-web CI and merge queue; after KEN-1922 | kendex-web: Add CI and a merge queue |
| KEN-1910 | Backlog P2 | keep | review-gate-sandbox fail closed | review-gate-sandbox: Make CI fail closed |
| KEN-1911 | Backlog P2 | keep | vg aggregate CI; after KEN-1922 | vg: Aggregate every CI job under CI |
| KEN-1912 | Backlog P2 | keep | hyprtrade-io aggregate CI; after KEN-1922 | hyprtrade-io: Aggregate the workflow checks under CI |
| KEN-1913 | Backlog P2 | keep | hyprtrade aggregate as CI | hyprtrade: Report the aggregate as CI |
| KEN-1914 | Backlog P2 | keep | drovr aggregate merge checks | drovr: Aggregate all merge checks under CI |
| KEN-1915 | Backlog P2 | keep | memsira merge lanes behind CI | memsira: Put every merge lane behind CI |

### CLI and core (19)

| Issue | State | Disposition | Reason | Title |
|---|---|---|---|---|
| KEN-1272 | Backlog P4 | keep | P4 typed-refusal defect in crates/core citation rendering; no covering, duplicate or superseding issue in the 1890-row comparison set; passes the creation bar as filed | A root-level catalog skill is cited as /SKILL.md:<line> |
| KEN-1273 | Backlog P4 | keep | P4 typed-refusal defect for a folder at an agent path; no covering, duplicate or superseding issue in the 1890-row comparison set; passes the creation bar as filed | A folder standing where an agent file goes refuses with a raw Io error, not a typed refusal |
| KEN-1277 | In Progress P2 | keep, moved to CLI & Distribution | all 22 children Done or Canceled; only the owner design approval after 1.0.0 remains; container-parked by design, not stale | Consumer UX simplification wave: the app feels simple to use, process and understand; owner design review gates 1.0.0 |
| KEN-1493 | In Review P3 | keep, P3→P2 | only open blocker of KEN-1504 and KEN-1489; PR #2801 DIRTY, owner-held | settings: every package settings comment block is rewritten as a plain explainer (what it is, what each value does) for the file and the Customize tab |
| KEN-1590 | Backlog P3 | keep | child of KEN-1723; Pi update prompt wording | kendex refresh's Pi update prompt says install or update and where, and answering No is an unchanged scope, not a failure |
| KEN-1636 | Backlog P3 | keep, ready | app commit-offer region-aware preview; blockers complete | app: the commit-offer change preview is region-aware for AGENTS.md, so it shows only the owned region |
| KEN-1688 | Backlog P3 | keep | settings key declares same-everywhere or project-own; its reader (consumer-train.md § 1.1) changes when KEN-1779 retires the train | kendex: a settings key declares whether its value is meant to be the same in every project or the project's own, and one command reports every subscribed project that disagrees |
| KEN-1696 | Backlog P3 | keep | kendex adopt default harness set and verb docs; no covering, duplicate or superseding issue in the 1890-row comparison set; passes the creation bar as filed | kendex adopt: the default is every harness the project enables, and the verb is documented where a consumer looks |
| KEN-1711 | Backlog P3 | keep | kendex-local.toml naming from one helper; no covering, duplicate or superseding issue in the 1890-row comparison set; passes the creation bar as filed | core: every message that names the scope's manifest file names kendex-local.toml in a source-catalog checkout, from one helper |
| KEN-1722 | In Review P2 | keep, live lane, In Review | PR #2971 merged; stays In Review for the owner manual vgs v2 validation | refresh: a skipped bot-instructions render never ends in a commit offer the pre-commit check must refuse; kendex offers setup, runs the package checker first, and a linked worktree is not silently unarmed |
| KEN-1723 | Backlog P2 | keep | guided-decision design parent; holds implementation scope until the core Attention/Choice child is filed at the plan gate | kendex: every error, conflict or choice is one guided decision, the same in the CLI and the app, and kendex never offers an action it can predict will fail |
| KEN-1729 | Backlog P3 | keep | verify reports orphan comment blocks; related to KEN-1493 (same seeded blocks) | settings: verify reports comment blocks with no key under them, and refresh offers to remove them |
| KEN-1783 | Backlog P2 | cancel (obsolete) | KEN-1832 shipped the in-place contract | engine: an in-place package is compared against its files in place, so an ordinary edit never marks it unmanaged in refresh, check or verify |
| KEN-1818 | Triage P3 | keep, updated, ready | Done-when widened to every row unreadable under the credential in use; KEN-1777 and KEN-1781 Done | cli: kendex check relays the D003 standard check's verdict per row, off by default, with the bypass-actor row unreadable rather than red under the app token |
| KEN-1859 | Triage P3 | keep, agent:rust, bug | tree_signature recomputed per call (48 calls, 7.3 s); distinct from KEN-1860 | refresh: a no-op refresh in a remote-catalog consumer re-hashes the catalog checkout once per package for the drift snapshot; check each checkout once per invocation |
| KEN-1860 | Triage P3 | keep, agent:rust, bug | checkout_hash one git process per file per harness (111 calls, 43.990 s); distinct from KEN-1859 | hash: a CRLF checkout still runs one git process per source file per harness; one ls-files --eol per tree and one portable hash per source reused across harnesses |
| KEN-1866 | Triage P2 | keep | edited-orphan remedy removes a hook another tool still requests; review-born P2 with a Symptom line | kendex-core: the edited-orphan row's remove-it-by-name remedy on a hook still requested for another tool removes the hook and its declaration from that tool too |
| KEN-1879 | Backlog P3 | keep | plaintext-secrets audit reads its own PREFIXES list; no covering, duplicate or superseding issue in the 1890-row comparison set; passes the creation bar as filed | core: the plaintext-secrets audit reads the secret-value pattern's one home instead of its own PREFIXES list, so an xapp- Slack token is flagged |
| KEN-1926 | Backlog P2 | keep | version 10 lock recovery in one command; related to KEN-1721 (history) | refresh: recover a version 10 lock and finish owned updates in one command |

### Pi extensions and hooks (6)

| Issue | State | Disposition | Reason | Title |
|---|---|---|---|---|
| KEN-1482 | Backlog P3 | keep, ready | owned-verb-check hook; related to KEN-1898 (shared command-position seam); blockers complete | hooks: owned-verb-check refuses a bare git rebase, git worktree, gh pr merge, gh pr review or a writing gh api call at command position, naming the owning script |
| KEN-1519 | Backlog P3 | keep | pi-task-panel re-open defect; no covering, duplicate or superseding issue in the 1890-row comparison set; passes the creation bar as filed | pi-task-panel: panel doesn't auto reopen |
| KEN-1622 | Backlog P3 | keep | Pi reuses the Codex account through one refresh authority; blocked by KEN-1658 | Pi: reuse the selected Codex account through one authentication refresh authority |
| KEN-1658 | In Progress P2 | keep, moved to Agent Harness Integrations | pi-codex-bridge; In Progress 77 h with no PR and no lane artifact on this host; the overseer decides the stale marker | pi-codex-bridge: a Pi provider that runs Codex models through the Codex CLI's own process and login, modelled on pi-claude-bridge, with no credential in Pi's config |
| KEN-1774 | Backlog P3 | cancel (obsolete) | KEN-1832 shipped the help-form pass and the --project-path probe in block-worktree-refresh.sh | block-worktree-refresh: a help read of a guarded verb passes whatever the redirections, and a refusal names --project-path only where the installed kendex takes it |
| KEN-1801 | Backlog P3 | keep, + harness | pi-prompt-stash keybindings; no covering, duplicate or superseding issue in the 1890-row comparison set; passes the creation bar as filed | pi-prompt-stash: make in-popup keybindings configurable via settings |

### Release (1)

| Issue | State | Disposition | Reason | Title |
|---|---|---|---|---|
| KEN-787 | In Review P1 | keep, P1→P2 | owner channel steps remain (publish-aur, channel checks, delete v5.0.1); outside ranks 1-5, owner-held | Remove the 5.0.1 release; kendex ships 1.0.0 with every channel repointed |

### Docs and skill tooling (6)

| Issue | State | Disposition | Reason | Title |
|---|---|---|---|---|
| KEN-1567 | Backlog P3 | keep | doc-limits excludes row byte figure; no covering, duplicate or superseding issue in the 1890-row comparison set; passes the creation bar as filed | doc-limits: an excludes row carries no byte figure, or the guard refuses a figure the file disagrees with |
| KEN-1568 | Backlog P3 | keep, moved to Skills & Agents Library | change lands in skills/docs-writing or agents/reviewer-doc.md | docs-writing: a count stated in prose carries its own enumeration |
| KEN-1736 | Backlog P3 | keep, body needs an update | main already classifies a failed codex target (EXIT_CLI_FAILED=5); residual is the round count and the stderr-after-prompt case | second-opinion: a codex target that exits before producing a review is reported as one keyed line and does not count as a review round |
| KEN-1854 | Triage P3 | keep, design label | decider record bar; deliberate split from KEN-1855 (different tools) | decider: the record bar admits constants and incomplete records; require a rejected alternative and a revisit trigger, cap a record under 80 lines, and make RESEARCH_REF a bare issue id |
| KEN-1855 | Triage P3 | keep, feature label | decider Retired status; no covering, duplicate or superseding issue in the 1890-row comparison set; passes the creation bar as filed | decider: a Retired status for a decision record that the commit-guards md-refs lane accepts without a full file |
| KEN-1916 | Todo P2 | keep, this audit | publishes docs/plans/kendex-backlog-vision.md through this lane; closes on merge | kendex: audit active issues and package duplication |
