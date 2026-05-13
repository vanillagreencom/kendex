# Workflow: `handle-prompt` — Per-Pane Prompt Handler

Routes a single classified prompt to its handler logic, sends a response (or escalates), logs the decision.

**Inputs**: `<ISSUE_ID>`, `<TAG>` (substate from `prompt-classify`), captured buffer (from caller's last `pane-poll`).

**Pre-conditions**: master state initialized; issue is registered; state == `prompting`.

**Post-condition**: either a response was sent and decision logged, or `master_state.paused_for_user` is set with `{issue_id, reason, prompt_text}` and the watch loop will yield.

---

## § 1: Look Up Handler

Read `<ISSUE_ID>`'s registry entry to obtain `pane_target` and `worktree`:

```
.agents/skills/flightdeck/scripts/pane-registry get <ISSUE_ID>
```

Route by `<TAG>` to the matching subsection below. Each subsection is documented in detail in `patterns/prompt-handlers.md`, `patterns/conflict-detection.md`, `patterns/opencode-questions.md`, and `patterns/pi-questions.md`.

---

## § 1.4: Handler — `pi-bg-task-exit`

A `pi-background-tasks` bg_task reached a terminal state inside this issue's pane. The daemon emits this canonical event whenever a `vstack-background-tasks:event` message with `details.eventType="exit"` lands in the Pi bridge stream (vstack#15), independent of whether the inner agent's follow-up turn actually fires. Default behavior is to verify the bg_task's downstream effect (typically a PR/CI state change) and nudge the orchestrator forward rather than wait for the silent stall.

**Pre-conditions**: structured event details from `watch.md` § 2.0a carry `task.id`, `task.status`, `task.exitCode`, `task.command`, `task.notifyOnExit`. If details are absent (degraded event path), re-poll the pane once before falling through to escalation.

1. Read `task` from the daemon event details. If `task.notifyOnExit == false` or `task` is missing → do nothing this cycle (the agent never asked to be woken); demote state back to `waiting` and log a `pi-bg-task-exit:ignored` decision.
2. Inspect `task.command` and recover bg_task intent:
   - **bot-review-wait** (matches `.agents/skills/orchestration/scripts/bot-review-wait` or `bot-review-wait `): query `gh pr view <registry.pr_number> --json statusCheckRollup,reviewDecision,labels,mergeStateStatus`. If review state matches the orchestrator's normal continuation gate (bot check `SUCCESS` + `reviewDecision == APPROVED`, or no reviewers required), send a continuation directive via `pane-respond <pane> "bot-review-wait bg_task ended (task=<id> status=<status>). PR state: <reviewDecision>/<mergeStateStatus>. Continue with the normal merge-readiness path."`. If review state is `CHANGES_REQUESTED` or checks failed, escalate with the structured PR state included.
   - **ci-wait** / generic check waiters: same shape, querying `statusCheckRollup` only.
   - **Unknown command shape**: nudge the orchestrator with `"Background task <id> (<command excerpt>) ended with status=<status> exitCode=<exitCode>. Inspect log via bg_task log id=<id> and resume."`.
3. Log: `pane-registry log-decision <ISSUE_ID> pi-bg-task-exit "<task.id>:<task.status>:<resolution>"`.
4. If the bg_task exited `failed` AND the inferred downstream state cannot be recovered (no PR number, registry has no `pr_number`, or `gh` query fails), escalate via `paused_for_user = {issue_id, reason: "pi-bg-task-exit-unknown-context", prompt_text: <task.id> <task.command excerpt>}`.

### Why this exists

The original incident (hyprtrade CC-503) silently stalled because `bg_task` transitioned `running → stopped` with `exitCode: null` and no agent turn surfaced the wake. The `pi-bg-task-exit` event makes the daemon see the terminal transition directly; this handler routes that event into the same continuation path the orchestrator would have followed if its own follow-up turn had landed.

---

## § 1.5: Handler — `oc-question` / `pi-question`

Structured question events already include the authoritative request payload; do not infer labels from the rendered TUI.

1. Read `request_id`, `harness`, and `question` from the daemon event details passed by `watch.md` § 2. If details are absent, fetch pending questions through the adapter (`GET /question` for opencode, `pi-bridge questions --pid <PID>` for Pi) and match by request id.
2. For known prompt shapes, choose exact labels from `question.questions[i].options[].label` and answer:
   - Opencode: `pane-respond <pane_target> --harness opencode --question <request_id> --answer "<label>"`, `--answer-multi "l1,l2"`, or `--answers-json '[[...]]'` for multi-tab requests.
   - Pi: `pane-respond <pane_target> --harness pi --question <request_id> --answer "<label>"`, `--answer-multi "l1,l2"`, or `--answers-json '[[...]]'` for multi-tab requests.
3. For Pi free-form/custom answers, use `--answer-text "<text>"` only when the target tab has `allowCustom=true`. This is the bridge equivalent of tabbing to the custom row and typing into the inline editor.
4. For opencode free-form answers, do not pass off-list labels; reject and follow up with a normal attached user message as documented in `patterns/opencode-questions.md`.
5. If the prompt shape is novel or the safe label/custom answer cannot be determined, escalate by setting `paused_for_user` with the structured question payload excerpt.
6. Log via `pane-registry log-decision <ISSUE_ID> <TAG> <answer-summary>`.

---

## § 2: Handler — `cleanup-prompt`

See `patterns/prompt-handlers.md` § Handler: `cleanup-prompt`.

1. Extract the target worktree path from the prompt buffer.
2. Compare to `<ISSUE_ID>.worktree` from the registry.
3. **Equal** → answer the affirmative option (typically `1` or `Yes`). `pane-respond <pane_target> --option 1`.
4. **Not equal** → use a custom answer that scopes only to the asker's own worktree, or pick the negative option if the prompt is binary (`--option 2`).
5. Log: `pane-registry log-decision <ISSUE_ID> cleanup-prompt <answer>`.

---

## § 3: Handler — `bot-review-wait-stuck`

See `patterns/prompt-handlers.md` § Handler: `bot-review-wait-stuck`.

Master does NOT re-invoke `bot-review-wait` — that script runs inside per-issue agent contexts. Master observes the actual PR state via `gh`:

1. Query: `gh pr view <PR> --json statusCheckRollup,reviewDecision,latestReviews,labels`.
2. Parse:
   - Bot check (e.g., `Claude Code claude` workflow's `claude` job) conclusion.
   - `reviewDecision`: `APPROVED | CHANGES_REQUESTED | REVIEW_REQUIRED | null`.
   - `latestReviews`: per-reviewer state.
3. Apply decision matrix:
   - Bot check `SUCCESS` AND `reviewDecision == APPROVED` (or no human reviewers required) → answer `Skip` option in the agent's prompt.
   - Bot check `SUCCESS` AND `reviewDecision == CHANGES_REQUESTED` → escalate (review-feedback path, not bypass).
   - Bot check `IN_PROGRESS | null` AND elapsed past wait threshold → escalate; the agent's wait was indeed stuck.
   - Real human reviewer pending → escalate.
4. Log decision via `pane-registry log-decision`.

---

## § 4: Handler — `rebase-multi-choice`

See `patterns/prompt-handlers.md` § Handler: `rebase-multi-choice`.

1. Identify the **upstream issue** whose merged code now lives on main and may have logic the rebase must preserve. Heuristic: find the most recently merged issue from the master state's history that touched any file in `<ISSUE_ID>`'s PR.
2. From the upstream issue's PR, gather what to PRESERVE: changed function signatures, new wrappers, new parameters. Use `gh pr diff <upstream-PR>` against the conflict files.
3. From `<ISSUE_ID>`'s PR description / branch, gather what to APPLY: field renames, type updates, restructure surface.
4. Choose VERIFY: a test invocation that exercises the upstream fix's contract (e.g., specific test names added by the upstream PR).
5. Compose the combined payload (option label + preserve / apply / verify triplet — see `patterns/prompt-handlers.md` § Example shape).
6. Use the prompt's "Type your own answer" / "Chat about this" option to combine the option pick with the guidance.
7. Send via `pane-respond <pane_target> "<payload>" --tag rebase-multi-choice`. The script validates the triplet is present before sending.
8. Log decision.

---

## § 4.6: Handler — `stale-no-pr-branch` / `stale-orphan-worktree`

Defensive coverage for Flightdeck-scope violations (issue #18). The
per-issue `orchestration merge-pr` workflow honors a Flightdeck-mode
guard (`skills/orchestration/scripts/flightdeck-mode`) and should not
surface these prompts from a managed pane. If one still arrives —
older orchestration build, guard bypassed, prose drift — master must
refuse the destructive option.

### Decision

1. Identify the negative / keep option in the buffer. Common shapes:
   - `1. Keep branch` / `2. Delete branch` — pick `--option 1`.
   - `1. Keep worktree` / `2. Remove worktree` — pick `--option 1`.
   - Free-text or non-binary prompt — send a payload reading
     `Keep. Per-issue cleanup is scoped to the asking issue's own
     worktree/branch; unrelated artifacts are master's responsibility.`
2. Send via `pane-respond <pane_target> --option <N>` (binary) or the
   payload form above. Do NOT use `Type your own answer` to invent a
   delete instruction; the only safe answers are Keep / scope-to-self.
3. Log via `pane-registry log-decision <ISSUE_ID> <TAG> Keep`.
4. Treat the appearance as a process violation: append a note to the
   issue's `decisions_log` flagging that the per-issue pane surfaced an
   out-of-scope cleanup prompt so it shows up in the end-of-session
   report (`terminate.md` § 1) for follow-up.

Never escalate to the user for these tags — the safe answer is
mechanical, and asking the user wastes their attention on a bug that
should have been caught upstream.

---

## § 4.5: Handler — `force-push-prompt`

Per-issue agent has prompted to force-push (typically over an orphan or diverged remote ref). Master auto-approves only when the push is bounded.

### Auto-approve predicate

All must be true:

1. The push uses `--force-with-lease` (NOT `--force`). Re-read the prompt buffer and confirm the lease flag is present in the proposed command.
2. No other in-flight session's PR depends on this branch's remote ref. Cross-check `pr-conflict-graph` against the issue's branch.
3. The branch's last remote commit author equals the current orchestrator's identity (no foreign commits on remote that would be silently dropped).

If the predicate is satisfied → answer the affirmative option via `pane-respond <pane> --option <N>`.

If any clause fails → escalate (`paused_for_user`) with the failing reason named (`"force-push without --force-with-lease"`, `"sibling PR depends on this ref"`, `"foreign author on remote — confirm intentional"`).

Log decision via `pane-registry log-decision`.

---

## § 5: Handler — `audit-relation-prompt`

See `patterns/prompt-handlers.md` § Handler: `audit-relation-prompt`.

1. Parse the audit prompt to extract proposed new issues with their structure column (`child of <X>` / `related to <X>` / `none`).
2. For each proposed `child of <current-PR-issue>`:
   - Run a conflict check: would this child's scope (file refs in description, or inferred from title) intersect with any other live worktree's PR file set?
   - **No conflict** → accept `child of` (expansion bias).
   - **Conflict** → use `Type your own` to redirect — propose `related` instead, or a different parent.
3. For proposed `related to <X>` with `X` being the current-PR-issue → respect the audit (`related` is the safe default for follow-ups).
4. Submit the audit response with the master's structure choices applied.
5. Capture each created issue's `id`, `title`, `parent`, `project`, `priority` in master state for the end-of-session report — append to `<ISSUE_ID>.decisions_log` and to a top-level `created_issues` array (initialize on first creation).
6. Log decision.

---

## § 6: Handler — `merge-now`

The per-issue agent has prompted to merge its PR. Orchestration has already gated on review-approved, CI-passing, threads-resolved, and branch-protection — that's why this prompt exists. Master does NOT re-validate those gates; it answers the prompt.

The only check master adds is one orchestration cannot see: cross-session conflict with other in-flight panes.

1. Cross-session conflict check via `pr-conflict-graph <THIS_PR> <OTHER_LIVE_PRS...>`. If this PR's file set overlaps with another in-flight session whose PR is still open and unmerged → escalate (the right action is to land the other one first, or coordinate; master can't decide unilaterally).
2. No conflict → answer `Merge` via `pane-respond <pane> --option <N>` where N is the merge option's index (typically 1).
3. If the orchestrator's prompt also indicated `mergeStateStatus == "UNKNOWN"` (sometimes surfaced as a sub-message), defer to § 7 (`merge-ready-but-unknown`) — the orchestrator hasn't actually finished gating yet.
4. Log decision.

Opt-out: `FLIGHTDECK_AUTO_MERGE=0` escalates this prompt unconditionally instead of auto-answering. For sessions where the user wants the human gate (compliance review, big-blast-radius PR).

---

## § 7: Handler — `merge-ready-but-unknown` & `force-merge-confirm`

See `patterns/conflict-detection.md` § Handler: `merge-ready-but-unknown`.

1. Compute `(now - unknown_since)`.
2. Evaluate force-merge predicate:
   - `reviewDecision == APPROVED`
   - All checks in `{SUCCESS, SKIPPED}`, zero `FAILURE`
   - `unknown_since` elapsed ≥ `FLIGHTDECK_FORCE_MERGE_AFTER_SECS`
   - Content disjoint: this PR's files don't intersect main's recent commits (use `pr-conflict-graph` against post-base PR head).
3. Re-fetch immediately before deciding. If state flipped to `DIRTY | BEHIND` with overlap → escalate.
4. **Predicate satisfied** → answer the affirmative force-merge option.
5. **Predicate not satisfied** → answer `Wait` if elapsed < threshold, else escalate.
6. Log decision.

---

## § 8: Handler — `external-fix-suggestions`, `cycle-fix-suggestions`, and computed `scope-creep-detected`

For `scope-creep-detected`, do not answer the pane. Set `master_state.paused_for_user = {issue_id: <ISSUE>, reason: "scope-creep-detected", prompt_text: <summary of actual_files vs scope_files_declared>}` and yield to the user. The tag is computed by the watch/handler pipeline from PR file counts, not emitted by `prompt-classify` from pane text.

Per-issue agent surfaces a list of review-suggested fixes with options (All / subset / None).

1. For each fix item, evaluate per `patterns/decision-biases.md` § PR/branch expansion bias:
   - In-domain, mechanical, no defer-trigger → mark for inclusion.
   - Different scope / requires measurement / blocked dep → mark for defer (separate issue).
2. **All in-scope** → answer `All` (or equivalent).
3. **Mixed** → answer with the in-scope subset; flag deferred items for follow-up issue creation.
4. **Scope-creep risk** (the proposed fixes would push the PR's `actual_files` past `2 × declared_files`) → escalate.
5. Log decision.

---

## § 9: Handler — `descope-related`

The agent's reconciliation pass found that a sibling issue's scope has been partially absorbed by the current PR (e.g., a follow-up's first bullet is already implemented).

1. Default → answer the affirmative descope option. Reconciliation is a Linear-tracking action, not a code change.
2. Master state captures the descope action in `<ISSUE_ID>.decisions_log` for the end-of-session report.

---

## § 10: Handler — `bash-permission-prompt`

The harness is asking permission to run a bash command. Default state is bypass-enabled (`--dangerously-skip-permissions` for Claude Code, pre-flight `bypassPermissions` settings file) so this prompt should be rare. It surfaces when:

- Bypass was opted out via `OPEN_TERMINAL_NO_BYPASS=1` / `OPEN_TERMINAL_NO_BYPASS_SETTINGS=1`.
- Harness has no bypass flag wired yet for that scenario (codex / opencode rely on per-pane permission deny, not a CLI bypass flag).
- A specific command pattern bypassed the harness's allowlist (e.g., shell substitutions tripping the parser).

### Allowlist auto-approve

Master maintains a regex allowlist of command patterns that are safe to auto-approve. The allowlist is conservative — anything not matching escalates.

Patterns to match (from the prompt's command excerpt):

| Pattern | Why safe |
|---------|----------|
| `\.agents/skills/[^/]+/scripts/[^/]+` | Vstack-installed skill scripts (orchestration's `workflow-state`, github skill commands, linear CLI, etc.) — these are part of the skill contract |
| `^gh (pr (view|list|files|diff|checks)|issue view|run (list|view))` | Read-only `gh` calls |
| `^git (status|log|diff|show|rev-parse|fetch|worktree list)` | Read-only git |
| `^tmux (capture-pane|list-(windows|panes)|display-message|send-keys|select-window)` | Pane observation and response (master's own primitives, indirectly) |
| `^(jq|cat|head|tail|grep|awk|sed|wc|sort|uniq|tr|cut)\s` | Read-only text processing |
| `^(linear)\s` | Linear CLI wrapper handles its own auth and scope |

### Decision

1. Extract the proposed command from the prompt buffer.
2. If the command matches any allowlist pattern → answer the "Allow once" / "Yes" option via `pane-respond <pane> --option <N>`.
3. Otherwise → escalate. The user reviews and either approves once, approves always (which the harness records), or denies.

Allowlist additions are skill-level concerns, not project-level. If a project frequently sees a non-allowlisted prompt for a routine command, the right response is usually to add the command's wrapper to a skill, not to widen the allowlist for arbitrary patterns.

---

## § 10.5: Handler — `awaiting-direction`

Inner agent has emitted a recoverable post-cancel / post-decline state with no prompt to answer (e.g., "Awaiting user direction" after a Cancel during error recovery, or "User declined to answer questions" after the user backed out of a multi-choice prompt). The agent is alive and waiting for free-text guidance.

### Decision

1. Read the issue's `decisions_log[-1]` from the registry to recover the most recent intent — what prompt was being answered, what action the inner agent was attempting.
2. Synthesize a one-sentence continuation directive that matches that intent. Example mappings:
   - Last decision was a `cycle-fix-suggestions` Apply that the user cancelled → "Apply the previously-listed fix suggestions inline; if any required clarification, surface it via a follow-up prompt rather than declining."
   - Last decision was a `merge-now` Skip → "Resume merge sequencing for this PR; check `gh pr view` for merge readiness and proceed."
   - No prior decision context (registry empty) → escalate via `paused_for_user` with reason `awaiting-direction-no-context`. Master cannot synthesize a directive without knowing what the agent was doing.
3. Send via `pane-respond <pane> "<directive>"` (free-text payload mode). No `--tag` validation.
4. Log: `pane-registry log-decision <ISSUE_ID> awaiting-direction "<directive-summary>"`.

### Why this exists

Without this handler, `prompt-classify` would have routed the buffer to `idle` (no option-list footer) and the daemon would never fire wake. The pane sits indefinitely until the user manually addresses it. The classifier's `awaiting-direction` sentinel + this handler converts the dead-end into a recoverable resume.

---

## § 11: Handler — `generic-multi-choice`

No specific tag matched. The classifier returned a generic option-list — bounded numeric options, possibly with a "(recommended)" marker on one option, possibly with a "Type something" free-text option at the end.

Master tries to auto-decide before falling back to escalation. Escalation is reserved for genuine novelty, not for rubber-stamping bounded choices.

### Auto-decide policy

1. **Enumerate options** from the buffer. Each option is a numbered line; capture text per option and note any `(recommended)` marker.
2. **Detect destructive options** — anything that would mutate `main` directly, force-push, abort the issue, revert the agent's work, or close a PR. If the only viable option is destructive, escalate.
3. **Apply expansion bias** (see `patterns/decision-biases.md` § PR/branch expansion bias):
   - Default action: pick the option that bundles the most into the current PR / advances the issue toward terminal state. Examples: "Apply all", "Delegate now", "Include in this PR".
   - Override to a more conservative option ONLY when:
     - `pr-conflict-graph` shows the proposed work touches files another in-flight session is also editing → split.
     - Proposed work is clearly different scope (different module, different concern, different agent role) → defer to standalone follow-up.
4. **Use the `(recommended)` marker as a SIGNAL, not an instruction**. The inner agent's "(recommended)" reflects its own conservatism. Master weighs it against expansion bias and the conflict graph; agreement is incidental, not the deciding factor.
5. **Send via `pane-respond <pane> --option <N>`**. Log `{chosen_option, chosen_text, inner_recommended_option, agreed: bool, reason, conflict_graph_state}` to the decision log.

### When to escalate

- Cannot enumerate options reliably (buffer truncated, options span multiple lines unparseably).
- All options are destructive or all are deferrals with no expand-now choice.
- Cross-session conflict graph is itself ambiguous (some PRs UNKNOWN, can't compute overlap).
- Buffer matches a shape no rule above covers (truly novel).

On escalation: `master_state.paused_for_user = {issue_id: <ISSUE>, reason: "novel-prompt-shape" | "ambiguous-conflict" | "destructive-only", prompt_text: <buffer-excerpt>}`. The watch loop yields. After user resumption the prompt's hash will have changed, so debounce won't re-fire.

---

## Returns

To `watch.md` § 4 (or `§ 3` continuation if multiple windows are prompting in the same cycle).
