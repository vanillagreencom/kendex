# Linear CLI

A shell CLI for Linear issues, projects and planning data.

## Features

- Read and change issues, projects, comments and planning data.
- Read every page a read asks for, or fail with no partial output.
- Upload attachments, list the files an issue references and download one.
- Check configured issue requirements during creation and completion.
- Observe request attempts with an opt-in journal that stops after one hour.
- Apply and create only the labels the repository's label taxonomy declares, and list the labels that drift from it.

## Install

```bash
kendex add vanillagreencom/kendex --skill linear
```

## How it works

You configure credentials and the target team. Each command sends its reads and writes to Linear's GraphQL API and keeps no tracker data on disk, with one exception: a read given `--inventory FILE` writes one audit pass's team inventory to FILE, and later reads given that file answer from it (`issues --help`, `--inventory`). Client-pair authentication keeps its OAuth token in a per-user cache file, described under § Setup. A rate-limited request reports the time the request quota refills.

## Setup

Requires Bash 4.0 or newer, curl and jq.

1. Set the credentials in the project's private env file.
2. Set `LINEAR_TEAM` in `kendex.settings.toml`.
3. Run the installed `scripts/linear.sh auth-check --strict`.

A personal key can also be set in the kendex app, on this package's Customize tab.

Set non-secret keys in committed `kendex.settings.toml` under `[env]`; the key list with each default and what leaving it unset means is [kendex.settings.toml.example](kendex.settings.toml.example).

| Variable | Purpose |
|----------|---------|
| `LINEAR_APP_TOKEN` | Pre-minted application token, in the private env file or a secret store via `op://` |
| `LINEAR_CLIENT_ID` | OAuth application client ID, in the project's private env file |
| `LINEAR_CLIENT_SECRET` | OAuth application client secret, in the project's private env file |
| `LINEAR_API_KEY` | Personal API key fallback, in the project's private env file |
| `LINEAR_TEAM` | Team target |
| `LINEAR_JOURNAL_ITEM` | Known carrying issue identifier or `owner/repo#number` |
| `KENDEX_USER_EMAIL` | Your Linear account email address, in the project's private env file |

- `LINEAR_TEAM` targets creates and writes that do not address an issue. It is also the one team whose issues `linear.sh` creates or changes: [SKILL.md § Team Target](SKILL.md#team-target).
- An absent or invalid `LINEAR_JOURNAL_ITEM` stays unread.

- Set application credentials in `.env.local` unless `KENDEX_ENV_FILE` names another private file.
- Enable client credentials tokens in the application's Linear settings.

Credential selection and precedence, expiry and attribution: [references/authentication.md](references/authentication.md).

- On a host with the real client pair, run `scripts/linear.sh auth-mint`. It prints `access_token` and `expires_at` (epoch seconds) as JSON and writes no files. The fleet publishes the token as `LINEAR_APP_TOKEN` to its secret store and replaces it before expiry.
- Keep one minting host.

Client-pair token storage: [references/authentication.md § Client-pair token store](references/authentication.md#client-pair-token-store). Delete stale token files an earlier version left under a checkout's `.cache/linear/oauth/`.

Set `KENDEX_USER_EMAIL` to the address your Linear account signs in with. The app's Customize tab writes it to the private env file.

- With your email configured, `issues activate` can assign an unassigned issue to you.
- An orch-launched lane assigns nobody.
- `linear.sh issues --help` gives the assignment details.

`LINEAR_CACHE_ROOT` is retired with the local store: set in the environment or a project file, even empty, it fails every command with `linear-setting: retired=LINEAR_CACHE_ROOT`. Remove it.

## Licence

MIT, in the repository's LICENSE file.
