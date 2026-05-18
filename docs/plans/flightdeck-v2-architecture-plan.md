# Flightdeck v2 — Architecture Cleanup Plan

**Status:** Draft. Execute after PRs #123 / #124 merge and `main` syncs with `origin/main`.

**Owner:** Autonomous execution by the orchestrating agent. One PR per phase (or merged-bottom-up if phases are independent).

**Hard rule:** Linear workflow **behavior** is preserved exactly. File locations, command surface, and skill prose may be reorganized; the rules inside `start.md` / `watch.md` / `merge-plan.md` / `close-issue.md` / `handle-prompt.md` / `terminate.md` are not changed.

**Hard rule:** No legacy compromises elsewhere. No backwards-compat aliases for renamed commands. No "deprecated" branches. Engineering, not patching.

---

## 1. Why

Three implicit lanes today, with a confused command surface:

1. **Linear issue workflow** (mature, well-loved, ~7 workflow files, hard-wired to Linear + project-management).
2. **Generic session management** (works, but no PR/review/merge semantics).
3. **Planning pass-through** — `cycle-plan`, `audit-issues`, `roadmap-*`, `research-*` (these are really `project-management` commands surfaced via flightdeck).

Pain points:

- No GitHub-issue workflow. GitHub-only repos either fall through to generic (no PR semantics) or hack the Linear path.
- `start` (Linear) collides with `session start` (generic). Lane is unclear from the command alone.
- `SKILL.md` is ~1500 lines, dense, hard for an AI agent to parse to find the right workflow path.
- `README.md` mixes user-facing prose with implementation detail (schema, env vars, daemon internals).
- Slash-command reload: every daemon wake emits `/skill:flightdeck watch --from-daemon`, which re-expands the entire SKILL.md into the master agent's context as a fresh user message — wasted tokens, unnecessary re-load.

---

## 2. Target

### 2.1 Three explicit lanes, each with their own subcommand group

| Lane | Command prefix | Purpose | Use when |
|------|----------------|---------|----------|
| Linear | `flightdeck linear *` | Linear-tracked issue lifecycle | Linear repo |
| GitHub | `flightdeck github *` | GitHub-tracked issue lifecycle | GitHub-only repo |
| Session | `flightdeck session *` | Generic tmux pane orchestration | Anything that's not issue-tracked |

`project-management` commands (`cycle-plan`, `audit-issues`, `roadmap-*`, `research-*`) move out of flightdeck. They are project-management skill commands and should be invoked as `project-management <verb>` (or however project-management chooses to surface them). Flightdeck no longer documents or routes them.

### 2.2 Verbs per lane

**Linear** (renamed from current top-level, behavior unchanged):

| New | Old |
|-----|-----|
| `flightdeck linear start [ID]` | `flightdeck start [ID]` |
| `flightdeck linear start new [title]` | `flightdeck start new` |
| `flightdeck linear watch [IDS...]` | `flightdeck watch [IDS]` |
| `flightdeck linear parallel-check [IDS]` | `flightdeck parallel-check` |
| `flightdeck linear merge-plan` | `flightdeck merge-plan` |
| `flightdeck linear close-issue <ID>` | `flightdeck close-issue` |
| `flightdeck linear terminate` | `flightdeck terminate` |

**GitHub** (NEW, pared-down strict subset):

| Verb | Behavior |
|------|----------|
| `flightdeck github start <N>` | Resolve issue via `gh issue view`, create worktree, spawn pane, register entry, enter github watch loop |
| `flightdeck github start new [title]` | Create issue via `gh issue create`, then `flightdeck github start <N>` |
| `flightdeck github watch [Ns...]` | Issue-extension of `shared/session-watch.md` with PR/CI/review prompt handlers |
| `flightdeck github close-issue <N>` | Verify terminal state, close issue if not auto-closed by merge, kill window |
| `flightdeck github terminate` | Session summary (PR + new-issues + worktree cleanup recommendations) |

No `merge-plan` (no project/parent-child/audit/relation concept exists in vanilla GitHub issues). No `parallel-check` (file-overlap conflict graph belongs to `merge-plan`).

**Session** (renamed, behavior unchanged):

| New | Old |
|-----|-----|
| `flightdeck session start ...` | `flightdeck session start ...` (unchanged invocation) |
| `flightdeck session attach ...` | unchanged |
| `flightdeck session watch ...` | unchanged |
| `flightdeck session status` / `stop` / `remove` | unchanged |

### 2.3 Workflow file layout

```
workflows/
  shared/
    session-watch.md               # generic daemon/poll/handler loop
    session-handle-prompt.md       # generic prompt handlers
  linear/
    start.md
    start-new.md
    watch.md
    handle-prompt.md
    merge-plan.md
    close-issue.md
    terminate.md
    parallel-check.md
  github/
    start.md
    start-new.md
    watch.md
    handle-prompt.md
    close-issue.md
    terminate.md
  session/
    start.md                       # documents the bare flightdeck-session start flow for an LLM
```

`linear/*.md` are byte-for-byte copies of today's top-level workflow files (just moved), with internal cross-references updated.

`shared/*.md` are today's `session-watch.md` and `session-handle-prompt.md`, unchanged content, moved into `shared/`.

`github/*.md` are net-new and intentionally a subset of `linear/`. They reuse `shared/session-watch.md` and `shared/session-handle-prompt.md` for plumbing; the github-specific files only describe github verb prose (PR/CI/review prompts, github close, github terminate).

### 2.4 Scripts layout

No changes. Scripts stay flat under `scripts/`; multiple lanes share them.

`open-terminal` is the one piece worth a closer look: today it's Linear-shaped (default `GH_ISSUE_PATTERN=[A-Z]+-[0-9]+`). For the GitHub lane, either (a) extend it to accept pure-numeric IDs when a `--tracker github` flag is set, or (b) add a sibling `github-issue-spawn` script. **Decision:** extend `open-terminal` with `--tracker github` — single source of truth for "spawn an issue worktree pane" is cleaner than two scripts.

---

## 3. Skill-reload fix (orthogonal but bundled)

### 3.1 Symptom

Every daemon wake (`pi-bridge send "/skill:flightdeck watch --from-daemon"`) renders in the chat as `● Skill flightdeck · ctrl+o expand` — and emits the **entire SKILL.md content** as a fresh user-role message in the master agent's context. SKILL.md is loaded into context on session start already; re-emitting it every wake wastes tokens.

### 3.2 Root cause

Client-side slash expansion in `pi-extensions/pi-session-bridge/bin/pi-bridge.js` (or equivalent) expands `/skill:<name>` by reading the SKILL.md file and including its full content as the user message body. There is no per-session dedup: the second expansion of the same skill emits the same body.

### 3.3 Fix

Per-pi-session "skills already expanded" cache keyed by `(skill_name, content_hash)`. On second expansion of an already-expanded skill:

- Emit only the invocation text (e.g. `flightdeck linear watch --from-daemon` or just the post-skill argument).
- Prefix with a one-line reminder: `Skill flightdeck (previously loaded). Invocation: <args>`.
- Skip the SKILL.md body.

If the SKILL.md file changes mid-session (file hash differs), treat as a fresh expansion and emit the full body. This handles the case where someone `vstack refresh -g`'s mid-session.

If pi-session-bridge restarts mid-session, cache is lost; full content is re-emitted on next wake. Acceptable degradation; rare in practice.

### 3.4 Scope

This is a `pi-session-bridge` change, not a flightdeck change. It will ship as a separate commit/PR within the same flightdeck-v2 branch (or as a sibling PR if reviewers prefer to split). The behavior improvement applies to all skills, not just flightdeck.

---

## 4. SKILL.md simplification (bottom-up)

Current SKILL.md sections (rough breakdown):

| Section | Lines | Action |
|---------|-------|--------|
| STOP / required setup | ~15 | Keep, condense to 5 lines |
| Dependency modes | ~20 | Keep, condense |
| Mode (master mode prose) | ~20 | Keep |
| Commands tables (session/issue/planning) | ~80 | Re-shape into the new three-lane layout; condense |
| Skill Rules (5 sub-domains) | ~150 | Keep — these are operational decision rules, load-bearing |
| Scripts table | ~80 | **Move** to `SCRIPTS.md`; keep one-line pointer in SKILL.md |
| Long bg-task / activity-broker / daemon-exited prose | ~80 | **Move** to `SCRIPTS.md` |
| Schema — master state | ~120 | **Move** to `SCHEMA.md` |
| Reliability watchdogs | ~50 | **Move** to `WATCHDOGS.md` |
| Configuration / env-var tables | ~120 | **Move** to `ENV.md` |
| Workflows table | ~30 | Keep (small) |
| Workflow Execution rules | ~40 | Keep |
| Implementation Constraints | ~30 | Keep |
| Compaction Recovery | ~10 | Keep |
| Various prose | ~200 | Compress aggressively |

**Target:** SKILL.md under 600 lines (from ~1500). All moved content lives in sibling reference docs that the agent loads on demand.

Reference docs to create:

- `skills/flightdeck/SCHEMA.md` — master state, activity sidecar, registry, tracked entry shape
- `skills/flightdeck/SCRIPTS.md` — full script table with args, bg-task semantics, activity-broker, daemon-exited row
- `skills/flightdeck/ENV.md` — every env var (master-loop, watchdog gates, daemon hygiene, dashboard)
- `skills/flightdeck/PROMPT-TAGS.md` — `prompt-classify` tag catalog
- `skills/flightdeck/WATCHDOGS.md` — agent-end / idle-stall / edit-loop / rate-limit watchdog details

SKILL.md keeps the load-bearing rules (lane decision, escalation rules, prompt handler decision tables, workflow execution rules, implementation constraints) and points to reference docs for the rest.

**Test:** after the rewrite, an AI agent reading SKILL.md alone should be able to (a) pick the right lane for a user request, (b) run a generic `session start` invocation correctly, (c) know when to consult each reference doc. Validation: have a reviewer-doc subagent read the new SKILL.md and answer canned questions.

---

## 5. README.md rewrite (humans only)

Keep only:

- **What flightdeck is** — one short paragraph.
- **Features** — bulleted list (PR review/merge orchestration, multi-pane management, daemon-driven wake, dashboard, etc).
- **Commands quick reference** — table grouped by lane.
- **Settings users actually set** — short table of the env vars and config knobs a user (not a developer) would change.
- **High-level architecture** — 5–10 sentences max, no schema details. Maybe a 4–5 box ASCII diagram.
- **Pointers** — "For AI agents using flightdeck → see SKILL.md. For development → see DEVELOPMENT.md."

Strip:

- State schema details
- Daemon internals
- Watchdog tuning knobs (those move to DEVELOPMENT.md or ENV.md)
- Per-handler behavior tables
- All of "Workflow Execution" section

**Target:** README.md under 200 lines.

---

## 6. Tasks (phased, sequential)

Each phase is one PR unless explicitly grouped. After each PR merges to `main`, sync the next worktree before starting the next phase to avoid drift.

### Phase 0 — Pre-flight

- Verify PRs #123, #124, #125 are merged.
- `git checkout main && git fetch origin && git pull --ff-only origin main`
- `skills/worktree/scripts/worktree create flightdeck-v2`
- Subsequent phases run in that worktree.

### Phase 1 — Workflow file reorganization (no behavior change)

- Move `session-watch.md` and `session-handle-prompt.md` from top-level `workflows/` into `workflows/shared/`.
- Move Linear workflow files (`start.md`, `start-new.md`, `watch.md`, `handle-prompt.md`, `merge-plan.md`, `close-issue.md`, `terminate.md`, `parallel-check.md`) from top-level `workflows/` into `workflows/linear/`.
- Grep + sed update internal cross-references in workflow files.
- Update SKILL.md command tables to use new paths.
- Run `cd skills/flightdeck/lib/flightdeck-core && bun test && bun run typecheck`.
- One PR: "Reorganize flightdeck workflows into shared/linear subdirs (no behavior change)"

### Phase 2 — GitHub-issue lane (NEW)

- Write `workflows/github/start.md`, `start-new.md`, `watch.md`, `handle-prompt.md`, `close-issue.md`, `terminate.md`.
- Each github workflow uses `shared/session-watch.md` + `shared/session-handle-prompt.md` for plumbing and adds only the github-specific verbs.
- Extend `scripts/open-terminal` with `--tracker github` (accepts numeric issue IDs).
- Add new `prompt-classify` tags only if absolutely needed for a github-only prompt shape; reuse existing tags otherwise.
- Update SKILL.md to add the GitHub lane to command tables.
- Add github-issue parity tests under `lib/flightdeck-core/tests/parity/`.
- Smoke test: take a recently-merged GitHub issue (e.g. one of #120–#122), run `flightdeck github watch <N>` in read-only mode against the existing merged PR.
- One PR: "Add github lane: flightdeck github start/watch/close-issue/terminate"

### Phase 3 — Command surface rename (Linear)

- Decide on entry point. Today `flightdeck <verb>` is text-routing (the agent reads "flightdeck start" as a directive and routes via SKILL.md). No script entry. Rename is purely SKILL.md + workflow prose edits.
- Update SKILL.md tables: `start` → `linear start`, `watch` → `linear watch`, etc.
- Update workflow file prose to refer to the new command names where they appear.
- Update CLAUDE.md / AGENTS.md if they reference flightdeck commands.
- One PR: "Rename Linear commands to `flightdeck linear *` for explicit lane separation"

### Phase 4 — SKILL.md simplification

- Audit current SKILL.md. Tag each section: keep / move / compress / remove.
- Create `skills/flightdeck/SCHEMA.md`, `SCRIPTS.md`, `ENV.md`, `PROMPT-TAGS.md`, `WATCHDOGS.md`.
- Move content from SKILL.md into reference docs.
- Rewrite SKILL.md condensed.
- Verify target SKILL.md under 600 lines (`wc -l SKILL.md`).
- Reviewer-doc subagent validates load-bearing rules preserved.
- One PR: "Simplify flightdeck SKILL.md; move reference content to SCHEMA/SCRIPTS/ENV/PROMPT-TAGS/WATCHDOGS"

### Phase 5 — README.md rewrite

- Audit current README.md.
- Rewrite as human-facing only.
- Move tech detail to DEVELOPMENT.md if not already there.
- Verify target README under 200 lines.
- One PR: "Rewrite flightdeck README for human readers; move implementation detail to DEVELOPMENT.md"

### Phase 6 — Skill-reload fix (`pi-session-bridge`)

- Identify the slash-command expansion site in `pi-extensions/pi-session-bridge/`.
- Add per-session `(skill_name, content_hash) → already-expanded` set.
- On subsequent expansion of an already-expanded skill: emit `Skill <name> (previously loaded). Invocation: <args>` instead of the full SKILL.md body.
- On content hash mismatch: treat as fresh, full body.
- Test: unit test for the dedup logic + integration smoke (spawn a flightdeck session, force daemon wake twice, verify second wake doesn't include full SKILL.md).
- Update pi-session-bridge README/instructions to document the behavior.
- `vstack refresh -g` after commit.
- One PR: "pi-session-bridge: dedup skill expansion per session to avoid re-emitting SKILL.md on daemon wakes"

### Phase 7 — Cross-doc updates

- Update `.claude/CLAUDE.md`, `AGENTS.md`, any `agents/*.md` that reference old flightdeck commands.
- Update `skills/project-management/SKILL.md` to remove references to `flightdeck cycle-plan` etc.
- Update prompts in `.pi/prompts/` and `.claude/prompts/` that reference flightdeck.
- Grep sweep: `grep -rn "flightdeck \(start\|watch\|merge-plan\|close-issue\|terminate\|parallel-check\)" --include="*.md" --include="*.toml" | grep -v node_modules | grep -v "\.agents/" | grep -v "\.pi/agents/" | grep -v "\.claude/agents/" | grep -v "\.opencode/agents/" | grep -v "\.codex/agents/"`
- One PR (or fold into Phase 3 if small): "Update cross-references for flightdeck lane rename"

### Phase 8 — Test + review + merge per phase

For each phase's PR:

- `cd skills/flightdeck/lib/flightdeck-core && bun test && bun run typecheck`
- `cd cli && cargo test`
- Fan out reviewer subagents (arch / test / doc / error / safety) on the diff.
- Address major findings via additional commits in the same PR.
- Wait for CI green.
- Merge.

After all 7 phase-PRs merge: smoke-test end-to-end by running a real flightdeck github session against a sandbox issue.

---

## 7. Validation

1. **Linear behavior preservation:** run a Linear smoke test pre- and post-rename, diff the dashboard / activity output. Must be identical.
2. **GitHub lane works:** pick a closed GitHub issue, run `flightdeck github watch <N>` against the merged PR in read-only mode. Verify the watch loop classifies prompts correctly and reaches a terminal recommendation.
3. **Generic session unchanged:** run `flightdeck session start` smoke test, verify behavior identical to pre-change.
4. **Skill-reload dedup:** spawn a flightdeck session, force two daemon wakes, observe master's chat — second wake should show the reminder line, not full SKILL.md content.
5. **SKILL.md still load-bearing:** reviewer-doc subagent reads the new SKILL.md and answers: "How do I start a Linear issue?", "How do I start a GitHub issue?", "Where is the watchdog tuning documented?", "What does the daemon do?" — must answer correctly from SKILL.md + linked reference docs.

---

## 8. Risks

| Risk | Mitigation |
|------|------------|
| Linear behavior drifts during file move | Phase 1 is pure file rename + reference update. No logic edits. Parity tests run immediately. |
| GitHub workflow misses an edge case Linear handles | Explicit non-goals list (no merge-plan, no parallel-check, no audit/relation). If a user needs them, the answer is "use Linear or extend github mode in a separate PR." |
| Skill-reload dedup breaks slash expansion elsewhere | Test against multiple skills, not just flightdeck. Add a regression test. |
| Cross-doc rename misses references | Aggressive grep before committing each phase. List in PR body. |
| pi-session-bridge restart loses dedup cache | Acceptable; next wake re-emits full content. Cache is in-memory by design. |
| `open-terminal` `--tracker github` extension breaks Linear default | Default tracker stays Linear (`GH_ISSUE_PATTERN=[A-Z]+-[0-9]+`). Github mode is opt-in via flag. |

---

## 9. Non-goals

- Auto-detect tracker from repo config. Lane is explicit.
- Backwards-compatible aliases for old command names. No `flightdeck start` aliasing `flightdeck linear start`.
- Multi-tracker support (GitLab, Jira). Future workstream.
- Audit / parallel-check / merge-plan for GitHub mode. Intentional subset.
- Removing project-management commands from `project-management` skill. They stay there; just unreferenced from flightdeck.
- Replacing the daemon, dashboard, state schema, or activity sidecar. Those are out of scope.

---

## 10. Done definition

- All 7 phase-PRs merged to `main`.
- `git grep "flightdeck start\b\|flightdeck watch\b\|flightdeck merge-plan\|flightdeck close-issue\|flightdeck terminate\|flightdeck parallel-check"` returns no live references (only old plan docs / git history).
- SKILL.md `wc -l` < 600.
- README.md `wc -l` < 200.
- A daemon wake on a long-running flightdeck session emits a one-line reminder, not the full SKILL.md.
- Reviewer-doc subagent confirms SKILL.md still answers the four canned questions.
- One end-to-end github-lane smoke test passes against a real issue.
