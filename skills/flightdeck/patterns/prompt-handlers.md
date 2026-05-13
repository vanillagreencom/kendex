# Prompt handlers

Classification tags and per-tag handler logic for the prompts that surface across spawned panes during a multi-issue session.

## Classification tags

`scripts/prompt-classify` reads a captured pane buffer and returns most of these tags; computed pipeline tags use the same handler vocabulary. Each tag has a corresponding handler in `workflows/handle-prompt.md`.

| Tag | Sentinel pattern (illustrative) | Handler |
|-----|--------------------------------|---------|
| `cleanup-prompt` | `"Cleanup the .* worktree after merge"` or `"Worktree for .* exists. Cleanup"` | Cleanup scope handler |
| `stale-no-pr-branch` | `"Local branch .* has no associated PR. Delete"` | Out-of-scope under Flightdeck — always answer `Keep branch` |
| `stale-orphan-worktree` | `"orphan: .*"` or `"Stale worktree for .* \(PR already merged\). Remove"` referring to a non-asker worktree | Out-of-scope under Flightdeck — always answer `Keep worktree` |
| `bot-review-wait-stuck` | `"No bot review comments were found"` or `"Bot review hasn't started"` after defer-ci is set and `Claude Code claude` check is SUCCESS | Skip — drop defer-ci |
| `rebase-multi-choice` | `"How should I resolve the .* merge conflicts"` with options including `Rebase + force push` | Combined preserve/apply/verify payload |
| `audit-relation-prompt` | `"Create issue .*"` or `"Create the audited follow-up issues"` with structure column showing `child of` / `related` | Default `related` |
| `merge-ready-but-unknown` | `"Mergeable status still UNKNOWN"` or `"GitHub mergeable status stuck at UNKNOWN"` | Force-merge predicate (see `conflict-detection.md`) |
| `scope-creep-detected` | Computed: `gh pr view --json files | length > 2 × scope_files_declared` | Escalate to user via `handle-prompt.md` § 8 |
| `merge-now` | `"PR .* is approved with CI passing. Merge now"` | Auto-merge if no overlap with later queue |
| `external-fix-suggestions` | `"Apply the external review fix suggestions"` | Apply per expansion bias unless scope-creep risk |
| `cycle-fix-suggestions` | `"Apply fix suggestions"` post-review (also matches topical variants like `"Apply doc-wording fix from reviewer-doc?"`) | Apply per expansion bias |
| `force-merge-confirm` | `"Mergeable status still UNKNOWN after .+ min.* Force merge"` | Force-merge predicate |
| `descope-related` | `"Descope CC-.* to reflect"` | Auto-descope when reconciliation flags overlap |
| `rendering` | Buffer doesn't end with a recognized terminator (e.g., `Enter to select` footer or `❯ ` cursor) | Re-poll, do not act |
| `generic-multi-choice` | Buffer matches "multi-choice" shape but no specific sentinel | Auto-decide by bounded policy; escalate only on destructive, ambiguous, or novel choices |

If a buffer matches multiple sentinels, the most specific tag wins (e.g., `force-merge-confirm` before `merge-ready-but-unknown` before `generic-multi-choice`).

## Handler: `cleanup-prompt`

Some agents propose batch cleanup of multiple worktrees. That's wrong because parallel sessions are still using sibling worktrees.

**Rule**: answer YES iff the prompt's target worktree path equals the asking pane's registered worktree. NO for any sibling.

## Handler: `stale-no-pr-branch`

Per-issue orchestration's `merge-pr` workflow has a Flightdeck-mode guard
(`skills/orchestration/scripts/flightdeck-mode`) that suppresses the broad
"local branch without an associated PR" sweep when the pane is managed by
Flightdeck. If a prompt of this shape still reaches master — e.g. the pane
is running an older orchestration build, or the guard was bypassed — master
MUST answer `Keep branch`. Per-issue finalization has no business touching
branches that don't belong to the asking pane's registered scope; the
destructive option (`git branch -D <unrelated-branch>`) runs from the main
repo and may delete work that other live worktrees or the master's own
maintenance schedule depend on.

After answering, log a `process-violation` decision against the asking
issue: the per-issue agent should not have surfaced this prompt in the
first place, and the orchestration workflow doc should be updated to honor
the guard.

## Handler: `stale-orphan-worktree`

Same rule, different artifact: prompts of the form `"Stale worktree for
[BRANCH] (PR already merged). Remove?"` or `"orphan: <dir>"` that refer to
a worktree path other than the asking pane's own registered worktree are
out-of-scope under Flightdeck. Master answers `Keep worktree` and, where
the prompt offers a free-text response, scopes any agreed removal to the
asker's own worktree only.

The master's pane registry is authoritative for worktree ownership; do not
let a per-issue pane unilaterally retire sibling worktrees. Project-wide
orphan cleanup is a separate standalone maintenance workflow.

### Extracting the target

Cleanup prompts name the worktree path. Examples:

```
Worktree for <ISSUE> exists. Cleanup after merge?
Cleanup the <issue-slug> worktree after merge?
Remove these other merged branches? [list of branches]
```

Extraction:
1. Look for a path matching `trees/<issue-slug>` or the project's issue-ID pattern (configured via `GH_ISSUE_PATTERN`).
2. Resolve to absolute worktree path.
3. Compare to `master_state.issues[<asking_issue>].worktree`.

### Decision

- Target equals asker's own worktree → answer YES.
- Target is a different worktree (sibling) → answer NO.
- Prompt offers batch cleanup including siblings → respond with custom answer that scopes only to the asker's own worktree.

## Handler: `bot-review-wait-stuck`

When a per-issue agent's bot-review wait times out, it surfaces a Skip/Wait/Abort prompt. The per-issue agent owns the bot-review-wait script invocation; master never re-runs it. Master decides what to answer based on the **actual PR state** queried via `gh`.

### Query the PR state directly

```bash
gh pr view <PR> --json statusCheckRollup,reviewDecision,latestReviews,labels --jq '.'
```

Inspect:
- `statusCheckRollup`: find the bot's check (e.g., the workflow named `Claude Code` with job `claude`). Its `conclusion` is `SUCCESS | FAILURE | IN_PROGRESS | null`.
- `reviewDecision`: `APPROVED | CHANGES_REQUESTED | REVIEW_REQUIRED | null`.
- `latestReviews`: per-human-reviewer state, useful when there are required human reviewers.
- `labels`: confirm `defer-ci` is or isn't set.

### Decision matrix

- Bot check `SUCCESS` AND (`reviewDecision == APPROVED` OR no required human reviewers) → **Skip is safe**. Pick the Skip option in the agent's prompt; agent will remove `defer-ci` and CI will spin up.
- Bot check `SUCCESS` AND `reviewDecision == CHANGES_REQUESTED` → **don't skip**. Escalate (review-feedback path, not bypass).
- Bot check `IN_PROGRESS | null` AND elapsed past wait threshold → escalate. The bot is genuinely stuck or hasn't started.
- Real human reviewer pending → escalate. PR isn't ready.

### What happens after Skip

The per-issue agent removes `defer-ci`. GitHub's heavy CI lanes spin up. The pane transitions to `submitting (CI running)`. Master continues polling.

### Multi-bot setups

If the project has multiple bot reviewers (e.g., Claude Code + Codex), inspect each in `statusCheckRollup`. All must be `SUCCESS` for Skip to be safe.

## Handler: `rebase-multi-choice`

The most failure-prone prompt class. Wrong handling here = upstream sibling-PR fix gets reverted during rebase.

### The trap

Pane prompts: "How should I resolve the merge conflicts?" with options like:
1. Merge commit
2. Rebase + force push
3. Abort

If you pick option 2 (`Rebase + force push`) and only THEN send guidance to the dev sub-agent, the guidance arrives **after** the orchestrator has already delegated the rebase work. The dev agent has already started without the guidance and may apply renames in a way that reverts the upstream sibling-PR's bug fix.

### The rule: combine guidance with response

Pick "Type your own answer" (or "Chat about this") and send the option label + full guidance in a single input.

### The preserve / apply / verify triplet

The combined payload MUST include three sections, each named explicitly:

```
Rebase + force push.

PRESERVE: <upstream-PR>'s logic shape that arrived in main and must NOT be reverted.
  Specifically: <function signature, parameter split, new wrapper>
  Files: <conflict file paths>

APPLY: <this-PR>'s changes that go ON TOP of the preserved upstream shape.
  Specifically: <field renames, type updates, refactors>

VERIFY: After resolving, run <exact test command> and confirm <specific test names from upstream-PR> still pass.
```

### Example shape

```
Rebase + force push.

PRESERVE: <upstream-issue> changed <function-name> to take <new-signature>
  and added the wrapper <new-helper-name>.
  Do NOT collapse the signature back to the prior shape.
  Files: <conflict file paths>

APPLY: <this-issue>'s <restructure-name> renames:
  <old.path.A> → <new.path.A>
  <old.path.B> → <new.path.B>
  Apply these ON TOP of <upstream-issue>'s logic shape, not replacing it.

VERIFY: <exact test command for the project's test runner>
  The tests added by <upstream-issue> must pass:
    - <test-name-1>
    - <test-name-2>
```

### Validation

`pane-respond` rejects rebase-multi-choice payloads that don't include
all three sections. Each section must be non-empty and labeled
`PRESERVE:`, `APPLY:`, `VERIFY:`. The TS port enforces the same
contract through its validator and is covered by parity tests against
the bash body.

## Handler: `audit-relation-prompt`

When TPM audits create follow-up issues from review findings, prompts ask whether to make each new issue a `child of`, `related to`, or standalone.

### Orchestration invariant

**Child issues must be completed in the parent's branch/PR.** This is mandated by orchestration's bundled-issue workflow — `parent_id` triggers in-PR delegation to the dev agent. Picking `child of` is a binding commitment to expand the current PR.

That's not always wrong — expansion bias (see `decision-biases.md`) prefers fitting work into an existing PR when reasonable. The decision turns on whether the new child can land safely without conflicting with other in-flight work.

### Pre-decision capture

Before answering the audit prompt, capture for each proposed new issue:
- proposed `parent` (or `related` / standalone)
- proposed `project`
- proposed scope (file references in the description)
- the audit's reason

Persist this in the issue's `decisions_log` so the end-of-session new-issues report (see `terminate.md`) can summarize what was created where.

### Decision rule

For each proposed `child of <current-PR-issue>`:

1. **Conflict check**: would the new child's scope (file paths in description, or inferred from title) intersect with any **other** live flightdeck worktree's PR file set?
   - **No intersection** → accept `child of`. Expansion bias applies; the child lands in the parent's PR.
   - **Intersection with sibling worktree X** → rearrange: either propose `related to` instead (defer to a follow-up after X merges), or propose making the child a child of X if it more naturally belongs there. Use the prompt's "Type your own answer" / "Chat about this" / "Override" options to redirect.
2. **Same-domain bundle obviously OK** (no other worktree touches this domain) → accept `child of` even if it expands scope a bit.
3. **Genuinely orthogonal follow-up** (different scope, different agent, requires measurement, future-conditional) → propose `related` instead. Don't create a child that won't actually be worked on this session.
4. **Audit's own structural recommendation** says `none` (related/standalone) → respect it; the audit has more context on intent than the master does.

### What to do when the audit prompt offers a structure column

Some audits present a multi-row prompt with a `Structure` column (`child of CC-X` / `related: CC-Y` / `none`). The master should:

- Toggle ON every row whose structure passes the conflict check.
- Use `Type your own` / `Override` for rows where the structure should change (e.g., from `child of` to `related` due to conflict).
- Submit.

Then verify post-creation that each new issue's `parent_id` and `related` fields match the master's intent (Linear sometimes asynchronously sets relations).

### Recovery if a child was created with conflict

If a `child of` was accepted and afterwards a conflict surfaces (sibling worktree starts touching overlapping files):

1. Stop bundled delegation in the parent's pane (interrupt before dev agent starts on the child's scope).
2. Convert the child to `related`:
   ```
   linear issues update <NEW> --remove-parent
   linear issues add-relation <NEW> --related <PARENT>
   linear issues update <NEW> --status Backlog
   ```
3. Tell the parent's dev agent to drop the bundled work and resume original PR scope.

The conflict check at decision time is meant to prevent this recovery path.

## Handler: `verify-don't-trust` post-action

After any agent claims a structural change is complete, run a verification grep against the worktree before advancing the issue's state.

### When to apply

- Post-rebase: dev agent says "rebase done, conflicts resolved".
- Post-fix delegation: dev agent says "review fixes applied".
- Post-restructure: agent says "field renames complete".

### The verification

For rebase-multi-choice post-action specifically:

1. **Function signature check** — for any function named in the PRESERVE section, grep the file and confirm the signature matches:
   ```bash
   grep -A5 "fn <preserved-fn-name>" <worktree>/<conflict-file>
   ```
   Confirm parameter count and names match expected.

2. **Field-rename count** — for each rename in APPLY, count old vs new occurrences:
   ```bash
   grep -c "<old.path>" <file>   # MUST be 0
   grep -c "<new.path>" <file>   # MUST be > 0
   ```

3. **Test invocation** — run the VERIFY command from the rebase guidance. If failures match what was supposed to be preserved, escalate (the upstream fix was lost).

### What to do on failure

- 0 of expected new pattern AND > 0 of expected old pattern → the rename was incomplete; re-message the dev agent with a targeted fix request naming the specific lines.
- Function signature collapsed to wrong shape → the upstream fix was reverted; re-message with the rebase guidance triplet again, more emphatic.
- Tests fail → escalate to user. This indicates the rebase resolution was wrong in a way the master can't safely correct.

## Sending responses: three modes

`scripts/pane-respond` has three input modes. Pick the one that matches the prompt UX:

| Mode | When | Example |
|------|------|---------|
| Free-text payload (positional) | "Type your own answer" / "Chat about this" — combined option pick + guidance | `pane-respond <pane> "Rebase + force push.\n\nPRESERVE: ..." --tag rebase-multi-choice` |
| `--option N` | Numeric option pick from a list | `pane-respond <pane> --option 2` |
| `--keys k1,k2,...` | Multi-step form (toggle, advance page, submit) | `pane-respond <pane> --keys Space,Right,Enter` |

### Why `--option N` is harness-aware

Number keys are NOT option shortcuts in Claude Code prompts — the footer says `Enter to select · ↑/↓ to navigate`. A digit gets buffered as text (often into a "Type something" free-text field) and the trailing Enter fires on whatever option the arrow cursor is currently on, which defaults to option 1. Sending `"2"` looks like it picked option 2 but actually picks option 1; the bug is silent.

`pane-respond --option N` dispatches per harness via
`select_option_for_harness`. The Claude Code adapter sends `(N-1) ×
Down` then `Enter`. When adding adapters for new harnesses, update both
implementations while the `.bash` siblings are still in tree:
`lib/flightdeck-core/src/bin/pane-respond.ts` (default TS path) and
`scripts/pane-respond.bash` (legacy bash sibling), plus the matching
parity test under `lib/flightdeck-core/tests/parity/`. Do not extend
the Down-key mechanic blindly.

### Multi-step forms (`--keys`)

Some prompts span multiple pages: toggle a row, press Right to advance to the Submit page, press Enter to confirm. `--keys` accepts a comma-separated list of tmux key names: `Up Down Left Right Enter Tab Space Escape BSpace`. Unrecognized keys are rejected so multi-character text doesn't smuggle through this path — text belongs in payload mode.

## General rules

- All responses go through `scripts/pane-respond` which targets pane 0 explicitly.
- Every response is followed by `scripts/pane-clear-bell` to clear the window's bell flag.
- Every decision is logged to `master_state.issues[<id>].decisions_log` with the prompt tag, answer, and rule reference for traceability.
