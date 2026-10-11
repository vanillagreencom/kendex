# D025: Remove repeated watch work in its owners

[← Decision Index](INDEX.md)

**Date**: 2026-10-11

**Status**: Active

**Research**: [KEN-3790](https://linear.app/vanillagreen/issue/KEN-3790), [stage review and calibration](https://linear.app/vanillagreen/issue/KEN-3790#comment-4e889f24-eb4b-420b-a427-61066be83f79).

**Decision**: Remove repeated issue reads and record processing before changing watch intervals or lane limits. [KEN-2708](https://linear.app/vanillagreen/issue/KEN-2708) narrows issue discovery and bulk triage membership. [KEN-3792](https://linear.app/vanillagreen/issue/KEN-3792) batches verification records. [KEN-3793](https://linear.app/vanillagreen/issue/KEN-3793) retires mail rows through the existing successful terminal close and archive owner. Keep unresolved triage work and resumable mail cursors. Bind mail retirement to the closed lane generation. A done status or missing fleet record alone is insufficient. Keep current head, blocker, deadline and authentication checks. Reuse evidence only for equal lookup identities within the pass. Mail file replies do not replace process-status proof. Fleet owns provider work in [FLT-1167](https://linear.app/vanillagreen/issue/FLT-1167) and tmux server work in [FLT-1168](https://linear.app/vanillagreen/issue/FLT-1168). [KEN-3317](https://linear.app/vanillagreen/issue/KEN-3317) owns the combined host load reading.

**Why**: The measured fleets differ in issue workload and completed passes. Verification and triage explain measured long-pass differences. Historical mail rows make current row walks costly. The mail calibration has different heads and conditions from the live stage window. Its bound does not prove a live saving. The existing owners can remove repeated work without delaying every long-pass check. Their saving bounds do not prove the future host load.

**Rejected**: A wider interval or lane cap as the initial repair. Both change supervision or throughput before removing repeated source work. A new cache or index adds an owner before proven retired work is removed. A running-lane whitelist loses retained cursors. Fewer pane captures cannot receive tmux server saving without a measured cause.

**Revisit when**: The filed watch builds ship and KEN-3317 still fails its live load condition. Use new stage readings and the Fleet provider and tmux results before changing cadence or lane admission.
