# D031: The organization's own tooling owns review-secret setup and app installation

[← Decision Index](INDEX.md)

**Date**: 2026-10-20

**Status**: Active

**Research**: [KEN-3499](https://linear.app/vanillagreen/issue/KEN-3499); the owner's approval is that issue's comment of 2026-10-20; fleet's matching move is [FLT-992](https://linear.app/vanillagreen/issue/FLT-992)

**Supersedes**: [D018](D018-platform-review-requirements.md) in part, environment provisioning and the standard report's app and environment rows

**Decision**: The review-gate package ships no command that creates or corrects a repository's review-secret environment or its secrets, and its organization-standard report has no row for the app installation, the environment or secret placement. The organization's own tooling sets up and checks them; in the vanillagreen organization that is fleet. The report keeps the ruleset, required-check and CI-context rows, and refresh adoption keeps its read-only check of the caller's environment in `scripts/lib/environment.py`. The three settings those rows read are retired.

**Why**: Two tools writing the same GitHub settings can silently undo each other. The organization's tooling already owns the rulesets and, since FLT-992, the environment and app installation, so kendex keeps only the reads every consumer needs: pull-request watching, the standard report and refresh adoption.

**Rejected**: Keeping provisioning and the rows in both tools: two writers of one setting, with no owner to settle a disagreement.

**Revisit when**: A consumer outside an organization with its own tooling needs kendex to set up its review-secret environment or app installation.
