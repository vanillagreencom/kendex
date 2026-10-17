# D024: Skill Tests budgets retain selected macOS proof

[← Decision Index](INDEX.md)

**Date**: 2026-10-11

**Status**: Active (macOS coverage → D026; patch proof → D027)

**Research**: [KEN-3774](https://linear.app/vanillagreen/issue/KEN-3774), [measured findings](https://uploads.linear.app/09589536-0763-447e-a0ed-6d9bf346d4cc/c9d06561-4387-464a-ad51-ffcaff2e59cb/dc460b31-e659-4b53-be3e-d5472d765adf)

**Decision**: [D026](D026-macos-native-contracts.md) governs macOS test eligibility. Keep matching patch proof and integrated-tree checks under [D013](D013-admin-merge-green-prs.md) and [D016](D016-merge-route-reads-bypass.md). Keep public Skill Tests on standard GitHub runners. Keep the 300-second Linux and 600-second macOS shard review triggers and all current hard limits. Reduce work when a successful maximum times 1.25 exceeds its suite or job limit. Judge timing in the existing suite runner through GitHub warning annotations. The existing overseer watch reads them for maintenance. The current code has only a budget comment and reports main failures. [KEN-3775](https://linear.app/vanillagreen/issue/KEN-3775) implements the warning route. [KEN-3776](https://linear.app/vanillagreen/issue/KEN-3776) pools the remaining serial batteries. [KEN-3777](https://linear.app/vanillagreen/issue/KEN-3777) reduces remaining orch-state work after KEN-3773. KEN-3762 and KEN-3773 stand as separate first repairs.

**Why**: Successful suites already approach their limits. Longer limits would retain the delay. Shared shell changes need native macOS proof even without Mac-specific paths. Matching proof already removes eligible repeated queue work. Public standard compute is free. No matched Blacksmith speed result or current account allowance read supports paid migration.

**Rejected**: Required timing checks, higher limits and a second Mac-only selector. They can reject valid proof or omit required coverage. A new runner or monitor would add cost or another timing owner before repeated test work is removed.

**Revisit when**: Landed work still exceeds the review triggers or lacks bound headroom at an indivisible coverage seam. A matched, owner-approved Mac pilot establishes actual proof time and cost with current account credits and allowance read.
