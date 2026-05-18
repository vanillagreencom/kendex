# Flightdeck v3 — Plan-File Orchestration Lane

**Status:** Draft. Execute as a 4th lane on top of merged v2 architecture.

**Owner:** Autonomous execution by the orchestrating agent. Plan doc commits with the implementation PR.

**Hard rule:** Linear, GitHub, and session lanes are not modified. The plan-file lane is purely additive.

---

## 1. Why

A common workflow shape in this repo:

1. The `planner` agent (or a human) produces a plan file at `docs/plans/<name>.md`.
2. The plan file describes a multi-item implementation: 2–10+ work items, each potentially independent.
3. Someone has to orchestrate execution: per item, create a worktree, spawn an implementation pane with the right brief, watch, run reviews, fix loops, merge.

That orchestration role has been the **master agent** so far — done by hand in chat, the same pattern playing out repeatedly. This adds a 4th flightdeck lane that automates it. `flightdeck plan start <path>` does the per-item spawn/watch/merge dance; the human stays in the loop only for novel decisions and merge confirmations (per existing flightdeck safety gates).

The github and linear lanes already handle the **single-issue** case end-to-end. The plan lane handles the **N-item plan** case where one document drives multiple parallel/sequential PRs.

---

## 2. Target

### 2.1 Command surface (4th lane)

| Command | Argument | Purpose |
|---------|----------|---------|
| `flightdeck plan start <path>` | path to plan file | Parse the plan, identify work items, create worktree per item, spawn implementation pane per item, enter watch loop |
| `flightdeck plan watch [item-ids...]` | optional filter | Issue-extension of `shared/session-watch.md`: per-item PR/CI/review handling, fix-loop steering, merge gating |
| `flightdeck plan close-item <id>` | item id | Terminal validation + per-item teardown (PR merged + worktree cleanup) |
| `flightdeck plan terminate` | — | Session summary (per-item PR outcomes + new follow-ups identified during execution) |

### 2.2 Lanes recap (post-v3)

| Lane | Command prefix | Input shape | Output shape |
|------|----------------|-------------|--------------|
| Linear | `flightdeck linear *` | A Linear issue id | One PR per session |
| GitHub | `flightdeck github *` | A GitHub issue number | One PR per session |
| Plan | `flightdeck plan *` | A plan file path | N PRs per session, one per work item |
| Session | `flightdeck session *` | Bare prompt/cmd | Generic, no PR semantics |

### 2.3 Plan file format

Loose-convention markdown. Master parses with judgment; no strict schema enforced by code.

```markdown
# <Plan title>

Free-form prose: motivation, scope, non-goals, etc.

## <Work item title 1>

Brief for the implementation pane assigned to this item. Should describe:
- What to build / fix
- Acceptance criteria
- Files / modules to touch
- Tests to add or update
- Anything to AVOID

### Worktree (optional)
my-custom-name

### Depends on (optional)
<other work item title>, <another>

## <Work item title 2>

…
```

**Rules the master applies when parsing:**

- Each `## H2` section is one work item.
- Item id = slugified title (lowercase, dash-separated, alphanum-only, truncated to 32 chars).
- Worktree name = `Worktree:` override OR `flightdeck-plan-<item_id>` (so it's namespaced and doesn't collide with `issue-<N>` worktrees).
- Branch name matches worktree name.
- `Depends on:` adds dependency edges. The watch loop spawns dependency-free items first; downstream items spawn after their deps merge.
- Section content (everything between this H2 and the next H2, excluding the optional H3 subsections like `Worktree:` and `Depends on:`) becomes the implementation pane's brief.
- The H1 title is the plan title (for summary); the H1 body is informational only.

**The master is permitted to use judgment** when a plan file doesn't conform exactly — e.g., interpreting a `### Approach` H3 as part of the brief. The rules above are the happy path, not a contract.

### 2.4 Entry domain shape

Plan-lane entries live alongside linear/github/session in the same flightdeck state file. They write their own domain key:

```ts
domain?: {
  issue?: { ... };          // linear
  github_issue?: { ... };   // github
  plan_item?: {             // NEW for v3
    plan_path: string;      // absolute path to the plan file
    plan_title: string;     // H1 from the plan file
    item_id: string;        // slug
    item_title: string;     // original section title
    depends_on: string[];   // item ids this depends on
    worktree: string;       // absolute path
    pr_number: number | null;
    merge_commit: string | null;
  };
}
```

Linear's `domain.issue` shape is unchanged. GitHub's `domain.github_issue` is unchanged. Plan adds `domain.plan_item` additively.

### 2.5 File layout

```
skills/flightdeck/workflows/
  shared/                          # unchanged from v2
  linear/                          # unchanged
  github/                          # unchanged
  plan/                            # NEW
    start.md
    watch.md
    handle-prompt.md
    close-item.md
    terminate.md
```

### 2.6 Dependencies (loaded on plan-mode entry)

Plan lane dependencies — load lazily on entering plan commands:

- `github` — PR ops (every plan item ends up as a PR, regardless of whether the plan came from Linear or anywhere).
- `worktree` — per-item worktree creation/cleanup.

NOT `linear`, NOT `project-management`. Same dependency posture as the GitHub lane.

### 2.7 Sharing with the GitHub lane

The plan-lane PR lifecycle is identical to the GitHub lane PR lifecycle: open PR via `gh pr create`, watch CI, gate merge on `mergeStateStatus === "CLEAN"`, force-merge predicate, authoritative `gh pr view` verification before issue close.

The plan-lane workflows should **reuse the GitHub lane's handle-prompt prose** (merge-now, force-merge-confirm, merge-ready-but-unknown, bot-review-wait-stuck, cleanup-prompt) by referencing it where applicable, not duplicating. The plan lane's `handle-prompt.md` adds only plan-specific routing on top — e.g., the dependency-edge-resolution prompt ("item B's dep is now merged; spawn B?").

If the GitHub lane's prose can be parameterized to also serve plan items (probably yes — the `entry.domain.github_issue` references can be generalized to "the PR for this tracked entry"), we save duplication. Otherwise we accept some duplication but flag it for a later consolidation.

### 2.8 Spawn shape per work item

Same self-contained-child-prompt pattern as the github lane (no `/skill:` recursion). The brief written to `<worktree>/tmp/brief.md` is the section content from the plan file, prepended with a small header:

```
# Plan: <plan_title>
# Work item: <item_title>
# Plan file: <plan_path>

You are a Pi engineering agent working on ONE work item of a larger plan. The plan and your specific item are in `tmp/brief.md`. Read the whole brief, execute end-to-end, push a PR with body referencing the plan path + item id. Print the PR URL as the LAST line.

---

<section content from plan file>
```

The pane is spawned with prompt = "Read tmp/brief.md and execute end-to-end. Print the PR URL as the LAST line." — identical to what the master has been doing manually in this very session.

---

## 3. Phases

One PR (single substantial change):

### Phase 1: Plan lane (one PR)

Files to create:

- `skills/flightdeck/workflows/plan/start.md` — parse plan file, create worktrees, spawn panes, enter watch
- `skills/flightdeck/workflows/plan/watch.md` — supervise (uses `shared/session-watch.md` for plumbing)
- `skills/flightdeck/workflows/plan/handle-prompt.md` — plan-specific prompts (dependency resolution) + delegate PR/CI prompts to github-lane handler
- `skills/flightdeck/workflows/plan/close-item.md` — terminal validation + per-item teardown
- `skills/flightdeck/workflows/plan/terminate.md` — N-item session summary
- `skills/flightdeck/PLAN-FILE.md` — user-facing reference doc for the plan file format

Files to modify:

- `skills/flightdeck/SKILL.md` — add "Plan workflows" command table; update Dependency modes to mention plan-mode loading github + worktree; update Workflows table at bottom.
- `skills/flightdeck/README.md` — add "Plan lane" quick reference section.
- `skills/flightdeck/lib/flightdeck-core/src/state/tracked-entry.ts` (or equivalent) — extend `domain` union with `plan_item` shape. Update validators to accept the new key. `entry.domain.plan_item` is mutually exclusive with `domain.issue` and `domain.github_issue` (same shape rule as v2's github addition).
- `skills/flightdeck/lib/flightdeck-core/src/bin/open-terminal.ts` (and bash trampoline) — extend to accept `--tracker plan` if needed, OR rely on the master driving spawns directly via `flightdeck-session start --kind workflow` per item (cleaner — no new script flag). DECISION: master spawns each item via `flightdeck-session start --kind workflow --cwd <worktree> --prompt "Read tmp/brief.md..."`. No open-terminal change needed.

Tests:

- Parser test fixtures: 3–5 plan files of varying shapes (simple, with deps, with worktree overrides, malformed sections). Test the master's parsing rules (slugification, dep resolution, worktree naming). If parsing is purely master-LLM-driven, this becomes prose-test patterns rather than unit tests. If a parsing helper is added in TS, unit-test it.
- Mutually-exclusive-domain test: entry with both `domain.issue` and `domain.plan_item` is rejected, same as the v2 dual-domain test.
- Plan-spawn invocation test: confirm the per-item spawn uses self-contained prompt (no `/skill:flightdeck plan` recursion).

---

## 4. Validation

1. **Plan-mode smoke test:** create a small fixture plan file with 2 items, run `flightdeck plan start <fixture>`, verify 2 worktrees + 2 panes spawn.
2. **Dependency-edge resolution:** plan with item B depending on item A. Verify A spawns first; B spawns only after A's PR merges.
3. **Mixed-mode safety:** session has 1 Linear entry + 1 plan entry. Verify they don't cross-contaminate; terminate reports each lane separately.
4. **No regression on existing lanes:** linear/github/session smoke tests still pass.
5. **Load-bearing phrase grep** (same approach as v2 Phase 4): every command name, env var, classifier tag from the merged v2 SKILL.md must still grep-find post-v3.

---

## 5. Risks

| Risk | Mitigation |
|------|------------|
| Plan parsing is LLM-driven, so malformed plans could be silently misinterpreted | Document the convention clearly in `PLAN-FILE.md`. Master should DRY-RUN the parsing (print identified items + deps) before any worktree creation; user can abort. |
| Dependency cycles in the plan | Detect during parsing; refuse to start if a cycle exists; emit `paused_for_user` with the cycle. |
| Plan file moved/deleted mid-session | Master should `realpathSync` at start and store the resolved path; check existence on watch re-entry and pause if gone. |
| One item's failure shouldn't block others | Items without inter-dependencies should be independent. A single failed PR pauses ITS item; other items continue. `terminate` summarizes per-item outcomes. |
| Worktree name collisions with existing `issue-<N>` worktrees | Plan worktrees use `flightdeck-plan-<item_id>` prefix; namespace can't collide with `issue-<N>` form. |
| PR scope conflicts between items (same files touched) | Apply the existing conflict-graph approach from `pr-conflict-graph` if the plan items end up overlapping. May escalate via `paused_for_user`. |

---

## 6. Non-goals

- Strict plan file schema. Loose convention only.
- Multiple plans in one session. One session = one plan file.
- Cross-tracker plans (mix of Linear + GitHub items in one plan). Plan items are tracker-agnostic; PR routes through the github lane handlers.
- Plan editing mid-session. The plan file is frozen at `plan start` time; later edits are ignored unless the user re-runs `plan start`.
- Replacing project-management's `roadmap-*` workflows. Those are separate; if someone wants a roadmap to become a plan file, they can output one.

---

## 7. Done definition

- One PR merged with all of: 5 workflow files under `workflows/plan/`, `PLAN-FILE.md`, SKILL.md + README updates, state-type extension, parity tests.
- A canned plan-file smoke test passes end-to-end against a 2-item fixture plan.
- Load-bearing phrase grep passes (v2's full set preserved).
- The github and linear lanes are unchanged.
- `bun test` + `bun run typecheck` clean.
