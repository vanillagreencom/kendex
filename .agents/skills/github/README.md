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

Use `GH_BOT_TOKEN` for a configured bot credential, including a 1Password `op://vault/item/field` reference. `scripts/github.sh --help` defines token selection, setting defaults and timeout rules. `scripts/pr-watch.sh --help` defines the watcher quiet period through `PR_REVIEW_WAIT_SECS`.

## Licence

MIT, in the repository's LICENSE file.
