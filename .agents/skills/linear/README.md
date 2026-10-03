# Linear CLI

A shell CLI for Linear issues, projects and planning data. It includes a local cache for reads and sends changes to the Linear API.

## Install

```bash
kendex add vanillagreencom/kendex --skill linear
```

Requires Bash 4.0 or newer, curl and jq. Set the credentials in the project's private env file and `LINEAR_TEAM` in `kendex.settings.toml`. A personal key can also be set in the kendex app, on this package's Customize tab. Run the installed `scripts/linear.sh auth-check --strict`, then `scripts/linear.sh sync --reconcile`.

## Features

- Read and change issues, projects, comments and planning data.
- Refresh a local cache for repeated reads.
- Upload and download attachments.
- Check configured issue requirements during creation and completion.
- Apply and create only the labels the repository's label taxonomy declares, and list the labels that drift from it.

## How it works

You configure credentials and the target team. A sync downloads Linear data into the project's local cache. Cache commands read that saved data. Write commands send changes to Linear and update the cache.

## Settings

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
| `LINEAR_REQUIRE_REACH` | Non-empty enforces the `Reached by:` and `Symptom:` lines at create |
| `LINEAR_FORMAT` | Default read format: `safe`, `table`, `ids`, `raw` |
| `LINEAR_RETRY_BASE_DELAY` | Seconds before the first retry of a failed call, doubling after |
| `LINEAR_CACHE_ROOT` | Overrides the cache root for one invocation; refused if it names no directory |
| `KENDEX_USER_EMAIL` | Your email address, in the project's private env file; `issues activate` assigns an unassigned issue to the Linear user with that address |

Set application credentials in `.env.local` unless `KENDEX_ENV_FILE` names another private file. Enable client credentials tokens in the application's Linear settings. Credential precedence is `LINEAR_APP_TOKEN`, then the client pair, then `LINEAR_API_KEY`. Without a token, a partial pair refuses instead of changing actors. Application values use process environment precedence over project files. The personal key keeps its project-file precedence over inherited keys.

With `LINEAR_APP_TOKEN`, the skill sends a Bearer header and never mints, renews or caches the token. HTTP 401 reports that the token is expired or revoked. A configured client pair does not provide a fallback.

On a host with the real client pair, run `scripts/linear.sh auth-mint`. It prints `access_token` and `expires_at` (epoch seconds) as JSON and writes no files. The fleet publishes the token as `LINEAR_APP_TOKEN` to its secret store and replaces it before expiry. Keep one minting host. The client credentials grant always requests scope exactly `read,write`. Linear revokes existing app tokens when an application requests a different scope set. See [client credentials tokens](https://linear.app/developers/oauth-2-0-authentication#client-credentials-tokens).

Without `LINEAR_APP_TOKEN`, the client-pair API path stores tokens and their expiry under `.cache/linear/oauth/` at the resolved cache root. It renews before expiry and once after HTTP 401. Token files are private and replaced atomically. `auth-check` reports the selected credential and the application's or user's ID and name.

Application tokens attribute issue creation, comments and state changes to the application. Linear also supports `createAsUser` and `displayIconUrl` on `issueCreate` and `commentCreate`, with no additional request. This skill has no lane name or avatar input, so it keeps application attribution. See [OAuth actor authorization](https://linear.app/developers/oauth-actor-authorization).

`KENDEX_USER_EMAIL` is kendex's own setting, not this skill's: the app's Customize tab writes it to the private env file (`.env.local` unless `KENDEX_ENV_FILE` names another), never to `kendex.settings.toml`. Use the address your Linear account signs in with; it is matched whole and without regard to case. Empty or absent assigns nobody. A worktree whose `WORKTREE_SYMLINKS` lists `.env.local` links that file to its main checkout, and a hosted lane receives a copy of the checkout's `.env.local` each time it is created, so a value set there reaches every lane of that checkout. A value exported only in the shell that starts the lanes does not: a local lane's tmux pane takes its environment from the tmux server, not from that shell.
