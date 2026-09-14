# Lane host

The `scripts/lane-host` command selects a provider from `ORCH_LANE_HOST`. `resolve` prints `local` when the setting is empty or unset. Any other value is an executable script path. Credentials do not select a provider. The existing launcher and watcher retain their local behavior until their host integration is installed.

## Provider protocol

| Verb | Arguments | Result |
|---|---|---|
| `create` | `--item ID --repo OWNER/REPO --harness claude\|codex\|pi --account CONFIG_DIR [--relaunch] [--reuse]` | One stdout line: `ssh-target=TARGET`, `path=WORKTREE`, `remote-prefix=PREFIX`, separated by literal tabs. |
| `cat` | `--item ID PATH` | Exact file bytes on stdout. A missing file exits `2`. Any other failure exits nonzero and not `2`, so a caller can tell an unwritten file from a read it could not make. |
| `put` | `--item ID PATH` | Write stdin to the file with private permissions, through a temporary file beside it that is renamed over the target once the whole transfer has arrived. A provider that crosses a network compares the bytes it staged against the count the sender declared before renaming, because a sender that dies mid-feed closes the stream and the receiver reads that as an ordinary end of input. A transfer that fails never replaces the file, and no reader meets a half-written one. No credential bytes in argv or diagnostics. |
| `touch` | `--item ID` | Keep the host alive, or probe a static host with no idle expiry. |
| `close` | `--item ID` | Refuse with exit `3` when the remote worktree is dirty. Archive remaining `tmp` records before deletion and print `kept=PATH` on stdout. An archive failure stops close. |
| `list` | none | Tab-separated repository/item, state, age, name for each configured host of this repository. A provider can append fields. |

- `create` uses a durable repository/item identity. A retry or reuse reaches the same host. An existing owner returns `75`; `--relaunch` requests reuse. Other create failures produce `host-create-failed` through the dispatcher. No failure starts a local lane. The caller runs `create` for one host one at a time, so a provider reads, merges and writes shared host files during `create` without a lock.
- The dispatcher passes all provider bytes and exit codes unchanged. Provider verbs under `local` refuse with `host-local` and exit `2`; the launcher owns local work. That is the same `2` a provider uses for a missing file, so a caller reading `cat`'s `2` as an unwritten file confirms the host with `touch` first: every dispatcher refusal fails that verb too.
- `TARGET` opens an SSH shell session. The caller then types `PREFIX 'cd WORKTREE && exec START_COMMAND'` with shell quoting. `PREFIX` belongs to the provider. The caller does not add the local `CLAUDE_CONFIG_DIR` environment prefix. The local account path remains the claim identity.
- The provider fetches or clones the repository and writes the remote clone's `.env.local`. A fresh clone receives the source clone's `.cache/linear` when present, excluding lock files. The provider runs `kendex update-pi --leave`, then `kendex refresh --yes --leave` when `kendex.toml` exists. It calls the installed worktree command to create the item, with `--reuse` for relaunch or reuse only when the item worktree exists. Before the first turn, the provider places the caller's per-harness pre-approval, such as folder trust and hook approval, where that harness reads it. A failed preparation remains a failed create.
- `.kendex-lock.json` stays gitignored and local to each machine. A provider neither copies nor commits it.

## Static SSH implementation

`scripts/lane-host-ssh --help` owns the inventory shape, source selection, account files and static-host lifecycle. The inventory binds each item to a target and clone before dispatch; it performs no automatic allocation. The host already has SSH access, Git, gh, Bash, kendex and the selected harness. The reference requires Python 3.8 or later on the control machine.

`close` checks the clone and any remaining worktree for uncommitted files. It archives their remaining `tmp` records on the control machine and prints the saved path before delegating worktree removal to the installed worktree command. No remaining `tmp` means no archive and no `kept` line. A worktree already removed by lane cleanup does not prevent close, but its deleted records cannot be recovered. Close keeps the static machine, source clone and account files. `list` reports configured hosts, including available ones; static hosts have no age or expiry timer.

`tests/fixtures/lane-host` implements the same protocol with fixed output and a call log. Launcher and watcher suites can install it without SSH or a provider account.
