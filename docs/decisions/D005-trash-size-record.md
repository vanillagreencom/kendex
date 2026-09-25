# D005: Measure a trash entry once; keep the sizes in one record inside the trash

[← Decision Index](INDEX.md)

**Date**: 2026-09-25

**Status**: Active

**Research**: —

**Refines**: [D004](D004-trash-retention.md)

**Context**: D004's pass measured every kept entry on every `apply`, `refresh`, `remove` and `update-pi`, one `lstat` per file, and declined a size record beside each entry as a second file the layout would have to keep consistent. The perf QA on KEN-1704 met D004's revisit condition: a no-op release `kendex apply -y` went from 0.176 s to 0.309 s on a 137-entry, 42,675-file trash and from 0.178 s to 0.635 s on a 200,000-file one, linear in the kept file count. The `pi-agents-tmux` frontmatter editor runs `kendex refresh` synchronously, so that time blocks its event loop.

**Decision**: An entry is measured once in its lifetime. The pass records each measured entry's bytes by name in one file inside the trash, `sizes.json` (`trash::SIZES_FILE`), reads it back on every later pass, drops a name the listing no longer holds on the next write, drops an entry's row before its removal is tried, and writes nothing when it learned nothing. A record that will not read, parse or write stops the pass like a trash that will not read. `kendex trash list` still measures fresh: it is the person's own request for the number on disk.

**Rationale**:

- Nothing writes into an entry after it lands, so a size measured once holds until the entry goes. The consistency D004 declined reduces to one rule: a row lives exactly as long as its entry, and the listing enforces it on every write.
- One file, not one beside each entry: a sidecar per entry doubles the directory listing every pass reads, and the record's name opens with no stamp, so the listing and `kendex trash` skip it under the rule they already have.
- A size in the entry's name needs the walk before the move and changes a name people read in `kendex trash list` and restore by hand.
- A record that will not parse stops the pass, at the cost of a warning per pass until the file is removed; every input the pass cannot read stops it, which keeps invariant 2 of `docs/architecture/trash.md` one rule.

**Revisit When**: A pass's cost is dominated by the directory listing rather than measurement, or an entry gains a writer after it lands.

**Verification**: `cargo test -p kendex-core --lib trash::` (`an_entry_is_measured_once_in_its_lifetime`, `the_record_holds_only_the_entries_the_trash_holds`, `a_crossing_entry_whose_removal_fails_keeps_no_row`, `a_record_that_will_not_read_or_parse_stops_the_pass_with_everything_intact`, `a_record_that_will_not_write_stops_the_pass_after_its_decisions`), and the release timing in the KEN-1803 pull request body.

**References**: KEN-1803, KEN-1704, [D004](D004-trash-retention.md).
