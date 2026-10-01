# Development

## Boundaries

The package reads GitHub's review state. GitHub enforces approvals and thread resolution. The package reports attention states but grants no merge permission.

The settings loader is shared by the watcher, the standard report and environment provisioning. Its process values override project files. `REVIEW_GATE_SETTINGS_FILE=/dev/null` selects no settings source.

Consumer adoption uses the committed workflow hash to prove that a retired copy remains unedited. Core refresh preserves adopted inventory records when their template disappears. Adoption uses that record to find a retired copy, including a renamed copy. It checks ownership before it changes any workflow or inventory entry.

Secret writes on repeat provisioning runs and rotation follow the [`REVIEW_GATE_STANDARD_SECRETS` contract](references/adoption.md#settings).

## Consumer refresh

Refresh has no JSON report, so `refresh-consumer.sh` reads the plain conflicts section and ledger. The ledger counts distinct kind/name items, not conflict records. The runner classifies every conflict record before comparing those identities with the ledger. A proven held edit stops before adoption or publication. The first refresh can update other managed files, but cannot replace the held edit. `tests/refresh-consumer.test.sh` uses a real binary, an isolated home and a local catalog for local and upstream edits, multiple items, shared edits, unmanaged installations, edited orphans and lost output. Its controls restore discard or bypass record classification or count agreement. The same byte-preservation assertion rejects the baseline runner and the discard mutant. The required-binary control fails with no binary on PATH before sandbox initialization.

Automatic refresh starts only after the [trusted removal PR](references/adoption.md#trusted-removal-for-an-existing-consumer) merges. The consumer runs `adopt-refresh.sh`, its environment validator and their libraries from the preserved checkout. It passes refreshed templates as data with `--templates-dir`. The core verifier owns template equality. The refresh adoption contract is in [references/adoption.md § Automatic consumer refresh](references/adoption.md#automatic-consumer-refresh). The adoption record inventories the copy; it does not determine whether a person edited it. The adopter owns shipment equality against the public catalog's full default-branch ancestry. It executes no fetched code. It classifies before retired-writer removal, then rechecks observed bytes before replacement. Tests substitute only its transport in disposable copies with a local Git catalog. That catalog includes the historical shipped workflow from `f7db7e89`. Consumer commits and invented metadata cannot establish shipment. Independent controls disable workflow and template equality, history-read refusal, symlink refusal and each changed-byte precondition.

`refresh-consumer.sh` preserves the remote commit when its tree already equals the proposed tree. This keeps CI results across scheduled runs. A changed tree is pushed with a lease against the observed remote head. The class controls publication and auto-merge per [SKILL.md § Scripts](SKILL.md#scripts). Tests use local Git repositories to prove current, stale, repeated, failed-verification, and non-render outcomes. A concurrent remote-head fixture proves the lease preserves a competing commit. A force-push mutant replaces it and turns that assertion red. A duplicate-creation mutation proves the rolling pull request assertion can fail.

`refresh-report.py` routes a finding with the classified commit's inventory and lock record, not the current checkout's provenance. Later package removals must not change that historical route. The upstream Issues token belongs only to the issue API; Git, kendex and the classifier use the consumer environment.

## Tests

Run the shell suites under `tests/` through the repository's skill-suite entry point. `tests/adopt-refresh.test.sh` proves refresh updates and retired workflow removal. Its controls disable each ownership guard in a disposable script copy.

`tests/settings-parsing.test.sh` holds settings precedence and refusal of unreadable sources. The standard-report and provisioning suites drive GitHub API fixtures. The consumer-refresh and refresh-review suites hold branch creation, render proof and the [automatic-review thread rules](references/adoption.md#automatic-consumer-refresh).

`tests/refresh-report.test.sh` holds issue identity, historical routing and credential isolation. `tests/refresh-workflow.test.sh` holds the workflow's token boundaries. `tests/refresh-consumer.test.sh` proves that an unchanged tree keeps its remote commit and CI results. `tests/refresh-reviews.test.sh` holds retry records and containment of a reporter failure to its own pull request.

The suite fixtures pass an explicit child environment so host credentials cannot alter the cases.
