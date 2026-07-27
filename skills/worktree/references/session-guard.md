# Session guard: rationale and limits

The claim/release/status contract, exit codes, and lifecycle table live in [../SKILL.md](../SKILL.md). This file holds the design rationale and the guard's limits.

## Why a native Git worktree lock

Recording the lease as a native `git worktree lock` reason line needs no cooperation from whoever runs the cleanup, which a private marker file would.

## Why claiming is the caller's job

**Claiming is the caller's job, deliberately.** A lease means "a live session is working here", and only something that knows a session's lifetime can say that truthfully. orch claims in `orch/workflows/initialize.md` once the worktree is the session's, and `remove` releases at teardown.

If `create` claimed instead, every worktree would stay claimed for life — nothing but an explicit `remove` releases — so a lease-aware `cleanup` would collect nothing without `--stale`, trading a silent-destruction bug for a silent-accumulation one. Releasing on a provably merged branch was the other candidate and it guts the guarantee: a merged branch does not mean an idle tree, and uncommitted work in one is exactly what the incident behind this guard lost.

## Limits

The lease is scoped to the OWNER string, which the workflow sets to the issue ID, so two sessions on the same issue share one lease and either may release it. What refuses a second implementer is bare `create <ID>`, which surveys worktrees, refs, and open PRs and exits 75 on existing ownership; `create --reuse|--restack` skips that refusal by design, so **nothing prevents a second implementer there**. The per-issue claim lock is not that gate either — it is a repository-local flock held only inside one `create` invocation.

Staleness is heartbeat age with **no liveness check**. The recorded pid and host identify who took a claim but are never consulted, so a session that is still running and has **outlived its TTL without refreshing** is indistinguishable from an abandoned one and will be unlocked by `release --stale` or `sweep`. Nothing refreshes a lease automatically and nothing runs `sweep` automatically; confirm the owner is really gone before releasing.

The guard serializes every mutating command through `flock(1)` when it is on PATH, and through a `mkdir` mutex beside the lock file otherwise — it is a capability, not a platform, so **wherever the repository's common dir is writable, the claim is mandatory**, stock flock-less macOS included. When neither mechanism can take the lock (an unwritable common dir), mutating commands fail loudly rather than leaving the session silently unguarded.

A Git worktree lock does not block writes, commits, or rebases inside the worktree, and `git worktree remove -f -f` or a plain `rm -rf` still destroy a claimed tree — `status` and `list` exist so such a removal can be attributed afterwards.

Owner identity for the lifecycle commands is derived from the command itself where possible: `remove <ID>` and `create <ID> --reuse` probe with the issue ID they were addressed with first, because the documented claim is keyed to the issue ID — that is what makes claim and release agree on a default install, with no session env plumbing. The env ladder (`$VSTACK_SESSION_OWNER`, else `$HT_SESSION_OWNER`, else `$USER`) is probed as the second identity and is the only identity for path-addressed calls. `$USER` is a login rather than a session: two sessions on one machine share that fallback identity, and either can `remove` a tree the other claimed under it. Naming an issue in `remove <ID>` likewise releases that issue's lease whoever claimed it — the lease is keyed to the issue, and addressing the issue is the operator's assertion, exactly as `--reuse` is. `cleanup` never releases on an owner match — it skips every lease regardless of owner.
