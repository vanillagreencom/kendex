---
name: commit-guards
description: "Load to add, tune, or debug a commit guard lane, its git hooks, or COMMIT_GUARDS_* settings."
summary: "Commit guards for bytes, suppressions, conflicts, changelog, markdown and Python names, plus git hook shims."
license: MIT
user-invocable: true
metadata:
  author: vanillagreen
  source: kendex
  repository: "https://github.com/vanillagreencom/kendex"
  bugs: "https://github.com/vanillagreencom/kendex/issues"
tags: [automation]
dependencies:
  optional: [docs-writing]
repo-effects:
  summary: "Arms git pre-commit, commit-msg and pre-push hooks, so every commit in this repository runs the guard chain and every push runs it over the branch, for everyone who commits or pushes here, not only for kendex."
  writes:
    - ".git/hooks/kendex-guards"
    - ".git/hooks/pre-commit"
    - ".git/hooks/commit-msg"
    - ".git/hooks/pre-push"
    - ".git/commit-guards-runs.tsv"
  installer: "scripts/install-git-hooks"
  uninstaller: "scripts/install-git-hooks --uninstall"
  checker: "scripts/install-git-hooks --check"
  removal: "kendex guard uninstall, or any kendex CLI verb that drops the package (remove, an apply or refresh that takes it away, marketplace unsubscribe --remove-packages) runs the uninstaller before the files go; it drops only the helper and one marked line, leaving any hook you wrote. Deleting the package any other way leaves shims that exec scripts which are gone and fail every commit and every push closed. The uninstaller keeps commit-guards-runs.tsv in the common git directory. You can delete that log by hand."
  companions:
    - "doc-limits"
    - "preflight"
    - "bot-instructions"
    - "github-repository-settings"
  notes:
    - "Pre-commit skips a missing companion silently. Preflight is skipped on a first commit. A companion installed with its script missing or not executable is named unrun and blocks nothing, except the selected github-repository-settings owner, which blocks with exit 2. The selected review-file check's `unconfigured` record with its `renders=none` attestation at exit 0 or the older exit 2 is named not adopted and blocks nothing; every other companion or guard failure blocks the commit, a stale review-file render included."
    - "Every hook blocks on a nonzero result; Git's no-verify flag bypasses the commit hooks for one commit and the pre-push hook for one push."
    - "Git runs no hook when it replays a commit, so a rebase or a cherry-pick can carry a violation onto a branch unseen; the pre-push hook is where that branch is judged, and CI where its credential scan is."
    - "Git does not clone hooks; arm every clone once."
---

# Commit Guards

```bash
.agents/skills/commit-guards/scripts/commit-guards all --staged          # commit scope
.agents/skills/commit-guards/scripts/commit-guards all --base origin/main # branch scope
.agents/skills/commit-guards/scripts/commit-guards CHECK --help           # one check's interface
.agents/skills/commit-guards/scripts/md-reflow PATH...                    # paragraph reflow
```

Read [CHECKS.md](CHECKS.md) before adding, tuning or debugging a check. It owns check contracts, scopes and unavailable-tool conditions. `scripts/commit-guards --help` names the batch checks and flags. Exit codes are `0` clean, `1` violations and `2` usage, configuration or collection error; an unmerged scanned path is a collection error.

## Git hooks

Obtain the repository owner's consent before setup runs repository scripts. Arming and disarming affect the whole repository. Disarm before removing the skill.

Before installing, checking or repairing Git hooks, read `scripts/install-git-hooks --help` and [DEVELOPMENT.md § Git hook install contract](https://github.com/vanillagreencom/kendex/blob/main/skills/commit-guards/DEVELOPMENT.md#git-hook-install-contract).

Before changing setup, hook order or the repo-local check, read [hooks and settings](references/hooks-and-settings.md). Before judging a push, read its [Pre-push scope](references/hooks-and-settings.md#pre-push-scope) contract. Refuse a push whose tip is not HEAD, whose index differs from HEAD or whose ref/index evidence cannot be read. The credential scan never runs at push; [CHECKS.md § secrets](CHECKS.md#secrets) owns the remaining CI boundary.

For installer maintenance or ref/scope collection mechanics, read [DEVELOPMENT.md](https://github.com/vanillagreencom/kendex/blob/main/skills/commit-guards/DEVELOPMENT.md).

## Configuration

Before resolving a setting, writing a settings file, exclusions or a baseline, or enabling release collation, read [hooks and settings](references/hooks-and-settings.md#settings-resolution). That reference owns settings resolution, grammar and exclusion/baseline formats. Use [kendex.settings.toml.example](kendex.settings.toml.example) for project declarations and the matching [CHECKS.md](CHECKS.md) section for check-specific semantics. Each check's script owns its defaults.

The settings template also declares `COMMAND_SAFETY_HISTORY_POLICY` for the command-safety hook. Select its native Git history fence only with Git 2.45.1 or later, the floor kendex's command-safety reference derives under Git history policy.

## Generated-file exclusions

Before changing render exclusions or handling an unread inventory, read [Generated-file exclusions](references/hooks-and-settings.md#generated-file-exclusions). Keep inventory repair with the refresh owner and non-render exceptions in the reasoned excludes list.
