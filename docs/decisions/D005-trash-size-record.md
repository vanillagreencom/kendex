# D005: Measure a trash entry once; keep the sizes in one record inside the trash

[← Decision Index](INDEX.md)

**Date**: 2026-09-25

**Status**: Active

**Research**: KEN-1803

**Refines**: [D004](D004-trash-retention.md), its measurement only

**Decision**: An entry is measured once in its lifetime. The pass records each measured entry's bytes by name in one file inside the trash, `sizes.json`, reads it back on every later pass, drops a row whose entry is gone, drops an entry's row before its removal is tried, and writes nothing when it learned nothing. A record that will not read, parse or write stops the pass like a trash that will not read. `kendex trash list` still measures fresh.

**Why**: D004's pass walked every kept file on every write, and a no-op apply grew linear in the kept file count, which blocked an editor that runs `kendex refresh` synchronously. Nothing writes into an entry after it lands, so a size measured once holds until the entry goes, and one file whose name carries no stamp is skipped by the listing under the rule it already has.

**Rejected**: A sidecar per entry doubles the directory listing every pass reads. A size in the entry's name needs the walk before the move and changes a name people restore by hand.

**Revisit when**: A pass's cost is dominated by the directory listing rather than measurement, or an entry gains a writer after it lands.
