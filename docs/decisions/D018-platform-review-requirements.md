# D018: GitHub enforces review requirements and the package keeps review operations

[← Decision Index](INDEX.md)

**Date**: 2026-09-30

**Status**: Active (lanes-app kendex/refresh heads with passing render proof → D023)

**Research**: KEN-2067; the design note is attached to that issue

**Supersedes**: [D003](D003-one-merge-path.md) in part, the required review status and the review-finding answer contract; [D013](D013-admin-merge-green-prs.md) in part, the approval and required review status

**Decision**: GitHub's organization pull-request rule requires an approval, dismisses stale approvals on push and requires review-thread resolution. Copilot reviews each push and its approvals count toward merge requirements. Repository required checks exclude the retired review status and bind each remaining context to its reporting app. The review engine and its settings are deleted; the package keeps the multi-PR watcher, the organization-standard report, environment provisioning and consumer refresh. The overseer app approves the current head only after internal review passes with no open blocker and the approval wait expires, and its pull-request-mode bypass on the required-checks and merge-queue rulesets permits an emergency merge when a required check cannot pass, posted with the pull request, head, broken check and reason.

**Why**: GitHub enforces the same head binding, stale-approval dismissal and thread resolution without a separately published status, and every served pull-request repository has Copilot approvals. The watcher and the standard report answer questions GitHub does not report for the organization.

**Rejected**: Keeping the review engine beside the platform rules: two judges of one head.

**Revisit when**: A served repository cannot use Copilot approvals or GitHub rulesets, or GitHub stops counting Copilot approvals toward merge requirements.
