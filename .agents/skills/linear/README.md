# Linear CLI

A shell CLI for Linear issues, projects and planning data. It includes a local cache for reads and sends changes to the Linear API.

## Install

```bash
kendex add vanillagreencom/kendex --skill linear
```

Requires Bash 4.0 or newer, curl and jq. Put `LINEAR_API_KEY` in `.env.local` and `LINEAR_TEAM` in `kendex.settings.toml` under `[env]`. Run the installed `scripts/linear.sh auth-check --strict`, then `scripts/linear.sh sync --reconcile`.

## Features

- Read and change issues, projects, comments and planning data.
- Refresh a local cache for repeated reads.
- Upload and download attachments.
- Check configured issue requirements during creation and completion.

## How it works

You configure the API key and target team. A sync downloads Linear data into the project's local cache. Cache commands read that saved data. Write commands send changes to Linear and update the cache.

## Settings

Set non-secret keys in committed `kendex.settings.toml` under `[env]`; the key list with each default and what leaving it unset means is [kendex.settings.toml.example](kendex.settings.toml.example).

| Variable | Purpose |
|----------|---------|
| `LINEAR_API_KEY` | The API key, in `.env.local` |
| `LINEAR_TEAM` | The team every write targets; required |
| `LINEAR_TEAM_PREFIX` | Issue identifier prefix used in examples |
| `LINEAR_AGENT_LABELS` | Agent-routing labels an `issues create` must carry one of |
| `LINEAR_REQUIRE_REACH` | Non-empty enforces the `Reached by:` and `Symptom:` lines at create |
| `LINEAR_FORMAT` | Default read format: `safe`, `table`, `ids`, `raw` |
| `LINEAR_RETRY_BASE_DELAY` | Seconds before the first retry of a failed call, doubling after |
| `LINEAR_CACHE_ROOT` | Overrides the cache root for one invocation; refused if it names no directory |
