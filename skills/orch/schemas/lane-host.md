# Lane host

Read when writing a lane host provider, or when a step reads what `orch-runtime` asks a provider and what it makes of the answer. A provider is an executable that runs lanes on a machine other than the control machine. The orch runtime calls it once per verb, with the verb as its first argument.

## Host selection

`ORCH_LANE_HOST` names the host every lane launch, watch pass and close runs under:

| Value | Host |
|---|---|
| empty or unset | `local`: lanes run in tmux windows on this machine |
| `claude-cloud` | Claude Code cloud sessions |
| anything else | a provider: the path of an executable file, a relative path read from the working directory, never looked up on `PATH` |

A program outside the runtime calls a host through `orch-runtime host`:

```bash
orch-runtime host [--host HOST] resolve
orch-runtime host [--host HOST] capabilities
orch-runtime host [--host HOST] VERB ARGS...
```

`--host` overrides `ORCH_LANE_HOST`. `resolve` prints the host. `capabilities` prints the host's capability line (§ Host kinds). Every other verb takes a slot of its pool (§ Call bound), then the process becomes the provider: the arguments, stdin, stdout, stderr and exit status are the provider's own. The provider runs with `ORCH_LANE_HOST` naming itself.

`orch-runtime host` refuses before any provider starts, with one line `orch-runtime: KEY FIELD=VALUE...` on stderr:

| Key | Exit | Cause |
|---|---|---|
| `verb-invalid verb=` | 2 | a verb outside § Provider protocol |
| `host-local verb=` | 2 | a provider verb on `local`; the runtime does local work itself |
| `host-kind-verb kind=claude-cloud verb=` | 2 | a provider verb on `claude-cloud` |
| `host-unavailable path=` | 1 | the path is missing, a directory or not executable |
| `setting-invalid name= value=` | 1 | a pool setting outside its form (§ Call bound) |
| `slot-failed path=` | 1 | the slot directory, its lock or a slot file could not be written |
| `host-busy count= cap= verb= item=` | 1 | every slot of the pool stayed taken for the pool's wait |
| `provider-not-started path= cause=` | 1 | the provider could not be executed |

A caller tells these refusals from a provider's answer by that stderr line, never by the status: a provider also exits `2` for a missing file or an absent verb.

## Host kinds

Every place a lane runs is a host kind. A host declares its kind as one capability line: tab-separated `key=value` fields, each of the twelve keys below exactly once, each value from its key's set. The runtime answers the line for `local` and `claude-cloud` itself. For a provider it runs the provider's `capabilities` verb, taking no slot, and parses the answer. A line with a key missing, repeated or unknown, or a value outside its set, is refused as `capability-invalid key=KEY value=VALUE`. A provider whose `capabilities` exits non-zero is refused with its status and its stderr. No line is guessed for a host, and every read of a lane on a host whose line was refused is unreadable with that cause.

| Key | Values | What the runtime does with it |
|---|---|---|
| `kind` | `local`, `ssh`, `claude-cloud`, `codex-cloud` | Nothing: callers act on the other keys. |
| `launch` | `window`, `ssh`, `cloud-session`, `cloud-task` | A provider launch runs only on `ssh`; `cloud-task` refuses `kind-unbuilt kind=codex-cloud`; `cloud-session` on a provider refuses `cloud-session-invalid host=provider`; `window` refuses `host-capabilities-failed launch=window`. The account judge admits an account on a `cloud-session` host only with access to this checkout's repository. The wake reaches a hosted lane only where `launch=ssh`. |
| `channel` | `mailbox`, `session`, `task` | Declared, read by no caller. |
| `files` | `local`, `verb`, `none` | `verb`: the watch and the close read lane files, a Pi lane's session rows among them, through `cat`. `none`: no lane file is read. |
| `status` | `pane`, `verb`, `task`, `none` | `verb`: the watch, the wake and the close ask `status`. |
| `pane` | `local`, `verb` | `local`: the lane's window on the control machine holds the ssh client its harness runs under. `verb`: the provider owns the harness's session; the runtime reads it through `capture` and types into it through `send`. |
| `stop` | `window`, `verb`, `none` | The close's stop: `window` and `verb` end the harness by its record and its provider, `none` stops nothing. |
| `relaunch` | `resume`, `fresh` | Declared, read by no caller. |
| `park` | `verb`, `none` | Declared, read by no caller: a park asks `stop-sandbox --check` instead. |
| `accounts` | `verb`, `none` | Declared, read by no caller: the account listing asks the `accounts` verb and reads exit `2` as absent. |
| `pool` | `plan`, `cloud-credit` | The account judge's tier: a Claude row on a `cloud-credit` host is judged on cloud credit. |
| `land` | `lane`, `handoff` | The `pr-watch` `disarmed` rule in [oversee-events.md](../references/oversee-events.md). |

The lines the runtime and the shipped provider declare:

| Kind | `launch` | `channel` | `files` | `status` | `stop` | `relaunch` | `park` | `accounts` | `pool` | `land` | `pane` |
|---|---|---|---|---|---|---|---|---|---|---|---|
| `local` | `window` | `mailbox` | `local` | `pane` | `window` | `resume` | `none` | `none` | `plan` | `lane` | `local` |
| `ssh` (`scripts/lane-host-ssh`) | `ssh` | `mailbox` | `verb` | `verb` | `verb` | `resume` | `none` | `none` | `plan` | `lane` | `local` |
| `claude-cloud` | `cloud-session` | `session` | `none` | `none` | `none` | `fresh` | `none` | `none` | `cloud-credit` | `handoff` | `local` |

`codex-cloud` is a kind a line can declare, and no launch for it is built.

## Provider protocol

Exit `0` is the verb done. Exit `2` is an absent verb, and for `cat` a missing file. Every other non-zero status is the verb failing, its cause on stderr. A status of `128` or more, or no answer within the runtime's bound, is read as a call that may have acted: a launch that meets one on `create`, `wait` or `start` stays held at that step until a close supersedes it.

| Verb | Arguments | Answer |
|---|---|---|
| `capabilities` | none | The host kind's capability line on stdout, exit `0`. It reads no host state. |
| `create` | `--item ID --repo OWNER/REPO --harness claude\|codex\|pi\|copilot --account CONFIG_DIR [--relaunch]` | One stdout line of tab-separated fields: `ssh-target=TARGET`, `path=WORKTREE` and `remote-prefix=PREFIX`, each required and non-empty; `state=preparing` from a create that returns before its preparation ends; `pi-root=DIR` where a Pi lane runs under a Pi root other than `.pi/agent` under the host home; `copilot-home=DIR` where a Copilot lane runs under a Copilot home other than `.copilot` under the host home; `tree=unrebased` where a reused worktree stands on the item's own head because its rebase onto the base was aborted. `--relaunch` is passed when the launch re-enters a standing lane record: reuse the worktree the host holds for the item. A create holds the item under a durable repository and item identity, so a retry reaches the same host. Exit `75` with `state=preparing` is an accepted preparation. Exit `75` without it is an item another session owns, refused as `item-owned`. A line missing a required field is refused as `host-line-invalid`; any other failure is `host-create-failed`. |
| `wait` | `--item ID` | Blocks until the preparation an accepted `create` started ends. Exit `0` when the item is ready, with `tree=unrebased` on stdout where the reused tree was kept unrebased. Any other status is a failed preparation, `host-wait-failed`, its cause on stderr. |
| `cat` | `--item ID PATH` | The file's exact bytes on stdout, exit `0`. A missing file exits `2`. Any other failure exits non-zero and not `2`. A relative `PATH` resolves under the host user's home. |
| `touch` | `--item ID` | Exit `0` when the host answers. The runtime asks it after a `cat` exits `2`: a `cat` `2` is a missing file only once `touch` answers. |
| `put` | `--item ID PATH` | Writes stdin to the file, creating its parent directory, with private permissions. Stage the bytes beside the target and rename them over it only once the whole transfer has arrived, so a failed transfer replaces nothing. A provider that crosses a network compares the staged byte count with the count the sender declared, since a sender that dies mid-feed ends the stream like a normal end of input. |
| `append` | `--item ID PATH` | Adds stdin to the file under a lock taken on the host that holds it, creating the file with private permissions. The lock is the one every writer of that file on that host takes; a provider reaching a kendex checkout adds the bytes through the mailbox package's `scripts/lib/mailbox-append.sh` in that checkout. Close an unterminated last line before adding the bytes. Count the staged bytes as `put` does. A repeated mail envelope exits `4` with `duplicate id=FIRST` on stderr and adds nothing. A failed append adds nothing. A file several machines write is only ever appended: a read followed by a `put` drops a line another machine added in between. |
| `read-many` | none; stdin is a JSON array of `{"item": "ID", "path": "PATH"}` rows | One JSON array on stdout, one row per request in request order. Each row holds the request's `item` and `path`, an integer `status` from `0` to `255` other than `69`, `data` the file's bytes in padded standard base64, and an optional `error` string. `status` `0` is a read file, an empty one included; `2` is a missing file; any other status is a failed read, with empty `data`. A failed transport to one host fails only that host's rows. Exit `0` only after every row is written. A reply short a row, a row naming another file, a status of `69`, bytes on a failed row or `data` that is not base64 fails the whole batch. Read each path as `cat` reads it, under the mailbox rule below. |
| `status` | `--item ID --harness claude\|codex\|pi\|copilot` | `running` on stdout while a process of the named harness of the item's lane runs, else `exited`, exit `0`, signalling nothing. An item the host holds nothing of answers `exited`. Exit `75` beside the stderr words `status-unowned item=ID` is a host whose sandbox for the item is not the lane's own. Any other status is a failed read, and the lane stays unjudged. |
| `stop` | `--item ID --harness claude\|codex\|pi\|copilot` | Ends the named harness's processes of the item's lane and prints `stopped item=ID processes=COUNT`, the count of processes signalled; a lane with none running answers `processes=0`. Exit `4` beside the stderr words `stop-worktree-removed item=ID` is an item whose worktree its own close-out removed; exit `75` beside `stop-unowned item=ID` is an item whose sandbox the host does not hold for the lane. Never type a shell command into the lane's session. |
| `close` | `--item ID [--merged]` | Ends the item's sandbox and removes its worktree. Exit `0` with `kept=PATH` on stdout names the archive of the lane's records the provider kept; no `kept=` line is read as `kept=none`. An item the host holds no sandbox for is closed: exit `0` with `closed=absent item=ID`. Exit `3` with `close-refused path=PATH` on stderr or stdout refuses, keeping the checkout `PATH` names. Any other status fails the close, `host-close-failed`. `--merged` is the caller's word that the item's pull request merged, passed on a full close of an item its tracker ended completed whose cycle record carries the merge or whose branch `worktree merged` reads merged; a provider may then keep less of the archive, and every provider accepts the flag. |
| `stop-sandbox` | `--item ID` or `--check --item ID` | Stops the sandbox's compute, keeping its disk whole: worktree, harness session store, mailbox and `tmp`. Print `sandbox-stopped item=ID`; the runtime reads the sandbox as stopped only on that exact stdout. `--check` changes nothing and prints `sandbox-stoppable item=ID` where the provider implements `stop-sandbox` and `start` for the item; a provider without the pair exits `2`. The lane's harness is already stopped through `stop` before this verb runs. |
| `start` | `--item ID` | Brings a sandbox `stop-sandbox` stopped back up on the same disk and prints `sandbox-started item=ID`; a sandbox already up answers the same line. The harness is not started: the relaunch's `create --relaunch` follows. |
| `list` | none | One tab-separated row per host of this repository: `OWNER/REPO/ITEM`, state, age, name. State `available` marks a host holding no item. A provider can append fields. The runtime reads an item's row by its first field ending in `/ITEM`, in any case, outside an `available` row; no such row is a sandbox gone. |
| `capture` | `--item ID` | Asked only of a `pane=verb` host. The harness's visible screen as plain text on stdout, exit `0`. Any other status is a failed read, `capture-failed`, never a screen. |
| `send` | `--item ID --file PATH` or `--item ID --key KEY` | Asked only of a `pane=verb` host. `--file`: `PATH` is a file on the control machine; type its text into the harness and submit it. `--key`: press the one key `KEY`; the runtime sends `C-c`. Exit `0` only after delivery. Any other status is read as a send that may have typed part of the input, and the runtime does not send that input again. |
| `viewer-prefix` | `--item ID` | Optional, asked only of a `pane=verb` host. One non-empty stdout line, exit `0`: the command that opens a person's viewer attached to the harness's session. Exit `2`: no viewer. An empty or multi-line answer is `host-viewer-invalid`; any other status is `host-viewer-failed`. |
| `accounts` | none | Optional. One line per account the provider holds a credential for, in § Accounts rows. Exit `2`: the verb is absent. |

A provider puts no bytes of a file it carries, a credential among them, in an argument list or a diagnostic: the bytes travel on stdin.

A provider refuses `cat`, `put` and `append` on a path under `tmp/lane-mail/`, before reading or writing and with a status other than `2`, when its `tmp/lane-mail` or item directory is a symlink or not a directory, or the file is a symlink or not a regular file.

Before `send` types into a Pi lane, the runtime has judged the lane idle from its `capture` and, on a `files=verb` host, its session rows. A provider that judges a Pi lane's rows itself on the host reads them with `agent-runtime rows verdict --kind lane --file -`, the rows on stdin.

## Who calls each verb

- The launch (`launch-lane` request) asks `capabilities`, then `start` for a parked lane, `create`, `wait` after an accepted create, `cat` and `put` for the host files of § Launch on a provider and § Launch record, and on a `pane=verb` host `status`, `capture`, `viewer-prefix` and, after a failure, `stop`.
- The watch asks only of lanes in flight: a `done`, `stopped` or `parked` record's host is never asked. Each pass reads each host's `capabilities` once and makes one `read-many` per host of the hosted lanes' mailbox files under `<lane root>/tmp/lane-mail/<item>/`, which `lane-mail drain --host` reads from the unpacked batch. Its lane duty reads lane files through `cat` and `touch`, asks `status` of each lane on a `status=verb` host, and `capture` where `pane=verb`. Before a hosted relaunch it asks `stop`.
- The wake asks `status` of a lane on a `pane=local`, `status=verb` host, and sends a `pane=verb` lane its line through `send --file`.
- `lane-mail` reads a hosted mailbox through `cat`, `touch` and `list`, and writes it through `append`.
- The close (`close-lane` request) asks `stop`, `cat`, `list` and `close`, and for a park `stop-sandbox --check` then `stop-sandbox`. A Copilot lane on a `pane=verb` host is first sent `C-c` and `/exit` through `send`. A Copilot lane on a `pane=local` host is typed `C-c` and `/exit` in its window after the close transition, then asked `stop` and `status`, so a refused stop is reported after the harness has exited. On a full close the close skips the stop on `stop`'s `4` with `stop-worktree-removed` or `75` with `stop-unowned`, noting `stop-skipped item=ID harness=HARNESS cause=worktree-removed` or `cause=unowned`; a keep or a park refuses `stop-failed` on either, or holds that `pane=local` Copilot lane's close `unconfirmed` with it. The close procedure is [lane-reach.md § Lane close](../references/lane-reach.md#lane-close).
- The account listing asks `accounts`.

## Call bound

Every provider call takes a slot first, in one of two pools per home, shared by every overseer and checkout one user runs on the machine. `capabilities` takes none.

| Pool | Verbs | Cap | Wait |
|---|---|---|---|
| long | `create`, `wait`, `start`, `close`, `stop`, `stop-sandbox` | `ORCH_LANE_HOST_MAX_CALLS`, default `4` | `ORCH_LANE_HOST_BUSY_WAIT_SECS`, default `30` |
| short | every other verb | `ORCH_LANE_HOST_SHORT_MAX_CALLS`, default `4` | `ORCH_LANE_HOST_SHORT_BUSY_WAIT_SECS`, default `30` |

A cap is a whole number of at least `1` and a wait a whole number of seconds, neither with a leading zero. A slot is a file under `~/.cache/orch/host-slots/long` or `short` naming its owner's process; a slot whose owner is gone is reclaimed by the next take. A call still at the cap after the wait runs nothing and is refused `host-busy`. A provider process started outside the runtime takes no slot.

## Launch on a provider

The launch admits a provider host only on a `launch=ssh` line. Before `create`, it refuses a Pi lane whose model bills a Claude seat as `host-pi-claude-seat`. It passes the account's config directory as `create --account` on every create, a relaunch included, and adds no variable to the remote line: the provider's `remote-prefix` carries every variable the harness needs on the host, its credential among them.

After `create`, and `wait` where the create was accepted, the launch reads and writes these host files through `cat` and `put`, and fails before any window where one is refused:

| Harness | Host files |
|---|---|
| Claude, under the bypass posture | `.claude/settings.json` under the host home: `skipDangerousModePermissionPrompt` set `true` where absent, every other key kept; a recorded `false` refuses `bypass-refused`. |
| Pi | `settings.json` under the Pi root (`pi-root=`, else `.pi/agent`) and `.pi/settings.json` in the worktree, then the pi-hooks carrier they load; the keys it refuses with are in [pi-runtime.md](../references/pi-runtime.md). |
| Copilot | Under the Copilot home (`copilot-home=`, else `.copilot`): the context reader extension `extensions/kendex-lane-context/extension.mjs` and `enabledFeatureFlags.EXTENSIONS` in `settings.json`, refused as `no-context-reader`; then the lane-mail hooks registered in the worktree or the home. |
| Codex | None. Every Codex command the launch builds carries `--dangerously-bypass-hook-trust`, so the lane's hooks need no recorded approval. |

The launch then verifies the launch record (§ Launch record) and builds the command:

```text
ssh -t|-T -o BatchMode=yes -o ConnectTimeout=SECS -- TARGET 'PREFIX LINE'
```

`TARGET` is `ssh-target`, `PREFIX` is `remote-prefix`, and `LINE` is the harness command for the worktree at `path`, shell-quoted as one word, with the brief inline. `SECS` is `AGENT_RUNTIME_TMUX_VERIFY_SECS`. The client answers no host-key, password or passphrase prompt.

- On a `pane=local` host the command runs with `-t` in the lane's window on the fleet's tmux server; a client that closes fails the launch `pane-gone`.
- On a `pane=verb` host the command runs with `-T` on the control machine, and `PREFIX` starts the harness in a session the provider owns and returns. Exit `1` to `127` is `host-exec-failed`. The launch then confirms the harness through `status` and `capture` within `AGENT_RUNTIME_TMUX_VERIFY_SECS`, refusing `host-harness-exited` or `host-harness-unconfirmed`. Only then it asks `viewer-prefix` and opens the lane's window, which runs no harness, with the window option `@lane-viewer-command` set to the viewer line. A failure from the exec on asks `stop` before the launch fails.

A Pi lane on a `github-copilot/` model runs a session-environment step before the harness, in the same login shell. Inside tmux it copies into the pane's tmux session, from the login shell, each variable the `github-copilot` provider in the Pi root's `models.json` names in its key or header values, and `HTTPS_PROXY`, `HTTP_PROXY`, `NO_PROXY`, `NODE_EXTRA_CA_CERTS`, `SSL_CERT_FILE` and `NODE_USE_ENV_PROXY`. A `models.json` jq cannot read ends the shell with `lane-session-env: models-unreadable path=PATH`, and a refused copy with `lane-session-env: set-failed name=NAME`, each on stderr, before the harness starts. A provider puts those variables in the host login profile.

Every hosted launch starts the harness fresh: the lane's context continues through the item's handoff record on the host.

## Launch record

`create` writes two records under the clone's common git directory, the directory the worktree's `.git` file names:

| Record | Holds |
|---|---|
| `lane-mail/<item in lower case>` | The worktree path, one line: the lane's root. |
| `lane-launch/<item in lower case>.json` | `runtime`, the absolute path of the orch runtime binary built for the clone's sources; `identity_file`, the absolute path of the record the prefix writes of the lane's process group. |

The orch turn-end reads `identity_file` to know the lane is hosted. The launch verifies the records rather than trusting them:

1. It reads `<path>/.git` through `cat`. A file it cannot read is `host-gitfile-unread path=`; one that does not name a linked worktree's git directory under `<clone>/.git/worktrees/` is `host-gitfile-invalid path= value=`.
2. It reads the marker through `cat`, and where it does not hold the worktree path, writes it through `put` and reads it back. A read, write or read-back that fails is `marker-failed path= cause=`.
3. It reads the launch fields record. A missing record is `host-runtime-unbuilt path= cause=record-missing`; a record naming no absolute `runtime` is `host-runtime-unbuilt path= cause=runtime-unnamed`; a record that is not JSON is `marker-failed`.
4. For a refresh lane, it writes the worktree path to `lane-refresh` in the worktree's git directory through `put`.

The mailbox directory `tmp/lane-mail/<item>` in the worktree is made by the first `append` that reaches it.

## Accounts rows

The account listing asks `accounts` under `ORCH_LANE_HOST_ACCOUNTS_TIMEOUT_S`, default `30`, `0` for no bound. It caches an answer, and an exit `2`, under its usage window; a failure is never cached. Any other non-zero status is `host-accounts-unreadable host= exit=`, and a refused slot `host-busy ... step=accounts`. A line the parser cannot read is left out with a `host-account-invalid account=ACCOUNT field=FIELD` note, keeping only its words.

Each line is tab-separated `key=value` fields:

| Field | Value |
|---|---|
| `account` | Required: the config directory `create --account` receives. |
| `harness` | Required: `claude`, `codex`, `pi` or `copilot`. |
| `status` | The listing's status word; `ok` when absent. Only `ok` and `rate_limited` rows are measured: a row whose usage read backs off says `rate_limited` with its last reading's percentages while that reading is fresh, and any other word leaves the account unmeasured, so a pick passes over it. |
| `detail` | The provider's text for the status, carried into the record as written. A `detail` starting `api-credit-` marks a Pi row as an API grant. |
| `weekly-pct`, `model-pct`, `monthly-pct` | Whole numbers `0` to `100`. |
| `model-label` | The model window's label. |
| `weekly-resets`, `model-resets`, `monthly-resets` | Each window's reset timestamp. |
| `plan-ends`, `reserved`, `seat` | Words the judge reads whatever the figures: the plan's end, a reservation, and `seat=1` for an account an overseer or Jarvis session holds on any machine. |
| `credit-limit`, `credit-spent`, `credit-remaining`, `credit-expires` | A Pi API grant, on a `harness=pi` row with no `monthly-pct`: all four together, dollars as non-negative decimals with at most two places, a limit above zero, the expiry a timestamp. |
| `credit-remaining`, `credit-available`, `credit-overage-limit-reached`, `credit-spend-control-reached` | A Codex credit, on a `harness=codex` row: all four together, the balance a non-negative decimal, each flag `1` or `0`. |

A credit field on any other row makes the line unreadable. A `harness=pi` row with `monthly-pct` is a Copilot pool: `account` is the Pi root a Pi lane on that pool receives as `create --account`. A provider can append fields.

## Static SSH provider

`scripts/lane-host-ssh` binds each item to one SSH target and clone from a JSON inventory; `lane-host-ssh --help` is its contract, the inventory, the account files and the host preparation among it. It implements every verb but `wait`, `capture`, `send`, `viewer-prefix`, `stop-sandbox`, `start` and `accounts`, on which its parser exits `2`; a park on it refuses `park-refused reason=provider-unsupported`.

- `create` fast-forwards an existing clone's base branch or clones the repository, and refuses a checkout without its committed render as `render-missing` or `render-untracked`; it runs no `kendex refresh` and no `update-pi`. It copies `.env.local` from `LANE_HOST_SSH_SOURCE`, the account's `setup-token` for Claude or `auth.json` for Codex and Pi, and nothing for Copilot, at every create. It merges `ACCOUNT/lane-host/.claude.json` into the host home's `.claude.json` and copies `ACCOUNT/lane-host/config.toml` (Codex) or `trust.json` (Pi) into the remote account where present. It creates the worktree with `--hosted`, at the clone's one hosted path that `worktree path --hosted` prints, adding `--reuse --keep-on-conflict` where the item's tree stands, and builds the clone's orch runtime and agent-runtime through their own setups. A setup answers a binary already standing in its cache before it looks for `cargo`, so a host with no Rust toolchain holds both binaries in that cache (`AGENT_RUNTIME_CACHE`).
- Its `remote-prefix` sets `ORCH_STATE_DIR` to the worktree's `tmp` and the harness's home variable to the row's account, then runs `agent-runtime process lead`, which makes the lane's process group and records its leader in `<clone>/.git/lane-host-pid`.
- `status` and `stop` read that group alone; `stop` first stops the worktree's validation runs through the clone's orch runtime. A clone holding neither a marker naming the item nor its worktree answers `processes=0`, `exited` and `closed=absent`; a marker missing or naming another item beside the item's worktree refuses `stop-unowned`, `status-unowned` or `close-unowned`, exit `75`.
- `create`, `status`, `stop` and `close` hold one lock beside the clone; an overlapping call exits `75` with `ownership-busy`, which the launch refuses as `host-create-busy`.
- `close` saves render-only drift as a binary patch under the clone's `tmp`, restores the rendered paths and syncs the base, refusing any other dirty path with exit `3`. Where `ORCH_ARCHIVE_ROOT` is set, it archives the remaining `tmp` records there and prints `kept=PATH`. It then removes the worktree. It accepts `--merged` and keeps the whole archive.
- `append` stages the bytes and hands them to the clone's `mailbox-append.sh`; a clone whose library lacks the repeat check delivers with `append-library-outdated path=LIBRARY repeat-check=skipped` on stderr.
- `.kendex-lock.json` arrives with the clone; the provider copies no lock file.

## Test provider

`tests/fixtures/lane-host` implements the protocol with fixed answers and a call log, for suites that run without SSH or a provider account.
