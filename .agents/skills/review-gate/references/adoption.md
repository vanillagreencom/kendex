# Repository wiring and consumer refresh

## Repo-side wiring

GitHub rulesets enforce review requirements. The organization ruleset holds pull-request approval, stale-approval dismissal, thread resolution, Copilot review, deletion and force-push rules. Each repository keeps its required-checks ruleset and merge-queue ruleset. It keeps no classic branch protection.

Required contexts match `REVIEW_GATE_STANDARD_CONTEXTS` and exclude the retired gate context. Bind each context to its reporting app. Enable Copilot approvals and let them count toward merge requirements. Leave the approval path list blank so every changed file can qualify.

The organization's overseer app may approve a head after the managing workflow's internal review passes and its approval wait expires. Its emergency merge bypasses only the required-checks and merge-queue rulesets. Approval and thread resolution still apply. These operations belong to the managing workflow, not this package.

`validate-standard.sh` reports rule sources, approval requirements, stale-approval dismissal, required contexts, merge-queue checks, app installation and secret placement. Its `standard-bypass-actors` row judges bypass actors per ruleset: a queue-only ruleset admits `REVIEW_GATE_STANDARD_QUEUE_BYPASS`, a checks-only ruleset admits `REVIEW_GATE_STANDARD_CHECKS_BYPASS`, and any other ruleset admits none. The owner holds the ruleset split. Merge routing follows the github skill’s `pr-merge --help` § Merge route.

Until 2.0, the report reads the rows the 1.3.0 standard added as `advisory`, which fails nothing and keeps exit status 0: the rule sources, the 1 approval, stale-approval dismissal, and an unset or empty `REVIEW_GATE_STANDARD_CONTEXTS`. A branch that still requires the retired gate context fails the required-contexts row whatever that key holds. The run prints one `standard-advisory` warning naming each row's new form. Meet each row in the organization and repository rulesets and set the contexts key now; at 2.0 these rows fail.

## Settings

Declare values in the `[env]` table of `kendex.settings.toml`. The standard loader reads process values, `.env.local`, `.kendex/settings.toml`, then the committed file. `REVIEW_GATE_SETTINGS_FILE` selects an explicit file. `/dev/null` selects no file and keeps only process values and caller defaults.

| Key | Meaning | Default |
| --- | --- | --- |
| `REVIEW_GATE_STANDARD_APP` | Organization app slug read by the full standard report and environment provisioning. | None; empty refuses, and so does unset in provisioning. Until 2.0 the report reads unset as `vanillagreen-fleet-lanes`, the value before 1.3.0, with one warning. |
| `REVIEW_GATE_STANDARD_ENVIRONMENT` | App-secret environment read by both scripts. | None; empty refuses, and so does unset in provisioning. Until 2.0 the report reads unset as `kendex`, the value before 1.3.0, with one warning. |
| `REVIEW_GATE_STANDARD_SECRETS` | Secret names separated by `;`, never their values. Names use uppercase letters, digits and underscores and start with a letter or underscore. Provisioning reads each value from the environment variable of the same name and re-writes it on every run, including when the secret name is present. A rotation needs one owner run. | None; empty refuses, and so does unset in provisioning. Until 2.0 the report reads unset as `FLEET_GH_APP_ID;FLEET_GH_APP_PRIVATE_KEY`, the value before 1.3.0, with one warning. |
| `REVIEW_GATE_STANDARD_CONTEXTS` | Required contexts separated by `;`, compared by the full standard report. | None; until 2.0 an unset or empty list reports the required-contexts row advisory, unless the branch still requires the retired gate context, which fails the row; from 2.0 an unset or empty list fails the row. |
| `REVIEW_GATE_STANDARD_QUEUE_BYPASS`, `REVIEW_GATE_STANDARD_CHECKS_BYPASS` | Actors admitted by a queue-only and a checks-only ruleset, as `TYPE:ID:MODE`. Both standard scripts refuse malformed entries with `standard-bypass-invalid`. | Empty admits none. |
| `PR_REVIEW_WAIT_SECS` | Watcher quiet period before an absent approval needs attention. | The watcher's `--help` states the default. |

The report's earlier values name the vanillagreen organization's app, environment and secrets, so another organization sets all three keys. One `standard-setting-unset` warning per run names each unset key. Provisioning writes, so it never reads an earlier value: it would create that organization's environment in another's repositories.

`validate-standard.sh --environment-only` reads the environment and secret keys only. Consumer adoption supplies these values from the refresh template, so it needs no consumer assignment.

## Trusted removal for an existing consumer

A consumer with the retired gate package needs a one-time trusted removal PR before automatic refresh can update it. Its default-branch adopter needs a template the new package deletes. The automatic job preserves those default-branch scripts and never executes the refreshed adopter under its app token. It never performs retirement.

1. After the catalog removal merges, the consumer's owning lane refreshes the packages and runs the reviewed new adopter from the consumer root:

   ```bash
   kendex refresh
   .agents/skills/review-gate/scripts/adopt-refresh.sh --retire-writer
   kendex verify --scope project
   git add -A
   ```

2. Commit the package update, retired workflow deletion and inventory removal in a normal PR. It takes the surviving CI checks, a final-head Copilot approval and resolved review threads. It does not use the automatic render-only route. An edited, symlinked or unrecorded workflow stops adoption and needs an owner decision.
3. With those checks met, the repository's overseer sends the owner one line that the removal PR is ready to arm. The owner removes `Review gate` from that repository's required-checks ruleset and binds its other contexts to GitHub Actions (`integration_id` 15368). The target layout is the KEN-2067 design note § Target, attached to that Linear issue.
4. After the owner replies done, arm the removal PR. The required-check transition precedes writer removal, or later PRs wait for a status no workflow posts. Once the removal PR merges, automatic refresh starts from the fully migrated default branch.

## Automatic consumer refresh

After trusted removal, the shipped `templates/kendex-refresh.yml` checks for updates every 30 minutes. A manual run uses the same path. Each run installs the latest released kendex through `scripts/install-latest.sh`. That script resolves the release tag and its installer commit at run time. Each run updates `kendex/refresh` and keeps one open pull request. Every measured class publishes and arms auto-merge per [SKILL.md § Scripts](../SKILL.md#scripts). The required approval, thread resolution, required CI checks and the merge queue still control merging. A current consumer opens no pull request.

Provision the `kendex` environment before adoption. It must contain `FLEET_GH_APP_ID` and `FLEET_GH_APP_PRIVATE_KEY` and allow deployments from the default branch only. The organization owner uses `scripts/provision-environment.sh --org ORG` from their own machine, with `--repo ORG/NAME` for one new repository. `scripts/adopt-refresh.sh` reads the existing environment through `validate-standard.sh --environment-only`. It checks the environment and secret names the refresh template it installs reads, whatever the consumer's `REVIEW_GATE_STANDARD_*` settings say, so refresh adoption needs none of those keys. For the shared-workflow caller those are the names the shared workflow declares, and it refuses, with `refresh-error=caller-secrets`, a caller that does not map exactly those names, in order, to their same-named secrets on the line under its `uses:` line. A missing environment, secret or branch policy stops adoption with the failed check and provisioning remedy.

`refresh-consumer.sh` reports the exact `kendex --version` output in the rolling pull request body, or in `GITHUB_STEP_SUMMARY` when the consumer is current. A failed version read stops publication. `tests/refresh-consumer.test.sh` holds these report paths. The retained writer template also uses `install-latest.sh` for its release engine; only its optional main-build installer keeps a fixed commit. `tests/refresh-workflow.test.sh` checks that call, and `tests/install-latest.test.sh` checks immutable installer resolution.

Run from the consumer root after installing the skill:

```bash
.agents/skills/review-gate/scripts/adopt-refresh.sh
kendex verify --scope project
git add -A
```

Commit the workflow and inventory with the installed skill. Without `--retire-writer`, adoption keeps a recorded retired gate workflow and its inventory entry and prints one `refresh-warning=legacy-writer` line. Retirement belongs to the trusted removal route above. That route removes an unedited retired copy, proved by the committed adoption hash. An edited, symlinked or unrecorded retired copy needs an owner decision and stops adoption without changing the files.

Refresh workflow adoption in `scripts/adopt-refresh.sh` compares exact bytes with `skills/review-gate/templates/kendex-refresh.yml` in kendex's default-branch ancestry. It fetches that history from `https://github.com/vanillagreencom/kendex.git` as data only. Both the replacement template and any existing workflow must match shipped bytes. Consumer history and adoption records supply no replacement permission.

| Existing `.github/workflows/kendex-refresh.yml` | Refresh result |
|---|---|
| Absent, or equal to a shipped template | Write the selected shipped template and its adoption record. A missing, matching or stale record does not change acceptance. |
| Equal to no shipped template | Stop with `refresh-error=workflow-edited value=PATH` before writer adoption. Preserve the workflow and inventory. |
| Symlink | Stop with `refresh-error=workflow-symlink value=PATH`. Leave its target unchanged. |
| Bytes changed during writer adoption | Stop with `refresh-error=workflow-changed value=PATH` before refresh replacement or inventory writes. Preserve the new bytes. |

An unshipped replacement stops with `refresh-error=template-edited value=PATH`. A replacement changed during writer adoption stops with `refresh-error=template-changed value=PATH`. A Git history or blob read failure stops with `refresh-error=read value=workflow-history` before adoption. It does not classify the workflow as edited. `tests/adopt-refresh.test.sh` checks historical acceptance, edit preservation, read refusal and concurrent changes. `tests/refresh-consumer.test.sh` checks that refused workflow or render edits cause no publication. A held render edit prints `refresh-error=render-edited value=COUNT`, followed by its held records. COUNT is the distinct item count, not the harness-row count.

When orch is present after refresh, the refresh pull request adds Settings for refused or deprecated `ORCH_OVERSEER_PREFERENCE` entries. The release-installed parser runs read-only with only `PATH` and `HOME` in its environment. The running refresh script, the preserved default-branch copy or the kendex release tree, validates its stdout as data. A failed extraction stops publication and auto-merge. Each row names the entry and `harness:model:effort` as the replacement form. The same parse lists each committed `kendex.settings.toml` `[env]` value that names `gpt-6-astra` or Fable, in any case, as a `KEY = "value"` row under Deprecated models. That section is a warning: exit status, publication and auto-merge do not change. The scan skips comments, other tables and private overrides, and runs whether or not orch is present; without orch the parse lists no preference entries. A setting joins this report by exposing its existing parse the same way. A clean parse leaves the body unchanged. A run with no render change opens no pull request; it appends the same Settings and Deprecated models sections to its run summary. `tests/refresh-consumer.test.sh` checks committed settings, private overrides, no-change summaries, first installations and credential isolation.

After the refresh, the run stages it and asks kendex to render `bot-instructions` once, wherever the install put it, so the pull request carries the render the consumer's check demands and the render removes each file the refreshed package no longer produces. No setup record is read or written. The render runs with only `PATH`, `HOME` and `KENDEX_UI` in its environment. Where it renders nothing, the run prints one line: `refresh-render=skipped package=bot-instructions cause=absent` where the package is not installed, `refresh-render=skipped package=bot-instructions cause=unconfigured` where the manifest declares no `[bot-instructions]` table, and `refresh-render=skipped package=bot-instructions cause=engine` where the installed kendex predates the render verb, which an inline adopter on the latest stable release can run. Any other failure prints `refresh-error=bot-instructions-render value=STATUS`, or `refresh-error=bot-instructions-probe value=STATUS` where asking kendex for the verb failed, and stops publication and auto-merge.

The refresh pull request also adds Consumer settings, report only: it changes no setting. The same parse passes every committed `kendex.settings.toml` `[env]` setting, and the report names each key `retired-settings.json` lists under `keys` and each value it lists under `values` for that key, a shipped default since replaced. The section also carries the `setting-unset:` line change-class printed for the pull request, and its `queue-only:` line where the cause is `queue-list-undeclared` or `queue-settings-unreadable`, so an unset `HARNESS_CI_QUEUE_PATHS` is named there. The `queue-only:` line every other verdict prints names no setting and stays out. A run with no render change runs no classifier and appends the retired rows to its run summary. A report that fails, such as on an unreadable list, stops publication and auto-merge. Removing a retired setting is the consumer's own change.

Commit the workflow copies and inventory with the installed skill. Adoption records each byte-identical copy's template path and SHA-256 hash. `kendex refresh` updates the template and its expected hash. Adoption then rewrites the refresh copy and records it. Verification and the shared change classifier compare the copy with the declared package template. Verification rejects a registered copy that differs from its template.

Schedule and manual refresh work in a consumer with the app installation and environment above. The shared-workflow caller passes the two app secrets by name, and their values come from the consumer's `kendex` environment. Review-gate-sandbox run 37191124465 read both set for a caller in vanillagreencom that maps each name to its same-named secret, and both empty for a caller that passes nothing; a consumer in another organization is not proven on this route. Instant refresh also needs organization dispatch wiring. The catalog's `.github/workflows/kendex-dispatch.yml` signals every non-archived consumer repository visible to its app installation after a push to `main`. Adoption and dispatch exclude `vanillagreencom/kendex`, whose build-bound lock workflow owns its refresh. It attempts all destinations and fails the run if any dispatch fails.

Only the default-branch workflow can use the private key. It checks out the default branch before minting a repository-scoped app token. It rebuilds the rolling branch from that checkout and asks the shared classifier to measure the full diff before pushing. It preserves the default-branch review scripts in a detached worktree before refreshing. Those scripts prove that each rolling pull request has class `render` before they file, reply to or resolve an automatic review thread. Findings on other classes remain unchanged.

The last two steps request an Issues-write token scoped only to `vanillagreencom/kendex`, then use it to file findings and resolve their threads. Each automatic review thread on a render-proven pull request has one of these outcomes:

- The thread is outdated at the current head: the workflow prints a keyed skip, replies with `Not filed upstream: ` and the reason, and resolves the thread. It files nothing and does not hold the run.
- The thread is live and no single package claims its path (including paths outside the inventory, the lock, the inventory and a Copilot `.github/agents/*.agent.md` render): the workflow prints `upstream-unfiled`, gives no reply and leaves the thread open. It files nothing. Review text about content kendex has not claimed is never published. The consumer must answer the finding through its trusted removal PR or a reply, then resolve the thread by hand.
- The thread is live and `kendex report` routes its one package to `vanillagreencom/kendex` with a package label: the workflow files the finding there for upstream confirmation, replies with the issue, and resolves the thread. GitHub-to-Linear sync sends the reports to KEN Triage. The report carries the review evidence, rendered path, consumer run and that package label. Its title fingerprint hashes the package, the path inside its directory (none for a package the lock records under any kind but skill, since such a package is one file whose rendered name and layout differ by harness, a command rendering as a Codex skill tree among them), and the head lines the comment names, joined by its wording where that text occurs more than once in the file at head, or its wording alone for a file-level or base-side comment. The lookup counts only issues a GitHub App wrote, in every state: GitHub issue search, then, on the run's first miss just before filing, one read of the issues updated in the last hour, since search indexes another consumer's filing from the same schedule late, plus the run's own filings. Two consumers that both read before either files can still file twice. An open match gains a comment with the thread's text and evidence where its body lacks that evidence. A closed match is the answer, linked in the reply with its close reason, and nothing is filed.
- Other live findings are not filed when `kendex report` routes the package elsewhere, or the token or Issues access is missing. The error line gives the reason.

Live unfiled findings stay open and fail the run under the thread-resolution rule. Report the finding where it belongs and resolve the thread by hand: a resolved not-filed thread no longer fails the run. Filing replies and not-filed replies are durable answers; a later run only resolves their threads. A reporter failure holds only its own pull request and also fails the run. If the token lacks Issues access, the Actions summary supplies filing links for routed findings only. A later run with the token files the finding and resolves the thread. A pull request the classifier cannot measure keeps its findings unanswered, and the run adds a warning with the cause.
