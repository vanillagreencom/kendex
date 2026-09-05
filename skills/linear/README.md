# Linear CLI

A Bash CLI over Linear's GraphQL API with a local JSON cache: reads are served from the cache, writes hit the API and write through to it. For a project whose agents plan, track and close work in Linear from the shell.

## Install

```bash
kendex add vanillagreencom/kendex --skill linear
```

Needs Bash 4.0 or newer, `curl` and `jq`; macOS system Bash 3.2 is unsupported, so invoke `linear.sh` with the newer Bash. Then:

1. Put `LINEAR_API_KEY` in `.env.local`.
2. Set `LINEAR_TEAM` in committed `kendex.settings.toml` under `[env]`; the install writes the key with an empty value, and writes refuse until it is set.
3. Run `./scripts/linear.sh auth-check --strict`, then `./scripts/linear.sh sync --reconcile`.

## What it does

- Issues, comments, projects, initiatives, milestones, labels, teams, users, cycles, workflow states and documents: list, get, create, update, and the relations between them.
- A local cache for reads that need no API key, refreshed by `sync`.
- Attachment upload and download.
- Issue rules applied at create and transition time: a required agent-routing label, a required `Reached by:` line, completion validation.

## How it works

```bash
./scripts/linear.sh cache issues list --project "Phase 2" --state "Todo,In Progress"
./scripts/linear.sh issues update ABC-100 --state Done
./scripts/linear.sh sync --reconcile
```

`./scripts/linear.sh --help` lists the resources; `./scripts/linear.sh <resource> --help` is one resource's options. The cache lives at `.cache/linear` under the physical git worktree root, so symlinked checkout spellings share one copy.

## Customise

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
