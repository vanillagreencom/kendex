# Cross-Repo Conventions

Conventions shared across vstack and its consuming repos (drovr, memsira, hyprtrade). Kept out of AGENTS.md, which covers working in vstack itself.

## Recording Facts Across Repos

When a session records a fact other sessions will act on, tag how it is known. Vendoring makes the alternative actively dangerous: anything merged here lands in the consuming repos' trees, so their greps of the vendored artifact will keep "confirming" whatever was asserted upstream.

- **`[live]`** — observed directly against a real system. Note the method and its limits.
- **`[corroborated]`** — checked against a source **not derived from the same observation**. Not "additionally verified", which is a phrasing you cannot fail: it certifies whatever you already believe. Naming the second source is the test, because that is when you notice it is your own output.
- **`[inferred]`** — reasoned from docs or code, not observed.

Real instance (2026-07-24): a live connector enumeration went upstream as the exact-id lists in vstack#821, vendored into the consuming repos, and a later grep of that bundle read back as independent agreement with the enumeration it came from — in a note that had itself recorded, two paragraphs earlier, that the entries did not exist before #821.

The corollary that resolves most cases: checking your own code's *behavior* against a fact corroborates it (it tests whether the code copes). Checking a *list you populated* does not (it tests your memory of what you typed).

Two ways the tags fail in practice, both observed:

- **Reading the artifact instead of the source.** Control-flow claims derived from a vendored, minified, post-bundler copy are not `[live]` readings of the code — they are `[inferred]` from a lossy transform. This is structurally likely here for the same reason as the round-trip: consuming repos hold bundles, not sources, so the nearest copy is the wrong one. Cite `src/` with file and line; if only a bundle is at hand, say so and downgrade the claim.
- **Tone upgrading a tag.** `[inferred]` labelled honestly and then described as "the most promising lead" functions as `[live]` for every reader. The tag is not a disclaimer that buys stronger prose — if the surrounding sentence would survive being read as verified, the tag is not doing its job.
- **Claims about what another repo has shipped.** These need a tag and a source more than any other kind, because the repo being described is the only one that can check the claim and it never sees it. Two handoffs once each asserted the other had already built a feature; neither cited anything, both were wrong, and the work sat unbuilt while each pointed at the other. The claim carried no tag at all — untagged is how it travelled.

Same family as the date-stamping rule below — both let a future reader judge how far to trust a line without re-deriving it.

## Cross-Repo Review Gate

Agreed shape for drovr, memsira, and hyprtrade (settled 2026-07-24). Empirically tested on two repos independently — memsira PR #272 and drovr PR #262, each a live PR with a real unresolved thread — not inferred from docs. Recorded here so it is not re-litigated per repo.

- **The invariant: thread resolution is enforced by a dedicated ruleset with `bypass_actors: []`.** A `pull_request` rule with `required_review_thread_resolution: true` and an empty bypass list. That is the only form proven to hold on every merge path.
- **Classic branch protection is NOT sufficient, and this was the trap.** `required_conversation_resolution: true` with `enforce_admins: false` does **not** stop `gh pr merge --admin` — verified on memsira PR #272 (2026-07-24): with the ruleset disabled and classic protection still on, an admin merge succeeded with a thread left unresolved. The same PR with the zero-bypass ruleset active was blocked: `GraphQL: Repository rule violations found` / `A conversation must be resolved before this pull request can be merged`. Since `--admin` is a documented merge path, any repo relying on classic protection alone has a hole exactly where it assumes coverage.
- **Keep classic `required_conversation_resolution` on anyway — defense in depth, never the mechanism.** It is redundant for the admin path and must never again be relied on there, but it costs nothing and it is the layer that survives someone disabling or misconfiguring the ruleset. The counterfactual half of the memsira test created exactly that window: with the ruleset disabled, classic protection was the only thing standing between a *non-admin* merge and an unresolved thread. Enforcement is the ruleset; this is the backstop.
- **`bypass_actors` is per-ruleset, not per-repo — so split the rules.** Thread resolution goes in its own zero-bypass ruleset; rules that legitimately need an escape hatch stay in a separate ruleset that keeps its bypass (e.g. memsira's `main merge queue` ruleset retains a `RepositoryRole` 5 always-bypass). Classic protection cannot express this because `enforce_admins` is binary and repo-wide.
- **Set `required_approving_review_count` EXPLICITLY to `0`.** The API fills omitted sub-parameters with defaults. Our review bots only ever submit COMMENTED reviews, so any nonzero count deadlocks every PR in every repo. Also set `conditions.ref_name.include` to `~DEFAULT_BRANCH` and verify `bypass_actors` is literally `[]` after creation, not merely as posted.
- **GitHub does not name the ruleset in the error.** An operator sees only `Repository rule violations found` plus `A conversation must be resolved before this pull request can be merged` — no indication which ruleset blocked, so point them at the thread ruleset by name when diagnosing. On a merge-queue repo the violation list also carries `Changes must be made through the merge queue`; both lines appear together and the queue line is not the blocker.
- **Deleting a repo's CI thread term is a per-repo cost decision, NOT part of the invariant.** Only drop it once the zero-bypass ruleset exists. Worth ~23.9 min/run on hyprtrade; worth nothing measurable on memsira, where 20/22 sampled gate failures were the review-at-head term and zero were threads. Classify gate failures by reading `##[error]` lines — grepping the log body echoes the script and yields a confidently wrong answer.
- **Unresolved threads can become unreachable in the UI while still blocking the merge.** After a rebase or force-push the commented commits are gone, the conversation link 404s, and the PR shows zero visible conversations yet refuses to merge (github/community #144455, #10592, #184355). GraphQL still sees them: list with `github.sh pr-threads <N>`, resolve by id with `github.sh resolve-thread <PRRT_...>`. The skill is the escape hatch from a deadlock branch protection creates.
- **Date-stamp measured state, and re-measure before relying on it.** During the conversation that produced this section, two sessions reported hyprtrade branch-protection values that a later read contradicted within the hour. Nobody captured a timestamped before/after, so a genuine mid-flight change and an inaccurate first read are **indistinguishable after the fact** — do not cite either earlier number as evidence of anything. That ambiguity is the actual lesson: with several sessions reading and mutating the same repos concurrently, an unreproducible measurement is worthless, so capture the command output with a timestamp or treat the value as unknown. State as of 2026-07-25 00:42Z, measured directly rather than taken from the sessions' reports — all three converged on **both** layers: every repo has classic `conv_res=true` plus an active thread ruleset with `bypass_actors: []`, `required_review_thread_resolution: true`, `required_approving_review_count: 0`. `enforce_admins` still differs (hyprtrade `true`; drovr and memsira `false`) and that is fine — it is no longer the mechanism. Note this list replaced an earlier one within about an hour, when drovr enabled its classic flag on the strength of the defense-in-depth bullet above; that is the rule working, not a contradiction, and a later audit disagreeing again is expected.


## Driving Another Session's Pane

All three sessions send into each other's tmux panes. The failure modes are not obvious.

- **A pane showing an interactive prompt is not a composer.** `send-keys` into one is unsafe *even without pressing Enter* — the keystrokes are themselves input, and digits or arrows can move a selection. Capture the pane and confirm an empty composer before sending, not just before Enter.
- **Re-capture after sending, before Enter.** If the composer holds anything that is not your own just-sent text — an in-progress draft, an earlier queued line, a menu — do not press Enter. Surface the collision instead.
- **Verify delivery by a short distinctive fragment.** Long phrases wrap across lines and a `grep` for them returns zero on a message that landed fine. Search the scrollback (`capture-pane -S -300`), not just the visible pane.
- **Backticks in the message body get shell-expanded** by the sending shell and silently drop identifiers. Quote with single quotes, or avoid them.

## Capability Probe Contract

For any probe whose result other repos store and act on — connector inventories being the live case.

- **An empty result is not evidence of absence.** It must never overwrite a known-good inventory; mark the snapshot as a failed check and render "couldn't check", not "not connected", so a retry cannot erase what was already known.
- **A partial result is not evidence of absence either, and it is more dangerous.** An empty probe looks wrong; a partial one looks successful. A search-driven probe returns a lower bound — whatever the search surfaced — so a result can be genuinely non-failing and still incomplete. `probe_failed = false` answers "did the probe error", never "is this list complete".
- **Consumers may only treat a result as an enumeration if it says it is one.** Absent an explicit completeness signal, treat every probe result as a lower bound and never conclude a capability is missing from it.
