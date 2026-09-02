# Session guard limits

The claim/release/status contract and exit codes live in `worktree-session-guard --help`; each worktree command's lease behaviour is in its own `--help`.

Claiming is the caller's job: `create` never claims, the orchestrating workflow claims once the worktree is the session's, and `remove` releases at teardown. Probe with `status`, which is read-only, never with `claim` — `claim` takes or rewrites the lease.

The lease is scoped to the OWNER string, which the calling workflow sets to the issue ID: two sessions on the same issue share one lease and either may release it. Bare `create <ID>` exits 75 on existing ownership; `create --reuse|--restack` skips that refusal, so **nothing prevents a second implementer there**. The per-issue claim lock is a repository-local flock held only inside one `create` invocation and is not that gate either.

Staleness is heartbeat age with **no liveness check**. The heartbeat moves only when a caller re-enters or re-claims the tree, and nothing does so on a timer, so an unattended lease's age is the age of its claim and not of the session's last work in it: a session working steadily past its TTL is stale by this measure and will be unlocked by `release --stale` or `sweep`. `worktree-session-guard refresh <path> --owner <ISSUE_ID>` is what holds a live lease open. Nothing runs `sweep` automatically; confirm the owner is really gone before releasing.

A Git worktree lock does not block writes, commits, or rebases inside the worktree, and `git worktree remove -f -f` or a plain `rm -rf` still destroy a claimed tree; use `status` and `list` to attribute such a removal afterwards.

`remove <ID>` and `create <ID> --reuse` probe with the issue ID they were addressed with first. The env ladder (`$KENDEX_SESSION_OWNER`, else `$HT_SESSION_OWNER`, else `$USER`) is probed as the second identity and is the only identity for path-addressed calls. Two sessions on one machine share the `$USER` fallback identity, and either can remove a tree the other claimed under it. Naming an issue in `remove <ID>` releases that issue's lease whoever claimed it. `cleanup` never releases on an owner match — it skips every lease regardless of owner.
