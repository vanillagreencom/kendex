# tools/

This repository's own scripts and the exclusion lists its commit guards read. Nothing here is catalog content: these run in this repository's commit chain and in CI, never on a consumer's machine.

- A script's suite belongs at `tests/<n>.test.sh`, where the guards shard of `../.github/workflows/skill-tests.yml` runs it; `release-channel-point` is the one script with none, exercised from [`../crates/cli/tests/release_workflow/`](../crates/cli/tests/release_workflow/) instead.
- An exclusion list is `<n>-excludes`, read by the one commit-guards lane named in its own header; the row format and what may be excluded are [`../skills/commit-guards/SKILL.md`](../skills/commit-guards/SKILL.md).
- `guard` and `setup` are described in the root [`../AGENTS.md`](../AGENTS.md) § Commands; `guard` is where a repo-specific rule is added, one lane per rule.
- `bash32-lint` and `bash32-parse` hold this directory and the shell the catalog ships to Bash 3.2; where each runs is [`../skills/AGENTS.md`](../skills/AGENTS.md).
- `release-digests` and `release-channel-point` belong to the release feed, which [`../docs/architecture/updates.md`](../docs/architecture/updates.md) covers.
- `check-aur-sync` and `publish-aur` are the AUR side of [`../packaging/README.md`](../packaging/README.md) § Publishing: the first holds each `packaging/arch/<name>/` PKGBUILD to its `.SRCINFO` (and, with `--remote`, to the AUR), the second pushes them from `.github/workflows/publish-aur.yml`. `check-aur-sync` is Python, the one script here that is; its suite is beside the others.
- `harness-smoke` answers which harness CLIs are usable on the machine it runs on; it reads installed CLIs and writes nothing to the repository.
