# Lane host

The `scripts/lane-host` command selects a provider from `ORCH_LANE_HOST`. `resolve` prints `local` when the setting is empty or unset. Any other value is an executable script path. Credentials do not select a provider. `open-terminal --host SPEC`, or this setting, launches a lane through `create`; `oversee-watch --hosted` reads a hosted lane's mailbox and workflow state through `cat` and closes the lane through `close`.

## Provider protocol

| Verb | Arguments | Result |
|---|---|---|
| `create` | `--item ID --repo OWNER/REPO --harness claude\|codex\|pi --account CONFIG_DIR [--relaunch] [--reuse]` | One stdout line: `ssh-target=TARGET`, `path=WORKTREE`, `remote-prefix=PREFIX`, separated by literal tabs. |
| `cat` | `--item ID PATH` | Exact file bytes on stdout. A missing file exits `2`. Any other failure exits nonzero and not `2`, so a caller can tell an unwritten file from a read it could not make. |
| `put` | `--item ID PATH` | Write stdin to the file with private permissions, through a temporary file beside it that is renamed over the target once the whole transfer has arrived. A provider that crosses a network compares the bytes it staged against the count the sender declared before renaming, because a sender that dies mid-feed closes the stream and the receiver reads that as an ordinary end of input. A transfer that fails never replaces the file, and no reader meets a half-written one. No credential bytes in argv or diagnostics. |
| `touch` | `--item ID` | Keep the host alive, or probe a static host with no idle expiry. |
| `close` | `--item ID` | Refuse with exit `3` when the clone or the remote worktree has uncommitted files, with a stderr line holding `close-refused path=PATH` naming that checkout. Archive remaining `tmp` records before deletion and print `kept=PATH` on stdout. An archive failure stops close. |
| `list` | none | Tab-separated repository/item, state, age, name for each configured host of this repository. State `available` marks a host holding no item. A provider can append fields. |

- `create` uses a durable repository/item identity. A retry or reuse reaches the same host. An existing owner returns `75`; `--relaunch` requests reuse. Other create failures produce `host-create-failed` through the dispatcher. No failure starts a local lane. The caller runs `create` for one host one at a time, so a provider reads, merges and writes shared host files during `create` without a lock.
- The dispatcher passes all provider bytes and exit codes unchanged. Provider verbs under `local` refuse with `host-local` and exit `2`; the launcher owns local work. That is the same `2` a provider uses for a missing file, so a caller reading `cat`'s `2` as an unwritten file confirms the host with `touch` first: every dispatcher refusal fails that verb too.
- `cat` and `put` on a path under `tmp/lane-mail/` refuse, with a status other than `2` and before reading or writing, when its `tmp/lane-mail` or item directory is a symlink or not a directory, or the file is a symlink or not a regular file; every other path is unaffected.
- `TARGET` opens an SSH shell session. The caller then types `PREFIX 'cd WORKTREE && exec START_COMMAND'` with shell quoting. `PREFIX` belongs to the provider. The caller does not add the local `CLAUDE_CONFIG_DIR` environment prefix. The local account path remains the claim identity.
- The provider fetches or clones the repository and writes the remote clone's `.env.local`. A fresh clone receives the source clone's `.cache/linear` when present, excluding lock files. The provider runs `kendex update-pi --leave`, then `kendex refresh --yes --leave` when `kendex.toml` exists. It calls the installed worktree command to create the item, with `--reuse` for relaunch or reuse only when the item worktree exists. Before the first turn, the provider places the caller's per-harness pre-approval, such as folder trust and hook approval, where that harness reads it. A failed preparation remains a failed create.
- `.kendex-lock.json` stays gitignored and local to each machine. A provider neither copies nor commits it.

## Codex hook approval

A provider that places Codex hook approval writes one `hooks.state` entry in the account's `config.toml` per `command` handler and per `mcp_tool` handler outside `session_end`; `prompt` and `agent` handlers, and `mcp_tool` handlers on `session_end`, get no entry. An entry whose `trusted_hash` differs from the value Codex computes leaves the hook unapproved.

| Item | Value |
|---|---|
| Key | `<hooks.json path>:<event label>:<group index>:<handler index>`; the event label is snake_case, such as `pre_tool_use`, not the hooks.json name `PreToolUse`; both indices are zero-based positions in hooks.json |
| Hash input | `{"event_name": <event label>, "matcher": <matcher>, "hooks": [<normalized handler>]}`, with every field still unset after normalization omitted; the normalized `timeout` is always present |
| Digest | `sha256:` followed by the SHA-256 hex of the hash input as compact JSON, keys sorted at every level |
| `command` handler | `{"type": "command", "command", "timeout", "async"}`, `async` as written |
| `mcp_tool` handler | `{"type": "mcp_tool", "server", "tool", "input", "timeout"}`, plus `statusMessage` when set |

- Timeout: `session_end` and `interrupt` hash the timeout clamped to 1..3, 1 when absent. Every other event hashes the timeout floored at 1, 600 when absent, so a timeout of 0 hashes as 1.
- Matcher: `user_prompt_submit`, `stop` and `interrupt` never hash a matcher, even when the group sets one. Every other event hashes the group's matcher as written, an empty string included.
- Extra fields: a `command` handler adds `statusMessage` when set, and `additionalContextLimit` only when it is set to a value other than 2500 on `pre_tool_use`, `post_tool_use`, `session_start`, `user_prompt_submit` or `subagent_start`. `commandWindows` never enters the hash.
- Key path: the path Codex builds, `<dir>/.codex/hooks.json`, made absolute without resolving symlinks. A linked Git worktree keys under the main checkout's `.codex/hooks.json`.

These rules mirror Codex 0.154.0: `codex-rs/hooks/src/engine/discovery.rs` `hook_hash`, `codex-rs/config/src/fingerprint.rs` `version_for_toml`, and `codex-rs/config/src/loader/mod.rs` for the worktree key. Check a later Codex release against those files, never against this section.

## Static SSH implementation

`scripts/lane-host-ssh --help` owns the inventory shape, source selection, account files and static-host lifecycle. The inventory binds each item to a target and clone before dispatch; it performs no automatic allocation. The host already has SSH access, Git, gh, Bash, kendex and the selected harness. The reference requires Python 3.8 or later on the control machine.

`close` checks the clone and any remaining worktree for uncommitted files. It archives their remaining `tmp` records on the control machine and prints the saved path before delegating worktree removal to the installed worktree command. No remaining `tmp` means no archive and no `kept` line. A worktree already removed by lane cleanup does not prevent close, but its deleted records cannot be recovered. Close keeps the static machine, source clone and account files. `list` reports configured hosts, including available ones; static hosts have no age or expiry timer.

`tests/fixtures/lane-host` implements the same protocol with fixed output and a call log. Launcher and watcher suites can install it without SSH or a provider account.
