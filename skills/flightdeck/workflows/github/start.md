# Workflow: `github start` — GitHub Issue Lane

Start a GitHub-issue Flightdeck session. This lane is intentionally **not** a supervisor recursion path: the spawned child pane receives a self-contained implementation prompt and must not invoke flightdeck again.

**Inputs**: `<ISSUE_NUMBER>` numeric GitHub issue number, optional launch profile.

**Pre-conditions**:
- `$TMUX` set.
- `github` and `worktree` skills available. Do not load `linear` or `project-management` for this lane.
- `gh` authenticated against the target repo.

**Post-condition**: a tracked `kind="issue"` entry exists with GitHub metadata under `entry.domain.github_issue`, the child pane is running in branch `issue-<N>`, and `workflows/github/watch.md` owns supervision.

---

## § 1: Resolve issue context

1. Resolve repo:
   - Prefer `--repo <OWNER/REPO>` if supplied.
   - Else parse `git config --get remote.origin.url`.
   - Else run `gh repo view --json nameWithOwner --jq .nameWithOwner`.
2. Fetch issue context:
   ```bash
   gh issue view <N> --repo <OWNER/REPO> --json number,title,body,url,labels
   ```
3. If any `gh` command fails, retry once after 2s. On second failure:
   - Emit activity warning: `github-start gh-cli-unavailable command=<cmd> stderr=<stderr>`.
   - Set `paused_for_user = {issue_id: <N>, reason: "gh-cli-unavailable", prompt_text: <stderr>}`.
   - Stop; do not spawn a pane.

---

## § 2: Compose child prompt

The child prompt is plain text. It is the child's first user message and contains all issue context needed for implementation. It must not contain flightdeck or orchestration slash-command invocations.

<child_prompt_format>
Fix GitHub issue <REPO>#<N>: <TITLE>

Issue body:
<BODY>

URL: <URL>

Instructions:
- Read the project's CLAUDE.md or AGENTS.md for binding repo rules.
- Verify the bug or scope against the actual source before writing code (verify-don't-trust).
- Push commits to branch issue-<N>.
- Open a PR with `Fixes #<N>` in the body so GitHub auto-closes on merge.
- Do NOT bump any version numbers.
- Do NOT merge the PR yourself; the supervisor reviews + merges.
- Print the PR URL as the LAST line of your final message.
</child_prompt_format>

If the prompt is larger than 4 KiB, write the full prompt to `<worktree>/tmp/brief.md` and pass this pointer prompt instead:

<child_pointer_prompt_format>
Read tmp/brief.md and execute. Print the PR URL as the LAST line of your final message.
</child_pointer_prompt_format>

---

## § 3: Create worktree

1. Run preflight worktree check if not already done by the caller:
   ```bash
   .agents/skills/worktree/scripts/worktree check
   ```
2. Create or reuse a GitHub issue worktree. The worktree id is numeric, but the branch must be `issue-<N>`:
   ```bash
   WT_PATH=$(.agents/skills/worktree/scripts/worktree create <N> issue-<N>)
   ```
3. If the worktree tool reports rebase conflicts or dirty state, pause for the user. Do not mutate `main`.

---

## § 4: Launch child pane

1. Select explicit harness/model/effort profile. Recommended defaults match Linear's § 4.0:
   - Claude max: `--harness claude --model 'opus[1m]' --effort max`
   - Codex xhigh: `--harness codex --model gpt-5.5 --effort xhigh`
   - Pi xhigh: `--harness pi --model openai-codex/gpt-5.5 --effort xhigh`
   - OpenCode xhigh: `--harness opencode --model openai/gpt-5.5 --effort xhigh`
2. Launch through `open-terminal`:
   ```bash
   .agents/skills/flightdeck/scripts/open-terminal --tracker github --repo <OWNER/REPO> <N> <LAUNCH_FLAGS>
   ```
3. Contract by harness:
   - Pi: positional plain-text prompt, e.g. `pi --model ... "<child prompt>"`.
   - Codex: positional plain-text prompt, e.g. `codex -m ... "<child prompt>"`.
   - Claude: positional plain-text prompt, e.g. `claude -n <N> ... "<child prompt>"`.
   - OpenCode: `--prompt "<child prompt>"`.
4. Forbidden child invocations: do not pass any master-side flightdeck workflow command. The child implements the issue directly.

---

## § 5: Register GitHub domain entry

The tracked entry id is `<N>` and `kind="issue"`. GitHub metadata must be stored under `entry.domain.github_issue`, not `entry.domain.issue`.

Minimum shape:

```jsonc
{
  "domain": {
    "github_issue": {
      "number": <N>,
      "url": "https://github.com/<REPO>/issues/<N>",
      "worktree": "/abs/path/to/worktree",
      "pr_number": null,
      "merge_commit": null,
      "scope_files_actual": null
    }
  }
}
```

Linear entries keep `entry.domain.issue` unchanged. Mixed sessions may contain both domain keys on different entries.

---

## § 6: Enter watch

Invoke `workflows/github/watch.md <N>` after spawn. `watch.md` reuses `workflows/shared/session-watch.md` for daemon/poll mechanics, then adds GitHub PR/CI/review handling.

## Returns

To the GitHub issue watch loop.