# Session guard limits

The claim/release/status contract, exit codes, and lifecycle table live in [../SKILL.md](../SKILL.md).

The lease is scoped to the OWNER string, which the calling workflow sets to the issue ID: two sessions on the same issue share one lease and either may release it. Bare `create <ID>` exits 75 on existing ownership; `create --reuse|--restack` skips that refusal, so **nothing prevents a second implementer there**. The per-issue claim lock is a repository-local flock held only inside one `create` invocation and is not that gate either.

Staleness is heartbeat age with **no liveness check**. A session that is still running and has **outlived its TTL without refreshing** will be unlocked by `release --stale` or `sweep`. Nothing refreshes a lease automatically and nothing runs `sweep` automatically; confirm the owner is really gone before releasing.

The guard serializes every mutating command through `flock(1)` when it is on PATH, and through a `mkdir` mutex beside the lock file otherwise: **wherever the repository's common dir is writable, the claim is mandatory**, stock flock-less macOS included. When neither mechanism can take the lock, mutating commands fail loudly.

A Git worktree lock does not block writes, commits, or rebases inside the worktree, and `git worktree remove -f -f` or a plain `rm -rf` still destroy a claimed tree; use `status` and `list` to attribute such a removal afterwards.

`remove <ID>` and `create <ID> --reuse` probe with the issue ID they were addressed with first. The env ladder (`$KENDEX_SESSION_OWNER`, else `$HT_SESSION_OWNER`, else `$USER`) is probed as the second identity and is the only identity for path-addressed calls. Two sessions on one machine share the `$USER` fallback identity, and either can `remove` a tree the other claimed under it. Naming an issue in `remove <ID>` releases that issue's lease whoever claimed it — unless the lease's recorded claiming session (its session-leader pid) is still alive on this host and is not the removing session or an ancestor, which refuses without `remove <ID> --force`. `cleanup` never releases on an owner match — it skips every lease regardless of owner.
