# Authentication

Read when selecting, checking or renewing the credential a Linear command uses, or when a write's attribution matters. The person's credential inputs and setup are in [README.md § Setup](../README.md#setup).

## Credential selection

- Credential precedence is `LINEAR_APP_TOKEN`, then the client pair, then `LINEAR_API_KEY`.
- Without a token, a partial pair refuses instead of changing actors.
- Application values use process environment precedence over project files.
- The personal key keeps its project-file precedence over inherited keys.

`auth-check` reports the selected credential and the application's or user's ID and name, and `{ok: false}` when the mint fails.

## Application token

- With `LINEAR_APP_TOKEN`, the skill sends a Bearer header and never mints, renews or caches the token.
- HTTP 401 reports that the token is expired or revoked.
- A configured client pair does not provide a fallback.

The client credentials grant uses the fixed scope set declared by `_LINEAR_APP_SCOPE` in `scripts/lib/auth.sh`.

- It does not request `admin` or the optional agent mention and assignment scopes. See [agent scopes](https://linear.app/developers/agents#actor-and-scopes).
- Keep the same set across minters: changing it revokes existing app-actor tokens. See [client credentials tokens](https://linear.app/developers/oauth-2-0-authentication#client-credentials-tokens).

## Client-pair token store

Without `LINEAR_APP_TOKEN`, the client-pair API path mints a token on the first request that needs one. It keeps the token with its expiry in a private per-user file, replaced atomically.

- The file is `kendex/linear-oauth/<fingerprint>.json` under `XDG_CACHE_HOME`, or else `~/.cache`.
- A session with neither set, or one that cannot write that directory, keeps the file in `kendex-linear-oauth-<uid>/` under `TMPDIR` (else `/tmp`) instead. A sandbox held to its workspace and temporary directory is such a session.
- Each invocation reads and stores the token in one directory: the first of the two that this user owns and can write, probed with a write.
- A token in a directory the invocation cannot write is never read, so a revoked token there cannot shadow its renewal.
- A symlink or another user's directory is never used.
- The fingerprint covers the pair and the fixed scope, so a token minted under another scope set is never reused.
- Every later request and invocation reuses that token until a minute before it expires, which keeps the application under Linear's cap on active client-credentials tokens.
- An HTTP 401 renews it once and writes the renewal back.
- When neither directory qualifies, or the store into the chosen one fails, the request still runs on the minted token. Only the reuse is lost.
- In that case stderr carries one `linear-auth: token-store=failed` line naming each directory tried and its cause (`mkdir-failed`, `symlink`, `not-owned`, `not-writable`, `write-failed`).
- A mint is retried and reports a rate limit as every request does.

## Attribution

- Application tokens attribute issue creation, comments and state changes to the application.
- Linear also supports `createAsUser` and `displayIconUrl` on `issueCreate` and `commentCreate`, with no additional request.
- This skill has no lane name or avatar input, so it keeps application attribution. See [OAuth actor authorization](https://linear.app/developers/oauth-actor-authorization).
