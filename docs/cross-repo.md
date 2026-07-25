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
- **State what a measurement was taken relative to.** An inherited base is invisible in the result, so a correctly-tagged `[live]` reading can still be wrong. Two retractions in one night traced to this: a loader claimed to resolve from `process.cwd()` when it resolves from `import.meta.url`, because the probe's shell cwd had drifted; and a stderr claim read against the wrong process. Say which directory, which process, which artifact — the number alone does not carry it.
- **Claims about what another repo has shipped.** These need a tag and a source more than any other kind, because the repo being described is the only one that can check the claim and it never sees it. Two handoffs once each asserted the other had already built a feature; neither cited anything, both were wrong, and the work sat unbuilt while each pointed at the other. The claim carried no tag at all — untagged is how it travelled. But tagging alone does not close this: a claim can be correctly tagged and still false. `[live, from X]` is accurate about the source while the present tense turns X's stated intent into X's shipped code, and a reader builds against something that does not exist. A tag records provenance, never truth, because whoever applies it already believes the claim. So before finalising anything that asserts what another repo has, send them the sentences and let them check — they are the only ones who know the difference between what they intend and what they have.

Same family as the date-stamping rule below — both let a future reader judge how far to trust a line without re-deriving it.

## Deciding Which Repo Owns a Change

**Ownership follows the dependency, not the vocabulary.** Ask one question: does this change need anything from another repo? If not, it is yours — however much shared language it borrows.

"Shared" is a vibe and cannot be checked; the dependency question can. The failure it prevents is the one recorded above, where two handoffs each assigned a feature to the other and neither built it — that is this bug's specific instance, and the vocabulary trap is its general form. A mechanism can be upstream in one use and purely local in another: probe convergence used as an attach-race gate is the bridge's, while the same convergence used as inventory reconciliation needs nothing upstream and belongs to the app. Calling both "the convergence work" makes the second read as upstream-blocked and stalls it behind a repo that owes it nothing.

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


## Do Not Restate Another Repo's Status From A Stale Check

On 2026-07-25 a steward broadcast to both product repos carried one sentence — "still pending: re-vendoring for Opus 5" — that was stale for **both**. Each overseer corrected it independently; each was right. The check behind it was ~an hour old and both repos had merged in the interval.

- **Re-verify a cross-repo status claim at send time, or attribute it.** "As of my check at 11:40" is honest; a bare "still pending" asserts current state you have not observed.
- **A broadcast multiplies the error.** The same stale sentence went to two repos and cost two overseers a correction round. Per-repo claims deserve per-repo verification even when the rest of the message is shared.
- **Prefer asking to asserting** for the other repo's half of a handoff: "has the re-vendor landed?" costs nothing and cannot be stale.
- The correction convention worked exactly as intended — the described repo corrected the claim, and that is why the error was cheap. Do not let that make the claim careless in the first place.

## Driving Another Session's Pane

All three sessions send into each other's tmux panes. The failure modes are not obvious.

- **A pane showing an interactive prompt is not a composer.** `send-keys` into one is unsafe *even without pressing Enter* — the keystrokes are themselves input, and digits or arrows can move a selection. Capture the pane and confirm an empty composer before sending, not just before Enter.
- **Re-capture after sending, before Enter.** If the composer holds a menu, a selection list, or any other interactive prompt, do not press Enter — surface the collision instead.
- **Text after `❯` is usually NOT a draft.** Claude Code renders the last submitted message as dim hint text in an empty composer, and `capture-pane` strips the dimming, so an idle pane looks exactly like one holding an unsent draft. Reading it as a draft blocks legitimate coordination: on 2026-07-25 this rule stopped a steward from notifying both overseers about a merged change, and both panes turned out to be idle. Judge by pane state, not by the presence of text — a pane showing a completed recap or an idle prompt is safe to send into, and typing replaces hint text harmlessly. Treat a real draft as the exception it is, and if genuinely unsure, ask rather than assuming either way.
- **Verify delivery by a short distinctive fragment.** Long phrases wrap across lines and a `grep` for them returns zero on a message that landed fine. Search the scrollback (`capture-pane -S -300`), not just the visible pane.
- **Backticks in the message body get shell-expanded** by the sending shell and silently drop identifiers. Quote with single quotes, or avoid them.

## An Export Surface Is A Security Surface — Re-vendor Before You Re-export

**Action for the next drovr session, carried here because drovr ran out of context before confirming it.** drovr's vendored `pi-claude-bridge` sits at `071b3c67`, which contains a high-severity ReDoS in `connectorsListUrl` (`apiBase.replace(/\/+$/, "")`, a backtracking regex on a caller-supplied parameter). It is **harmless there** because that function is not exported from the root bundle, so nothing can hand it a hostile `apiBase` — internal callers only ever pass the default constant.

**Re-vendor to `9d78051a` (vstack#851) before adding any local re-export of that module.** Exporting first would make the unfixed regex you already carry reachable. The re-vendor is not only adding the enumeration capability; it is removing a latent defect.

The general rule this instance taught, which applies to every export any of us adds:

- **A latent defect becomes reachable the moment you export it.** The CodeQL alert on vstack#851 fired *only* once the module gained a real export surface — making the API genuinely callable made its inputs genuinely untrusted. The code had been identical for three merges before that.
- **Fix and export in the same change.** vstack#851 and memsira#284 both did, which is why no merged state in either repo was ever simultaneously reachable and vulnerable. The dangerous window existed only in intermediate *branch* pushes — which is the concrete argument for never vendoring from an unmerged branch, with a real near-miss attached rather than as a principle.

## A Bundled Package With Externals Will Not Import From An Arbitrary Directory

`pi-claude-bridge`'s `bundle/index.js` keeps `@earendil-works/pi-ai` and `@earendil-works/pi-coding-agent` as externals, so importing the package root only works from a tree where those resolve — inside the consuming app, not from a repo root or a scratch directory.

**The failure mode is a false negative that looks exactly like a real one.** A root import from the wrong directory returns `ERR_MODULE_NOT_FOUND`, which reads as "the export is missing" and invites an upstream bug report. Both consuming sessions hit this within minutes of each other; one had been warned and recognised it, the other would have filed upstream. Run the import from the directory that declares the dependency before concluding anything about the export.

## When A Grep Surprises You, The Pattern Is The First Suspect

Three grep-shaped errors in one night across two agents, all producing confident wrong statements:

- A shell-escaped pattern matched nothing useful and reported that a just-verified fix **had not landed**.
- A whole-artifact grep for the same regex returned hits from **unrelated bundled libraries**, reporting a fix present that belonged to different code.
- `grep -c` on an identifier proved it **appears in** an artifact and was read as proof it is **exported from** it. Those are different questions; only the second determines whether a caller can use it.

The rules:

- **When a grep result surprises you, re-measure a different way before writing it down.** Read the actual site. A surprising result is far more often a broken pattern than surprising code.
- **A result that CONFIRMS what you expected deserves the same suspicion, and gets less.** Of the three errors above, two produced surprising numbers and were caught quickly; the third produced a comfortable, confirming count (`grep -c charCodeAt` over a 2MB bundle returning 19) and went unexamined precisely because it agreed. Confirmation is where the check is skipped.
- **A whole-artifact grep answers a question about the artifact, not about the site you care about.** Scope the search to the call site, or read it.
- **Appearing, being exported, and being resolvable are three different properties.** Verify the specific one your claim depends on.

## Installed Connectors Are Not Attached Connectors

Deterministic enumeration (vstack#848) reports what an **account has installed**. Whether a connector's MCP server has finished attaching inside the `claude` child about to run a turn is a different question, answered by a different mechanism, and the two can legitimately disagree.

They used to be conflated by accident. The search-driven probe could only surface tools that had already attached, so an inventory implied availability — wrongly, but conservatively: it under-reported, and under-reporting fails safe. Deterministic enumeration removes that accidental coupling, so the failure now points the other way.

- **Installed is a property of the account. Attached is a property of one process at one instant.** A correct `complete: true` inventory can name Slack while `mcp__claude_ai_Slack__*` is not yet callable in that sidecar.
- **A write gate that consults the inventory alone will green-light a call that then finds no tool.** Treat an inventory as necessary but not sufficient for availability and keep an attach-time check on the call path.
- This is the successor hazard to the attach race (vstack#832), not a restatement of it — that issue stays open precisely because enumeration does not address tool availability.

## Connector Enumeration Is Token-Scoped

Deterministic connector enumeration (vstack#848) answers "which connectors does this account have" by calling the account rather than asking the model. One property is easy to get wrong and fails silently:

- **The organization UUID in the request path is ignored.** Verified live — an all-zero UUID and the literal string `not-a-uuid` both returned the bearer token's own account, identical to passing the real org. The **token alone** selects the account.
- **So a multi-account host cannot scope by org.** Selecting an account means selecting the credential — which `CLAUDE_CONFIG_DIR` gets read — not passing that account's UUID. This matters for named-multi-account work: passing account B's org UUID with account A's token returns **account A's connectors, marked complete**, with nothing anomalous in the result.
- Treat a connector inventory as belonging to whichever credential produced it, and carry the account identity alongside it rather than inferring it from the request you made.

## Capability Probe Contract

For any probe whose result other repos store and act on — connector inventories being the live case.

- **An empty result is not evidence of absence.** It must never overwrite a known-good inventory; mark the snapshot as a failed check and render "couldn't check", not "not connected", so a retry cannot erase what was already known.
- **A partial result is not evidence of absence either, and it is more dangerous.** An empty probe looks wrong; a partial one looks successful. A search-driven probe returns a lower bound — whatever the search surfaced — so a result can be genuinely non-failing and still incomplete. `probe_failed = false` answers "did the probe error", never "is this list complete".
- **Consumers may only treat a result as an enumeration if it says it is one.** Absent an explicit completeness signal, treat every probe result as a lower bound and never conclude a capability is missing from it.
