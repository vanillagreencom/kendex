# Removal never deletes

Read before removing or replacing files kendex wrote, or changing the trash or its bounds.

## The approach

Every removed or replaced installation moves to the trash under `<data>/kendex/trash`, through one writer, `move_to_trash` in `crates/core/src/trash.rs`, under a name that opens with the moment it moved. A pass at the end of every writing verb brings the trash within two bounds, age and size, and never takes what that verb itself moved. `kendex trash` lists and empties by hand.

## Why

A person who removes a package, or whose package kendex replaced, can get the bytes back without kendex having to be right about what they wanted. A bound is what keeps a host that replaces Pi extensions daily from filling with `node_modules` trees. The bounds and the unbounded mirrors are [D004](../decisions/D004-trash-retention.md); measuring each entry once is [D005](../decisions/D005-trash-size-record.md).

## Rules

- Do move through `move_to_trash`; a second writer is a removal nobody can undo, and a name without the stamp is not kendex's and is neither listed nor removed.
- Do run the pass only at the end of a completed `apply`, `refresh`, `remove` or `update-pi`, and the desktop's equivalent after its plan is on disk; a plan-only run and every other verb leave the trash alone.
- Do keep every entry the invocation wrote, then every entry within `KENDEX_TRASH_KEEP_DAYS` while the running total stays within `KENDEX_TRASH_KEEP_MB`, newest first; the entry that crosses the size bound goes with everything older. The defaults are the constants in `crates/core/src/trash.rs`.
- Do measure an entry once in its lifetime, in `sizes.json` inside the trash; `kendex trash list` measures fresh because it is the person's own request.
- Do fail the pass closed: a bound that is not a count, a trash or record that will not read, or an entry that will not measure or remove stops it with what is left intact, reported as a warning, never as a failure of the verb.
- Never bound the source-cache mirrors: a mirror is kept for the life of the install and removed by hand.

## The canonical example

`crates/core/src/trash.rs`: `move_to_trash` is the writer and `retain` the pass, and `crates/core/src/trash/tests.rs` plants each bound and each failure. A verb that removes something calls the writer and closes on the pass as `tidy_trash` in `crates/cli/src/commands/engine_common.rs` does.

## Revisit when

A mirror directory dominates a host's cache measurement, or the pass shows in the apply's own latency budget.

## Not governed

What is removed and when: the planner in [engine.md](engine.md) decides that, and the trash only receives it.
