# Bot instructions

Covers: crates/core/src/bot_instructions.rs, crates/app/src/audit.rs, crates/app/src/commit_offer.rs, crates/cli/src/commands/engine_common.rs

The installed bot-instructions package owns the render grammar for a repository's review-bot instruction files. kendex locates that package, runs it after a project apply, and carries the surfaces it reports into the same action's commit offer.

## Boundaries

- A project apply runs the installed renderer after its engine writes, including an empty plan, only where the repository-effect arming record licenses package code. An unarmed install runs no package code and names the setup step. A global apply, or a project without that package, runs no renderer. Enforced by `crates/core/tests/bot_instructions_refresh.rs` and `crates/app/tests/repo_effects.rs`.
- The package decides which bot surfaces are enabled and reports whole-file or Markdown-section ownership; kendex reads that report and judges no part of the grammar. Enforced by `crates/core/tests/bot_instructions_refresh.rs`.
- The package parser supplies the owned section byte bounds for each repository snapshot. The shared commit and restore owner splices with those bounds, so other staged and working-tree bytes in `AGENTS.md` stay unchanged. Enforced by `crates/core/src/commit_offer/tests.rs::committing_a_region_preserves_surrounding_staged_and_working_bytes` and `::restoring_a_region_preserves_surrounding_staged_and_working_bytes`.
- The app and the CLI add that typed output to the commit offer of the same action, never a later one. Enforced by `crates/app/src/commit_offer.rs::tests` and `crates/cli/tests/commit_offer_cli.rs`.
