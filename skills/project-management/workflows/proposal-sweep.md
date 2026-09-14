# Proposal sweep

Run this workflow only in the TPM lane that [oversee](../../orch/workflows/oversee.md) launches. Read proposal comments, verify them, and write analyzed audit JSON. Do not modify the tracker or repository source.

## Inputs

The launch brief carries `Worktree`, `Tracker`, optional GitHub `Repository`, `Fleet issues`, `Resolved comments`, `Status file`, and `Mailbox`. Every fleet issue belongs to that tracker and repository batch. `Resolved comments` contains the comment IDs that already have outcomes in the fleet log.

## 1. Read proposals

For Linear, run `linear.sh sync --reconcile`, then `linear.sh cache comments list [ISSUE_ID]` for each issue. For GitHub, run `gh issue view [NUMBER] --repo [OWNER/REPO] --json comments` for each issue. Select each comment absent from `Resolved comments` whose first line starts exactly `Proposal:`. A proposal carries `Source:`, `Priority:`, `Reached by:`, `Reason:`, and `Evidence:` lines, plus `Symptom:` when its source is `review`, `pr-comments`, or `local-review` and its proposed priority is 2. Keep its tracker, repository, issue ID, comment ID, and comment URL with the candidate.

## 2. Verify

Treat each candidate as a proposed item in [tpm-audit](tpm-audit.md) issue mode. Map its title, reached behavior, reason, and evidence path to the issue-mode title, impact, description, and location. Validate its proposed priority, then infer its project, labels, estimate, and requirements from the verified scope and project taxonomy. Copy `Source:` to `create_fields.source`. Set `create_fields.review_born` true exactly for `review`, `pr-comments`, and `local-review`, and false otherwise. Map the required `Symptom:` to `create_fields.symptom`. A review-born priority-2 candidate with no symptom becomes `skip`. Read the repository path on its `Evidence:` line in this worktree. Apply the creation bar, decision search, source verification, full-backlog duplicate check, and cancellation sweep from that workflow. A proposal-backed row has only two actions: `create` when it clears the creation bar, or `skip` with a one-line reason. Existing or overlapping work makes the proposal row `skip`; name the covering issue in its reason. Never emit `expand`, `update`, `supersede`, `combine`, or `cancel` for a proposal-backed row. A missing field, an unreadable evidence path, or a claim the source does not support also becomes `skip` with a one-line reason. Do not read another lane's worktree or status file.

## 3. Write the audit

Write one issue-mode file that follows [audit-output.md](../schemas/audit-output.md), with `tracker` set from the batch and `approved_at_plan_gate` false. Put the `create` and `skip` proposal rows before the cancellation-sweep rows. Keep cancellation-sweep rows separate, with the cancellation actions that [tpm-audit](tpm-audit.md) assigns to verified obsolete issues. Each proposal and cancellation row carries a one-line reason. Add one tracker-specific `proposal_sources[]` entry for each proposal row only, so the overseer can record its outcome against the source comment. A proposal source mapped to any action other than `create` or `skip` makes the output invalid; correct it before writing the file. Keep verification details out of the lane status file.

Write the JSON under this worktree's `tmp/`. Write the status file so it contains exactly one `Proposal audit: [REPOSITORY_RELATIVE_PATH]` line. After both files close successfully, write `Proposal sweep complete: [STATUS_FILE]` to a message file and send it with `.agents/skills/orch/scripts/lane-mail notice --item [CARRIER_ID] --file [MESSAGE_FILE]`. That notice is the lane's final worktree action. After it succeeds, access no worktree file and exit. A failed or incomplete sweep sends no completion notice. The lane creates no tracked issue and changes no repository file.
