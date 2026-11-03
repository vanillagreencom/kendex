# Removal never deletes

Read before removing or replacing files kendex wrote, or changing the trash or its bounds.

## The approach

Every removed or replaced installation goes through `crates/core/src/trash.rs::move_to_trash`. The person can recover its bytes from `<data>/kendex/trash`. Retention limits the trash by age and size after a completed writing verb, while protecting everything that invocation moved. `kendex trash` provides manual listing and emptying.

## Why

A removal can be a mistake. One trash writer gives every removal the same recovery route. [D004](../decisions/D004-trash-retention.md) governs retention and the unbounded source mirrors. [D005](../decisions/D005-trash-size-record.md) governs measuring entries once.

## Rules

- Do move through `move_to_trash`. Its timestamped name identifies a kendex entry; never list or remove a name without that stamp.
- Do run retention only after a completed `apply`, `refresh`, `remove` or `update-pi`, and the desktop equivalent after its plan is on disk. A plan-only run and every other verb leave the trash alone.
- Do protect every entry the invocation wrote. Count its bytes toward the size bound. Keep the other entries newest first while they meet both bounds; remove the entry that crosses the size bound and everything older. `trash.rs` declares the environment settings, defaults and size-record format.
- Do measure a retained entry once in its lifetime. `kendex trash list` measures fresh because the person asked for a current listing.
- Do stop retention on an invalid bound, unreadable trash or record, or failed measurement, removal or record write. Leave the remaining entries intact and report the stop as a warning. Never turn a retention stop into failure of the completed writing verb.
- Never bound the source-cache mirrors: a mirror is kept for the life of the install and removed by hand.

## The canonical example

`crates/cli/src/commands/engine_common.rs::tidy_trash` reports the result of `crates/core/src/trash.rs::retain` as notices and warnings after the verb's writes. The desktop uses `crates/app/src/trash.rs::tidy` under the same rule.

## Revisit when

A mirror directory dominates a host's cache measurement, or the pass shows in the apply's own latency budget.

## Not governed

What is removed and when: the planner in [engine.md](engine.md) decides that, and the trash only receives it.
