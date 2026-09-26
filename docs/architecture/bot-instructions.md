# Bot instructions

Covers: crates/core/src/bot_instructions.rs, crates/core/src/commit_offer/stale.rs, crates/app/src/audit.rs, crates/app/src/commit_offer.rs, crates/cli/src/commands/engine_common.rs, crates/cli/src/commands/commit_offer.rs

The installed bot-instructions package owns the render grammar for a repository's review-bot instruction files. kendex locates that package, runs it after a project apply, and carries the surfaces it reports into the same action's commit offer.

## Boundaries

- A project apply runs the installed renderer after its engine writes, including an empty plan, only where the repository-effect arming record licenses package code. An unarmed install runs no package code and names the setup step. A global apply, or a project without that package, runs no renderer. Enforced by `crates/core/tests/bot_instructions_refresh.rs` and `crates/app/tests/repo_effects.rs`.
- The package decides which bot surfaces are enabled and reports whole-file or Markdown-section ownership; kendex reads that report and judges no part of the grammar. Enforced by `crates/core/tests/bot_instructions_refresh.rs`.
- The package parser supplies the owned section byte bounds for each repository snapshot. The shared commit and restore owner splices with those bounds, so other staged and working-tree bytes in `AGENTS.md` stay unchanged. Enforced by `crates/core/src/commit_offer/tests.rs::committing_a_region_preserves_surrounding_staged_and_working_bytes` and `::restoring_a_region_preserves_surrounding_staged_and_working_bytes`.
- The app and the CLI add that typed output to the commit offer of the same action, never a later one. Enforced by `crates/app/src/commit_offer.rs::tests` and `crates/cli/tests/commit_offer_cli.rs`.
- No surface offers a commit that would carry the package's surfaces out of date. Where the set touches the package's files or surfaces, the offer asks `commit_offer::stale`: an unarmed package, or an armed one whose declared check exits nonzero, holds the commit and is offered its setup instead. Enforced by `crates/core/tests/bot_instructions_refresh.rs::an_unarmed_doctrine_change_never_offers_the_commit_the_staged_check_refuses`, `crates/cli/tests/commit_offer_cli.rs::a_package_whose_check_fails_holds_the_commit` and `crates/app/src/commit_offer.rs::an_offer_lists_the_packages_that_hold_its_commit`.
- The arming record stays per work tree. A linked work tree of a repository whose main checkout armed the package names that main checkout in its skip line, and the CLI offers the setup there in one step. Enforced by `crates/core/src/repo_effects/setup/tests.rs::a_linked_work_tree_names_the_main_checkout_that_set_the_package_up`.
