# D018: GitHub enforces review requirements and the package keeps review operations

[← Decision Index](INDEX.md)

**Date**: 2026-09-30

**Status**: Active (proved lanes-app kendex/refresh heads → D023; non-render refresh approval follows KEN-3462)

**Research**: KEN-2067; the design note is attached to that issue. [KEN-3462](https://linear.app/vanillagreen/issue/KEN-3462) authorizes the non-render consumer refresh approval route.

**Supersedes**: [D003](D003-one-merge-path.md) in part, the required review status and the review-finding answer contract; [D013](D013-admin-merge-green-prs.md) in part, the approval and required review status

**Decision**: GitHub's organization pull-request rule requires an approval, dismisses stale approvals on push and requires review-thread resolution. Copilot reviews each ordinary pull-request push and its approvals count toward merge requirements. The exact `kendex/refresh` branch authored by `vanillagreen-fleet-lanes[bot]` with author type `Bot` requests no Copilot review. Repository required checks exclude the retired review status and bind each remaining context to its reporting app. The review engine and its settings are deleted; the package keeps the multi-PR watcher, the organization-standard report, environment provisioning and consumer refresh. For a non-render consumer refresh with that identity, the overseer app approves the current head after its second-opinion review passes with no open blocker and CI passes on that head, through [Consumer refresh approval](../../skills/orch/references/copilot-head-notices.md#consumer-refresh-approval). That route needs no Copilot wait. [D023](D023-consumer-refresh-review.md) exempts only proved render heads from repeated review. For every other pull request, the overseer app approves the current head only after internal review passes with no open blocker and the approval wait expires. Its pull-request-mode bypass on the required-checks and merge-queue rulesets permits an emergency merge when a required check cannot pass, posted with the pull request, head, broken check and reason.

**Why**: GitHub enforces the same head binding, stale-approval dismissal and thread resolution without a separately published status, and every served pull-request repository has Copilot approvals. The watcher and the standard report answer questions GitHub does not report for the organization.

**Rejected**: Keeping the review engine beside the platform rules: two judges of one head.

**Revisit when**: A served repository cannot use Copilot approvals or GitHub rulesets, or GitHub stops counting Copilot approvals toward merge requirements.
