# D018: GitHub enforces review requirements and the package keeps review operations

[← Decision Index](INDEX.md)

**Date**: 2026-09-30

**Status**: Active

**Research**: [KEN-2067 design note](../plans/review-gate-platform.md)

**Approval**: owner direction 1790636017 and owner note 1790642054, recorded in the design note; KEN-2089 requires this record.

**Supersedes**: [D003](D003-one-merge-path.md) item 3's required review status and item 2's review-finding answer contract; [D013](D013-admin-merge-green-prs.md) item 1's approval and required review status. [D016](D016-merge-route-reads-bypass.md) keeps ownership of the merge route and emergency bypass.

**Decision**: GitHub's organization pull-request rule requires an approval, dismisses stale approvals on push and requires review-thread resolution. Copilot reviews each push and its approvals count toward merge requirements. Repository required checks exclude the retired review status and bind each remaining context to its reporting app. The review engine and its settings are deleted. The package keeps the multi-PR watcher, organization-standard report, environment provisioning and consumer refresh.

**Fallback approval**: the overseer app approves the current head only after internal review passes with no open blocker and the approval wait expires. This satisfies the approval rule without changing any ruleset.

**Emergency merge**: the overseer app's `pull_request`-mode bypass on the required-checks and merge-queue rulesets permits an emergency merge when a required check cannot pass. The organization approval and thread-resolution rules still hold. The overseer posts the pull request, head, broken check and reason. No temporary bypass entry is added.

**Consumer refresh**: an existing consumer first takes a one-time trusted removal PR from its owning lane. The lane runs the reviewed new adopter to remove the unedited retired gate workflow and its inventory entry. The PR takes normal CI, final-head Copilot approval and resolved threads. Before arming, the owner removes the retired required context and binds the surviving Actions contexts to app 15368. Automatic refresh starts from the migrated default branch and never performs retirement or executes refreshed scripts under its app token. Automatic review threads are resolved only after upstream filing succeeds and the reply names the issue. A thread that cannot be filed stays open until it is resolved by hand. Review bodies are not read by the refresh runner.

**Rationale**:

- GitHub enforces the same head binding, stale-approval dismissal and thread resolution without a separately published status.
- Every served PR-flow repository has Copilot approvals under Enterprise Cloud, per the design note.
- The watcher and standard report answer questions GitHub does not report for the organization.

**Revisit When**: a served repository cannot use Copilot approvals or GitHub rulesets, or GitHub stops counting Copilot approvals toward merge requirements.

**Verification**: the design note records the sandbox approval, unresolved-thread refusal and stale-approval dismissal proof. `skills/review-gate/tests/adopt-refresh.test.sh` proves workflow and inventory retirement. `skills/review-gate/tests/refresh-reviews.test.sh` proves filing before thread resolution. The kendex overseer distributes the trusted removal route to fleet, vg, vsys, drovr, hyprtrade, hyprtrade-io and memsira after the catalog merge. Fleet owns the consumer proof and the decision superseding fleet D061 item 6. The kendex overseer records fleet’s merge evidence and closes KEN-2089.

**References**: KEN-2089, KEN-2067, [D003](D003-one-merge-path.md), [D013](D013-admin-merge-green-prs.md)
