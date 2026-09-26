# Generated files and adopted workflows

Covers: crates/core/src/engine/generated_paths.rs, crates/core/src/engine/generated_paths/, crates/core/src/attest.rs, crates/core/src/commit_offer/, crates/cli/src/commands/verify.rs

The inventory records files that verification can compare with declared content. A verification record does not grant permission to overwrite or restore a file.

## Boundaries

- CI reads the committed generated-file inventory from the render plan. In-place sources and Pi carrier payloads stay outside it. Enforced by `crates/core/tests/instruction_shims.rs::generated_inventory_tracks_renders_and_excludes_source` and the harness-ci package tests.
- Apply records rendered paths in the inventory. Package adoption commands also declare workflow copies there, with a template path and SHA-256 hash. The writer and `crates/core/src/engine/generated_paths/own_inventory.rs` use one selected set and document from `GeneratedPaths`: written positions, adoption declarations, and held positions already listed at `HEAD`. Existing held files remain outside the commit offer. Enforced by `crates/cli/tests/refresh_fresh_clone.rs::a_stale_committed_skill_keeps_its_inventory_with_or_without_a_lock` and `crates/core/tests/instruction_shims.rs::refused_outputs_stay_out_of_inventory_and_later_ownership`.
- Adopted workflow equality uses template bytes from declared package artifacts. An edited installed template cannot attest an edited workflow. Refresh records the expected hash but never rewrites or restores the workflow. An invalid inventory retains its bytes so apply cannot erase unreadable adoption declarations. Enforced by `crates/cli/tests/verify_adopted_workflows.rs` under [D003](../decisions/D003-one-merge-path.md).
