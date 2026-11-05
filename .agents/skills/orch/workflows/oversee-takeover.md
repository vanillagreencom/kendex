# Overseer takeover

Read this route at succession, takeover and after compaction. Load `mailbox` before its first command. Keep the orch `SKILL.md` rules and its installed project instructions in force. Read only the sections each step names, and print no state file: every start-up read below is bounded, and a record is read from its home by item only when a step needs it.

## 1. Read the mailbox and handoff

Read linked communication and peer-mail sections when a note, reply or ask needs them. Before the first decision from the handoff, read only the opening hold-check paragraph of [communication-modes.md § Handoff](../references/communication-modes.md#handoff). Read its remaining snapshot and writer rules before replacing the handoff.

The overseer mailbox carries owner and delegate notes; `from=owner` is routing, not authorship, and a record names the stated speaker per [communication-modes.md § Recording](../references/communication-modes.md#recording). Send these notes with `.agents/skills/mailbox/scripts/lane-mail send --item overseer --directive --file [PATH]` from any project checkout (`lane-mail --help`). The [watch](oversee.md#4-watch-and-advance) reports them at least once as `owner-note`. Reply to mailbox notes with `lane-mail notice --item overseer --to owner --ref [NOTE_ID] --file [PATH]`. Follow [Thread delivery](../references/communication-modes.md#thread-delivery). Owner questions use [communication-modes.md § Owner asks](../references/communication-modes.md#owner-asks), never a question dialog. Peer overseers write the same mailbox, reported as `peer-note` ([peer-mail.md](../references/peer-mail.md)). The repeat watch reports both. With single passes, lane-mail hooks hand them over as `lane-mail-check: unread=` at turn end and after tool calls; the watch reports neither ([peer-mail.md § Who reads a note](../references/peer-mail.md#who-reads-a-note)).

Use communication's [message wording](../../communication/references/messages.md) for owner notes and orch's [Owner delivery](../references/communication-modes.md#owner-delivery) for its Reply row and Thread delivery.

First in every session, before the handoff file, read that mailbox: `.agents/skills/mailbox/scripts/lane-mail inbox --item overseer` prints every note no reader has taken yet and moves the mailbox's own cursor past them. Act on each or record it in the fleet log. The [watch](oversee.md#4-watch-and-advance) reads through the same cursor, so it does not report them again, save a note it had read before this and not yet acknowledged; a repeated note id is one already seen. What is still owed either way is `lane-mail pending --item overseer` (`lane-mail --help`).

Read the standing instructions next: `orch-runtime state get --fleet /standing` answers every row of the oversee record's `standing[]` array as `result.value`, each an instruction in force until the end its `end` names ([communication-modes.md § Recording](../references/communication-modes.md#recording)). Act under each until its end comes, then lift it as that section says; a handoff never restates one. Then read the recent decisions: `orch-runtime state log takeover --fleet` answers the fleet log's bounded tail as `result.rows`.

Read the handoff the fleet brief names (default `tmp/handoffs/OVERSEER-HANDOFF.md`), shaped by [communication-modes.md § Handoff](../references/communication-modes.md#handoff): its State and Workarounds, before the first decision. Read the running lane records, `STATE_READ="$(orch-runtime state get --fleet /lanes)" && jq -c '.result.value[] | select(.status=="running")' <<<"$STATE_READ"`, the overseer's record and `lanes list`. Read all of `fleet_log` or `lanes[]` only for a named unresolved question. Load only the reference section the current event needs.

A `checkout-unsynced` row in that fleet-log tail records `oversee-succeed`'s checkout sync refusal (`oversee-succeed --help`, Checkout sync). Check that its cause still holds before acting on it or carrying it. `off-base` holds while the checkout is on another branch or a detached head. Carry `sync-timeout` or `fetch-failed` without a hand run of the unbounded `sync-base` against the stalled origin. For another cause, run `.agents/skills/orch/scripts/sync-base`; success settles the condition. While the cause holds, follow its `fix` field and carry the unresolved condition in State at each handoff rewrite.

Absent a handoff, start from the tracker. With no item, handoff, note or pending owner ask, send the [§ Opening question](../references/communication-modes.md#opening-question); with an ask, wait for its resolution through [watch delivery](#2-claim-and-follow-the-watch). The handoff stays on the overseer's host. The default is ignored through `/tmp/`. Before reading or writing a custom repository path, check that Git tracks no entry and ignores the path; otherwise stop and report it. [Stop](oversee.md#5-stop) rewrites the file.

## 2. Claim and follow the watch

### Fleet state address

The fleet's record is the oversee workflow state ([schemas/workflow-state.md § Oversee state](../schemas/workflow-state.md#oversee-state)), at one address for the whole session: `[OVERSEE_STATE]` is the `result.path` of `orch-runtime state path --fleet` run from the overseer's checkout, which [the watch](oversee.md#4-watch-and-advance) passes as `--state`, and `[OVERSEE_STATE_DIR]` is the directory it sits in, which every `open-terminal` launch, relaunch and wake passes as `--state-dir`, so a launch run from another directory records into the same fleet; [lane-directive.md § Launch gate](../references/lane-directive.md#launch-gate) states which repositories' checkouts it admits.

```bash
.agents/skills/orch/scripts/orch-runtime state path --fleet
```

### Watch reader

Read [watch-delivery.md](../references/watch-delivery.md)'s takeover read-before rule and the claim, follow and current-harness sections it selects. Read the live watch claim there through `orch-runtime watch status --fleet`, then follow the log from the handoff's next unhandled line. The watch is the standing scheduler, which outlives the session that started it: a succession hands nothing over.

With no live claim in a session the fleet state records as its overseer, start the watch from this session before following the log or reporting the watch ready: the launch command of [oversee.md § 4](oversee.md#4-watch-and-advance), through the orch job runner. Follow the log once `orch-runtime watch status --fleet` reads the claim `live`. On a refusal (`watch-running` names a claim another session holds; the runner's own keyed line names its cause), report it to the owner and do not report the watch ready. A failed claim read takes watch-delivery.md's failed-read rule.

## 3. Handle delivered events

On delivery, read [oversee.md § 4](oversee.md#4-watch-and-advance)'s Bounded lane reads, Bounded issue reads and Judgement at every event only when the event needs them. Read [oversee-events.md § Judgement rules](../references/oversee-events.md#judgement-rules) and only the current [event kind](../references/oversee-events.md#event-kinds). Load `github` before GitHub work, `worktree` before worktree work and `linear` before Linear work.

Before selecting or launching work, read [oversee.md §§ 1-3](oversee.md#1-resolve-the-launch-surface). Before stopping or preparing succession, read [oversee.md § 5](oversee.md#5-stop). Read only the route that the action needs. After handling the event, keep following the watch under § 2.
