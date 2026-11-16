# Heartbeat audit

Read when [oversee-events.md § Heartbeat backlog audit](oversee-events.md#heartbeat-backlog-audit) runs at a `heartbeat`. It applies to the fleet's Linear team. A GitHub-only fleet skips it with a note: `audit-issues team` has no GitHub mode.

Keep Triage enabled only for a team whose public repository receives outside issues. Fleet filings enter Backlog per the project-management skill's `workflows/audit-issues.md` § 7.2.

## Trigger

| Heartbeat input | Action |
|-----------------|--------|
| A fresh, complete Backlog count for the team, and `last_backlog_audit` from the fleet state | Run a full audit when the record is missing, its `at` is older than 24 hours, or today's count is at least 50 above its `backlog`. Otherwise skip the full audit. |
| Every Triage item of the team, read with `--max`, with no created-since or `triaged` filter | Decide every item whose `created_at` is older than 24 hours, even when no full audit is due. |
| An input that failed, came back truncated or did not read | Report the failure. Never read it as zero, and never advance the audit record. |

The overseer reads counts and identifiers only; the TPM reads bodies, comments and source. Every state command names the fleet's `[OVERSEE_STATE_DIR]`:

```bash
.agents/skills/orch/scripts/orch-runtime --state-dir [OVERSEE_STATE_DIR] state get --fleet /last_backlog_audit
.agents/skills/linear/scripts/linear.sh issues list --team [TEAM] --state Backlog --max --format ids
.agents/skills/linear/scripts/linear.sh issues list --team [TEAM] --state Triage --max --format ids
```

## Full audit

1. Run `.agents/skills/orch/scripts/orch-runtime reconcile-items` as the audit-issues workflow § 1.2.1 says. Its successful reply's `result.findings` and `result.lines` supply findings; a refused reply stops the audit.
2. Run `audit-issues team` over Backlog, Todo, In Progress and In Review, then `audit-issues issue [TRIAGE_IDS]` over every aged Triage item. An empty Triage set needs no issue-mode run. Both are primary-session wrappers: the overseer runs them and never delegates them.
3. Combine the two wrappers' § 4.1 analysis briefs into one fresh canonical `tpm` task, launched and captured as [oversee-events.md § Lane proposals](oversee-events.md#lane-proposals) launches its `tpm`. It follows the project-management skill's `workflows/tpm-audit.md` with `--team`, then with `--issues [FILE_PATH]`, the existing-issue input file the audit-issues workflow § 4.1 prepares from the Triage IDs. It returns the team-mode and issue-mode payloads, each inline, in one final return. A heartbeat with only aged Triage items delegates the issue analysis alone.
4. The brief includes [SKILL.md § The Cycle](../SKILL.md#the-cycle), Item work stays in lanes: the control host permits read-only analysis, no item work and no bulk writes. The TPM changes no tracker field. For this audit Triage is an eligible input despite `tpm-audit`'s active-state restriction: the TPM recommends acceptance to Backlog or Todo with labels, priority and project, a duplicate merge, or a decline with its reason.
5. Collect and validate each payload through audit-issues § 4.2, then run the wrappers in the order of step 2.
6. Authorize the actions (§ Authorization), run the Triage dispositions (§ Triage execution), and send the one owner ask (§ Owner ask).
7. Record the audit (§ Audit record).

Leave Triage items younger than 24 hours unchanged.

## Authorization

- A run over aged Triage items alone authorizes dispositions only for its own input Triage IDs, and ignores every sweep row for any other issue.
- Before audit-issues § 6, check every proposed action against live lanes, open pull requests and branches, issue bodies and pending owner decisions.
- Hold every creation, and every action on an item with a live lane, an open pull request or branch, an owner hold or gate, a quoted owner directive, or Urgent or High priority. Also hold a cancel that depends on a pending owner decision, and a close by folding into a larger item.
- Under `PM_CREATE_AUTONOMY=auto`, authorize the remaining duplicate closes, `below_bar` cancels, and obsolete closes whose row names a Done item or merged commit and shows it satisfies the closed item's scope. A `below_bar` cancel posts its one-line failed-bar reason, then sets Canceled through audit-issues § 7's comment-then-cancel route.
- Apply the remaining label, priority, relation, hierarchy and project corrections. Accept an unheld aged Triage item with those fields. A decline outside the eligible close set needs an ask.
- Under `PM_CREATE_AUTONOMY=ask`, closures also wait for approval.
- Take held rows out of the execution set, their `supersedes[]` and cascading child cancellations included, and keep them in the findings for the owner. Every held row appears in the owner ask or the progress report, with its proposed action, its reason and any pending ask. The automatic Cancel set is never the whole displayed Cancel section.

## Triage execution

1. Accept an authorized aged Triage item, after audit-issues § 7.0's label preflight:

   ```bash
   .agents/skills/linear/scripts/linear.sh issues update [ID] --state "[Backlog|Todo]" --labels "[VALIDATED_FINAL_LABELS]" --priority [PRIORITY] --project "[PROJECT]"
   ```

   An issue-mode `valid` or `skip` alone does not accept it.

2. Close an authorized duplicate, an existing issue assigned `skip` with the kept issue as `target` among them: write a reason naming the kept issue to a file, run `.agents/skills/linear/scripts/linear.sh comments create [ID] --body-file [REASON_FILE]`, then `linear.sh issues update [ID] --state "Canceled"`, per the linear skill's `patterns/workflow-actions.md` § State Transitions.
3. Verify every change live through audit-issues § 7.5 before counting it or recording the audit.

## Owner ask

1. Batch the held rows of both passes into one file, naming each proposed action and its evidence.
2. Send one owner ask, `lane-mail ask --item overseer --to owner --file [PATH]` with its options and the safe recommendation, in the form [communication-modes.md § Owner asks](communication-modes.md#owner-asks) gives, never the wrapper's interactive multi-select. An open ask for the same rows stays pending; do not send it twice.
3. When the Jarvis session runs, check its presence before sending: the root's `SLACK_JARVIS_SESSION_FILE` is younger than `SLACK_JARVIS_SESSION_MAX_AGE` (the slack skill's `README.md` § The Jarvis session hold), and `slack listen --status` reports `held-by=jarvis`. The Jarvis session then reads the root's mailbox first. Without that presence, the relay posts the ask to the owner.
4. Apply only the rows the owner authorizes, after the ruling.

## Audit record

After both full-audit passes validate, the authorized actions are applied and any owed ask is sent, record a fresh Backlog count read after the audit:

```bash
.agents/skills/orch/scripts/orch-runtime --state-dir [OVERSEE_STATE_DIR] op --fleet --request-json '{"op":"record-overseer-ledger","entry":"backlog-audit","backlog":[BACKLOG_COUNT]}'
```

The runtime stamps `at` from its own clock. Pending owner rows do not hold back the record. A failed pass or change leaves the earlier record as it stands. A run over aged Triage items alone does not reset the full-audit clock.

## Progress report

Every `report-due` owner summary follows the communication skill's [summary template](../../communication/references/reports.md#summary-template):

- Report `created N, closed M since the last report` with the outcome readings. Count distinct issue IDs from verified audit-issues § 8 execution results and from lane creation and closure receipts since the last report sent to the owner, or since fleet start for the first. Proposals and pending rows do not count. Missing receipts read `counts unread`, never zero.
- Name every Triage item still older than 24 hours and why it stays in Triage, a pending owner ask included. Read Triage fresh for the report, never from the `triaged` log of the fleet's `triage` verifier.
