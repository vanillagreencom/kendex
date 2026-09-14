# Proposal sweep

Run this workflow only in the TPM lane that [oversee](../../orch/workflows/oversee.md) launches. Read proposal comments, verify them, and write analyzed audit JSON. Do not modify the tracker or repository source.

## Inputs

The launch brief carries `Worktree`, `Fleet issues`, `Resolved comments`, and `Status file`. `Resolved comments` contains the comment IDs that already have outcomes in the fleet log.

## 1. Read proposals

Run `linear.sh sync --reconcile`. For each fleet issue, run `linear.sh cache comments list [ISSUE_ID]`. Select each unresolved comment whose first line starts exactly `Proposal:`. A proposal comment carries `Reached by:`, `Reason:`, and `Evidence:` lines. Keep its issue ID and comment ID with the candidate.

## 2. Verify

Treat each candidate as a proposed item in [tpm-audit](tpm-audit.md) issue mode. Map its title, reached behavior, reason, and evidence path to the issue-mode title, impact, description, and location. Infer its project, labels, priority, estimate, and requirements from the verified scope and project taxonomy. Read the repository path on its `Evidence:` line in this worktree. Apply the creation bar, decision search, source verification, full-backlog duplicate check, and cancellation sweep from that workflow. A missing field, an unreadable evidence path, or a claim the source does not support becomes `skip` with a one-line reason. Do not read another lane's worktree or status file.

## 3. Write the audit

Write one issue-mode file that follows [audit-output.md](../schemas/audit-output.md), with `approved_at_plan_gate` false. Each create, skip, and cancellation row carries a one-line reason. Add `proposal_sources[]`, with `{ "index": N, "issue": "[ISSUE_ID]", "comment_id": "[COMMENT_ID]" }` for each proposal row, so the overseer can reply to the source thread. Keep verification details out of the lane status file.

Write the JSON under this worktree's `tmp/`. Write the status file so it contains exactly one `Proposal audit: [REPOSITORY_RELATIVE_PATH]` line. The lane creates no tracked issue and changes no repository file.
