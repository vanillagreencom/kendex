# The thing kendex writes is the thing it reads

Read before changing project resolution, the worktree guard or in-place packages.

## The approach

Project writes belong to the checkout the caller selected. Resolve the destination before writing, including when a linked worktree's project marker sits above that worktree. An in-place package has no render where its source already stands: kendex manages its harness links, the project-instructions block in `SKILL.md` and the installation record. The remaining source bytes belong to the person.

## Why

A worktree is where a lane works, and a write that lands in the main checkout from a worktree, or the other way round, is a write nobody asked for. An in-place package is the person's own tree; a record that owned it would turn every edit into a stale row, a hold or a take-over of their files.

## Rules

- Do resolve a bare verb's project through `crates/core/src/discover.rs::project_root_from`. A marker inside a worktree makes that folder a project without requiring a manifest. Use an explicit `--project-path` where the verb accepts it. The check report's remedy uses `crates/core/src/drift/report.rs::remedy_target` to resolve the project too.
- Do check parsed writing destinations before bootstrap writes through `crates/cli/src/commands/lane_refresh.rs::check`. Its `writing_scopes` owns which command families write; global scope and read or preview runs pass.
- Do keep the early hook's compatibility check separate from destination resolution. `hooks/block-worktree-refresh.sh` queries only the installed executable on its own PATH against `lane_refresh.rs::CAPABILITY`, which the CLI answers before bootstrap. An absent capability, failed call or unreadable answer refuses with the executable's update route. Catalog refresh and executable update are independent, so refreshed hook content alone cannot prove the CLI has the guard.
- Never execute a proposed command path to check capability. Only one plain bare kendex call may receive the hook's advisory. Other plain writer matches, including compound commands, prefixes and executable paths, retain their refusals without a capability query or execution. Global, read and preview inputs keep their existing classification. Keep quoted titles, messages and heredoc data outside the plain scan; the hook's non-plain compatibility check does not establish execution. The CLI owns actual target resolution.
- Do refuse a project-scope `refresh`, `apply`, `updates --apply` or `update-pi` from a marked lane unless the caller passes `--lane-refresh`. `crates/core/src/lane.rs` reads the marker written by orch's `lane-marker`. Check the inherited `KENDEX_LANE_ORIGIN` too, so changing into main does not hide the invoking lane.
- Do let `--lane-refresh` override both the marked-lane and cross-checkout restrictions for those whole-scope verbs. Other guarded project writers require a caller in the destination checkout.
- Do decide whether a tree is the source once, in `crates/core/src/engine/desired_skill.rs`. A copy delivered elsewhere from an in-place declaration is a render like any other. `crates/core/src/manifest/mod.rs::INPLACE_SOURCE_NAME` declares the source name.
- Never let a record own an in-place source tree. No edit hold, take-over or removal reaches it. `refresh`, `check` and `verify` compare only the links, the block and the entry point.

## The canonical example

`crates/cli/src/commands/lane_refresh.rs::check_project_writes_in` checks the caller and resolved destinations before dispatch writes. A refusal leaves project and first-run records unchanged. Use the same destination owners as dispatch when adding a writing verb.

## Revisit when

A lane starts through a route that does not preserve its launch root.

## Not governed

What a lane may write in its worktree beyond kendex's own verbs: the orch skill. How a render is compared with its source: [engine.md § The generated-file inventory](engine.md#the-generated-file-inventory).
