# Hooks and settings

Read before judging a push, changing hook setup or order, resolving settings, writing exclusions or baselines, handling a generated-file inventory failure, or writing the repo-local pre-commit check. The person's install and consent steps: [README.md § Setup](../README.md#setup). Check contracts: [CHECKS.md](../CHECKS.md). Maintainer mechanics: [DEVELOPMENT.md](https://github.com/vanillagreencom/kendex/blob/main/skills/commit-guards/DEVELOPMENT.md).

## Hook layering

The Git hooks run the committed skill scripts: `pre-commit` and `commit-msg` per commit, `pre-push` per branch. The harness pre-commit hook allows commits when these Git hooks are absent and reports the setup route. Git checks run only after setup is armed.

Consent and repository-wide setup/removal boundaries: [SKILL.md § Git hooks](../SKILL.md#git-hooks). For installation, status checks, re-arming and script selection across checkouts, read `scripts/install-git-hooks --help` and [DEVELOPMENT.md § Git hook install contract](https://github.com/vanillagreencom/kendex/blob/main/skills/commit-guards/DEVELOPMENT.md#git-hook-install-contract).

## Commit chain

Read when changing the hook order or diagnosing a commit that did not run a lane. `scripts/pre-commit` owns this order:

1. `doc-limits --staged`, when installed.
2. `preflight --staged`, when installed; a first commit skips it.
3. `github-repository-settings check --staged` when that package resolves, otherwise `bot-instructions check --staged` when installed. A failing or unrunnable selected owner never falls back. An attested `unconfigured` result with `renders=none` at exit `0` or the older exit `2` means not adopted and blocks nothing.
4. `commit-guards all --staged`.
5. The configured [repo-local check](#repo-local-check).

A missing companion is skipped silently. A present companion or batch whose script is missing or not executable is named unrun and blocks nothing, except the selected github-repository-settings owner, which blocks with exit `2`. Other failures block the commit. `commit-msg` runs the message gate. The hook folds lane exits as `0` clean, `1` violations, anything else a step that did not complete. Every nonzero hook result blocks. Git's `--no-verify` bypasses the commit hooks for one commit or the pre-push hook for one push.

## Pre-push scope

Read before judging a push. `scripts/pre-push` runs doc-limits over the pushed tree, then the enabled batch checks over each distinct push scope. Git replay runs no commit hook, so CI must also judge commits produced by rebase or cherry-pick. The credential scan never runs at push; its remaining CI boundary is [CHECKS.md § secrets](../CHECKS.md#secrets).

- Deletions and destinations under `refs/tags/` or `refs/notes/` are skipped. Other destinations are judged even when the left side is `HEAD`, `@` or a commit ID. An unreadable ref line is refused.
- The pushed tip must be HEAD, and the index must hold HEAD's content. A different tip, an index read failure or staged differences refuse the push. Untracked files and unstaged edits do not change this judgment. Tracked policy is read from the index; local settings sources remain local overrides.
- With a usable destination commit, tree checks judge what HEAD changes in that destination. Changelog and Markdown shape checks instead exclude changes already on the remote's default branch where that boundary can be established; otherwise they use the remote head.
- Without a usable destination commit, the boundary is the tracking-ref commit the branch reaches that descends from every other one it reaches. Where `git merge-base --independent` leaves more than one of those commits, no one of them descends from all the others, and the boundary is HEAD's merge base with the remote's default branch. Without a usable default branch, the boundary is those commits' common ancestor from `git merge-base --octopus`. That range can include commits already published on them, so a refusal can name another branch's change. The push then prints a `base-shared=<ref>:<base>:<cause>` line, and the cause says why the default branch did not decide. Every such boundary is best-effort evidence, not proof of the destination's state. After a remote URL change, those refs can still describe the old repository and let byte-ceiling treat an oversized binary as pre-existing.
- Where the tracking refs yield no range base, the batch judges the whole tree. The push prints a `base-none=<ref>:<cause>` line, and the cause says why no base was established. An enabled byte-ceiling check then holds an oversized binary to its baseline row; no row fails. A baseline row, a reasoned exclusion or the push bypass is the available route.
- A check given no usable scope is named withheld, never counted clean. Under `COMMIT_GUARDS_MD_SCOPE=touched`, a range reaches the Markdown checks; with no range they are withheld. Under `all`, md-refs keeps its whole-tree sweep even when a range exists. md-type takes a range under either setting and is withheld when none exists.

Collection failures remain errors. The verdict is `2` when any scope could not be judged, otherwise `1` when any scope found violations, otherwise `0`. Ref selection, boundary collection and scope dispatch mechanics: [DEVELOPMENT.md § The pre-push lane](https://github.com/vanillagreencom/kendex/blob/main/skills/commit-guards/DEVELOPMENT.md#the-pre-push-lane).

## Settings resolution

Each key resolves environment > `.env.local` > `.kendex/settings.toml` > committed `kendex.settings.toml` (flat `KEY = "value"` under `[env]`) > default; a `.env` file is never read. Per-check flags (`--excludes`, `--baseline`) override every source; relative paths are repo-root-relative.

`COMMIT_GUARDS_SETTINGS_FILE=/dev/null` skips file sources. The settings template [kendex.settings.toml.example](../kendex.settings.toml.example) declares project settings. Each check's script owns its defaults; `--help` describes its interface. `scripts/commit-guards --help` names the batch checks and scopes. `commit-msg` never batches. A configured retired `md-format` name is dropped with a `retired-check` warning.

For check-specific settings and their meaning, read the matching [CHECKS.md](../CHECKS.md) section. Its [md-refs](../CHECKS.md#md-refs) contract owns document and source path selection, the additive `_EXTRA` lists and extensionless scripts. Its [comments](../CHECKS.md#comments) contract owns source selection and `GH_ISSUE_PATTERN`; an empty issue pattern leaves issue-ID checks inactive. `COMMAND_SAFETY_DENY_PATTERN` configures the command-safety hook through this settings loader where that bundle installs it; its declaration is in the settings template.

Exclude immutable first-party sources, including applied SQL migrations, from comments and prose through their excludes lists. Keep preflight's `applied-migration-edited` lane enabled as the authority on migration bytes. Set `PREFLIGHT_MIGRATION_GLOBS` for excluded migration paths outside that lane's defaults.

`COMMIT_GUARDS_CHANGELOG_COLLATE=1` is environment-only. It authorizes collation on a clean index and working tree and lets commit-msg count the record change as the release entry. The [changelog contract](../CHECKS.md#changelog-entries) owns the remaining conditions.

## Settings file grammar

A settings file is read whole. Each `[env]` value is a single-line basic string with no `"` or `\` inside, or a literal string with no apostrophe inside. Literal strings preserve backslashes and double quotes as text. One value in another shape, or one key assigned twice, fails every read from that file, on any key, because every kendex settings reader refuses the same file. The error for a value in another shape names the file, the line and the key: `settings-string=kendex.settings.toml:3:OTHER`.

## Repo-local check

`COMMIT_GUARDS_PRE_COMMIT_LOCAL` names a repo-root-relative executable the pre-commit hook runs last. `COMMIT_GUARDS_PRE_COMMIT_LOCAL_PATHS` names the paths that check reads, as space-separated globs against the full repo-relative path; `*` crosses `/`. An empty path setting runs it on every commit. Otherwise, the hook runs it only when the commit changes a matching path, including a deletion or either side of a rename. A skip prints `pre-commit: local-entry=skipped`. A missing or non-executable configured entry blocks.

The entry's exits mean `0` clean, `1` violations, anything else a step that did not complete. The hook prints no install command of its own: write the check so that a missing tool prints its install command and exits `2`. With the paths set, that refusal blocks only a commit that changes them.

## Exclusions and baselines

Read when writing a check's excludes list or baseline. Excludes use `pattern<TAB>reason` per line. The shell glob matches the full repo-relative path, with `*` crossing `/`. A pattern without a reason is a configuration error. An opening `!` restores matches to the scan and wins over all exclusion rows regardless of order. Escape a literal opening exclamation mark as `\!foo`.

Baselines use `path<TAB>N`, sorted under `LC_ALL=C`, with unique paths and a positive integer. `N` is a suppression count or a binary object size in bytes. The initial suppression baseline procedure is [CHECKS.md § suppression-ban](../CHECKS.md#suppression-ban). Keep non-render exceptions in the reasoned excludes list.

## Generated-file exclusions

Read when a guard reports an inventory failure or when adding a render exclusion. Suppression-ban, conflict-markers, md-type and py-names exclude exact paths in `.kendex-generated.json`. Judge a render's defect at its source in the author's repository. Keep the inventory with the renders. In-place sources stay scanned because the writer does not list them. An explicit `!` exclusion row still restores a listed path to the scan.

The inventory follows the excludes list's index-first read contract. An absent inventory excludes nothing. An unreadable or unloadable inventory also excludes nothing: the lane reports `inventory-unread=read:<status>` or `inventory-unread=load:<status>` and judges every file. Findings then print `owner-unknown=<count>` and exit `0` locally because ownership is unknown; a nonempty `CI` or `GITHUB_ACTIONS` keeps those findings blocking. The classifier `changelog-entries --classify` still refuses with exit `2`.

The refresh owner repairs a malformed inventory at the Git repository root in the main checkout and stages it with the renders. For `jq-missing`, install jq. For `jq-error`, either the inventory or jq can be at fault: check both and use jq 1.7 or newer. jq 1.6 rejects valid inventories. `scripts/lib/generated-paths.sh` owns the `inventory-status` codes, rejected-entry details and remedy diagnostics; `scripts/lib/configured-paths.sh` owns the unread-inventory verdict. An unread inventory remains unresolved until its owner repairs it.
