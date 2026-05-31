# QA Review Lifecycle

**The workflow for QA agents — project-configured QA specialists invoked via `needs-*` labels.**

QA agents are review-only. They are never assigned as issue owners.

**Ownership**: You review ONE PR. Return verdict to orchestrator. No issue tracker state changes.

---

## 1. Set Up

### 1.1 Read Context

```bash
.agents/skills/linear/scripts/linear.sh cache issues get [ISSUE_ID]
.agents/skills/linear/scripts/linear.sh cache comments list [ISSUE_ID]
```

Extract from delegation prompt:
- Dev agent's completion summary
- Which `needs-*` label triggered this review

---

## 2. Execute Review

### 2.1 Read Decision/Research Context

Before reviewing, use the decider skill's search workflow: `.agents/skills/decider/scripts/decisions search "[RELEVANT_KEYWORDS]"` for decisions governing the changed areas. If matches found, read the full decision files — index summaries are insufficient for understanding scope and rejected alternatives. If the delegation prompt includes additional decision context, read those too.

**Suggestions that contradict active decisions are invalid** unless the decision itself is flawed (flag as blocker with justification, citing the specific decision and why it's wrong).

### 2.2 Identify Changed Files

```bash
.agents/skills/github/scripts/git-diff-summary -C [WORKTREE_PATH]
```

Use domain grouping and risk flags to focus review on changed files relevant to your domain.
**Exclude**: Research documents — historical research artifacts, not reviewable code or docs.

### 2.3 Run Agent Review

Run your agent-specific review. See your agent file for exact commands and Output section for blocker/suggestion mapping.
Apply the reviewer skill's General Review Ethos and Reviewer Scope Boundaries. Stay within this agent's domain; do not duplicate another specialist unless your domain adds distinct evidence, impact, or remediation.

### 2.4 Classify Regressions (performance QA agent only)

**Skip if** not the performance QA agent or no regressions detected (exit code 0).

When the benchmarking skill's regression check exits with code 1, classify every regressed operation using the project's benchmarking skill. Populate `blockers[]` and `qa_metadata.perf_qa.regressions[]` per your agent's Output section.

### 2.5 Record Benchmark Results (performance QA agent only)

**Skip if** not the performance QA agent.

- **Backend changes**: Pipe benchmark output through the benchmarking skill's parser for automatic recording
- **Frontend/UI changes**: Run a project-specific perf capture tool and pipe results to the benchmarking skill's record command
- **Manual entry**: Run the benchmarking skill's record command with the component name and JSON data

See the project's benchmarking skill for full recording details if available.

If the project has feature-gated benchmark targets, performance QA must include
them in any claimed "full benchmark" run. A successful bare `cargo bench` is
not enough if active lanes require explicit features such as `live-feeds` or
`ui-bridge`.

If the parser records zero results, stop and report the harness gap instead of
counting the run as benchmark coverage. Common causes are missing required
features, parser prefix drift after bench refactors, or tool output format
changes.

**Note**: Benchmark results may be symlinked to the main repo in worktrees. Results are written directly to main's directory — no commit needed. Record the latest commit SHA from your worktree branch as the benchmark commit in your return output (§ 3).

### 2.6 Return JSON Report

1. **Build JSON** per [`../schemas/review-finding.md`](../schemas/review-finding.md), filename `[WORKTREE_PATH]/tmp/review-[AGENT]-YYYYMMDD-HHMMSS.json`.
   - Standard fields: `agent`, `timestamp`, `verdict`, `summary`, `blockers[]`, `suggestions[]`
   - If performance QA agent: include `benchmark_commit` from § 2.5
   - `qa_metadata.[agent_type]` populated per your agent (project-configurable):

   | Agent | qa_metadata key | Required fields |
   |-------|-----------------|-----------------|
   | safety audit (example) | `safety` | `tool_results`, `unsafe_block_count`, `violations[]` |
   | performance QA (example) | `perf_qa` | `percentiles`, `regression_pct`, `regressions[]`, `platform`, `baseline_sha` |
   | architecture review (example) | `arch_review` | `dimension_scores`, `overall_score`, `pass` |

   **Verdict rules:**
   - `action_required`: 1+ items in `blockers[]`
   - `pass`: `blockers[]` empty

2. **Return the JSON** in your response (the calling agent writes the file):

---

## 3. Complete

Send this result to the orchestrator as an agent-to-agent message. **Writing the JSON to disk is not a return** — the orchestrator does not poll the filesystem, and turn text is not visible across team boundaries. Send exactly one message with the body below, then go idle.

**Return exactly**:

<output_format>
QA_COMPLETE
verdict: [pass|action_required]
agent: [AGENT_NAME]
benchmark_commit: [SHA or "none"]
File: tmp/review-[AGENT]-YYYYMMDD-HHMMSS.json
```json
{complete JSON object}
```
</output_format>

---

## Constraints

**Do NOT**:
- Claim the issue (`.agents/skills/linear/scripts/linear.sh issues activate`)
- Modify issue tracker state (labels, status)
- Mark issue done
- Create commits for code changes or push changes
- Call other subagents

**Note**: Benchmark results may be symlinked — writes go directly to main repo, no commit needed (§ 2.5).

**Orchestrator handles**: All issue tracker updates, routing blockers back to dev agent, merging JSONs, presentation.
