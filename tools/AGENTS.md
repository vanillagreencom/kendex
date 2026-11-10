# tools/

Repository scripts and commit-guard exclusion lists. These run in the commit chain and CI, not on a consumer's machine. Read a script's header before changing or running it.

- A script's suite belongs at `tests/<n>.test.sh`, registered in [skill-tests.yml](../.github/workflows/skill-tests.yml). Exceptions: `release-channel-point` runs through [crates/cli/tests/release_workflow/](../crates/cli/tests/release_workflow/); `lock-record` runs through [crates/cli/tests/lock_record.rs](../crates/cli/tests/lock_record.rs).
- `tests/orch-shard-partition.test.sh` must run outside the orch battery it partitions.
- `release-installer-check.ps1` has no local shell suite. The Windows release lane proves its real NSIS install and uninstall, including the PATH edit.
- An exclusion list is `<n>-excludes`, read by the one commit-guards lane its header names. [commit-guards](../skills/commit-guards/SKILL.md) owns the row format and permitted exclusions.
- Add repo-specific rules to `guard`, one lane per rule. Keep rules a shipped package already judges with that package.
- Before changing suite selection, CI coverage or merge requirements, read [merge-rail.md](../docs/architecture/merge-rail.md). Script headers own their selection and output contracts.
- Before changing commit-chain wiring or local validation, read [DEVELOPMENT.md](../DEVELOPMENT.md#the-commit-chain).
- Before changing catalog shell compatibility or source/render rules, read [skills/AGENTS.md](../skills/AGENTS.md).
- Before changing release helpers or publishers, read [DEVELOPMENT.md § Packaging](../DEVELOPMENT.md#packaging) and [§ Release](../DEVELOPMENT.md#release); [updates.md](../docs/architecture/updates.md) governs release feeds.
