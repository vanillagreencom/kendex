# Development

## Boundaries

The package reads GitHub's review state. GitHub enforces approvals and thread resolution. The package reports attention states but grants no merge permission.

The settings loader is shared by the watcher, the standard report and environment provisioning. Its process values override project files. `REVIEW_GATE_SETTINGS_FILE=/dev/null` selects no settings source.

Consumer adoption uses the committed workflow hash to prove that a retired copy remains unedited. Core refresh preserves adopted inventory records when their template disappears. Adoption uses that record to find a retired copy, including a renamed copy. It checks ownership before it changes any workflow or inventory entry.

Secret writes on repeat provisioning runs and rotation follow the [`REVIEW_GATE_STANDARD_SECRETS` contract](references/adoption.md#settings).

## Consumer refresh

The rolling refresh may discard hand edits because its pull request exposes the replacement diff. Interactive refresh keeps its refusal. Refresh has no JSON report, so `refresh-consumer.sh` reads the plain conflicts section and ledger. The ledger counts distinct kind/name items, not conflict records. The runner classifies every conflict record before comparing those identities with the ledger. Its pull request body keeps every authorized hold record, including shared edits. Adoption and verification still precede publication. `tests/refresh-consumer.test.sh` uses a real binary, an isolated home and a local catalog for multiple edited items, shared edits, unmanaged installations, edited orphans and lost output. Its controls remove discard, bypass record classification or count agreement, and reset the body accumulator. The required-binary control fails with no binary on PATH before sandbox initialization.

Automatic refresh starts only after the [trusted removal PR](references/adoption.md#trusted-removal-for-an-existing-consumer) merges. The consumer runs `adopt-refresh.sh`, its environment validator and their libraries from the preserved checkout. It passes refreshed templates as data with `--templates-dir`. The core verifier owns template equality. Refresh reconciliation and its report contract are in [references/adoption.md § Automatic consumer refresh](references/adoption.md#automatic-consumer-refresh). The adoption record inventories the refresh copy; it does not determine whether a person edited it.

`refresh-consumer.sh` preserves the remote commit when its tree already equals the proposed tree. This keeps CI results across scheduled runs. A changed tree is pushed with a lease against the observed remote head. The class controls publication and auto-merge per [SKILL.md § Scripts](SKILL.md#scripts). Tests use local Git repositories to prove current, stale, repeated, failed-verification, and non-render outcomes. A duplicate-creation mutation proves the rolling pull request assertion can fail.

`refresh-report.py` routes a finding with the classified commit's inventory and lock record, not the current checkout's provenance. Later package removals must not change that historical route. The upstream Issues token belongs only to the issue API; Git, kendex and the classifier use the consumer environment.

## Tests

Run the shell suites under `tests/` through the repository's skill-suite entry point. `tests/adopt-refresh.test.sh` proves refresh updates and retired workflow removal. Its controls disable each ownership guard in a disposable script copy.

`tests/settings-parsing.test.sh` holds settings precedence and refusal of unreadable sources. The standard-report and provisioning suites drive GitHub API fixtures. The consumer-refresh and refresh-review suites hold branch creation, render proof and upstream filing before thread resolution.

`tests/refresh-report.test.sh` holds issue identity, historical routing and credential isolation. `tests/refresh-workflow.test.sh` holds the workflow's token boundaries. `tests/refresh-consumer.test.sh` proves that an unchanged tree keeps its remote commit and CI results. `tests/refresh-reviews.test.sh` holds retry records and containment of a reporter failure to its own pull request.

The suite fixtures pass an explicit child environment so host credentials cannot alter the cases.
