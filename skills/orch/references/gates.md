# Review gate and waiter reference

Cross-script routing behind the gate-mode summary and the `approval-wait` / `ci-wait` / `queue-wait` rows in [../SKILL.md](../SKILL.md). Each script's `--help` is its authoritative contract — arguments, modes, settings, JSON fields, exit codes; nothing here restates one.

## Gate-mode routing

Read the effective reviewer-gate mode ONLY through `approval-wait --resolve-mode` — never re-derive the chain, and never auto-detect the mode from the requested-reviewer list. It prints:

| `GATE_MODE` | Meaning | Route |
|-------------|---------|-------|
| `approval` | GitHub-native approval verdict required | `approval-wait` |
| `review` | a non-author review of the current head plus zero unresolved threads | `approval-wait --mode review` |
| `off` | reviewer-less repo, or the engine's `REVIEW_GATE_MODE=off` disable (resolved first) | skip the wait; record the gate not-applicable |

The reviewer-gate settings — `PR_REVIEW_GATE`, `PR_REVIEW_CHECK`, `PR_REVIEW_QUORUM`, `PR_REVIEW_ON_TIMEOUT`, `PR_REVIEW_NUDGE_SECS` / `PR_REVIEW_NUDGE`, `PR_REVIEW_WAIT_SECS` — live in `kendex.settings.toml` `[env]`; semantics and defaults are in `approval-wait --help`. The gate predicate, writer, and engine-side `REVIEW_GATE_*` keys belong to the review-gate skill (its SKILL.md and `.agents/skills/review-gate/references/settings.md`).

## Which waiter answers which state

| Waiting on | Tool |
|------------|------|
| Reviewer verdict on one PR | `approval-wait` — statuses `approved`/`reviewed`/`changes_requested`/`comments`/`timeout`/`proceeded`/`error` |
| CI on one PR | `ci-wait` — verdicts `pass`/`fail`/`pending`/`none` |
| Merge-queue / auto-merge outcome | `queue-wait` owns the growing verdict set documented in its § Verdicts table; `merge-queue-watch` owns detached execution, identity, liveness, and consumption |
| Many PRs, long horizon | `pr-watch.sh` — § Multi-PR watching |

Per-verdict routing lives in the workflows (`submit-pr.md` § 4, `merge-pr.md` § 5); each verdict's semantics live in that script's `--help`.

A wait is a running waiter, never a session sitting at its prompt.

## Waiter auth ladder

All three waiters share `scripts/lib/gh-auth.sh`, wrapping the GitHub skill's helpers: env-first, each candidate source probed at most once, exit `3` on hard auth failure. Summary in each `--help`; full ladder in `DEVELOPMENT.md`.

## Multi-PR watching

The waiters above are single-PR waits. `merge-queue-watch` runs queue-wait as
one detached generation and exits after that generation publishes a result; it
is not a shared watcher. For many PRs across a long horizon, the review-gate skill (optional
dependency) ships `scripts/pr-watch.sh`, a needs-attention reducer — contract
in `pr-watch.sh --help`, wrap-in-anything loop in review-gate's adoption guide.
Orch consumes it through `oversee-watch` when the script is installed, passing
`--heal`, so a `gate-stale` line dispatches the writer workflow itself. That
WRITE needs, in this order, a `PR_WATCH_WRITER_WORKFLOW` workflow (default
`Review gate writer`) present with Actions enabled in every repo covered, then
a credential carrying `actions:write`. Missing any, the reducer emits
`gate-stale` plus an `error` naming the failed dispatch and no
`heal-dispatched`, and repair follows the same order: until a usable writer
exists there is nothing to hand-dispatch either, and only the credential case
is answered by a hand dispatch under a scoped token.
The fallback without it is per-PR `approval-wait`/`queue-wait`, which cannot
detect `gate-stale`: the waiters never read `REVIEW_GATE_CONTEXT` or verify
writer convergence, so a PR that reads reviewed-and-clean but sits unmerged
warrants a manual gate-status check
(`gh api repos/<owner>/<repo>/commits/<head>/statuses`) and a writer dispatch —
the hand-run equivalent of `pr-watch.sh --heal`.
