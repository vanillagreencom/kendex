# D026: macOS runs native contracts

[← Decision Index](INDEX.md)

**Date**: 2026-10-14

**Status**: Active (patch proof → D027; orch corpus removal → D035)

**Research**: [KEN-4013](https://linear.app/vanillagreen/issue/KEN-4013), [contract audit](https://uploads.linear.app/09589536-0763-447e-a0ed-6d9bf346d4cc/3afee16d-d50b-4e4c-9284-19d179e08ae3/470e242d-6f34-4f1f-8194-56f832fa2c21)

**Supersedes**: [D024](D024-skill-tests-time-budgets.md) for macOS test eligibility only.

**Decision**: Linux runs the complete shell contracts and their controls. macOS runs native, mixed and unresolved contracts through one eligibility owner at the existing runner and workflow boundary. Reviewed Linux duplicates leave macOS. A mixed suite can use a focused native entry that shares its original cases. Unknown suites remain selected as unresolved until reviewed. Unknown suites in an excluded shard's family use a retained job. An audit inventory is no prerequisite for executing discovered suites. The ownership proof checks exactly-once coverage. The existing selector removes empty native shards. Suite narrowing follows [merge-rail § Rules](../architecture/merge-rail.md#rules) (Jarvis decision 1793670033, [KEN-4788](https://linear.app/vanillagreen/issue/KEN-4788)). Keep matching patch proof, integrated-tree checks, standard runners, bounds and warnings.

**Applies to**: [D035](D035-orch-suites-in-ci.md) ended [KEN-4718](https://linear.app/vanillagreen/issue/KEN-4718)'s temporary removal of the orch suite corpus. [KEN-5489](https://linear.app/vanillagreen/issue/KEN-5489) ended the main-only exceptions for critical-path-deny, the tools shell partition and the whole Pi tmux package, and [KEN-5655](https://linear.app/vanillagreen/issue/KEN-5655) ended the Linux adopter suite's. These entries run in the Linux merge-group battery under [KEN-4733](https://linear.app/vanillagreen/issue/KEN-4733)'s restoration design. The cargo-only partition stays required. The same-head merge-group proof and the main remainder cover the selected roster.

**Why**: Repeated portable checks consume the native job deadline before native process and pipe checks finish. Native contracts can differ through the host shell, utilities, filesystem or process behavior. Running unknown suites preserves coverage as the roster changes. The restored entries protect the deny hook, suite ownership, Pi tmux behavior and the adopter's caller and secret placement before merge. The adopter returned without a causal fix. Its main-only job passed 89 straight main runs, so waiting for a failure kept an exception with no end. Every explicit exit in its suite body, and every set -e stop inside a row or setup step that sets ROW, reports that row, its exit code and output, so a later failure there can be read.

**Rejected**: Repeating every Linux suite on macOS, which retains the observed deadline failure. Requiring discovered suites to equal an audit inventory, which blocks native execution when main adds a suite. Independent platform selectors, which can disagree about required native coverage. Longer limits or extra macOS jobs, which the owner excludes.

**Revisit when**: A retained contract still exceeds its unchanged bound, or a portable contract gains native behavior.
