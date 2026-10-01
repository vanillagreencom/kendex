# Copilot head notices

The overseer applies these rules to the three Copilot head notices [review-pr-comments.md](../workflows/review-pr-comments.md) § 7.2 sends as a `lane-notice`, and to a head a pr-watch `awaiting-stale` line names, both events in [oversee-events.md § Event kinds](oversee-events.md#event-kinds). Each notice's first line is its kind, then `PR #[N] head [SHA]`. Before any approval below, the overseer re-reads the pull request's `headRefOid` and approves only when it equals the SHA the notice or the `awaiting-stale` line names; on a mismatch it approves nothing and writes no `use1` row, since the new head takes its own route.

- `copilot-declined-unchanged` → when the notice lists every thread `github.sh pr-threads [N]` gives with `author` `copilot-pull-request-reviewer` and each reply holds at that head, post one comment saying why each decline holds, then approve the head at once as the overseer's app, with no Copilot re-review. Otherwise direct the lane on what does not hold and approve nothing.
- `copilot-fallback` → approve the moved head as the app when the lane's own review of it passed with no open blocker; otherwise wake the lane with what its review left open.
- `copilot-approved-on-rerequest` → Copilot approved the head; approve nothing.

## Fallback approval

An `awaiting-stale` line means no approval reached the head within the quiet period. When the owning lane's own review of that head passed with no open blocker, approve the head as the overseer's GitHub App, whose approval the base's rules count like Copilot's, and send one notice naming the pull request and the head, to the master while one runs. No ruleset or setting changes. Otherwise, use the [Copilot request owner](gates.md#copilot-requests), with `[PR_NUMBER]` set to `[N]` and `[REVIEW_BASE_CHECKOUT]` bound per that reference. Route its answer before any review wait. Wake the lane with what its review left open. A head that a `copilot-declined-unchanged` notice names takes that notice's rule instead.

## Use 1 rows

Each head approved through a notice above, by the overseer or by Copilot, or through the fallback approval is one `use1` append to the fleet log, written as [oversee-events.md § Judgement rules](oversee-events.md#judgement-rules) directs, with `text` `PR #[N] head [SHA]` and `outcome` `declined-unchanged`, `fallback`, or `approved-on-rerequest` for Copilot's approval. The fallback approval is outcome `fallback`. `oversee-report` counts these rows in its Use 1 line.
