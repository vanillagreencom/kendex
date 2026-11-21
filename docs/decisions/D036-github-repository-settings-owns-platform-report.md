# D036: github-repository-settings owns the opt-in GitHub platform report

[← Decision Index](INDEX.md)

**Date**: 2026-11-21

**Status**: Active

**Research**: [KEN-2358](https://linear.app/vanillagreen/issue/KEN-2358); the owner's approval of the KEN-2332 plan, sign-off 1790816341, which assigns repository configuration to github-repository-settings; Jarvis's answer of 2026-11-21 under the owner's delegation, ask 1795249212-985091-10358: "one new short decision record. It records the move the owner approved with the KEN-2332 plan (sign-off 1790816341) and reverses no standing choice."

**Supersedes**: [D018](D018-platform-review-requirements.md) in part, the organization-standard report's owner; [D031](D031-organization-tooling-owns-review-secrets.md) in part, the organization-standard report's owner

**Decision**: The opt-in organization-standard report, its standard and its settings move from review-gate to github-repository-settings. The report's previous setting keys keep working with a warning that names each replacement. D018 and D031 keep every other part.

**Why**: The approved plan makes github-repository-settings the owner of a repository's GitHub configuration, and the report reads that configuration. review-gate keeps consumer refresh.

**Rejected**: Keeping the report in review-gate, which would leave repository settings with two owning packages.

**Revisit when**: github-repository-settings stops owning repository configuration, or the report gains a row that reads something other than GitHub settings.
