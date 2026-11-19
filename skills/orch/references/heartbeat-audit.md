# Heartbeat audit

Read when [oversee-events.md § Heartbeat backlog audit](oversee-events.md#heartbeat-backlog-audit) runs at a `heartbeat`. The audit covers the fleet's Linear team. A GitHub-only fleet skips it with a note, since `audit-issues team` has no GitHub mode.

Keep Triage enabled only for a team whose public repository receives outside issues.

## Trigger

| Heartbeat input | Action |
|-----------------|--------|
| A fresh, complete Backlog count for the team, and `last_backlog_audit` from the fleet state | Run a full audit when the record is missing, its `at` is older than 24 hours, or today's count is at least 50 above its `backlog`. Otherwise skip the full audit. |
| Every Triage item of the team, read with `--max`, with no created-since or `triaged` filter | Decide every item whose `created_at` is older than 24 hours, even when no full audit is due. |
| An input that failed, came back truncated or did not read | Report the failure. Never read it as zero, and never advance the audit record. |

The overseer reads counts and identifiers only. The TPM reads bodies, comments and source. Each state command names the fleet's `[OVERSEE_STATE_DIR]`:

```bash
.agents/skills/orch/scripts/orch-runtime --state-dir [OVERSEE_STATE_DIR] state get --fleet /last_backlog_audit
.agents/skills/linear/scripts/linear.sh issues list --team [TEAM] --state Backlog --max --format ids
.agents/skills/linear/scripts/linear.sh issues list --team [TEAM] --state Triage --max --format ids
```

## Full audit

1. Run `.agents/skills/orch/scripts/orch-runtime reconcile-items` as audit-issues § 1.2.1 says. A successful reply supplies findings in `result.findings` and `result.lines`. A refused reply stops the audit.
2. Run `audit-issues team` over Backlog, Todo, In Progress and In Review. Then run `audit-issues issue [TRIAGE_IDS]` over every aged Triage item; an empty Triage set needs no issue-mode run. The overseer runs both primary-session wrappers itself and never delegates them.
3. Combine the two wrappers' § 4.1 analysis briefs into one fresh canonical `tpm` task. Launch and capture it as [oversee-events.md § Lane proposals](oversee-events.md#lane-proposals) launches its `tpm`. The TPM follows the project-management skill's `workflows/tpm-audit.md` with `--team`, then with `--issues [FILE_PATH]`, the existing-issue file audit-issues § 4.1 prepares from the Triage IDs. It returns both payloads inline in one final return. A heartbeat with only aged Triage items delegates the issue analysis alone.
4. The brief includes [SKILL.md § The Cycle](../SKILL.md#the-cycle), Item work stays in lanes: the control host permits read-only analysis, no item work and no bulk writes. The TPM changes no tracker field. Triage is an eligible input for this audit, despite `tpm-audit`'s active-state restriction. For each Triage item the TPM recommends one of: acceptance to Backlog or Todo with labels, priority and project; a duplicate merge; or a decline with its reason.
5. Collect and validate each payload through audit-issues § 4.2. Then run the wrappers in step 2's order.
6. Authorize the actions (§ Authorization), run the Triage dispositions (§ Triage execution), and send the one owner ask (§ Owner ask).
7. Record the audit (§ Audit record).

Leave Triage items younger than 24 hours unchanged.

## Authorization

- A run over aged Triage items alone authorizes dispositions only for its own input Triage IDs. It ignores every sweep row for any other issue.
- Before audit-issues § 6, check every proposed action against live lanes, open pull requests and branches, issue bodies and pending owner decisions.
- Hold every creation. Hold every action on an item with a live lane, an open pull request or branch, an owner hold or gate, a quoted owner directive, or Urgent or High priority. Also hold a cancel that depends on a pending owner decision, and a close by folding into a larger item.
- Under `PM_CREATE_AUTONOMY=auto`, authorize the remaining duplicate closes and `below_bar` cancels. Also authorize an obsolete close whose row names a Done item or merged commit and shows it satisfies the closed item's scope. A `below_bar` cancel posts its one-line failed-bar reason, then sets Canceled through audit-issues § 7's comment-then-cancel route.
- Apply the remaining label, priority, relation, hierarchy and project corrections. Accept an unheld aged Triage item with those fields. A decline outside the eligible close set needs an ask.
- Under `PM_CREATE_AUTONOMY=ask`, closures also wait for approval.
- Take held rows out of the execution set, with their `supersedes[]` and cascading child cancellations. Keep them in the findings for the owner. Show every held row in the owner ask or the progress report, with its proposed action, its reason and any pending ask. The automatic Cancel set is never the whole displayed Cancel section.

### High-priority project correction

The Urgent or High priority hold does not hold a `wrong_project` correction whose `to` is a map project: that project-only move changes no state or owner. Every other hold still applies to that correction, and every other action on the item stays held. Apply the project-only update and its reason comment through `audit-issues` § 7.1, then verify it live through § 7.5.

## Triage execution

1. Accept an authorized aged Triage item after audit-issues § 7.0's label preflight:

   ```bash
   .agents/skills/linear/scripts/linear.sh issues update [ID] --state "[Backlog|Todo]" --labels "[VALIDATED_FINAL_LABELS]" --priority [PRIORITY] --project "[PROJECT]"
   ```

   An issue-mode `valid` or `skip` alone does not accept it.

2. Close an authorized duplicate, including an existing issue assigned `skip` with the kept issue as `target`. Write a reason naming the kept issue to a file. Run `.agents/skills/linear/scripts/linear.sh comments create [ID] --body-file [REASON_FILE]`, then `linear.sh issues update [ID] --state "Canceled"`, per the linear skill's `patterns/workflow-actions.md` § State Transitions.
3. Verify every change live through audit-issues § 7.5 before counting it or recording the audit.

## Owner ask

1. Batch the held rows of both passes into one file. Name each proposed action and its evidence.
2. Send one owner ask: `lane-mail ask --item overseer --to owner --file [PATH]`, with its options and the safe recommendation, in the form [communication-modes.md § Owner asks](communication-modes.md#owner-asks) gives. Never use the wrapper's interactive multi-select. An open ask for the same rows stays pending; do not send it twice.
3. When the Jarvis session runs, check its presence before sending. Presence means the root's `SLACK_JARVIS_SESSION_FILE` is younger than `SLACK_JARVIS_SESSION_MAX_AGE` (the slack skill's `README.md` § The Jarvis session hold), and `slack listen --status` reports `held-by=jarvis`. With presence, the Jarvis session reads the root's mailbox first. Without it, the relay posts the ask to the owner.
4. After the ruling, apply only the rows the owner authorizes.

## Audit record

Record the audit once both full-audit passes validate, the authorized actions are applied and any owed ask is sent. Record a fresh Backlog count read after the audit:

```bash
.agents/skills/orch/scripts/orch-runtime --state-dir [OVERSEE_STATE_DIR] op --fleet --request-json '{"op":"record-overseer-ledger","entry":"backlog-audit","backlog":[BACKLOG_COUNT]}'
```

Pending owner rows do not hold back the record. A failed pass or change leaves the earlier record standing. A run over aged Triage items alone does not reset the full-audit clock.

## Progress report

Every `report-due` owner summary follows the communication skill's [summary template](../../communication/references/reports.md#summary-template):

- Report `created N, closed M since the last report` with the outcome readings. Count distinct issue IDs from verified audit-issues § 8 execution results and from lane creation and closure receipts. Count since the last report sent to the owner, or since fleet start for the first. Proposals and pending rows do not count. Missing receipts read `counts unread`, never zero.
- Name every Triage item still older than 24 hours and why it stays in Triage, including a pending owner ask. Read Triage fresh for the report, never from the `triaged` log of the fleet's `triage` verifier.
