# D002: A hosted launch hands its wait to a background job after the host accepts the item

[← Decision Index](INDEX.md)

**Date**: 2026-09-24

**Status**: Active

**Research**: KEN-1644

**Decision**: A lane-host provider's `create` may return once it has accepted the item, printing `state=preparing`, and the `wait` verb reports the preparation's outcome. Under a fleet state the launcher opens the window and its lane claim, records the lane `preparing`, and hands `wait` and the rest of the launch to a detached background job, which records `running` or `stopped` with a reason; `oversee-watch` reports from that record. A provider that keeps the synchronous `create` prints no `state` and needs no `wait`.

**Why**: A hosted launch blocked the overseer's own session for the whole provider `create`, about five minutes per lane. Opening the window and the claim before the hand-off lets the next item in a batch pick its account knowing this one is in flight.

**Rejected**: Backgrounding a synchronous `create`: the launcher would record the lane before the provider had judged ownership, so an item another session owns would have its live record overwritten.

**Revisit when**: A provider cannot claim ownership before preparing, or the launcher must return before `create` answers at all.
