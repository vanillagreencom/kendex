# Hooks and settings

Read when resolving where a setting's value comes from, writing a settings file, judging how the Git hooks and the harness hook layer, or writing the repo-local pre-commit check. Every key, its default and its meaning: [SKILL.md § Configuration](../SKILL.md#configuration). The person's install and consent steps: [README.md § Setup](../README.md#setup).

## Hook layering

The Git hooks run the committed skill scripts: `pre-commit` and `commit-msg` per commit, `pre-push` per branch. The harness pre-commit hook allows commits when these Git hooks are absent. It reports the missing setup with a consent route, or a main-checkout owner route for a linked worktree. Git checks run only after setup is armed.

## Pre-push scope

Read before judging a push's scope or a pre-push refusal. `scripts/pre-push` owns the selection; maintainer mechanics are [DEVELOPMENT.md § The pre-push lane](https://github.com/vanillagreencom/kendex/blob/main/skills/commit-guards/DEVELOPMENT.md#the-pre-push-lane).

Only the current HEAD can be judged. A branch at another commit, an index that differs from HEAD, or an unreadable index comparison refuses the push. Untracked files and unstaged edits do not enter the verdict. A malformed or unreadable ref line refuses; deletions and destinations under the tag or note namespaces are skipped. A branch destination is judged regardless of how its source was spelled.

A destination commit that is available locally gives a range against that destination's tree. The changelog and Markdown-shape checks instead judge what the branch introduced, excluding changes already on the remote's default branch when that boundary can be established. Without that boundary they keep the destination baseline.

When the destination commit is unavailable, a usable local tracking boundary gives a best-effort local range. Tracking refs describe a past fetch, not proven current destination state. They can still name a previous repository after its remote URL changed, so the binary-size check can treat an oversized file as pre-existing. With no usable boundary, the scope is the whole tree. In that scope an enabled binary-size check uses its configured baseline and fails an oversized file with no row. Read failures that prevent collection refuse; missing or unsuitable boundary evidence never invents a narrower range.

The push runs document byte limits over the pushed tree and the enabled batch checks over each applicable scope. A check whose configured scope would open no file is named as withheld, not counted clean. Under `COMMIT_GUARDS_MD_SCOPE=touched`, the Markdown checks use an available range; without one they are withheld. Under `all`, md-refs keeps its whole-tree sweep even when a range is available. md-type still needs a range to judge introduced findings and is withheld without one. An invalid configured Markdown scope refuses when that setting is needed.

The credential scan never runs at push. Its commit and CI coverage, including commits Git replays without a local scan, is [CHECKS.md § secrets](../CHECKS.md#secrets).

Every scope contributes to the result: an incomplete check or collection is exit 2; otherwise any violation is exit 1; otherwise the push is clean. Both nonzero results block the push.

## Settings resolution

Each key resolves environment > `.env.local` > `.kendex/settings.toml` > committed `kendex.settings.toml` (flat `KEY = "value"` under `[env]`) > default; a `.env` file is never read. Per-check flags (`--excludes`, `--baseline`) override every source; relative paths are repo-root-relative.

## Settings file grammar

A settings file is read whole. Each `[env]` value is a single-line basic string with no `"` or `\` inside, or a literal string with no apostrophe inside. Literal strings preserve backslashes and double quotes as text. One value in another shape, or one key assigned twice, fails every read from that file, on any key, because every kendex settings reader refuses the same file. The error for a value in another shape names the file, the line and the key: `settings-string=kendex.settings.toml:3:OTHER`.

## Repo-local check

`COMMIT_GUARDS_PRE_COMMIT_LOCAL` names a project check the pre-commit hook runs last. `COMMIT_GUARDS_PRE_COMMIT_LOCAL_PATHS` names the paths that check reads. The hook runs the check only for a commit that changes one of those paths, and prints `pre-commit: local-entry=skipped` when it skips it. The hook prints no install command of its own: write the check so that a missing tool prints its install command and exits `2`. With the paths set, that refusal blocks only a commit that changes them.
