# D005: Measure a trash entry once; keep the sizes in one record inside the trash

[← Decision Index](INDEX.md)

**Date**: 2026-09-25

**Status**: Active

**Research**: KEN-1803

**Refines**: [D004](D004-trash-retention.md), its measurement only

**Decision**: An entry is measured once in its lifetime. The pass records each measured entry's bytes by name in `sizes.json` inside the trash, reads it back on every later pass, drops a row whose entry is gone, and writes nothing when it learned nothing. A record that will not read, parse or write stops the pass like a trash that will not read. `kendex trash list` still measures fresh.

**Why**: The first pass walked every kept file on every write, and a no-op apply grew linear in the kept file count, which blocked an editor that runs `kendex refresh` synchronously. Nothing writes into an entry after it lands, so a size measured once holds until the entry goes.

**Rejected**: A sidecar per entry: it doubles the directory listing every pass reads. A size in the entry's name: it needs the walk before the move and changes a name people restore by hand.

**Revisit when**: A pass's cost is dominated by the directory listing rather than measurement, or an entry gains a writer after it lands.
