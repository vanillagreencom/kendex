# Linear CLI

A Bash CLI over Linear's GraphQL API with a local JSON cache. Reads are served from the cache; writes hit the API and write through to it. `DEVELOPMENT.md` covers internals, `SKILL.md` the full command reference.

## Setup

1. Install Bash 4.0 or newer, plus `curl` and `jq`. macOS system Bash 3.2 is unsupported — invoke `linear.sh` with the newer Bash.
2. Put `LINEAR_API_KEY` in `.env.local`.
3. Set `LINEAR_TEAM` in committed `kendex.settings.toml` under `[env]`, along with the other non-secret defaults. [`kendex.settings.toml.example`](kendex.settings.toml.example) is the key list, each with what it does and what leaving it unset means.

```bash
./scripts/linear.sh auth-check --strict
./scripts/linear.sh sync --reconcile
```

`LINEAR_TEAM` has no default, and `auth-check --strict` exits non-zero until it is set: a team name resolves inside whatever workspace the API key reaches, so a guessed default would write into whichever tracker that key happens to own. With no team configured, writes refuse and reads run without a team filter.

## How

```bash
./scripts/linear.sh cache issues list --project "Phase 2" --state "Todo,In Progress"
./scripts/linear.sh cache issues get ABC-100 --with-bundle
./scripts/linear.sh issues create --title "New task" --project "Phase 2" --labels "agent:generalist" --description "Reached by: kendex apply"
./scripts/linear.sh issues update ABC-100 --state Done
./scripts/linear.sh sync --reconcile
```

Cache reads need no API key. The cache lives at `.cache/linear` under the physical git worktree root, so symlinked checkout spellings share one copy. `LINEAR_CACHE_ROOT` overrides that root for one invocation, and is refused if it names no directory.

Run `./scripts/linear.sh --help` for the resource list and `./scripts/linear.sh <resource> --help` for a resource's options.
