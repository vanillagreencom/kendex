# Authentication

Read when selecting, checking or renewing the credential a Linear command uses, or when a write's attribution matters. The person's credential inputs and setup are in [README.md § Setup](../README.md#setup).

## Credential selection

Credential precedence is `LINEAR_APP_TOKEN`, then the client pair, then `LINEAR_API_KEY`. Without a token, a partial pair refuses instead of changing actors. Application values use process environment precedence over project files. The personal key keeps its project-file precedence over inherited keys.

`auth-check` reports the selected credential and the application's or user's ID and name, and `{ok: false}` when the mint fails.

## Application token

With `LINEAR_APP_TOKEN`, the skill sends a Bearer header and never mints, renews or caches the token. HTTP 401 reports that the token is expired or revoked. A configured client pair does not provide a fallback.

The client credentials grant always requests scope exactly `read,write,issues:create,comments:create,timeSchedule:write,initiative:read,initiative:write,customer:read,customer:write`: every scope Linear documents for an application except `admin`, which an `app` actor token cannot hold, and `app:assignable` and `app:mentionable`, which change how the application appears in Linear and grant no data access. See [agent scopes](https://linear.app/developers/agents#actor-and-scopes). Linear revokes existing app tokens when an application requests a different scope set. See [client credentials tokens](https://linear.app/developers/oauth-2-0-authentication#client-credentials-tokens).

## Client-pair token store

Without `LINEAR_APP_TOKEN`, the client-pair API path mints a token on the first request that needs one and keeps it with its expiry in a private per-user file, `kendex/linear-oauth/<fingerprint>.json` under `XDG_CACHE_HOME` or else `~/.cache`, replaced atomically. A session with neither set, or one that cannot write that directory, such as a sandbox held to its workspace and temporary directory, keeps the file in `kendex-linear-oauth-<uid>/` under `TMPDIR` (else `/tmp`) instead. Each invocation reads and stores the token in one directory, the first of the two that this user owns and can write, probed with a write; a token in a directory it cannot write is never read, so a revoked token there cannot shadow its renewal. A symlink or another user's directory is never used. The fingerprint covers the pair and the fixed scope, so a token minted under another scope set is never reused. Every later request and invocation reuses that token until a minute before it expires, which keeps the application under Linear's cap on active client-credentials tokens. An HTTP 401 renews it once and writes the renewal back. When neither directory qualifies, or the store into the chosen one fails, the request still runs on the minted token and stderr carries one `linear-auth: token-store=failed` line naming each directory tried and its cause (`mkdir-failed`, `symlink`, `not-owned`, `not-writable`, `write-failed`); only the reuse is lost. A mint is retried and reports a rate limit as every request does.

## Attribution

Application tokens attribute issue creation, comments and state changes to the application. Linear also supports `createAsUser` and `displayIconUrl` on `issueCreate` and `commentCreate`, with no additional request. This skill has no lane name or avatar input, so it keeps application attribution. See [OAuth actor authorization](https://linear.app/developers/oauth-actor-authorization).
