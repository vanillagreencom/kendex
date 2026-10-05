# D004: Bound the trash by age and size; keep mirrors for the life of the install

[← Decision Index](INDEX.md)

**Date**: 2026-09-25

**Status**: Active (measurement → D005)

**Research**: KEN-1704

**Decision**: The trash is bounded by `KENDEX_TRASH_KEEP_DAYS` (default 30) and `KENDEX_TRASH_KEEP_MB` (default 512), read the way `KENDEX_SOURCE_CACHE_KEEP` is. The pass runs at the end of a completed `apply`, `refresh`, `remove` or `update-pi`, keeps every entry the invocation itself wrote, measures entries newest first and removes from the one that crosses the size bound without measuring the rest. The source-cache mirrors are not bounded: a mirror is kept for the life of the install and removed by hand, at the cost of any pin the upstream no longer references.

**Why**: Removal never deletes, so a host that reinstalls Pi extensions filled with `node_modules` trees. Thirty days is longer than the interval at which a person notices a removal they did not want, and the size bound holds the disk cost whatever the replacement rate. A mirror bound would need the set of repositories every scope declares and cost a full clone on the next read, for a measured mirror cost that did not justify it.

**Rejected**: A per-entry size record beside each entry: a second file the trash layout would have to keep consistent with the entry; [D005](D005-trash-size-record.md) later settled measurement with one record.

**Revisit when**: A mirror directory dominates a host's cache measurement, or the pass shows in the apply's own latency budget.
