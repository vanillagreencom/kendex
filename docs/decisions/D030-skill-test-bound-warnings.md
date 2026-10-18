# D030: Skill Tests warns near each bound

[← Decision Index](INDEX.md)

**Date**: 2026-10-18

**Status**: Active

**Research**: [KEN-4340 approval](https://linear.app/vanillagreen/issue/KEN-4340#comment-6d39a703-a97c-49cd-a478-44360b4d7634), recorded by the owner's delegate.

**Supersedes**: [D024](D024-skill-tests-time-budgets.md) for review-trigger warnings only.

**Decision**: Warn for a passing Skill Tests suite or completed job only above 80 percent of its own bound. Keep the existing margin calculation, annotation format, runner, watcher and hard limits. The Linux and macOS review values remain accepted annotation inputs and do not trigger warnings on their own.

**Why**: The measured job rows that warn on review time alone use 17 to 78 percent of their bounds. Repeated warnings below those bounds obscure rows that need work reductions. A job or suite that grows below the margin no longer warns early.

**Rejected**: Retaining review-only warnings, because they repeat without a distinct maintenance action. Higher limits or additional shards retain the measured work.

**Revisit when**: An earlier warning has a separate maintenance action that the bound warning cannot supply.
