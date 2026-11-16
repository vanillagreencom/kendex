# Overseer takeover

Run this at succession, at takeover and after compaction. Every controller the runtime opens starts on it. Load `mailbox` before the first command. Keep the orch `SKILL.md` rules and the installed project instructions in force. Read only the sections each step names, and print no state file: every read below is bounded, and a record is read by item only when a step needs it. A takeover never submits a fresh `start-controller`: that is a fleet's first start, and it empties the watch log.

## 1. Read the mailbox and handoff

The overseer mailbox carries owner and delegate notes. `from=owner` is routing, not authorship: a record names the stated speaker per [communication-modes.md § Recording](../references/communication-modes.md#recording). Notes arrive through `.agents/skills/mailbox/scripts/lane-mail send --item overseer --directive --file [PATH]`, run from any project checkout, and the [watch](oversee.md#4-watch-and-advance) reports each at least once as `owner-note`; peer overseers write the same mailbox, reported as `peer-note` ([peer-mail.md](../references/peer-mail.md)). Under single passes, the lane-mail hooks hand them over as `lane-mail-check: unread=` at turn end and after tool calls instead ([peer-mail.md § Who reads a note](../references/peer-mail.md#who-reads-a-note)). Reply with `lane-mail notice --item overseer --to owner --ref [NOTE_ID] --file [PATH]`, worded under communication's [message wording](../../communication/references/messages.md) and orch's [Owner delivery](../references/communication-modes.md#owner-delivery) and [Thread delivery](../references/communication-modes.md#thread-delivery). Owner questions use [communication-modes.md § Owner asks](../references/communication-modes.md#owner-asks), never a question dialog. Read the linked communication and peer-mail sections when a note, reply or ask needs them.

1. Read the mailbox first in every session, before the handoff. `.agents/skills/mailbox/scripts/lane-mail inbox --item overseer` prints every note no reader has taken and moves the mailbox's cursor past them. Act on each, or record it in the fleet log. The watch reads through the same cursor, so it does not report them again, except a note it read earlier and has not acknowledged; a repeated note id is one already seen. What is still owed is `lane-mail pending --item overseer` (`lane-mail --help`).
2. Read the standing instructions: `orch-runtime state get --fleet /standing` answers the fleet state's `standing[]` rows as `result.value`, each in force until the end its `end` names ([communication-modes.md § Recording](../references/communication-modes.md#recording)). Act under each until its end comes, then lift it as that section says; a handoff never restates one. Then read the recent decisions: `orch-runtime state log takeover --fleet` answers the fleet log's bounded tail as `result.rows`.
3. Read the opening hold-check paragraph of [communication-modes.md § Handoff](../references/communication-modes.md#handoff), then the handoff the brief names (default `tmp/handoffs/OVERSEER-HANDOFF.md`): its State and Workarounds, before the first decision. Read that section's snapshot and writer rules before replacing the handoff.
4. Read the open lane asks from the mailboxes, never from the handoff alone: `.agents/skills/orch/scripts/orch-runtime handoff --fleet --asks` answers every ask a running lane's mailbox holds open, with its id and lane. Answer each before reporting no lane waiting on the root.
5. Read the lane records, `orch-runtime state get --fleet /lanes`, keeping those whose `status` is `running`; the controller record, `orch-runtime state get --fleet /controller`; and the account listing, `.agents/skills/orch/scripts/orch-runtime lane roster`. Read the whole `fleet_log` or `lanes[]` only for a named unresolved question, and load only the reference section the current event needs.

With no handoff, start from the tracker. With no item, handoff, note or pending owner ask, send the [§ Opening question](../references/communication-modes.md#opening-question); with an ask, wait for its resolution through [the watch](#2-claim-and-follow-the-watch). The handoff stays on the overseer's host; the default path is ignored through `/tmp/`. Before reading or writing a custom repository path, check that Git tracks no entry there and ignores the path; otherwise stop and report it. [Stop](oversee.md#5-stop) rewrites the file.

## 2. Claim and follow the watch

### Fleet state address

The fleet's record is the oversee state ([workflow-state.md § Oversee state](../schemas/workflow-state.md#oversee-state)), at one address for the whole session. `[OVERSEE_STATE]` is the `result.path` of the command below, run from the overseer's checkout; [the watch](oversee.md#4-watch-and-advance) takes it as `--file`. `[OVERSEE_STATE_DIR]` is its directory: `orch-runtime --state-dir` names it for a command run outside the overseer's checkout, so that command reads and records the same fleet. [lane-directive.md § Launch gate](../references/lane-directive.md#launch-gate) states which repositories' checkouts a launch admits.

```bash
.agents/skills/orch/scripts/orch-runtime state path --fleet
```

### Watch reader

1. Read [watch-delivery.md](../references/watch-delivery.md) § The watch, § Reader directory, § Claim and the section and row for this harness.
2. Read the claim through `orch-runtime watch status --fleet`.
3. With a live claim, follow the log from the handoff's next unhandled line. The watch outlives the session that started it: a succession hands nothing over.
4. With no live claim, in a session the fleet state records as its overseer, start the watch from this session with the command of [oversee.md § 4](oversee.md#4-watch-and-advance) before following the log or reporting the watch ready. Follow the log once `watch status` reads the claim `live`.
5. On a refusal (`watch-running` names a claim another session holds; the runner's own keyed line names its cause), report it to the owner and do not report the watch ready. A failed claim read takes watch-delivery.md § Claim's rule.

## 3. Handle delivered events

1. On delivery, read [oversee.md § 4](oversee.md#4-watch-and-advance)'s Bounded lane reads, Bounded issue reads and Judgement at every event only where the event needs them, then [oversee-events.md § Judgement rules](../references/oversee-events.md#judgement-rules) and the current [event kind](../references/oversee-events.md#event-kinds) alone.
2. Load `github` before GitHub work, `worktree` before worktree work and `linear` before Linear work.
3. Before selecting or launching work, read [oversee.md §§ 1-3](oversee.md#1-resolve-the-launch-surface). Before stopping or preparing a succession, read [oversee.md § 5](oversee.md#5-stop). Read only the route the action needs.
4. After handling the event, keep following the watch under § 2.
