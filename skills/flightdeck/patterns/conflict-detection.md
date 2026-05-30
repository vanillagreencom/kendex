# Conflict detection

defer-ci label semantics, file-level conflict graph between in-flight PRs, and the force-merge safety predicate.

## defer-ci semantics

The `defer-ci` GitHub label is the project's "hold heavy CI until bot review" mechanism. It's a label, not a workflow.

### What it blocks

- Lint
- Cross-Platform tests (macOS, Windows, Linux Integration)
- Bench (iai-callgrind)
- Fixture Sync
- Any workflow gated on `defer-ci` absence

### What it does NOT block

- Bot reviews (Claude Code workflow). The bot runs and posts an approval check independently of `defer-ci`.

### Implication for flightdeck

When a pane is in `submitting` state with `defer-ci` set:
- Bot review status is read by master via `gh pr view <PR> --json statusCheckRollup,reviewDecision`. Master never invokes `bot-review-wait` — that script runs inside per-issue agent contexts.
- Heavy CI lanes show as `SKIPPED` until `defer-ci` is removed.
- Don't classify the SKIPPED checks as failures — they're awaiting label removal.

Once `defer-ci` is removed (after all configured bot reviewers are in `approved | skipped` per the `bot-review-wait-stuck` handler), heavy CI lanes spin up. Watch transitions: `submitting` → `submitting (CI running)` → `merge-ready` (on CI green).

### Detection

```bash
# Is defer-ci set?
labels=$(gh pr view <N> --json labels --jq '.labels[].name')
echo "$labels" | grep -q '^defer-ci$' && echo "defer-ci ON"

# Bot check + review state (no script invocation; master observes via gh)
gh pr view <N> --json statusCheckRollup,reviewDecision \
  --jq '{review:.reviewDecision, bot:(.statusCheckRollup[]|select(.name|test("claude|codex|review-bot";"i"))|{name,conclusion})}'
# reviewDecision==APPROVED + bot.conclusion==SUCCESS → safe to drop defer-ci
```

## File-level conflict graph

Two PRs conflict iff their changed-file sets intersect. `pr-conflict-graph` builds this graph for a list of in-flight PRs.

### Algorithm

```bash
# For each PR, get its changed files
for pr in $PRS; do
  gh pr view $pr --json files --jq '.files[].path' > /tmp/pr-$pr-files.txt
done

# Build adjacency
for pr_a in $PRS; do
  for pr_b in $PRS; do
    [[ $pr_a -ge $pr_b ]] && continue
    common=$(comm -12 <(sort /tmp/pr-$pr_a-files.txt) <(sort /tmp/pr-$pr_b-files.txt) | head -1)
    if [[ -n "$common" ]]; then
      echo "[$pr_a, $pr_b]"   # adjacency edge
    fi
  done
done
```

Output: JSON adjacency keyed by PR pair, with the intersecting file list per edge.

### Granularity

File-path intersection is a conservative proxy for actual conflict. Two PRs touching the same file may not conflict at git's line level — but the master treats them as ordered.

If accuracy matters more than conservatism, augment with `gh pr diff <N>` and check whether the touched line ranges overlap. For now, file-path intersection is the rule.

### Special cases

- **Generated files** (e.g., lockfiles): always intersect, but conflict is mechanical. Worth special-casing if needed.
- **Same-line changes within different functions**: still considered a conflict by file-path intersection. Acceptable false-positive — the smaller-PR-first ordering rule handles it gracefully.

## UNKNOWN-state force-merge predicate

GitHub's `mergeStateStatus` shows `UNKNOWN` for some minutes after upstream `main` moves (e.g., a sibling PR just merged). It eventually settles to `CLEAN` or `DIRTY` once GitHub recomputes mergeability.

If the master waits indefinitely, throughput drops. If it force-merges blindly, real conflicts can land in `main`. The predicate balances both.

### The predicate

Force-merge is safe iff ALL of:

1. `reviewDecision == APPROVED`
2. All check runs in `{SUCCESS, SKIPPED}` and zero in `{FAILURE, CANCELLED, TIMED_OUT}`
3. `mergeStateStatus` has been `UNKNOWN` for at least `FLIGHTDECK_FORCE_MERGE_AFTER_SECS` (default 240)
4. Content disjoint: this PR's files don't intersect with files changed in `main` since the PR's last sync (use `pr-conflict-graph` against the most recent main commits)

### Re-check immediately before merging

GitHub may have flipped state between the predicate evaluation and the actual merge call. Always re-fetch:

```bash
gh pr view <N> --json mergeable,mergeStateStatus
# or, equivalently via the skill wrapper:
github pr-view <N>
```

If state flipped to `DIRTY` or `BEHIND` AND content is no longer disjoint → escalate to user instead of force-merging. UNKNOWN→DIRTY transitions sometimes mean a real conflict appeared.

> **Never gate termination on the `mergeable` field alone.** It stays `UNKNOWN` permanently once a PR is merged or closed, so an `until [ mergeable != UNKNOWN ]` loop never terminates after merge. For bounded polling, use `github await-mergeable <N>` — it polls `state` and `mergeStateStatus` correctly and exits 124 on timeout.

## Handler: `merge-ready-but-unknown`

When a pane is in `merge-ready` state with `mergeStateStatus == UNKNOWN`:

1. Record `unknown_since` in master state on first sighting.
2. On subsequent polls, check `(now - unknown_since) > FLIGHTDECK_FORCE_MERGE_AFTER_SECS`.
3. If predicate satisfied → answer the agent's prompt with `Force merge` (or equivalent).
4. If predicate fails on (4) → escalate; show user the conflicting file list.
5. If state flips to CLEAN before threshold → normal merge path.
6. If state flips to DIRTY → conflict detected; trigger `rebase-multi-choice` flow.

`unknown_since` survives compaction (persisted in master state).

## Post-merge local main sync

After authoritative GitHub state proves a PR is actually merged (`state == MERGED` and non-null `mergeCommit`), Flightdeck runs:

```bash
.agents/skills/flightdeck/scripts/flightdeck-repo-sync main --project-root <PROJECT_ROOT> --remote origin --branch main --json
```

The helper is the only place git reconciliation logic lives. It validates remote/branch ref components, checks the remote branch with `ls-remote`, and fetches with `--no-tags`, `--refmap=`, plus an explicit remote-tracking refspec such as `+refs/heads/main:refs/remotes/origin/main`, not the repository's configured fetch/tag refspecs or tag auto-follow. It fast-forwards local `main` only when clean, unambiguous, and free of ignored/untracked collisions with incoming tracked paths, and returns JSON. Collision checks are bounded to incoming tracked paths and index-aware existing local candidates, so tracked-only dir→file fast-forwards and large unrelated ignored trees do not block a safe fast-forward; directories with ignored/non-tracked entries still block. Dirty paths, ignored-file collisions, local commits ahead of remote, diverged histories, missing refs, or unsafe checkout/ref updates return `status:"blocked"` with `ahead`, `behind`, `dirty_paths`, `reason`, and `commands_suggested`. Operators choose manual merge/rebase/cleanup; Flightdeck never hard-resets, stashes, discards, deletes dirty paths, mutates tags, or force-pushes local `main`.

Queued auto-merge is not a merge. Do not run the helper when a wrapper reports queued auto-merge or GitHub says the PR is still open. Wait for a later poll/close workflow to observe `MERGED`.
