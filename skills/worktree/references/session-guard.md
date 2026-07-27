# Session guard: rationale and limits

The claim/release/status contract, exit codes, and lifecycle table live in [../SKILL.md](../SKILL.md). This file holds the design rationale and the guard's limits.

## Why a native Git worktree lock

Recording the lease as a native `git worktree lock` reason line needs no cooperation from whoever runs the cleanup, which a private marker file would.

## Why claiming is the caller's job

**Claiming is the caller's job, deliberately.** A lease means "a live session is working here", and only something that knows a session's lifetime can say that truthfully. orch claims in `orch/workflows/start.md` once the worktree is the session's, and `remove` releases at teardown.

If `create` claimed instead, every worktree would stay claimed for life — nothing but an explicit `remove` releases — so a lease-aware `cleanup` would collect nothing without `--stale`, trading a silent-destruction bug for a silent-accumulation one. Releasing on a provably merged branch was the other candidate and it guts the guarantee: a merged branch does not mean an idle tree, and uncommitted work in one is exactly what the incident behind this guard lost.

## Limits

The lease is scoped to the OWNER string, which the workflow sets to the issue ID, so two sessions on the same issue share one lease and either may release it. What refuses a second implementer is bare `create <ID>`, which surveys worktrees, refs, and open PRs and exits 75 on existing ownership; `create --reuse|--restack` skips that refusal by design, so **nothing prevents a second implementer there**. The per-issue claim lock is not that gate either — it is a repository-local flock held only inside one `create` invocation.

Staleness is heartbeat age with **no liveness check**. The recorded pid and host identify who took a claim but are never consulted, so a session that is still running and has **outlived its TTL without refreshing** is indistinguishable from an abandoned one and will be unlocked by `release --stale` or `sweep`. Nothing refreshes a lease automatically and nothing runs `sweep` automatically; confirm the owner is really gone before releasing.

The guard requires `flock(1)` and checks only whether it is on PATH — it is a capability, not a platform, so **wherever flock is available, the claim is mandatory**, including a macOS host whose Homebrew setup installs it. Without flock the session is unguarded rather than protected.

A Git worktree lock does not block writes, commits, or rebases inside the worktree, and `git worktree remove -f -f` or a plain `rm -rf` still destroy a claimed tree — `status` and `list` exist so such a removal can be attributed afterwards.

Without `$VSTACK_SESSION_OWNER` (or `$HT_SESSION_OWNER`) the owner falls back to `$USER`, which is a login rather than a session: two sessions on one machine then share an identity, and either can `remove` a tree the other claimed. `cleanup` is unaffected — it skips every lease regardless of owner — so the exposure is limited to explicitly naming another session's worktree. Set the session owner to make a lease name one session.
