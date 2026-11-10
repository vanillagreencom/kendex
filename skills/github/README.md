# GitHub pull requests

A CLI for GitHub pull requests, reviews and CI results. Coding agents can read PR state, reply to findings and submit permitted changes from the shell.

## Features

- Read PR files, comments and review threads.
- Post replies and resolve review threads.
- Manage labels and inspect failed CI jobs.
- Check merge requirements and merge eligible PRs.
- Check, live before a merge, that review replies name an issue or a reason.
- Compare PR branches for conflicts and dependencies.
- Report open pull requests that need attention.
- Run Git over HTTPS with the caller's GitHub authentication.

## Install

```bash
kendex add vanillagreencom/kendex --skill github
```

## How it works

You run a command through `scripts/github.sh`. The CLI reads your project settings and selects the configured GitHub credentials. It calls GitHub and returns the requested result. Write commands report the outcome of the requested action.

The pull-request watcher, `scripts/pr-watch.sh`, reads GitHub's review state. It reports open threads, objections, approved pull requests that nothing will merge, and approvals that do not arrive within the wait period. It also reports an unapproved lanes-app refresh as soon as that head's CI aggregate passes.

## Setup

Requires authenticated `gh`, `jq` and `perl`; every time-bounded subprocess starts through perl. The `op` CLI is required only for credentials stored as 1Password references.

Set non-secret defaults in `kendex.settings.toml` under `[env]`; keep tokens in `.env.local`. A value set in the parent process wins over project files.

Authenticate `gh`, or supply `GH_TOKEN` / `GITHUB_TOKEN`. Set `GH_BOT_TOKEN` for a separate bot account, as a literal token or an `op://vault/item/field` reference.

Choose the review bot login, issue-id pattern and verification command in [kendex.settings.toml.example](kendex.settings.toml.example). That file also declares the command timeouts and watcher wait. Use `github.sh --help`, `pr-watch.sh --help` and `git-https-auth --help` for command behavior and defaults. The HTTPS helper's help covers `KENDEX_GITHUB_GIT_HTTPS_FALLBACK` and the credential boundary selected by `ORCH_GH_READ_TOKEN_FILE`.

## Licence

MIT, in the repository's LICENSE file.
