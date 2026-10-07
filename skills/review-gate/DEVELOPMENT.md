# Development

## Boundaries

The package reads GitHub's review state. GitHub enforces approvals and thread resolution. The package reports attention states but grants no merge permission.

The settings loader is shared by the watcher, the standard report and environment provisioning. Its process values override project files. `REVIEW_GATE_SETTINGS_FILE=/dev/null` selects no settings source.

Consumer adoption uses the committed workflow hash to prove that a retired copy remains unedited. Core refresh preserves adopted inventory records when their template disappears. Adoption uses that record to find a retired copy, including a renamed copy. It checks ownership before it changes any workflow or inventory entry.

Secret writes on repeat provisioning runs and rotation follow the [`REVIEW_GATE_STANDARD_SECRETS` contract](references/adoption.md#settings).

## Consumer refresh

The refresh scripts and their suites live in the repository's `refresh/` tree. They run from a kendex release checkout. The refresh adoption and publication contracts remain in [references/adoption.md](references/adoption.md#automatic-consumer-refresh).

`retired-settings.json` is the one list the refresh report's Consumer settings section reads. A change that retires a settings key a consumer may have committed adds it under `keys`; one that replaces a shipped default adds the old value under `values` for its key.

## Tests

Run the shell suites under `tests/` through the repository's skill-suite entry point.

`tests/settings-parsing.test.sh` holds settings precedence and refusal of unreadable sources. The standard-report and provisioning suites drive GitHub API fixtures.

The suite fixtures pass an explicit child environment so host credentials cannot alter the cases.
