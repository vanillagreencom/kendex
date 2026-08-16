# CLI module decomposition — proposal

Scope: `cli/src/project_config.rs` (4765 lines, the largest CLI module) and
`cli/src/installer.rs` (3697 lines, third after `config.rs` at 3730). This
is a seam map and a sequenced plan; nothing here is applied. Each step is a
behavior-preserving move with `cargo test` +
`cli/scripts/integration-check.sh` as the safety net, small enough to review
on its own.

Precedent to copy — the split already inside `installer.rs`:

- `installer.rs` declares `mod hooks;` and re-exports the submodule surface
  with `pub(crate) use hooks::{...}`, so callers keep writing
  `crate::installer::install_hook` — the split is caller-invisible.
- `installer/hooks.rs` nests `mod opencode;` and reaches back with a
  targeted `use super::checked_child_path;`, never a glob.
- Tests hoist to `<mod>/tests.rs` (`#[cfg(test)] mod tests;` +
  `use super::*;` at the top of the test file) — the same shape as
  `commands/refresh/tests.rs` and `tui/disk_mutations/tests.rs`.

`main.rs` declares both files as flat `mod x;`, so `x.rs` + `x/` works
without touching it.

## `installer.rs`

Impl 1–1348, tests 1349–3697 (64% of the file). Cluster line counts span
from an item's leading doc comment to the line before the next item's, and
a cluster split across the file sums its chunks (fs/path primitives is two,
divided by the anchoring cluster). The seven partition 1–1348 exactly. No
module-level state; the couplers are two path helpers (`normalize_absolute_path`, 9 internal
callers; `canonicalize_allowing_missing`, 6).

| Cluster | Lines | Members | Inbound (same file) | External callers |
|---|---|---|---|---|
| Hooks facade | 21 | `mod hooks`, re-exports, `codex_hook_safety_block` | remove_item | add, refresh, verify, harness/codex, config |
| Agent install | 37 | `InstallResult`, `install_agent` | none | commands/add |
| `install_skill` | 443 (one fn) | `install_skill` | none | add, refresh, harness/mod, tui/disk_mutations |
| `remove_item` | 367 | `RemoveOutcome`, `remove_item`, `ExpectedArtifact`, `remove_expected_path` | none | commands/remove, tui/disk_mutations |
| Lock bookkeeping | 37 | `record_install` | none | commands/add |
| fs/path primitives | 177 (33 + 144) | `remove_existing`, `normalize_absolute_path`, `canonicalize_allowing_missing`, `relative_path`, `lexical_relative`, `copy_dir` | install_skill, remove_item, anchoring | none (private) |
| Worktree anchoring | 266 | `AnchorEvidence`, `AnchorSharing`, `anchored_canonical_skill_roots`, `child_level_anchored_roots`, `corresponding_project_root_in`, `is_recognized_skills_surface`, `LinkHome`, `same_repo_link_home`, `skill_link_home`, `anchored_link_home` | install_skill, remove_item | config (`prune_broken_skill_symlinks`, `reconcile_lock_with_disk`, `scan_installed_skills_on_disk`) |

### Target layout

| Module | Rationale |
|---|---|
| `installer.rs` (~120 lines) | Orchestration and re-exports only: `install_agent`, `record_install`, `mod` declarations. |
| `installer/tests.rs` | The 2349-line test module, moved verbatim; the three git fixtures (`git_ok`, `init_repo_with_commit`, `write_skill_source`) hoisted to the top. |
| `installer/paths.rs` | Pure `std::fs`/`Path` leaf every other submodule imports; no outbound edges. |
| `installer/anchor.rs` | Worktree/link-home resolution — already has a `pub(crate)` surface `config.rs` consumes; maps 1:1 onto the `hooks` precedent. |
| `installer/skill.rs` | `install_skill`, after its comment-marked phases become named private fns (containment preflight, link-home selection, canonical refresh, dest-is-canonical short circuit, symlink spelling, copy mode). |
| `installer/remove.rs` | `remove_item` + `ExpectedArtifact`, after the same phase extraction (anchored snapshot, marker clearing, per-harness deletion, canonical deletion). |
| `installer/hooks.rs` (exists) | Unchanged. |

### Sequence

1. Hoist tests to `installer/tests.rs`. Pure move, no impl change.
2. Extract `paths.rs` (leaf, all private — `use paths::{...}` in the parent, no re-export).
3. Extract `anchor.rs`; re-export `AnchorEvidence`, `AnchorSharing`,
   `anchored_canonical_skill_roots` from `installer.rs` like `hooks`.
4. Name the phases inside `install_skill`, then move it to `skill.rs`.
5. Same for `remove_item` → `remove.rs`; demote `RemoveOutcome` to
   `pub(crate)` (never named outside the file).

Steps 4–5 are the only ones that touch control flow; each is one PR.

## `project_config.rs`

Impl 1–2961, tests 2963–4765. No module-level state. The couplers are the
TOML text primitives (`toml_multiline_string_content_lines`, 19 callers;
`is_section_header_line`, 14; `toml_inline_string`, 7) and a few repair
helpers used by four clusters (`ensure_value_section_entry_spacing`,
`dedupe_agent_frontmatter_sections`, `ensure_agent_frontmatter_scaffold`,
`section_start`, `same_ignoring_trailing_newline`).

| Cluster | Lines | Members (representative) | Inbound (same file) | External callers |
|---|---|---|---|---|
| Path resolution | 32 | `project_config_path`, `is_source_catalog` | six clusters | refresh, config |
| Data model + `[agent-frontmatter]` parse | 168 | `ProjectConfig`, `CustomHook`, `SHARED_INSTRUCTIONS_*`, `parse_agent_frontmatter_tables` | load, accessors | mapping, config, path_safety, agent |
| Load / strict / source overlay | 60 | `load`, `load_strict`, `load_agent_frontmatter_tables`, `overlay_source_frontmatter` | frontmatter defaults | add, refresh, remove, tui/disk_mutations |
| Read accessors | ~102 | `agent_skills_for`, `color_for`, `frontmatter_for`, `guidance_for`, `instructions_for`, `shared_*`, `skill_instructions_for`, `custom_hooks_for` | save_extracted, frontmatter defaults | resolve, every `harness/*`, agent, add, refresh, tui |
| Shared-instructions merge/mark/strip | 96 | `merge_shared_and_specific`, `mark_shared`, `merge_marked_shared_and_specific`, `strip_shared_block`, `strip_shared_prefix` | accessors, save_extracted | resolve, harness tests, agent tests |
| `save_extracted` write-back | 150 | `save_extracted`, `upsert_agent_value_in_section` | none | add, refresh |
| TOML text primitives | 313 | 18 string/array/inline-table scanners | every writer cluster | none (private) |
| agent-skills / colors writers | 255 | `upsert_agent_frontmatter_field`, `merge_upstream_agent_skills`, `replace_toml_array_value`, `write_agent_skills`, `write_agent_colors` | repair, create | refresh, add — `write_agent_colors` has no callers but its own test |
| Harness frontmatter defaults | 637 | `write_agent_frontmatter_defaults` + 28 per-harness default fns | none | add, refresh |
| Bootstrap / repair / headings / migrations | 792 | `ensure_project_config`, `repair_project_config_*`, header sync, `normalize_attached_section_headers`, `ensure_value_section_entry_spacing`, `dedupe_agent_frontmatter_sections`, `migrate_*`, scaffold + section locators | save_extracted, writers, frontmatter defaults, create | add, refresh (`ensure_project_config` only) |
| Create / update file | 339 | `create_project_config`, `update_project_config`, `insert_keys_into_section`, `insert_entries_into_section`, `strip_skills_reference` | save_extracted, writers, repair | none directly |

### Target layout

| Module | Rationale |
|---|---|
| `project_config.rs` (~300 lines) | `ProjectConfig` + `CustomHook` types, `project_config_path`, `load`/`load_strict`, `parse_agent_frontmatter_tables`, `mod` declarations and re-exports. |
| `project_config/tests.rs` | The 1803-line test module; normalize the seven `super::`-qualified tests and hoist `header_sync_fixture` / `canonical_repair_fixture` to the top. |
| `project_config/toml_text.rs` | Pure string leaf everyone imports; extracting it first unblocks every other move. |
| `project_config/frontmatter_defaults.rs` | The 637-line per-harness defaults engine has one entry point and zero inbound edges — the largest single win. |
| `project_config/instructions.rs` | Accessors + shared-instructions merge/strip + `save_extracted` + the `SHARED_INSTRUCTIONS_*` consts: the extracted-instructions round trip, in a second `impl ProjectConfig` block. |
| `project_config/repair/headings.rs` | Banner/heading sync and section locators (`section_start`/`section_end`, `*_heading` family). |
| `project_config/repair/normalize.rs` | Whitespace/structure normalizers (`ensure_value_section_entry_spacing`, `dedupe_agent_frontmatter_sections`, `repair_instruction_multiline_values`, …) — the shared dependency the writers reach for. |
| `project_config/repair/migrate.rs` | `migrate_section_names`, `migrate_agent_colors_to_frontmatter`, `agent_frontmatter_has_field`. |
| `project_config/writers.rs` | agent-skills/colors writers plus create/update/insert (`create_project_config`, `update_project_config`, `insert_*_into_section`). |

### Sequence

1. Hoist tests to `project_config/tests.rs`.
2. Extract `toml_text.rs` (leaf).
3. Extract `frontmatter_defaults.rs`; re-export `write_agent_frontmatter_defaults`.
4. Extract `instructions.rs`; re-export the consts and keep the accessor
   methods on `ProjectConfig` (second `impl` block).
5. Split repair into `repair/{headings,normalize,migrate}.rs`; the parent
   keeps `ensure_project_config` as the entry point.
6. Extract `writers.rs`; delete or wire `write_agent_colors` (currently
   dead) in the same step.

Steps 1–4 are moves with `use` rewiring only. Step 5 is the one that
needs judgment: `normalize.rs` is imported by four other submodules, so it
goes before `writers.rs`.

## Demotions to make in passing

`RemoveOutcome`, `CustomHook`, `CustomHookTarget`, `merge_shared_and_specific`,
`strip_shared_prefix` are `pub` but never named outside their file →
`pub(crate)` or private.

## Owner decision this depends on

A ground-up rebuild of the CLI is in progress with its own architecture
invariants. Before step 4 and later of either plan, decide whether this
layout informs the rebuild's module map or whether v1 stays the working
system long enough to justify the moves. Steps 1–3 (test hoist, leaf
extraction) are cheap enough to do regardless — they shrink the review
surface for every later change to these files. Size-ratchet adoption
(VST-248, VST-215) holds the line after the seams exist; it does not choose
them.
