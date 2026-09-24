# Review gate and waiter reference

Cross-script routing behind the gate-mode summary and the `approval-wait` / `ci-wait` / `queue-wait` rows in [../SKILL.md](../SKILL.md). Each script's `--help` is its authoritative contract — arguments, modes, settings, JSON fields, exit codes; nothing here restates one.

## Gate-mode routing

Read the effective reviewer-gate mode ONLY through `approval-wait --resolve-mode` — never re-derive the chain, and never auto-detect the mode from the requested-reviewer list. Pass the pull request's base and head with `--base` and `--head`: where the review gate's class policy is active the mode belongs to one pull request, and a call with no range exits 2 rather than guess one. An active class policy is the one path here that touches the network: both endpoints must be commits the checkout holds, so the resolver fetches a missing one from origin by SHA, and refuses when it is still missing rather than report a class for a diff nothing read. A non-zero exit is no mode: report it and stop rather than pick one. It prints:

| `GATE_MODE` | Meaning | Route |
|-------------|---------|-------|
| `approval` | GitHub-native approval verdict required | `approval-wait` |
| `review` | a non-author review of the current head that is APPROVED or CHANGES_REQUESTED, or COMMENTED with a body or a thread it opened, plus zero unresolved threads; under review-gate's default review-object settings (any state, no trusted-login list), the merge-blocking Review gate status still counts a reply-only non-author review, so the wait can keep waiting on a head that status already passed | `approval-wait --mode review` |
| `exempt` | the review gate's class policy waives review for this change class (resolved first) | skip the wait; record the gate not-applicable; no thread term applies either |
| `off` | reviewer-less repo, or the engine's `REVIEW_GATE_MODE=off` disable | skip the wait; record the gate not-applicable |

`exempt` and `off` both skip the wait, and they are not the same thing. `off` is a repository with no reviewer gate, where unresolved review threads still gate the merge. `exempt` is one change the review gate's own policy puts outside that gate, to the scope the [review-gate README class table](../../review-gate/README.md#class-policy) states, so the terms downstream — submit-pr's gate 3, merge-pr's `unresolved_threads` warning, `queue-wait`'s late-findings guard and `pr-merge`'s review-thread gate — do not apply to it either. Required CI checks, commit guards, exact-head checks and conflict refusal are untouched in both, and the merge path still refuses a `CHANGES_REQUESTED` review at its readiness check.

The class policy is the review-gate skill's, and `review-policy` is its only owner: it calls the shared `harness-ci` change classifier and maps the class to one evidence policy. Orch never classifies a change and never re-maps a class. A `bot` row is the `none` row's inverse — it keeps the reviewer keys authoritative even under `REVIEW_GATE_MODE=off`. The per-class table is [`../../review-gate/README.md` § Class policy](../../review-gate/README.md#class-policy).

The reviewer-gate settings — `PR_REVIEW_GATE`, `PR_REVIEW_CHECK`, `PR_REVIEW_ON_TIMEOUT`, `PR_REVIEW_WAIT_SECS` — live in `kendex.settings.toml` `[env]`; semantics and defaults are in `approval-wait --help`. The gate predicate, writer, and engine-side `REVIEW_GATE_*` keys belong to the review-gate skill (its SKILL.md and `.agents/skills/review-gate/references/settings.md`).

## Which waiter answers which state

| Waiting on | Tool |
|------------|------|
| Reviewer verdict on one PR | `approval-wait` — statuses `approved`/`reviewed`/`changes_requested`/`comments`/`timeout`/`proceeded`/`unreviewable`/`error` |
| CI on one PR | `ci-wait` — verdicts `pass`/`fail`/`pending`/`none` |
| Merge-queue / auto-merge outcome | `queue-wait` — the growing verdict set documented in its § Verdicts table |
| Many PRs, long horizon | `pr-watch.sh` — § Multi-PR watching |

Per-verdict routing lives in the workflows (`submit-pr.md` § 4, `merge-pr.md` § 5); each verdict's semantics live in that script's `--help`.

A wait is a running waiter, never a session sitting at its prompt.

## Stacked pull requests

`approval-wait` returns `unreviewable` (exit 1) when the deadline passes with no reviewer evidence and the PR's base sits outside the target set of the repo's automatic-review rulesets. Nothing was going to arrive on its own. Which bases draw an automatic review is per-repo configuration, read from the repo's rulesets: the review-gate skill's `.agents/skills/review-gate/references/automatic-review.md`.

Work the chain in this order:

1. Request the review by hand on the stacked PR. This is the remedy, not a workaround:

   ```bash
   gh pr edit [PR_NUMBER] --add-reviewer @copilot
   ```

   Then re-run the wait. It works on a base the ruleset does not target.

2. Merge the bottom of the stack. GitHub retargets the next PR onto the new base, but a retarget is not a documented review trigger: request the review by hand as in step 1, or push a new head where the rule's `review_on_push` is on, then re-run the wait.
3. Fallback, only when the manual request draws nothing: close the PR and open a fresh one against the default branch. Close-and-open, never reopen — reopening re-arms the reviewer only on a PR it has already reviewed once, and does nothing for one it never reviewed.

## Waiter auth ladder

All three waiters share `scripts/lib/gh-auth.sh`, wrapping the GitHub skill's helpers: env-first, each candidate source probed at most once (an env token check killed at its bound is asked again once), exit `3` on hard auth failure. Summary in each `--help`; full ladder in `DEVELOPMENT.md`.

## Multi-PR watching

The waiters above are single-PR blocking waits. For many PRs across a long horizon, the review-gate skill (optional dependency) ships `scripts/pr-watch.sh`, a needs-attention reducer — contract in `pr-watch.sh --help`, wrap-in-anything loop in review-gate's adoption guide. Orch consumes it through `oversee-watch` when the script is installed, passing `--heal`, so a `gate-stale` line dispatches the writer workflow itself. That WRITE needs, in this order, a `PR_WATCH_WRITER_WORKFLOW` workflow (default `Review gate writer`) present with Actions enabled in every repo covered, then a credential carrying `actions:write`. Missing any, the reducer emits `gate-stale` plus an `error` naming the failed dispatch and no `heal-dispatched`, and repair follows the same order: until a usable writer exists there is nothing to hand-dispatch either, and only the credential case is answered by a hand dispatch under a scoped token. The fallback without it is per-PR `approval-wait`/`queue-wait`, which cannot detect `gate-stale`: the waiters never read `REVIEW_GATE_CONTEXT` or verify writer convergence, so a PR that reads reviewed-and-clean but sits unmerged warrants a manual gate-status check (`gh api repos/<owner>/<repo>/commits/<head>/statuses`) and a writer dispatch — the hand-run equivalent of `pr-watch.sh --heal`.
