# Copilot head notices

The overseer applies these rules to the three Copilot head notices [review-pr-comments.md](../workflows/review-pr-comments.md) § 7.2 sends as a `lane-notice`, and to a head a pr-watch `awaiting-stale` line names, both events in [oversee-events.md § Event kinds](oversee-events.md#event-kinds). Each notice's first line is its kind, then `PR #[N] head [SHA]`. Every approval below is `overseer-approve [N] [SHA] --body-file [PATH] --repo [OWNER/REPO]`, with the SHA the notice or the `awaiting-stale` line names, as printed, and `[OWNER/REPO]` the repository the `pr-watch` line leads with, or for a notice the owning lane's repository: it re-reads the pull request's head, approves only when that head starts with the SHA, and binds the review to the full head it read. On its `head-moved` refusal the overseer writes no `use1` row, since the new head takes its own route; `overseer-approve --help` holds its token file and every refusal.

Before any approval below, run the one reader of review bodies at that head from `[REVIEW_BASE_CHECKOUT]`, bound per [gates.md § Gate-mode routing](gates.md#gate-mode-routing):

```bash
env -u GH_REPO -u GITHUB_REPOSITORY .agents/skills/github/scripts/github.sh -C [REVIEW_BASE_CHECKOUT] check-review-replies [N]
```

Approve only on exit `0` whose `head=` starts with the SHA. Any other result approves nothing, writes no `use1` row and wakes the lane with the lines it printed, or on exit `2` its first stderr line: a `suppressed-entry` is a finding Copilot wrote only in a review body, which no thread carries.

- `copilot-declined-unchanged` → when the notice lists every thread `github.sh pr-threads [N]` gives with `author` `copilot-pull-request-reviewer` and each reply holds at that head, and lists each body finding with the comment answering it, post one comment saying why each decline holds, then approve the head at once as the overseer's app with `overseer-approve`, with no Copilot re-review. Otherwise direct the lane on what does not hold and approve nothing.
- `copilot-fallback` → approve the moved head as the app with `overseer-approve` when the lane's own review of it passed with no open blocker; otherwise wake the lane with what its review left open.
- `copilot-approved-on-rerequest` → Copilot approved the head; approve nothing.

## Fallback approval

An `awaiting-stale` line means no approval reached the head within the quiet period. When the owning lane's own review of that head passed with no open blocker, approve the head as the overseer's GitHub App with `overseer-approve`, whose approval the base's rules count like Copilot's, and send one notice naming the pull request and the head, to the master while one runs. No ruleset or setting changes. Otherwise, use the [Copilot request owner](gates.md#copilot-requests), with `[PR_NUMBER]` set to `[N]` and `[REVIEW_BASE_CHECKOUT]` bound per that reference. Route its answer before any review wait. Wake the lane with what its review left open. A head that a `copilot-declined-unchanged` notice names takes that notice's rule instead.

## Use 1 rows

Each head approved through a notice above, by the overseer or by Copilot, or through the fallback approval is one `use1` append to the fleet log, written as [oversee-events.md § Judgement rules](oversee-events.md#judgement-rules) directs, with `text` `PR #[N] head [SHA]` and `outcome` `declined-unchanged`, `fallback`, or `approved-on-rerequest` for Copilot's approval. The fallback approval is outcome `fallback`. `oversee-report` counts these rows in its Use 1 line.
