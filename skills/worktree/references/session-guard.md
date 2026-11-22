# Session guard limits

The claim/release/status contract and exit codes live in `worktree-session-guard --help`. Each worktree command's lease behaviour is in its own `--help`.

The `worktree-prompt-claim` companion uses the session hook's claim decision before each Claude prompt:

- A required claim failure blocks the prompt.
- An established session's refresh failure (exit 6) is advisory: the prompt goes on and the lease stands.
- A successful prompt claim refreshes the lease.

Claiming is the caller's job:

- `create` never claims.
- The orchestrating workflow claims once the worktree is the session's.
- `remove` releases at teardown.

The session hook, and the workflow's claim after it:

- The catalog's `worktree-session-claim` hook claims at session start under the env ladder below, so a session opened by hand holds a lease too.
- The hook claims only a worktree whose private git dir holds the `kendex-issue` record. Every tree `create` returns carries it, one adopted through `--reuse` or `--restack` included.
- By default, a start meeting a lock another owner name or tool holds, an issue lease with no association to this session included, leaves that lock as it stands and says nothing.
- The exception is a guard lease past the TTL that records session processes all verified dead: the start takes it over.
- The hook's catalog declaration defines which harnesses refuse or only advise in its optional required-claim mode.
- The workflow's `claim --owner <ISSUE_ID> --adopt` takes over a lease the caller's env identity holds, so its claim follows the hook's.

Probe with `status`, which is read-only, never with `claim`: `claim` takes or rewrites the lease.

The lease is scoped to the OWNER string, which the calling workflow sets to the issue ID. Two sessions on the same issue share one lease, and either may release it at close-out.

The lease's `pid` belongs to the short-lived guard writer, which exits after claim or refresh. A live writer PID protects only the guard write window. It does not establish whether the harness is still working.

Bare `create <ID>` exits 75 on existing ownership. `create --reuse|--restack` skips that refusal, so **nothing prevents a second implementer there**.

For a lease that records no session process, staleness is heartbeat age with **no liveness check**:

- The heartbeat moves only when a caller re-enters or re-claims the tree, and nothing does so on a timer.
- Past its TTL, `release --stale` or `sweep` unlocks such a lease while its session may still work.
- `worktree-session-guard refresh <path> --owner <ISSUE_ID>` holds it open.
- Nothing runs `sweep` automatically. Confirm the owner is really gone before releasing such a lease.

A Git worktree lock does not block writes, commits, or rebases inside the worktree. `git worktree remove -f -f` or a plain `rm -rf` still destroys a claimed tree. Use `status` and `list` to attribute such a removal afterwards.

The env ladder (`$KENDEX_SESSION_OWNER`, else `$HT_SESSION_OWNER`, else `$USER`) supplies a fallback identity. Two sessions on one machine share the `$USER` fallback identity, and either can adopt a lease held under it under an issue ID.

## Session processes

A claim with `--session` or `--adopt` records in the lease the harness session process it runs under. A session-bound claim that cannot read its process records nothing and says `guard-session-unidentified`. `scripts/lib/process-identity.sh` owns the reads of that process.

A write adds the caller's process and drops only processes that read dead, so sessions sharing one lease keep each other's records.

The guard reads each recorded process as live, dead or unknown, as `worktree-session-guard --help` defines. A lease holds while any recorded process is live or unknown, without another prompt, start or timer. The caller's own process does not hold the lease, so a lane can remove its own worktree.
