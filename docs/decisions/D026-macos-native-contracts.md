# D026: macOS runs native contracts

[← Decision Index](INDEX.md)

**Date**: 2026-10-14

**Status**: Active

**Research**: [KEN-4013](https://linear.app/vanillagreen/issue/KEN-4013), [contract audit](https://uploads.linear.app/09589536-0763-447e-a0ed-6d9bf346d4cc/3afee16d-d50b-4e4c-9284-19d179e08ae3/470e242d-6f34-4f1f-8194-56f832fa2c21)

**Supersedes**: [D024](D024-skill-tests-time-budgets.md) for macOS test eligibility only.

**Decision**: Linux runs the complete shell contracts and their controls. macOS runs native, mixed and unresolved contracts through one eligibility owner at the existing runner and workflow boundary. Reviewed Linux duplicates leave macOS. A mixed suite can use a focused native entry that shares its original cases. The ownership proof rejects unclassified suites. The existing selector removes empty native shards. Dependency selection stays conservative until the complete input set is proved. Keep matching patch proof, integrated-tree checks, standard runners, bounds and warnings.

**Why**: Repeated portable checks consume the native job deadline before native process and pipe checks finish. A native contract can still differ through the host shell, utilities, filesystem or process behavior. Unresolved contracts retain that proof until their classification is established.

**Rejected**: Repeating every Linux suite on macOS, which retains the observed deadline failure. Independent platform selectors, which can disagree about required native coverage. Longer limits or extra macOS jobs, which the owner excludes.

**Revisit when**: A retained contract still exceeds its unchanged bound after portable work leaves, or a source change adds native behavior to a previously portable contract.
