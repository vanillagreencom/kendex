# GitHub platform checks

Read before running the read-only GitHub report, migrating its settings from review-gate, or finding which package renders the review files.

1. Set the report keys in the `[env]` table of [kendex.settings.toml](../kendex.settings.toml.example).
2. Run the report from the repository checkout. It needs GitHub CLI authentication and jq.

```bash
.agents/skills/github-repository-settings/scripts/validate-standard.sh
```

`--help` gives each row, what it reads and the GitHub permission it needs.

The organization's own tooling owns GitHub App installation, the review-secret environment and its secrets. In the vanillagreen organization, fleet performs that work. Refresh adoption retains its environment check.

## Settings

The shared settings reader checks process values, the private env file (`.env.local`, or the file `KENDEX_ENV_FILE` names), `.kendex/settings.toml` and `kendex.settings.toml`, in that order. `REVIEW_GATE_SETTINGS_FILE` selects an explicit TOML file in place of the two project files. `/dev/null` uses process values and defaults alone.

| Setting | Value |
| --- | --- |
| `GITHUB_STANDARD_PLATFORM_CHECKS` | `"true"` enables the report |
| `GITHUB_STANDARD_REVIEW_WORKFLOW_REPOSITORY_ID` | The positive numeric GitHub repository ID, as a string, of the repository that publishes `.github/workflows/request-copilot-review.yml` |
| `GITHUB_STANDARD_CONTEXTS` | Required contexts, separated by semicolons |
| `GITHUB_STANDARD_QUEUE_BYPASS` | Actors the report admits on a queue-only ruleset, as semicolon-separated `TYPE:ID:MODE` entries |
| `GITHUB_STANDARD_CHECKS_BYPASS` | Actors the report admits on a checks-only ruleset, in the same format |
| `GITHUB_STANDARD_LAND_BYPASS` | The landing app, in the same format |

- An absent `GITHUB_STANDARD_PLATFORM_CHECKS`, `"false"` or `""` emits a disabled notice and skips GitHub reads.
- The workflow repository ID is required when the report is enabled.
- Bind each required context in the ruleset to its reporting app.
- An empty bypass list admits no actor.

The organization's own ruleset applies approval, stale-dismissal, thread-resolution, deletion and force-push rules. Each repository owns its required checks and merge queue.

A branch that requires the retired gate context fails the required-contexts row, whatever the contexts setting holds.

## Migration from review-gate

1. Set the opt-in and the workflow repository ID.
2. Update the script path.
3. Rename these keys where configured.

| Previous key | Replacement |
| --- | --- |
| `REVIEW_GATE_STANDARD_CONTEXTS` | `GITHUB_STANDARD_CONTEXTS` |
| `REVIEW_GATE_STANDARD_QUEUE_BYPASS` | `GITHUB_STANDARD_QUEUE_BYPASS` |
| `REVIEW_GATE_STANDARD_CHECKS_BYPASS` | `GITHUB_STANDARD_CHECKS_BYPASS` |
| `REVIEW_GATE_STANDARD_LAND_BYPASS` | `GITHUB_STANDARD_LAND_BYPASS` |

A replacement key in any settings layer takes precedence, including when explicitly empty. The old script path warns and forwards. An explicit call to that path supplies the previous enablement and workflow repository defaults when those settings are absent. Setting the opt-in to `"false"` or `""` also disables the legacy path.

review-gate now requires github-repository-settings, so updating review-gate installs this package. Which package renders the review files then depends on how the project installs this package and on the checkout. The selection rule is kendex's [repository effects principle](https://github.com/vanillagreencom/kendex/blob/main/docs/architecture/repo-effects.md); this table applies it to the two install routes.

| Checkout | Only as review-gate's dependency | Listed by the project, or by a bundle such as workflow |
| --- | --- | --- |
| This clone, bot-instructions set up, this package not set up | bot-instructions renders and checks | Neither renders |
| This clone, this package set up | This package renders | This package renders |
| A fresh clone, nothing set up | Neither renders | Neither renders |
| The consumer refresh run, review files adopted | bot-instructions renders its full output | This package renders |
| The consumer refresh run, no `[bot-instructions]` table and no marked review files | Neither renders | Neither renders |

What each case reports, and what to do:

- This clone, bot-instructions set up, this package not set up:
  - Only as review-gate's dependency: `kendex apply` and `kendex refresh` name this package's setup.
  - Listed: `kendex apply` names this package's setup.
- A fresh clone, nothing set up:
  - Only as review-gate's dependency: `kendex apply` names the bot-instructions setup. Set this package up instead.
  - Listed: `kendex apply` names this package's setup.
- The consumer refresh run, review files adopted:
  - Only as review-gate's dependency: with `GITHUB_STANDARD_BOT_REVIEW = "on"`, bot-instructions' output matches this package's files. With `"off"`, the refresh pull request restores bot-instructions' output.
  - Listed: without a committed `GITHUB_STANDARD_CHECK_LOCATION`, this package's setup refuses and the run stops with `refresh-error=bot-instructions-render`.
- The consumer refresh run, no `[bot-instructions]` table and no marked review files:
  - Only as review-gate's dependency: the run logs `refresh-render=skipped package=bot-instructions cause=unconfigured` and continues.
  - Listed: with a committed `GITHUB_STANDARD_CHECK_LOCATION`, the run logs the same skip and continues. Without it, the run stops with `refresh-error=bot-instructions-render`.

Refresh does not configure review files. To add them to a repository with no `[bot-instructions]` table, follow bot-instructions' [add-repository workflow](../../bot-instructions/workflows/add-repository.md), which writes the table and adopts the existing files, then set this package up.

A setup is recorded only in the clone that ran it. To set this package up:

1. Choose `GITHUB_STANDARD_CHECK_LOCATION`.
2. Use Set up on this package's page, or run the `add` or `apply` that brings review-gate with `--allow-repo-effects`.

Where this package arrives only as review-gate's dependency, a scripted `add --commit` or `apply --commit` without that flag, in a checkout where bot-instructions is set up, commits nothing, names the setup and exits 1.

In a linked worktree, or in a repository where neither package is set up, an `add` can commit before the setup prompt. The setup then rewrites the review files after that commit. Commit those changes after the setup.

The old path and keys remain supported until 2.0. Remove the ignored keys `REVIEW_GATE_STANDARD_APP`, `REVIEW_GATE_STANDARD_ENVIRONMENT` and `REVIEW_GATE_STANDARD_SECRETS` without replacing them.
