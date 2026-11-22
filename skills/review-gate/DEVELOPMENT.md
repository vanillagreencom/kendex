# Development

## Settings loader

`scripts/lib/settings.sh` is shared: `refresh/refresh-consumer.sh` and the github-repository-settings package source it.

## Consumer refresh

The refresh scripts and their suites live in the repository's `refresh/` tree. They run from a kendex release checkout. The refresh adoption and publication contracts remain in [references/adoption.md](references/adoption.md#automatic-consumer-refresh).

`retired-settings.json` is the one list the refresh report's Consumer settings section reads.

- A change that retires a settings key a consumer may have committed adds it under `keys`.
- A rename also maps it to the new key under `successors`.
- A change that replaces a default an install wrote into the consumer's file adds the old value under `values` for its key.
