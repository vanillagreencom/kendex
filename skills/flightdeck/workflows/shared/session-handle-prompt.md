# Workflow: `session-handle-prompt` — Generic Prompt Handler

Routes a single generic prompt/event for one tracked entry. This file is deliberately domain-neutral: no PR, GitHub, Linear, worktree cleanup, merge, rebase, force-push, or issue-audit decisions live here.

**Inputs**: `<ENTRY_ID>`, `<TAG>`, plus either a captured buffer or structured event details from `session-watch.md`.

**Pre-conditions**: master state initialized; the entry exists in `pane-registry list --format json`; entry `state == "prompting"` unless handling a terminal completion signal.

**Post-condition**: either a response was sent and logged, the entry state was advanced (`waiting|submitting|complete|cancelled|dead`), or `paused_for_user` was set.

---

## § 1: Look up entry and guard domain

Read the normalized tracked entry:

```bash
ENTRY_JSON=$(.agents/skills/flightdeck/scripts/pane-registry list --format json \
  | jq -c --arg id "<ENTRY_ID>" '.[] | select((.id // .issue) == $id)')
```

Use `pane_id` / `pane_target`, `harness`, and adapter metadata from `ENTRY_JSON` for responses.

If `<TAG> == domain-mismatch`:

1. Append a warning decision: `pane-registry log-decision <ENTRY_ID> domain-mismatch "issue-only prompt on non-issue entry"` when the entry has issue-compatible logging; otherwise record the same warning through `flightdeck-state append` on `.entries[ENTRY_ID].decisions_log`.
2. Do **not** call issue handlers or run destructive actions.
3. Set `paused_for_user = {entry_id: <ENTRY_ID>, reason: "domain-mismatch", prompt_text: <buffer/event excerpt>}` so the master asks how to proceed.
4. Return to `session-watch.md`; the loop yields.

If the entry `kind == "issue"` and `<TAG>` is generic, continue here. The issue extension resumes after this handler returns.

---

## § 2: Handler — `oc-question` / `pi-question`

Structured question events include the authoritative request payload; do not infer labels from the rendered TUI.

1. Read `request_id`, `harness`, and `question` from daemon event details. If details are absent, fetch pending questions through the adapter (`GET /question` for OpenCode, `pi-bridge questions --pid <PID>` for Pi) and match by request id.
2. Choose exact labels from `question.questions[i].options[].label` when the safe answer is known:
   - OpenCode: `pane-respond <pane_target> --harness opencode --question <request_id> --answer "<label>"`, `--answer-multi "l1,l2"`, or `--answers-json '[[...]]'`.
   - Pi: `pane-respond <pane_target> --harness pi --question <request_id> --answer "<label>"`, `--answer-multi "l1,l2"`, or `--answers-json '[[...]]'`.
3. For Pi free-form/custom answers, use `--answer-text "<text>"` only when that tab has `allowCustom=true`.
4. For OpenCode free-form answers, do not pass off-list labels; reject and follow up with a normal attached user message as documented in `patterns/opencode-questions.md`.
5. If the prompt shape is novel or the safe label/custom answer cannot be determined, set `paused_for_user = {entry_id, reason: "structured-question", prompt_text: <question excerpt>}`.
6. Log via the entry decision log with tag `oc-question` or `pi-question`.

---

## § 3: Handler — `bash-permission-prompt`

The harness is asking permission to run a bash command. Auto-approve only conservative read-only commands or Flightdeck control-plane scripts.

Allowlist patterns:

| Pattern | Why safe |
|---------|----------|
| `\.agents/skills/flightdeck/scripts/(flightdeck-state|flightdeck-daemon|flightdeck-dashboard|flightdeck-session|pane-registry|pane-poll|pane-respond|pane-clear-bell)(\s|$)` | Flightdeck control-plane helper. |
| `^git (status|log|diff|show|rev-parse|fetch|worktree list)` | Read-only git / metadata. |
| `^tmux (capture-pane|list-(windows|panes)|display-message|send-keys|select-window)` | Pane observation/response primitives. |
| `^(jq|cat|head|tail|grep|awk|sed|wc|sort|uniq|tr|cut)\s` | Read-only text processing. |

Decision:

1. Extract the proposed command from the prompt buffer.
2. If it matches the allowlist, answer the "Allow once" / "Yes" option via `pane-respond <pane> --option <N>`.
3. Otherwise set `paused_for_user = {entry_id, reason: "bash-permission-prompt", prompt_text: <command excerpt>}`.
4. Log the decision.

Issue-mode may add domain-specific read-only commands (for example `gh pr view` or `linear`) in `handle-prompt.md`; generic mode does not require those CLIs.

---

## § 4: Handler — `awaiting-direction`

The inner agent is alive but waiting for free-text guidance after a cancel/decline/no-prompt state.

1. Read `decisions_log[-1]` for this entry to recover the most recent explicit user instruction or option selected by this workflow.
2. If the last decision contains an explicit selected option or user-provided instruction, restate only that prior decision as a one-sentence continuation directive. Do not add new plan content, new scope, or a fresh technical direction.
3. If there is no explicit prior selected option/user instruction, set `paused_for_user = {entry_id, reason: "awaiting-direction-no-context", prompt_text: <buffer excerpt>}`.
4. Send the directive via `pane-respond <pane> "<directive>"` and log `awaiting-direction`.

---

## § 5: Handler — safe `generic-multi-choice`

The classifier found a bounded option list but no specific sentinel. Generic mode uses a conservative policy that never relies on PR conflict graphs or issue scope.

1. Enumerate options from numbered lines.
2. Reject destructive or domain-specific options: mutate `main`, force-push, delete branches/worktrees, close/abort issues, merge PRs, or apply issue review fixes. If any destructive/domain-specific option appears and no clearly safe continue/inspect option exists, escalate.
3. Prefer the option that continues, inspects, retries, or asks for clarification without destructive side effects. A `(recommended)` marker is a signal, not an instruction.
4. Send via `pane-respond <pane> --option <N>`.
5. Log `{chosen_option, chosen_text, reason}`.

Escalate with `paused_for_user = {entry_id, reason: "novel-prompt-shape" | "destructive-only" | "ambiguous-options", prompt_text: <buffer excerpt>}` when options cannot be enumerated or the safe choice is unclear.

---

## § 6: Handler — `terminal-state-reached`

A generic entry reported completion.

1. Verify the pane is no longer actively rendering.
2. Mark the entry `complete` through the tracked-entry state path.
3. Log `terminal-state-reached` with a short completion excerpt.
4. Do not query GitHub, infer PR state, or run repository sync from the generic lane. PR-capable lanes must define an explicit domain workflow with authoritative merge proof.
5. Do not tear down the window automatically unless the caller explicitly requested stop/remove.

Issue mode overrides verification/teardown through `close-issue.md` after mapping to the generic `complete` state.

---

## § 7: Handler — `pi-bg-task-exit`

A Pi background task in the tracked entry reached a terminal state.

1. Read `task` from daemon event details. If `task` is absent, re-poll once; if still absent, log `pi-bg-task-exit:missing-details` and return to `waiting`.
2. If `task.notifyOnExit == false`, log `pi-bg-task-exit:ignored` and return to `waiting`.
3. For generic sessions, send a neutral continuation directive:
   `Background task <id> (<command excerpt>) ended with status=<status> exitCode=<exitCode>. Inspect its log if needed and continue.`
4. Log `pi-bg-task-exit "<task.id>:<task.status>"`.
5. If the task failed and no safe generic next step is obvious, set `paused_for_user = {entry_id, reason: "pi-bg-task-exit", prompt_text: <task summary>}`.

Issue mode may inspect the same event after this generic handling to recover PR/CI/bot-review state; that logic belongs in `handle-prompt.md`, not here.

---

## Returns

To `session-watch.md` § 3. When invoked from issue mode, return to `watch.md` so issue-specific merge planning and summaries can continue.
