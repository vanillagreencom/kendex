# Prompt handlers

Classification tags and per-tag handler logic for prompts surfaced by tracked panes. Tags now have explicit domains:

- **Generic session tags** are safe for any tracked entry (`adhoc`, `workflow`, or `issue`) and route to `workflows/session-handle-prompt.md`.
- **Issue tags** require `kind="issue"` and route to `workflows/handle-prompt.md` only after the domain guard passes.

This split is intentional: generic handlers are the core session-manager surface, while issue handlers are the issue-domain plugin. If an issue-only sentinel appears on a non-issue entry, `domain-mismatch` fails closed and no PR/worktree action runs.

If a buffer matches multiple sentinels, the most specific tag wins (for example `force-merge-confirm` before `merge-ready-but-unknown` before `generic-multi-choice`).

---

## Generic session tags

These tags do not require GitHub, Linear, PR, or worktree context.

| Tag | Sentinel / source | Handler |
|-----|-------------------|---------|
| `terminal-state-reached` | Work-complete / session-complete / destroyed-cwd completion signal | Mark generic entry complete; issue mode verifies through `close-issue.md`. |
| `bash-permission-prompt` | Harness asks to run a command | Conservative read-only/skill-script allowlist; otherwise escalate. |
| `awaiting-direction` | `Awaiting user direction`, declined questions, standing by | Synthesize a continuation from decision history or escalate. |
| `generic-multi-choice` | Numbered option list with no specific sentinel | Safe bounded-choice policy; no PR conflict graph. |
| `oc-question` | OpenCode structured question event | Answer by exact option labels from event payload. |
| `pi-question` | Pi structured question event | Answer by exact option labels/custom text only when allowed. |
| `pi-bg-task-exit` | Pi daemon event for `vstack-background-tasks:event` exit | Generic task-ended nudge; issue mode may follow with PR/CI recovery. |
| `domain-mismatch` | Guard output when an issue-only tag appears on non-issue entry | Log warning, no destructive action, ask master/user how to proceed. |
| `rendering` | Buffer lacks prompt terminator | Re-poll; no handler. |
| `idle` | No prompt detected | No-op. |

### Generic handler rules

- Generic handlers never call `gh`, `linear`, `pr-conflict-graph`, or worktree cleanup.
- Safe `generic-multi-choice` may choose continue/inspect/retry options, but escalates destructive choices: merge, force-push, delete branches/worktrees, abort/close issues, mutate `main`, or apply issue review fixes.
- A generic tag on an issue entry is still handled generically first; issue `watch.md` resumes domain flow afterwards.
- `domain-mismatch` is a guard, not an auto-answer. It sets `paused_for_user` with reason `domain-mismatch`.

---

## Issue-only tags

These tags assume issue-domain metadata (`domain.issue.*`), PR state, Linear/GitHub/project-management context, or a registered worktree. They must never run for `kind=adhoc`.

| Tag | Sentinel pattern (illustrative) | Handler |
|-----|--------------------------------|---------|
| `cleanup-prompt` | `"Cleanup the .* worktree"` or `"Worktree for .* exists. Cleanup"` | Cleanup scope handler. |
| `stale-no-pr-branch` | `"Local branch .* has no associated PR. Delete"` | Always answer keep. |
| `stale-orphan-worktree` | `"orphan: .*"` or stale sibling worktree removal prompt | Always answer keep. |
| `bot-review-wait-stuck` | Bot review absent/stalled with Skip/Wait/Abort options | Query PR/review state and skip only when safe. |
| `rebase-multi-choice` | Merge-conflict prompt with `Rebase + force push` option | Combined preserve/apply/verify payload. |
| `force-push-prompt` | `--force-with-lease`, force-push confirmation | Auto-approve only bounded lease push. |
| `audit-relation-prompt` | Create audited follow-up issues / child-vs-related structure | Default related unless child scope is conflict-free. |
| `merge-ready-but-unknown` | GitHub mergeable status stuck/still `UNKNOWN` | Force-merge predicate. |
| `force-merge-confirm` | Extended UNKNOWN force-merge dialog | Force-merge predicate. |
| `merge-now` | Approved + CI-passing PR merge prompt | Auto-merge if no cross-session conflict. |
| `external-fix-suggestions` | External review fix suggestions | Apply in-scope fixes per expansion bias. |
| `cycle-fix-suggestions` | In-cycle reviewer fix suggestions | Apply in-scope fixes per expansion bias. |
| `scope-creep-detected` | Computed: actual PR files exceed declared scope | Escalate; do not auto-revert. |
| `descope-related` | Reconciliation suggests sibling issue descope | Accept metadata descope. |
| `multi-select-tabbed` | Checkbox/tab UI for issue review/audit choices | Use issue policy and `pane-respond --option-multi` / `--keys`. |

### Domain guard

`prompt-classify --entry-kind <kind>` and the TS classifier option used by `pane-poll` rewrite issue-only tags on non-issue entries to `domain-mismatch`. Missing kind now fails closed by default: if an issue-only tag is classified without any kind signal, the classifier emits a warning and returns `domain-mismatch`. If registry lookup fails, callers should pass `--entry-kind-unknown`; that sentinel also routes issue-only tags to `domain-mismatch`. The watch loop must log a warning, skip all issue handlers, and surface a master question. This prevents an ad-hoc session from accidentally triggering cleanup, force-push, merge, Linear, or GitHub actions.

Legacy issue-mode callers that genuinely cannot pass kind yet must opt in explicitly with `--allow-missing-kind` (TS: `allowMissingKind: true`). That returns the original issue-only tag with a warning and exists only as a migration bridge; new call sites should pass `--entry-kind issue` or `--entry-kind-unknown` and should not rely on the opt-in.

---

## Issue handler notes

### `cleanup-prompt`

Answer YES iff the target worktree path equals the asking issue's registered `domain.issue.worktree`. Answer NO/keep for sibling worktrees, batch cleanup, or any path mismatch.

### `stale-no-pr-branch` / `stale-orphan-worktree`

These are defensive tags for managed Flightdeck scope violations. Per-issue orchestration should suppress broad cleanup sweeps; if one reaches master, answer `Keep branch` / `Keep worktree` and record a process-violation note.

### `bot-review-wait-stuck`

Master observes PR state via `gh pr view <PR> --json statusCheckRollup,reviewDecision,latestReviews,labels`. Skip only when the bot check succeeded and review state is approved (or no reviewers are required). Human reviewer pending, changes requested, or ambiguous state escalates.

### `rebase-multi-choice`

The response must combine the selected option with a preserve/apply/verify triplet:

- **PRESERVE**: upstream merged behavior that must not be reverted.
- **APPLY**: current issue's intended field/type/refactor changes.
- **VERIFY**: exact tests/greps proving both sides survived.

Send in one payload; do not pick an option first and send guidance later.

### `force-push-prompt`

All predicates must pass: `--force-with-lease`, no sibling dependency on the ref, and remote tip belongs to the current orchestrator identity. Otherwise escalate.

### `audit-relation-prompt`

Use `child of` only when the proposed child scope does not intersect another live PR. Otherwise prefer `related`, capture created issue metadata, and let `terminate.md` report it.

### `merge-now` / UNKNOWN force merge

`merge-now` trusts the orchestrator's CI/review gates and adds only cross-session conflict checks. `merge-ready-but-unknown` / `force-merge-confirm` require the force-merge predicate from `patterns/conflict-detection.md`.

### `external-fix-suggestions` / `cycle-fix-suggestions`

Apply in-domain mechanical fixes in the current PR. Defer different scope, measurement, blocked dependency, or architectural decisions. Escalate on scope creep.

### Verify-don't-trust post-action

After any agent claims a structural change is complete, verify before advancing issue state:

1. Check preserved function signatures in conflict files.
2. Count old/new field names for required renames.
3. Run the VERIFY command from the handler guidance.
4. On mismatch, re-message with targeted correction or escalate if the master cannot safely decide.

---

## Sending responses: three modes

`scripts/pane-respond` has three main input modes. Pick the mode that matches the prompt UX.

| Mode | When | Example |
|------|------|---------|
| Free-text payload | Type-your-own / chat answer / option plus guidance | `pane-respond <pane> "Rebase + force push.\n\nPRESERVE: ..." --tag rebase-multi-choice` |
| `--option N` | Numeric option pick | `pane-respond <pane> --option 2` |
| `--keys k1,k2,...` | Multi-step forms | `pane-respond <pane> --keys Space,Right,Enter` |

`pane-respond --option N` is harness-aware. Claude Code prompts do not treat number keys as shortcuts; the adapter sends arrow navigation plus Enter. When adding adapters, update both `lib/flightdeck-core/src/bin/pane-respond.ts` and `scripts/pane-respond.bash`, plus parity tests.

---

## General rules

- All responses go through `scripts/pane-respond` and are followed by `pane-clear-bell` on success.
- Every decision is logged to the entry/issue decision log with prompt tag, answer, and rule reference.
- Generic handlers must remain PR/Linear/GitHub/worktree-free.
- Issue handlers must require `kind="issue"` and treat non-issue entries as `domain-mismatch`.
