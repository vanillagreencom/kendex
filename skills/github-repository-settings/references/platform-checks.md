# GitHub platform checks

Read before running the read-only GitHub report or migrating its settings.

Set the report keys in the `[env]` table of [kendex.settings.toml](../kendex.settings.toml.example), then run the report from the repository checkout. The report needs GitHub CLI authentication and jq. `--help` lists the GitHub permissions by row.

```bash
.agents/skills/github-repository-settings/scripts/validate-standard.sh
```

The report reads the default branch's rules, each ruleset that holds them with its bypass actors, the branch's classic protection, and the latest merge's pull-request and merge-group CI contexts. The bypass-actor read needs Administration write; `--help` gives each row's permission. It writes no GitHub settings. The organization's own tooling owns GitHub App installation, the review-secret environment and its secrets. In the vanillagreen organization, fleet performs that work. Refresh adoption retains its environment check.

## Settings

The shared settings reader checks process values, the private env file (`.env.local`, or the file `KENDEX_ENV_FILE` names), `.kendex/settings.toml` and `kendex.settings.toml`, in that order. `REVIEW_GATE_SETTINGS_FILE` selects an explicit TOML file in place of the two project files. `/dev/null` uses process values and defaults alone.

| Setting | Value |
| --- | --- |
| `GITHUB_STANDARD_PLATFORM_CHECKS` | Set to `"true"` to enable the report. An absent key, `"false"` or `""` emits a disabled notice and skips GitHub reads. |
| `GITHUB_STANDARD_REVIEW_WORKFLOW_REPOSITORY_ID` | The positive numeric GitHub repository ID, as a string, of the repository that publishes `.github/workflows/request-copilot-review.yml`. Required when enabled. |
| `GITHUB_STANDARD_CONTEXTS` | Required contexts separated by semicolons. Bind each context in the ruleset to its reporting app. |
| `GITHUB_STANDARD_QUEUE_BYPASS`, `GITHUB_STANDARD_CHECKS_BYPASS` | Actors the report admits on a queue-only or checks-only ruleset, as semicolon-separated `TYPE:ID:MODE` entries. An empty list admits none. |
| `GITHUB_STANDARD_LAND_BYPASS` | The landing app, in the same format as other actors. An empty list admits none. |

The rule-source row expects the configured workflow repository and path in an organization ruleset. The Copilot review row accepts a native Copilot rule or that workflow at `refs/heads/main` with a full commit SHA. The organization's own ruleset applies approval, stale-dismissal, thread-resolution, deletion and force-push rules. Each repository owns its required checks and merge queue. A departing rule-source, minimum-approval or stale-dismissal row is advisory until 2.0. An empty contexts setting is also advisory until 2.0. A branch that requires the retired gate context fails the required-contexts row regardless of the setting. Follow the review-gate skill's [trusted removal workflow](../../review-gate/workflows/retire-consumer-writer.md) before retiring a gate writer.

The bypass row allows the landing app on queue-only and checks-only rulesets, and as the sole bypass actor on a ruleset holding `pull_request` alone or together with `workflows`. A ruleset holding deletion, force-push protection or any other rule admits no actor. The report allows the first-parent search for a merged pull request when the landing app is configured and the default-branch head came from a direct push. It reads the CI jobs from both legs of that merge.

## Migration from review-gate

The report and its settings moved to github-repository-settings. Set the opt-in and workflow repository ID, update the script path, and rename these keys where configured.

| Previous key | Replacement |
| --- | --- |
| `REVIEW_GATE_STANDARD_CONTEXTS` | `GITHUB_STANDARD_CONTEXTS` |
| `REVIEW_GATE_STANDARD_QUEUE_BYPASS` | `GITHUB_STANDARD_QUEUE_BYPASS` |
| `REVIEW_GATE_STANDARD_CHECKS_BYPASS` | `GITHUB_STANDARD_CHECKS_BYPASS` |
| `REVIEW_GATE_STANDARD_LAND_BYPASS` | `GITHUB_STANDARD_LAND_BYPASS` |

A replacement key in any settings layer takes precedence, including when explicitly empty. The report warns when it reads a previous key because its replacement is absent. The old script path warns and forwards. An explicit call to that path supplies the previous enablement and workflow repository defaults when those settings are absent. Setting the opt-in to `"false"` or `""` also disables the legacy path.

review-gate now requires github-repository-settings, so updating review-gate installs this package. Which package renders the review files then depends on how the project installs this package and on the checkout. The selection rule is kendex's [repository effects principle](https://github.com/vanillagreencom/kendex/blob/main/docs/architecture/repo-effects.md); this table applies it to the two install routes.

| Checkout | Only as review-gate's dependency | Listed by the project, or by a bundle such as workflow |
| --- | --- | --- |
| This clone, bot-instructions set up, this package not set up | bot-instructions renders and checks the review files. `kendex apply` and `kendex refresh` name this package's setup. | Neither package renders. `kendex apply` names this package's setup. |
| This clone, this package set up | This package renders. | This package renders. |
| A fresh clone, nothing set up | Neither package renders. `kendex apply` names the bot-instructions setup; set this package up instead. | Neither package renders. `kendex apply` names this package's setup. |
| The consumer refresh run, review files adopted | bot-instructions renders its full output. With `GITHUB_STANDARD_BOT_REVIEW = "on"`, that output matches this package's files; with `"off"`, the refresh pull request restores it. | This package renders. Without a committed `GITHUB_STANDARD_CHECK_LOCATION`, its setup refuses and the run stops with `refresh-error=bot-instructions-render`. |
| The consumer refresh run, no `[bot-instructions]` table and no marked review files | Neither package renders. The run logs `refresh-render=skipped package=bot-instructions cause=unconfigured` and continues. | Neither package renders. With a committed `GITHUB_STANDARD_CHECK_LOCATION`, the run logs the same skip and continues; without it, the run stops with `refresh-error=bot-instructions-render`. |

Refresh does not configure review files. To add them to a repository with no `[bot-instructions]` table, follow bot-instructions' [add-repository workflow](../../bot-instructions/workflows/add-repository.md), which writes the table and adopts the existing files, then set this package up.

A setup is recorded only in the clone that ran it. To set this package up, choose `GITHUB_STANDARD_CHECK_LOCATION`, then use Set up on this package's page, or run the `add` or `apply` that brings review-gate with `--allow-repo-effects`. Where this package arrives only as review-gate's dependency, a scripted `add --commit` or `apply --commit` without that flag, in a checkout where bot-instructions is set up, commits nothing, names the setup and exits 1. In a linked work tree, or in a repository where neither package is set up, an `add` can commit before the setup prompt, and the setup then rewrites the review files after that commit; commit those changes after the setup.

The warnings cover at least one minor release, beginning with the 1.23 release window. The old path and keys remain supported until 2.0. Remove the ignored keys `REVIEW_GATE_STANDARD_APP`, `REVIEW_GATE_STANDARD_ENVIRONMENT` and `REVIEW_GATE_STANDARD_SECRETS` without replacing them.
