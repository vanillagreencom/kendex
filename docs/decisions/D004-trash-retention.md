# D004: Bound the trash by age and size; keep mirrors for the life of the install

[← Decision Index](INDEX.md)

**Date**: 2026-09-25

**Status**: Active

**Research**: —

**Context**: Removal never deletes: every removed or replaced installation moves to `<data>/kendex/trash`, and nothing took entries out again. A host that reinstalls Pi extensions deposits a whole `node_modules` tree per replacement, and the control VM reached 540 MB across 137 entries in eight days with 2.2 GB free. The source cache's snapshots already had a bound (KEN-1629); the bare mirrors under `sources/mirrors` had none and no statement of one.

**Decision**: The trash is bounded by two settings read the way `KENDEX_SOURCE_CACHE_KEEP` is: `KENDEX_TRASH_KEEP_DAYS` (default 30) and `KENDEX_TRASH_KEEP_MB` (default 512). The pass runs at the end of `apply`, `refresh` and `remove`, keeps every entry the invocation itself wrote, measures entries newest first and removes from the one that crosses the size bound without measuring the rest. Mirrors are not bounded: `docs/architecture/sources.md` states that a mirror is kept for the life of the install and that the whole source cache may be removed by hand.

**Rationale**:

- 30 days is longer than the interval at which a person notices a removal they did not want, and the size bound holds the disk cost regardless of how often packages are replaced; 512 MB is under the 540 MB the incident host reached and a sixth of the fleet's 3 GB free-space floor.
- Measuring newest first and stopping at the crossing keeps the per-apply cost to one directory listing plus one walk of the kept entries; a per-entry size record beside each entry would save that walk but adds a second file the trash layout would have to keep consistent with the entry.
- A mirror bound needs the set of repositories every registered and unregistered scope declares, and a removed mirror costs a full clone on the next read; the measured mirror cost (122 MB on the incident host) does not justify that read, so the rule is stated rather than enforced.

**Revisit When**: A mirror directory dominates a host's cache measurement, or a per-apply pass over the trash shows in the apply's own latency budget.

**Verification**: `cargo test -p kendex-core --lib trash::` and `cargo test -p kendex-cli --test integration trash_cli`.

**References**: KEN-1704, KEN-1629.
