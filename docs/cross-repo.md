# Cross-Repo Conventions

Conventions shared across vstack and its consuming repos (drovr, memsira, hyprtrade). Kept out of AGENTS.md, which covers working in vstack itself.

## Recording Facts Across Repos

When a session records a fact other sessions will act on, tag how it is known. Vendoring makes untagged claims dangerous: anything merged here lands in the consuming repos' trees, so their greps of the vendored artifact will keep "confirming" whatever was asserted upstream.

- **`[live]`** — observed directly against a real system. Note the method and its limits.
- **`[corroborated]`** — checked against a source **not derived from the same observation**. Naming the second source is the test — that is when you notice it is your own output. Checking your code's *behavior* against a fact corroborates it; re-reading a *list you populated* does not.
- **`[inferred]`** — reasoned from docs or code, not observed.

Rules that keep the tags honest:

- **Read the source, not the artifact.** Claims derived from a vendored, minified, post-bundler copy are `[inferred]` from a lossy transform, not `[live]`. Cite `src/` with file and line; if only a bundle is at hand, say so and downgrade the claim.
- **Do not tone-upgrade a tag.** `[inferred]` described as "the most promising lead" functions as `[live]` for every reader. If the surrounding sentence would survive being read as verified, the tag is not doing its job.
- **State what a measurement was taken relative to.** Say which directory, which process, which artifact — an inherited base is invisible in the result, so a correctly-tagged `[live]` reading can still be wrong.
- **Claims about what another repo has shipped need the most care.** A tag records provenance, never truth, and present tense turns stated intent into shipped code. Before finalising anything that asserts what another repo has, send them the sentences and let them check — they are the only ones who know the difference between what they intend and what they have.

Same family as the date-stamping rule below — both let a future reader judge how far to trust a line without re-deriving it.

## Mailbox Collection Leaves A Receipt For One Cycle

Agreed 2026-08-04 (memsira proposed, drovr accepted), after a same-hour collection was
indistinguishable from a lost write: the drovr sender saw its entry vanish twice within
seconds of writing, read it as a stale-buffer clobber, re-sent, and pinged the receiver
directly — while the receiver had in fact recorded and acted on every item before the
first deletion. A fast collector and a clobber look identical from the sender's side,
and the mailbox file is untracked, so the sender has no history to check.

The rule: **the receiver does not delete an acted entry immediately.** It annotates the
entry in place with one line — `COLLECTED <date> → <receipts>` (the durable records:
issue ids, PR numbers, doc paths) — and removes the entry on its NEXT mailbox pass, or
after 24h, whichever comes first. The sender seeing the annotation knows the mail
landed; the sender seeing deletion without ever seeing an annotation knows to check
with the receiver before re-sending. Receipts follow the Recording Facts tags above:
they name where the durable copy lives, because the annotation itself is about to be
deleted too.

Everything else about the mailbox (receiver deletes, mail-not-archive, steady state of
zero-to-two entries) stands as written in the mailbox header.

## Deciding Which Repo Owns a Change

**Ownership follows the dependency, not the vocabulary.** Ask one question: does this change need anything from another repo? If not, it is yours — however much shared language it borrows. "Shared" is a vibe and cannot be checked; the dependency question can. A mechanism can be upstream in one use and purely local in another; naming both with the same shared label makes the local half read as upstream-blocked and stalls it behind a repo that owes it nothing.

## Cross-Repo Review Gate

Agreed shape for drovr, memsira, and hyprtrade, settled by live testing on real PRs. Recorded here so it is not re-litigated per repo.

- **The invariant: thread resolution is enforced by a dedicated ruleset with `bypass_actors: []`.** A `pull_request` rule with `required_review_thread_resolution: true` and an empty bypass list. That is the only form proven to hold on every merge path.
- **Classic branch protection is NOT sufficient.** `required_conversation_resolution: true` with `enforce_admins: false` does not stop `gh pr merge --admin`. Since `--admin` is a documented merge path, a repo relying on classic protection alone has a hole exactly where it assumes coverage.
- **Keep classic `required_conversation_resolution` on anyway — defense in depth, never the mechanism.** It is redundant for the admin path but is the layer that survives someone disabling or misconfiguring the ruleset.
- **`bypass_actors` is per-ruleset, not per-repo — so split the rules.** Thread resolution goes in its own zero-bypass ruleset; rules that legitimately need an escape hatch stay in a separate ruleset that keeps its bypass. Classic protection cannot express this because `enforce_admins` is binary and repo-wide.
- **Set `required_approving_review_count` EXPLICITLY to `0`.** The API fills omitted sub-parameters with defaults, and review bots only submit COMMENTED reviews, so any nonzero count deadlocks every PR. Also set `conditions.ref_name.include` to `~DEFAULT_BRANCH` and verify `bypass_actors` is literally `[]` after creation, not merely as posted.
- **GitHub does not name the ruleset in the error.** An operator sees only `Repository rule violations found` plus `A conversation must be resolved before this pull request can be merged` — point them at the thread ruleset by name when diagnosing. On a merge-queue repo the violation list also carries `Changes must be made through the merge queue`; both lines appear together and the queue line is not the blocker.
- **Dropping a repo's CI thread term is a per-repo cost decision, NOT part of the invariant.** Only drop it once the zero-bypass ruleset exists. Classify gate failures by reading `##[error]` lines — grepping the log body echoes the script and yields a confidently wrong answer.
- **Unresolved threads can become unreachable in the UI while still blocking the merge.** After a rebase or force-push the commented commits are gone, the conversation link 404s, and the PR shows zero visible conversations yet refuses to merge. GraphQL still sees them: list with `github.sh pr-threads <N>`, resolve by id with `github.sh resolve-thread <PRRT_...>`.
- **Date-stamp measured state, and re-measure before relying on it.** With several sessions reading and mutating the same repos concurrently, an unreproducible measurement is worthless — capture the command output with a timestamp or treat the value as unknown.

## A Vendored Tree Is Reviewed Once, Upstream

Consuming repos merge re-vendor PRs whose delta is bytes already reviewed upstream. Route each finding by where its fix would land, never by which file it sits on, and never silence a reviewer by excluding the path — mechanism, wiring, and the per-repo verification protocol: `skills/review-gate/references/vendored-paths.md`.

## Do Not Restate Another Repo's Status From A Stale Check

- **Re-verify a cross-repo status claim at send time, or attribute it.** "As of my check at 11:40" is honest; a bare "still pending" asserts current state you have not observed.
- **A broadcast multiplies the error.** Per-repo claims deserve per-repo verification even when the rest of the message is shared.
- **Prefer asking to asserting** for the other repo's half of a handoff: "has it landed?" costs nothing and cannot be stale.

## Driving Another Session's Pane

Sessions send into each other's tmux panes. The failure modes are not obvious.

- **A pane showing an interactive prompt is not a composer.** `send-keys` into one is unsafe *even without pressing Enter* — the keystrokes are themselves input, and digits or arrows can move a selection. Capture the pane and confirm an empty composer before sending, not just before Enter.
- **Re-capture after sending, before Enter.** If the composer holds a menu, a selection list, or any other interactive prompt, do not press Enter — surface the collision instead.
- **Text after `❯` is usually NOT a draft.** Claude Code renders the last submitted message as dim hint text in an empty composer, and `capture-pane` strips the dimming, so an idle pane looks exactly like one holding an unsent draft. Judge by pane state, not by the presence of text — typing replaces hint text harmlessly. If genuinely unsure, ask rather than assuming either way.
- **Verify delivery by a short distinctive fragment.** Long phrases wrap across lines and a `grep` for them returns zero on a message that landed fine. Search the scrollback (`capture-pane -S -300`), not just the visible pane.
- **Backticks in the message body get shell-expanded** by the sending shell and silently drop identifiers. Quote with single quotes, or avoid them.
- **Send ONE LINE. A multi-line `send-keys -l` becomes a paste, and a paste does not submit.** Claude Code collapses multi-line input to `[Pasted text #1]`, and neither `Enter` nor `C-m` submits it. Newlines are the trigger, not length — a very long single line is fine.
- **A collapsed paste also defeats fragment verification**, because `capture-pane` only ever shows `[Pasted text #1]` and never the body. One more reason single-line is the only reliable form.
- **Clear a stuck composer with `C-u` rather than leaving it.** Text abandoned there can later be submitted glued to the other session's own message. `C-u` doubles as the power check: if it clears the composer, keystrokes *are* registering, so "Enter did not submit" is a real finding rather than a dead pane.

## Installed Connectors Are Not Attached Connectors

Deterministic enumeration reports what an **account has installed**. Whether a connector's MCP server has finished attaching inside the `claude` child about to run a turn is a different question, answered by a different mechanism, and the two can legitimately disagree.

- **Installed is a property of the account. Attached is a property of one process at one instant.** A correct `complete: true` inventory can name a connector while its `mcp__claude_ai_*` tools are not yet callable in that sidecar.
- **A write gate that consults the inventory alone will green-light a call that then finds no tool.** Treat an inventory as necessary but not sufficient for availability and keep an attach-time check on the call path.

## The Connector Server Key Is The Tool Namespace — Must-Agree Across Repos

**The bridge declares each connected connector in `mcpServers` keyed by the CLI's own server name — `claude.ai <Connector>`, e.g. `claude.ai Slack`.** That key is not cosmetic: it *is* the tool namespace.

- **Keyed as anything else, the connector appears twice** — the declaration and the CLI's own loader each produce a namespace. Reusing the connector's *id* is not sufficient; only the `claude.ai <Connector>` key merges them.
- **What merges is the namespace, not the connection.** Under the shared name the declaration and the CLI's own loader each still connect, so declaring N connectors costs roughly 2N connections; they connect in parallel.
- **This is a compatibility contract for consumers that pin fully-qualified tool names.** A consumer that hard-codes `mcp__claude_ai_<Connector>__<tool>` names into `--allowedTools` or a system prompt never globs a namespace, so changing the key format makes every such write silently stop matching — surfacing as "unavailable" rather than as an error naming the cause. Guarded by `pi-extensions/pi-claude-bridge/tests/unit-connector-declarations.mjs`, so a change fails CI and points the author here.
- **Do not health-check the deferred-tool count.** `Dynamic tool loading` reports `0/N`, and N moves for two separate reasons: the CLI's own async fetch varies it, and declared tools are `alwaysLoad` and therefore leave the deferred pool, so declaring *more* servers makes N go *down*. N is not a health signal in either direction.
- **Declaring is a latency win, not a cost.** The `alwaysLoad` barrier is real but small and sub-linear; time to first token drops substantially and its spread collapses because the model stops flailing through speculative `ToolSearch` dead ends.
- **Fail-open is required.** The account-side connection picture is not stable run to run; a declared connector must still work when unrelated auto-fetched connections fail.
- **Only `installState === "connected"` connectors are declared.** The rest are never attempted by the CLI either, so declaring them would ask `alwaysLoad` to block startup on servers that cannot connect.

## Connector Write Classification Is A Gate Two Apps Depend On — Must-Agree

Consuming apps gate real user-facing approvals on a classification that lives in shared source.

- **`CONNECTOR_WRITE_TOOLS` and `isConnectorWriteTool` are public, not internal** (`pi-extensions/pi-claude-bridge/src/connectors.ts`). Consumers pin the actions they expose against this classification, because *"the sidecar structurally cannot do this itself"* is the **bridge's** claim, not theirs.
- **Reclassifying an entry as a READ makes a consumer's confirmation card bypassable, and nothing downstream notices.** Additions are safe and expected; removals and read-verb renames are breaking. Coordinate before changing one. `unit-connectors.mjs` asserts every listed id still classifies as a write and that each connector family stays represented, so the change has to be deliberate.
- **The connector-cache file format has an external reader.** A consumer that quarantines the bundle re-implements the reader half — path `<piUserDir()>/connector-cache/<sha256(CLAUDE_CONFIG_DIR).hex[0..16]>.json`, payload `{version, scope, savedAt, connectors}`, 7-day max age — as the "is this connector installed" half of its write gate. That coupling fails open on drift, so a format change degrades them from two gates to one rather than breaking them; bump `CACHE_VERSION` so their staleness check rejects rather than misreads.
- **Anything the deny path says is shown verbatim to every consumer's model.** The `PreToolUse` deny reason is handed straight to the `claude` child, so product-specific wording in it tells one app's model to use another app's product. Keep it product-neutral and let each host describe its own approval flow in its own prompt. Guarded by a test.

## Connector Enumeration Is Token-Scoped

Deterministic connector enumeration answers "which connectors does this account have" by calling the account rather than asking the model. One property is easy to get wrong and fails silently:

- **The organization UUID in the request path is ignored.** The **token alone** selects the account — a wrong or garbage org UUID still returns the bearer token's own account with nothing anomalous in the result.
- **So a multi-account host cannot scope by org.** Selecting an account means selecting the credential — which `CLAUDE_CONFIG_DIR` gets read — not passing that account's UUID.
- Treat a connector inventory as belonging to whichever credential produced it, and carry the account identity alongside it rather than inferring it from the request you made.

## Capability Probe Contract

For any probe whose result other repos store and act on — connector inventories being the live case.

- **An empty result is not evidence of absence.** It must never overwrite a known-good inventory; mark the snapshot as a failed check and render "couldn't check", not "not connected", so a retry cannot erase what was already known.
- **A partial result is not evidence of absence either, and it is more dangerous.** An empty probe looks wrong; a partial one looks successful. A search-driven probe returns a lower bound, and `probe_failed = false` answers "did the probe error", never "is this list complete".
- **Consumers may only treat a result as an enumeration if it says it is one.** Absent an explicit completeness signal, treat every probe result as a lower bound and never conclude a capability is missing from it.
