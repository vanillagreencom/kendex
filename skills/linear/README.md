# Linear CLI

A shell CLI for Linear issues, projects and planning data. Every read and write goes to the Linear API as it runs.

## Features

- Read and change issues, projects, comments and planning data.
- Read every page a read asks for, or fail with no partial output.
- Upload attachments, list the files an issue references and download one.
- Check configured issue requirements during creation and completion.
- Apply and create only the labels the repository's label taxonomy declares, and list the labels that drift from it.

## Install

```bash
kendex add vanillagreencom/kendex --skill linear
```

## How it works

You configure credentials and the target team. Each command sends its reads and writes to Linear's GraphQL API and keeps no tracker data on disk. Client-pair authentication keeps its OAuth token in a per-user cache file, described under § Settings. A read follows every page of each collection it asks for. A rate-limited request reports the time the request quota refills.

## Setup

Requires Bash 4.0 or newer, curl and jq. Set the credentials in the project's private env file and `LINEAR_TEAM` in `kendex.settings.toml`. A personal key can also be set in the kendex app, on this package's Customize tab. Run the installed `scripts/linear.sh auth-check --strict`.

Set non-secret keys in committed `kendex.settings.toml` under `[env]`; the key list with each default and what leaving it unset means is [kendex.settings.toml.example](kendex.settings.toml.example).

| Variable | Purpose |
|----------|---------|
| `LINEAR_APP_TOKEN` | Pre-minted application token, in the private env file or a secret store via `op://` |
| `LINEAR_CLIENT_ID` | OAuth application client ID, in the project's private env file |
| `LINEAR_CLIENT_SECRET` | OAuth application client secret, in the project's private env file |
| `LINEAR_API_KEY` | Personal API key fallback, in the project's private env file |
| `LINEAR_TEAM` | Team target for creates and writes that do not address an issue; existing-issue writes use the issue's team |
| `LINEAR_TEAM_PREFIX` | Issue identifier prefix used in examples |
| `LINEAR_AGENT_LABELS` | Agent-routing labels an `issues create` must carry one of; under a declared label taxonomy, the agent labels it declares |
| `LINEAR_REQUIRE_REACH` | Enforces the `Reached by:` and `Symptom:` lines at create; on when unset, off when empty |
| `LINEAR_FORMAT` | Default read format: `safe`, `table`, `ids`, `raw` |
| `LINEAR_RETRY_BASE_DELAY` | Seconds before the first retry of a rate-limited call, or of a query answered 5xx or not at all, doubling after |
| `KENDEX_USER_EMAIL` | Your email address, in the project's private env file; `issues activate` assigns an unassigned issue to the Linear user with that address |

Set application credentials in `.env.local` unless `KENDEX_ENV_FILE` names another private file. Enable client credentials tokens in the application's Linear settings. Credential precedence is `LINEAR_APP_TOKEN`, then the client pair, then `LINEAR_API_KEY`. Without a token, a partial pair refuses instead of changing actors. Application values use process environment precedence over project files. The personal key keeps its project-file precedence over inherited keys.

With `LINEAR_APP_TOKEN`, the skill sends a Bearer header and never mints, renews or caches the token. HTTP 401 reports that the token is expired or revoked. A configured client pair does not provide a fallback.

On a host with the real client pair, run `scripts/linear.sh auth-mint`. It prints `access_token` and `expires_at` (epoch seconds) as JSON and writes no files. The fleet publishes the token as `LINEAR_APP_TOKEN` to its secret store and replaces it before expiry. Keep one minting host. The client credentials grant always requests scope exactly `read,write,issues:create,comments:create,timeSchedule:write,initiative:read,initiative:write,customer:read,customer:write`: every scope Linear documents for an application except `admin`, which an `app` actor token cannot hold, and `app:assignable` and `app:mentionable`, which change how the application appears in Linear and grant no data access. See [agent scopes](https://linear.app/developers/agents#actor-and-scopes). Linear revokes existing app tokens when an application requests a different scope set. See [client credentials tokens](https://linear.app/developers/oauth-2-0-authentication#client-credentials-tokens).

Without `LINEAR_APP_TOKEN`, the client-pair API path mints a token on the first request that needs one and keeps it with its expiry in a private per-user file, `kendex/linear-oauth/<fingerprint>.json` under `XDG_CACHE_HOME` or else `~/.cache`, replaced atomically. A session with neither set, or one that cannot write that directory, such as a sandbox held to its workspace and temporary directory, keeps the file in `kendex-linear-oauth-<uid>/` under `TMPDIR` (else `/tmp`) instead. Each invocation reads and stores the token in one directory, the first of the two that this user owns and can write, probed with a write; a token in a directory it cannot write is never read, so a revoked token there cannot shadow its renewal. A symlink or another user's directory is never used. The fingerprint covers the pair and the fixed scope, so a token minted under another scope set is never reused. Every later request and invocation reuses that token until a minute before it expires, which keeps the application under Linear's cap on active client-credentials tokens. An HTTP 401 renews it once and writes the renewal back. When neither directory qualifies, or the store into the chosen one fails, the request still runs on the minted token and stderr carries one `linear-auth: token-store=failed` line naming each directory tried and its cause (`mkdir-failed`, `symlink`, `not-owned`, `not-writable`, `write-failed`); only the reuse is lost. A mint is retried and reports a rate limit as every request does. Token files an earlier version left under a checkout's `.cache/linear/oauth/` are stale; delete them. `auth-check` reports the selected credential and the application's or user's ID and name, and `{ok: false}` when the mint fails.

Application tokens attribute issue creation, comments and state changes to the application. Linear also supports `createAsUser` and `displayIconUrl` on `issueCreate` and `commentCreate`, with no additional request. This skill has no lane name or avatar input, so it keeps application attribution. See [OAuth actor authorization](https://linear.app/developers/oauth-actor-authorization).

`KENDEX_USER_EMAIL` is kendex's own setting, not this skill's: the app's Customize tab writes it to the private env file (`.env.local` unless `KENDEX_ENV_FILE` names another), never to `kendex.settings.toml`. Use the address your Linear account signs in with; it is matched whole and without regard to case. Empty or absent assigns nobody. A worktree whose `WORKTREE_SYMLINKS` lists `.env.local` links that file to its main checkout, and a hosted lane receives a copy of the checkout's `.env.local` each time it is created, so a value set there reaches every lane of that checkout. A value exported only in the shell that starts the lanes does not: a local lane's tmux pane takes its environment from the tmux server, not from that shell.

`LINEAR_CACHE_ROOT` is retired with the local store: set in the environment or a project file, even empty, it fails every command with `linear-setting: retired=LINEAR_CACHE_ROOT`. Remove it.

## Licence

MIT, in the repository's LICENSE file.
