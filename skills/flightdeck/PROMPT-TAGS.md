# Flightdeck prompt tag reference

Reference doc extracted from `SKILL.md`. See [`SKILL.md`](./SKILL.md) for the load-bearing rules; this file holds the detailed `prompt-classify` tag catalog for on-demand consultation.

## Classifier contract

`prompt-classify` is a regex/sentinel + computed-tag matcher. It maps pane state to a handler tag consumed by `pane-poll`, `session-watch.md`, `session-handle-prompt.md`, and issue-mode `handle-prompt.md` workflows.

`--entry-kind` guards issue-only tags on non-issue entries. If kind is omitted or `--entry-kind-unknown` is passed, issue-only tags fail closed as `domain-mismatch`.

## Pane-text tags

| Tag | Handler domain | Purpose |
|-----|----------------|---------|
| `rendering` | generic | Pane still rendering; do not answer yet. |
| `terminal-state-reached` | generic + issue | Pane reached a completion/terminal state; route to summary or close workflow. |
| `bash-permission-prompt` | generic | Harness asks whether to allow a shell command. |
| `force-merge-confirm` | issue | Prompt asks whether to force-merge. Apply conflict/UNKNOWN gate first. |
| `merge-ready-but-unknown` | issue | GitHub merge state is `UNKNOWN`; apply timer and force-merge predicate before acting. |
| `merge-now` | issue | Prompt asks to merge now; verify authoritative PR state before answering. |
| `bot-review-wait-stuck` | issue | Bot/reviewer gate appears stuck; verify check/review state before skip/wait/escalate. |
| `rebase-multi-choice` | issue | Rebase/update branch prompt that needs preserve / apply / verify guidance in the same response. |
| `force-push-prompt` | issue | Prompt asks whether force-push is allowed; escalate unless workflow rules explicitly allow it. |
| `cleanup-prompt` | issue | Prompt asks to remove worktree/files; compare prompt path to registered worktree before yes. |
| `audit-relation-prompt` | issue | Prompt asks parent/related issue relationship; apply parent-vs-related rule. |
| `descope-related` | issue | Prompt proposes descoping into a follow-up/related issue. |
| `external-fix-suggestions` | issue | Prompt proposes fixes outside current issue scope. |
| `cycle-fix-suggestions` | issue | Prompt proposes next-cycle fixes. |
| `scope-creep-detected` | issue computed | Computed scope expansion guard; escalate rather than auto-revert. |
| `multi-select-tabbed` | generic | Structured tabbed multi-select prompt. |
| `awaiting-direction` | generic | Agent asks for free-form or novel direction. |
| `generic-multi-choice` | generic | Bounded-choice prompt with no issue-only semantics. |
| `domain-mismatch` | generic guard | Issue-only tag appeared on non-issue or unknown entry; skip issue handler and pause. |
| `idle` | generic | No actionable prompt detected. |

## Daemon/event-only tags

These tags come from harness events, not normal assistant text classification.

| Tag | Source | Purpose |
|-----|--------|---------|
| `oc-question` | OpenCode question event | Structured OpenCode question waiting for answer. |
| `pi-question` | Pi question event | Structured Pi question waiting for answer. |
| `pi-subagent-completion` | Pi subagent event | Inner Pi subagent completion surfaced to tracked pane. |
| `pi-bg-task-exit` | Pi background task event | Background task exited; wake master through daemon path. |
| `pi-activity-broker` | Pi activity broker | Activity-only broker row; copied to activity sidecar without waking master. |
| `pi-rate-limit-retry` | Pi rate-limit watchdog | Rate limit detected and retry scheduled. |
| `pi-rate-limit-exhausted` | Pi rate-limit watchdog | Retry ladder spent; normal completion/blocking flow resumes. |
| `daemon-exited` | Flightdeck daemon lifecycle | Daemon exited for master-gone, signal, or recorded reason; route through respawn/recovery flow. |
