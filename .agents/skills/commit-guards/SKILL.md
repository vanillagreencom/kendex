---
name: commit-guards
description: "Load to add, tune, or debug a commit guard lane, its git hooks, or COMMIT_GUARDS_* settings."
summary: "Commit guards for markers, bytes, suppressions, conflicts, changelog, prose, markdown, Python names and commit messages, plus an optional comment audit and git hook shims."
license: MIT
user-invocable: true
metadata:
  author: vanillagreen
  source: kendex
  repository: "https://github.com/vanillagreencom/kendex"
  bugs: "https://github.com/vanillagreencom/kendex/issues"
  version: "1.0.0"
tags: [automation]
repo-effects:
  summary: "Arms git pre-commit, commit-msg and pre-push hooks, so every commit in this repository runs the guard chain and every push runs it over the branch, for everyone who commits or pushes here, not only for kendex."
  writes:
    - ".git/hooks/kendex-guards"
    - ".git/hooks/pre-commit"
    - ".git/hooks/commit-msg"
    - ".git/hooks/pre-push"
  installer: "scripts/install-git-hooks"
  uninstaller: "scripts/install-git-hooks --uninstall"
  checker: "scripts/install-git-hooks --check"
  removal: "kendex guard uninstall, or any kendex CLI verb that drops the package (remove, an apply or refresh that takes it away, marketplace unsubscribe --remove-packages) runs the uninstaller before the files go; it drops only the helper and one marked line, leaving any hook you wrote. Deleting the package any other way leaves shims that exec scripts which are gone and fail every commit and every push closed"
  companions:
    - "doc-limits"
    - "preflight"
    - "bot-instructions"
  notes:
    - "A missing companion is announced and skipped, as is preflight on a first commit; every other companion or guard failure blocks the commit, a bot-instructions check that finds a stale render included."
    - "Every hook blocks on a nonzero result; Git's no-verify flag bypasses the commit hooks for one commit and the pre-push hook for one push."
    - "Git runs no hook when it replays a commit, so a rebase or a cherry-pick can carry a violation onto a branch unseen; the pre-push hook is where that branch is judged, and CI where its credential scan is."
    - "Git does not clone hooks; arm every clone once."
---

<!-- kendex:project-instructions:start -->
## Project Instructions

<!-- kendex:shared-instructions:start -->
Problems with a kendex-owned skill go through `kendex report`; check ownership in the file first.
<!-- kendex:shared-instructions:end -->
<!-- kendex:project-instructions:end -->

# Commit Guards

```bash
.agents/skills/commit-guards/scripts/commit-guards                   # batch: every enabled check over the whole tree
.agents/skills/commit-guards/scripts/commit-guards all --staged      # the same batch at commit scope
.agents/skills/commit-guards/scripts/commit-guards all --base origin/main # the same batch over a branch's changes (CI)
.agents/skills/commit-guards/scripts/commit-guards todo-ban     # one check by name, flags pass through
.agents/skills/commit-guards/scripts/md-reflow PATH...          # rewrite markdown to the format md-format judges
.agents/skills/commit-guards/scripts/install-git-hooks          # arm the git pre-commit/commit-msg/pre-push shims
.agents/skills/commit-guards/scripts/install-git-hooks --check  # read-only: are the shims still armed?
```

## The checks

| Check | Verdict |
|---|---|
| **todo-ban** | Any work marker (TODO, FIXME, HACK, XXX in comment-marker shapes) in a tracked, non-excluded file fails. No baseline. |
| **byte-ceiling** | A new tracked file over the configured ceiling fails; an existing oversized file may hold or shrink but may not grow; Markdown files and lockfiles are exempt. |
| **suppression-ban** | Blanket lint suppressions fail; reasonless Rust dead or unused allows may only tighten against the baseline. |
| **conflict-markers** | An unresolved merge-conflict marker in a tracked, non-excluded file fails. |
| **changelog-entries** | Each `COMMIT_GUARDS_CHANGELOG_PATHS` fragment is one Markdown list item in a Keep a Changelog section. |
| **prose** | A history reference in Markdown named by `COMMIT_GUARDS_PROSE_PATHS` fails; `COMMIT_GUARDS_CHECKS` controls whether the lane runs. |
| **md-format** | A hard-wrapped paragraph or list item, a missing blank line around a heading, fence or list, or a trailing-double-space break in Markdown named by `COMMIT_GUARDS_MD_PATHS` fails; `md-reflow` is the remedy. |
| **md-refs** | Dead references in consumer-authored citing files fail; lock-listed citing files warn unless `--strict` is set. Skipped sources are one count per reason on the summary line, with a path named only where a judged reference lands on it. `COMMIT_GUARDS_MD_REFS_PATHS` selects documents; `COMMIT_GUARDS_MD_REFS_SOURCE_PATHS` selects source comments and TOML strings for `§` citations. The supported forms are in [CHECKS.md § md-refs](CHECKS.md#md-refs). |
| **py-names** | An undefined name or a syntax error in a Python file fails, judged by ruff or, where ruff is absent, pyflakes; neither installed while a Python file is selected is exit 2. See [CHECKS.md § py-names](CHECKS.md#py-names). |
| **secrets** | A credential gitleaks' default rules match fails, named by path, line and rule id and never by value. Under a diff scope only a match on an added line counts, and a range judges each of its commits. It never runs at push. When a missing or too-old gitleaks passes at a `gap` notice and when it refuses: [CHECKS.md § secrets](CHECKS.md#secrets). |
| **comments** | A history reference in the comment text of a source file named by `COMMIT_GUARDS_COMMENT_PATHS` fails: an issue id (`GH_ISSUE_PATTERN`), `#NNN`, or a date. Optional audit; see [CHECKS.md § comments](CHECKS.md#comments). |
| **commit-msg** | The header must be `type(scope)!: subject` within `COMMIT_GUARDS_SUBJECT_MAX`; a commit touching `COMMIT_GUARDS_CHANGELOG_REQUIRED_PATHS` also owes a changelog entry or `[no-changelog]`. |

Full check shapes and scopes: [CHECKS.md](CHECKS.md).

Exit codes: `0` clean, `1` violations, `2` usage, configuration, or collection error. An unmerged entry in a scanned path is a collection error.

## Git hooks

Run `scripts/install-git-hooks [--repo PATH]` to arm the shims.

A pulled render does not re-arm the helper; `scripts/install-git-hooks --check` names an outdated helper and the installer to run from the main checkout.

Pre-commit order: `doc-limits --staged` when installed -> `preflight --staged` when installed -> `bot-instructions check --staged` when installed -> `commit-guards all --staged` -> `COMMIT_GUARDS_PRE_COMMIT_LOCAL` when configured. `commit-msg` runs the message gate.

A repo-local entry names the paths it reads in `COMMIT_GUARDS_PRE_COMMIT_LOCAL_PATHS`. The chain runs it only when the commit touches one of those paths, a deletion or either side of a rename included, and otherwise prints `pre-commit: local-entry=skipped` and leaves the verdict to the other lanes. The chain reads the entry's exit as it reads every lane's: `0` clean, `1` violations, anything else a step that did not complete. It prints no install command of its own. An entry that needs a missing tool should print that tool's install command and exit `2`; with the paths set, that refusal blocks only a commit that touches them.

`pre-push` runs doc-limits over the pushed tree and then the batch over what each pushed branch would do to the remote, so a state a replay carried in — a rebase, a cherry-pick, an autosquash, none of which run a commit hook — is judged before the branch leaves the machine by every lane but `secrets`. What a ref line deposits decides whether it is judged, so `git push origin HEAD` is judged like any other branch push; a deletion and a line landing on a tag or a note are skipped, and a line the lane cannot read is refused. Two refusals keep the verdict about the thing being pushed, since every range scope there ends at HEAD, every scan not handed a range reads the index, and every lane reads its tracked policy from the index: a branch whose tip is not HEAD, and an index holding content HEAD does not. Neither consults untracked files or unstaged edits.

The batch runs the enabled checks less the ones this scope leaves nothing for. A check this run hands no scope, whose configured scope then selects from the staged diff, opens no file at push — nothing is staged, which the refusal above makes certain — so it is withheld and named rather than counted clean. Where a range can be established the markdown lanes are handed it under their default `touched` scope, and judge what the branch changed, so a malformed document or a broken reference that a replay carried in **is** caught. Where none can be, the whole tree is the scope and those lanes are withheld: that sweep is absolute rather than ratcheted, so imposing it would refuse every push in a repository holding markdown that predates the guard, and choosing it is `COMMIT_GUARDS_MD_SCOPE=all`, the project's call. A project that has chosen it keeps it under every scope — a range is narrower than that sweep, so the batch hands such a lane `--all` rather than the range, and a document the range never touched still fails. Which lanes read that setting at all is taken off their own scripts rather than listed, and what it resolves to is asked of the setting's owner. `secrets` is withheld at every push, for the reason [CHECKS.md § secrets](CHECKS.md#secrets) gives.

What the scope rests on: the remote oid git puts on a ref line is read from the destination itself, and it is the only destination-bound evidence a pre-push hook gets. Where it is there, the batch is asked what landing HEAD at that oid would **do** to it (`--against`, two dots) rather than what the branch adds over the ancestor the two share — on a force-pushed branch those differ, and only the first is what the destination receives. Where the oid is absent — every branch's first push — the scope is a best-effort local one taken from this repository's refs for the remote, which record a past fetch. After a `git remote set-url` those refs still describe the previous repository, so an oversized file can read there as pre-existing. Where no boundary can be established at all — a push by direct URL, a push URL those refs do not describe, a branch nothing of which has reached the remote — the scope is the whole tree, where an oversized file is held to its row in the byte baseline: a repository carrying a file that was already oversized when it adopted the package, with no row for it, has such a push refused, and a baseline row, the excludes list or the bypass is the way past. Scope details: [DEVELOPMENT.md § The pre-push lane](https://github.com/vanillagreencom/kendex/blob/main/skills/commit-guards/DEVELOPMENT.md#the-pre-push-lane).

Arming and disarming apply to the whole repository. Arm from the main checkout; a linked worktree is judged by its own render of the scripts when it carries one, and by the main checkout's copy when it does not. Disarm before removing the skill. Ownership and layering: [README.md § Git hooks](README.md#git-hooks); install mechanics: [DEVELOPMENT.md § Git hook install contract](https://github.com/vanillagreencom/kendex/blob/main/skills/commit-guards/DEVELOPMENT.md#git-hook-install-contract).

## Configuration

Exclude immutable first-party sources, including applied SQL migrations, from the comments and prose lanes through their shared excludes lists. Keep preflight’s `applied-migration-edited` lane enabled as the authority on migration bytes. Set `PREFLIGHT_MIGRATION_GLOBS` for excluded migration paths outside that lane’s defaults.

| Key | Default | Meaning |
|---|---|---|
| `COMMIT_GUARDS_CHECKS` | `todo-ban byte-ceiling suppression-ban conflict-markers changelog-entries prose md-format md-refs py-names secrets` | Batch check list (`commit-msg` never batches). Under `--skip-unscoped` a caller that stages nothing withholds the checks it hands no scope whose configured scope reads only the staged diff, and `secrets`. |
| `COMMIT_GUARDS_TODO_EXCLUDES` | `tools/todo-ban-excludes` | todo-ban exclusion list. |
| `COMMIT_GUARDS_BYTE_CEILING_KB` | `200` | Byte ceiling in KB. |
| `COMMIT_GUARDS_BYTE_WARN_PCT` | `90` | Percent of the byte ceiling at which byte-ceiling prints a `near-ceiling` notice, 1-100; the exit status is unchanged. |
| `COMMIT_GUARDS_BYTE_EXCLUDES` | `tools/byte-ceiling-excludes` | byte-ceiling exclusion list (declared asset trees). |
| `COMMIT_GUARDS_BYTE_BASELINE` | `tools/byte-ceiling-baseline` | byte-ceiling `--all` baseline: the object size each legacy oversized file is held to. |
| `COMMIT_GUARDS_SUPPRESSION_EXCLUDES` | `tools/suppression-ban-excludes` | suppression-ban exclusion list. |
| `COMMIT_GUARDS_SUPPRESSION_BASELINE` | `tools/suppression-baseline.tsv` | Bare-allow ratchet baseline. |
| `COMMIT_GUARDS_CONFLICT_EXCLUDES` | `tools/conflict-markers-excludes` | conflict-markers exclusion list. |
| `COMMIT_GUARDS_SECRETS_EXCLUDES` | `tools/secrets-excludes` | secrets exclusion list, the lane's only allowlist. |
| `COMMIT_GUARDS_CHANGELOG_PATHS` | `changelog.d/*/*.md` | Space-separated globs naming the changelog fragments, matched against the full repo-relative path (`*` crosses `/`). |
| `COMMIT_GUARDS_CHANGELOG_RECORD` | `CHANGELOG.md` | The collation destination; empty disables collation. |
| `COMMIT_GUARDS_CHANGELOG_VERSION_PATHS` | *(empty)* | JSON version-file globs for the [version-bump check](CHECKS.md#version-bumps); empty disables it. |
| `COMMIT_GUARDS_CHANGELOG_REQUIRED_PATHS` | *(empty)* | Globs whose change obliges a changelog entry, judged by `commit-msg`; empty switches the rule off. |
| `COMMIT_GUARDS_PROSE_PATHS` | `SKILL.md */SKILL.md AGENTS.md */AGENTS.md CLAUDE.md */CLAUDE.md workflows/*.md */workflows/*.md agents/*.md */agents/*.md docs/architecture/*.md` | Space-separated globs naming the markdown the prose lane scans, matched against the full repo-relative path (`*` crosses `/`). |
| `COMMIT_GUARDS_MD_PATHS` | `*.md` | Globs naming the markdown md-format and md-reflow take under `--all`. |
| `COMMIT_GUARDS_MD_REFS_PATHS` | `PATHS_DEFAULT` in `scripts/md-refs` | Globs naming the Markdown documents md-refs judges. |
| `COMMIT_GUARDS_MD_REFS_SOURCE_PATHS` | the `COMMIT_GUARDS_COMMENT_PATHS` default | Globs naming the source files md-refs reads for `§` citations in comment text. |
| `COMMIT_GUARDS_MD_EXCLUDES` | `tools/md-excludes` | Exclusion list both markdown lanes honour in every scope, and md-reflow under `--staged` and `--all`. |
| `COMMIT_GUARDS_MD_SCOPE` | `touched` | With no scope flag, `touched` runs md-format on staged files and md-refs on all configured documents when anything is staged; `all` checks every matching file. Under `touched` the batch may hand these lanes a commit range instead (`--base REF`, `--against REF`); under `all` it hands them `--all`, since a range is narrower than the sweep that setting asks for. |
| `DECISIONS_DIR`, `DECISION_ID_PREFIX`, `DECISION_ID_WIDTH` | `docs/decisions`, `D`, `3` | The decider skill's scheme, read by md-refs to judge decision IDs; IDs are not judged where the directory is not tracked. |
| `COMMIT_GUARDS_COMMENT_PATHS` | the extensions in [CHECKS.md § comments](CHECKS.md#comments) | Space-separated globs naming the source files the comments lane scans, matched against the full repo-relative path (`*` crosses `/`); replaces the default. |
| `COMMIT_GUARDS_COMMENT_EXCLUDES` | `tools/comments-excludes` | comments exclusion list (generated, vendored, and immutable first-party files). `GH_ISSUE_PATTERN` (the github skill's key) declares the tracker ID shape; empty leaves ID checks inactive. |
| `COMMIT_GUARDS_COMMENT_REFERENCE_TYPES` | `issue-id issue-number date` | Reference classes the comments lane checks; name at least one type. |
| `COMMIT_GUARDS_COMMIT_TYPES` | `build chore ci docs feat fix perf refactor revert style test` | Accepted commit types. |
| `COMMIT_GUARDS_SUBJECT_MAX` | `72` | Characters allowed in a hand-written commit header. |
| `COMMIT_GUARDS_PRE_COMMIT_LOCAL` | *(empty)* | Repo-root-relative executable the pre-commit shim runs last. |
| `COMMIT_GUARDS_PRE_COMMIT_LOCAL_PATHS` | *(empty)* | Space-separated globs naming the paths the repo-local entry reads, matched against the full repo-relative path (`*` crosses `/`). The entry runs only for a commit that touches a matching path; empty runs it on every commit. |
| `COMMAND_SAFETY_DENY_PATTERN` | a `systemd-run` memory cap in K or M | Command text the `command-safety` hook refuses, a POSIX extended regular expression the hook reads through this skill's loader where the `command-safety` bundle installs it; the hook applies the default with no setting, and `^$` turns matching off. |

Settings follow [README.md § Setup](README.md#setup). `COMMIT_GUARDS_SETTINGS_FILE=/dev/null` skips file sources; `COMMIT_GUARDS_CHANGELOG_COLLATE=1` is environment-only, authorizes `--collate` on a clean index and working tree, and lets `commit-msg` count a record change as the release changelog entry.

**Excludes format.** `pattern<TAB>reason` per line (shell glob against the full repo-relative path; `*` crosses `/`); a pattern without a reason is a config error. A pattern opening with `!` carves its matches back into the scanned set, and wins over every exclusion row whatever the order. To exclude a path that literally begins with `!`, escape it: `\!foo`. **Baseline format.** `path<TAB>N`, `LC_ALL=C` sorted, unique paths, N a positive integer: a count for suppression-ban, an object size in bytes for byte-ceiling. Initial suppression baseline: [CHECKS.md § suppression-ban](CHECKS.md#suppression-ban). Hook install and removal details: [DEVELOPMENT.md](https://github.com/vanillagreencom/kendex/blob/main/skills/commit-guards/DEVELOPMENT.md).

## Generated-file exclusions

Suppression-ban and py-names exclude the exact files the render writer lists in `.kendex-generated.json`. Adopted in-place skills and hooks remain governed because the writer leaves their source out of the inventory. Keep the inventory with the renders; adoption needs no manual ownership carve.

The inventory uses the exclusion list’s index-first read contract. An absent inventory is an empty one: nothing is excluded and every tracked file stays scanned, which is what a project whose items are all in-place, or one installed below the Git root, carries. An inventory the lane cannot read from the commit fails with exit `2` as `inventory-read=<status>`. A malformed one fails with exit `2` as `inventory-status=<status>`: `20` or `21` from the filter, jq's own status, or `127` when no jq is on `PATH`. The lines under it name the status word (`documents`, `entry-shape`, `jq-error`, or `jq-missing`), the jq that read the file, and the cause. For `entry-shape` the cause is the document's type when it is not an array, or else the index and the first 120 characters of the first rejected entry. The fix line names the remedy. For a malformed inventory, run `kendex refresh` at the Git repository root in the main checkout and stage the inventory with the renders. For `jq-missing`, install jq. For `jq-error`, the fix line names both remedies, the refresh and jq 1.7 or newer, because jq's status does not say which one applies. jq 1.6 finds a NUL in every string and changes the filter's `20` and `21` statuses under `-e`, so it refuses every inventory as `jq-error`. Explicit `!` rows still restore matching paths to the scan. Keep non-render exceptions in the reasoned exclusion list.
