# Lane host

Read when writing a lane host provider, or when a step reads what `orch-runtime` asks a provider and how it reads the answer. A provider is an executable that runs lanes on a machine other than the control machine. The orch runtime calls it once per verb, with the verb as its first argument.

## Host selection

`ORCH_LANE_HOST` names the host for every lane launch, watch pass and close: empty or unset for `local` tmux windows on this machine, `claude-cloud` for Claude Code cloud sessions, or a provider's executable path, read from the working directory and never looked up on `PATH`.

`ORCH_VALIDATE_HOST` names, in the same forms, the host a `validate entry --host` run goes to. Unset, host runs are off.

A program outside the runtime calls a host through `orch-runtime host`:

```bash
orch-runtime host [--host HOST] resolve
orch-runtime host [--host HOST] capabilities
orch-runtime host [--host HOST] VERB ARGS...
```

- `--host` overrides `ORCH_LANE_HOST`.
- `resolve` prints the host, and `capabilities` its capability line (§ Host kinds).
- Any other verb takes a slot of its pool (§ Call bound), then the process becomes the provider, with `ORCH_LANE_HOST` naming itself.
- A refusal before any provider starts is one stderr line `orch-runtime: KEY FIELD=VALUE...`. Tell it from a provider's answer by that line, never by the status: a provider also exits `2`.

## Host kinds

A host declares its kind in one capability line of tab-separated `key=value` fields. Include each required key once and use a value from its set.

- The runtime answers the line itself for `local` and `claude-cloud`; `orch-runtime host --host HOST capabilities` prints any host's line.
- For a provider, the runtime runs the `capabilities` verb, which takes no slot.
- It refuses a malformed line or a non-zero exit and guesses none; every read of a lane on that host is then unreadable.

Each key, its values, and what the runtime does with it:

- `kind`: `local`, `ssh`, `claude-cloud`, `codex-cloud`. Nothing: callers act on the other keys.
- `launch`: `window`, `ssh`, `cloud-session`, `cloud-task`.
  - A provider launch runs only on `ssh`.
  - The account judge admits an account on a `cloud-session` host only with access to this checkout's repository.
  - The wake reaches a hosted lane only where `launch=ssh`.
- `channel`: `mailbox`, `session`, `task`. Declared, read by no caller.
- `files`: `local`, `verb`, `none`.
  - `verb`: the watch and the close read lane files, session rows and their prompt digests among them, through `cat`.
  - `none`: no lane file is read.
- `status`: `pane`, `verb`, `task`, `none`. `verb`: the watch, the wake and the close ask `status`.
- `pane`: `local`, `verb`.
  - `local`: the lane's window on the control machine holds the ssh client its harness runs under.
  - `verb`: the provider owns the harness's session; the runtime reads it through `capture` and types into it through `send`.
- `stop`: `window`, `verb`, `none`. The close's stop: `window` and `verb` end the harness by its record and its provider, `none` stops nothing.
- `relaunch`: `resume`, `fresh`. Declared, read by no caller.
- `park`: `verb`, `none`.
  - `verb`: the provider holds the `stop-sandbox` and `start` pair.
  - A relaunch that is not a park asks `list` and `start` only of a `verb` host.
  - A park asks `stop-sandbox --check`.
- `accounts`: `verb`, `none`. Declared, read by no caller: the account listing asks the `accounts` verb and reads exit `2` as absent.
- `pool`: `plan`, `cloud-credit`. The account judge's tier: a Claude row on a `cloud-credit` host is judged on cloud credit.
- `land`: `lane`, `handoff`. The `pr-watch` `disarmed` rule in [oversee-events.md](../references/oversee-events.md).
- `peer-mail`: optional, `verb` only. It selects `peer-append` for a hosted peer send or ask. A valid line with `files=verb` and no `peer-mail` selects legacy `append`.
- `validate`: optional, `verb` only. `verb`: the provider serves `validate`. `validate entry --host` refuses `host-validate-undeclared` for a host whose line names no `validate`.

## Provider protocol

Exit statuses:

- Exit `0` is the verb done.
- Exit `2` is an absent verb, and for `cat` a missing file.
- Other non-zero exits report failures on stderr. The `peer-append`, `start` and `stop` entries below describe their specific outcomes.

The recorded cause:

- A failed `capabilities`, `create`, `wait`, `start`, `cat`, `touch`, `put`, `status`, `capture`, `send`, `list`, `close`, `stop`, `stop-sandbox`, `validate` or `viewer-prefix` records one stderr line as its cause: the last line carrying a `fix=` field, else the first non-blank line, else `stderr=empty`.
- A `create` that exits `75` without `state=preparing` records `item-owned exit=75` and no stderr line, unless its stderr holds `lane-host-ssh: ownership-busy`, the ssh provider's lock: that create records `host-create-busy create exit=75` and its cause line.
- A `close` that exits `3` records no stderr line, only the path its `close-refused path=` line names, `unknown` without one.
- Print any notice before a `fix=` refusal; a refusal without `fix=` that follows other stderr output is not recorded.
- A `create` that answers, exit `0` or an accepted preparation, keeps its stderr in the launch observation's `create_stderr`, whatever later step of the launch fails. Each line is trimmed and blank lines are dropped, with no line parsed. Over 20 lines, it keeps the first 10 and the last 10, and `create_stderr_elided` counts the lines between.

The runtime reads a status of `128` or more, or no answer within its bound, as a call that may have acted. A launch that meets one on `create`, `wait` or `start` stays held at that step until a close supersedes it.

Each verb, its arguments, and its answer:

- `capabilities`, no arguments.
  - The host kind's capability line on stdout, exit `0`.
  - It reads no host state.
- `create --item ID --repo OWNER/REPO --harness claude|codex|pi|copilot --account CONFIG_DIR [--relaunch]`.
  - One stdout line of tab-separated fields.
  - Required and non-empty: `ssh-target=TARGET`, `path=WORKTREE`, `remote-prefix=PREFIX`.
  - Optional: `state=preparing` where the create returns before its preparation ends.
  - Optional: `pi-root=DIR` where a Pi lane runs under a Pi root other than `.pi/agent` under the host home.
  - Optional: `copilot-home=DIR` where a Copilot lane runs under a Copilot home other than `.copilot` under the host home.
  - Optional: `read-prefix=PREFIX` for a Copilot lane: the `remote-prefix` environment, its account and credential, without the step that records the lane's process group. The launch reads the host's Copilot model list under it (§ Launch on a provider).
  - Optional: `tree=unrebased` where a reused worktree stands on the item's own head because its rebase onto the base was aborted.
  - On `--relaunch`, reuse the worktree the host holds for the item.
  - Hold the item under a durable repository and item identity, so a retry reaches the same host.
  - Exit `75` with `state=preparing` is an accepted preparation; exit `75` without it is an item another session owns.
- `wait --item ID`.
  - Blocks until the preparation of an accepted `create` ends.
  - Exit `0` when the item is ready, with `tree=unrebased` on stdout where the reused tree was kept unrebased.
  - Any other status is a failed preparation, its cause on stderr.
- `cat --item ID PATH`.
  - The file's exact bytes on stdout, exit `0`.
  - A missing file exits `2`; any other failure exits non-zero and not `2`.
  - The provider may confine transfers to its development root.
- `touch --item ID`.
  - Exit `0` when the host answers.
  - The runtime asks it after a `cat` exits `2`, and reads that `2` as a missing file only once `touch` answers.
- `put --item ID PATH`.
  - Uses the same path policy as `cat`.
  - Writes stdin to the file with private permissions, creating its parent directory.
  - Stage the bytes beside the target and rename them over it only once the whole transfer has arrived.
  - A provider that crosses a network compares the staged byte count with the count the sender declared.
- `append --item ID PATH`.
  - Adds stdin to the file under the lock every writer of that file on that host takes, creating the file with private permissions.
  - A provider reaching a kendex checkout adds the bytes through that checkout's mailbox `scripts/lib/mailbox-append.sh`.
  - Close an unterminated last line first.
  - Count the staged bytes as `put` does.
  - A repeated mail envelope exits `4` with `duplicate id=FIRST` on stderr and adds nothing.
  - A failed append adds nothing.
  - Only append to a file several machines write; never read it and `put` it back.
- `peer-append --item overseer --repo PATH`, optional, takes one newline-terminated peer envelope on stdin.
  - The recipient's installed mailbox validates the checkout, envelope and controller, then appends using its mailbox lock. A network provider verifies that it received the complete envelope before appending.
  - Static SSH calls `lane-mail peer-receive --root PATH` on the recipient. Its stdin starts with the decimal byte count and a newline, then the envelope bytes.
  - Exit `0` prints `monitor=live` or `monitor=none` on stdout, followed by any reader notice. Exit `3` carries a mailbox refusal on stdout. Exit `4` prints `duplicate id=FIRST` on stdout, followed by the original envelope for a repeated answer. These outcomes keep transport diagnostics on stderr.
  - The validated `peer-mail=verb` declaration selects this operation. Every failure is reported on that route, including exit `2`.
- `read-many`, no arguments; stdin is a JSON array of `{"item": "ID", "path": "PATH"}` rows.
  - One JSON array on stdout, one row per request, in request order.
  - Each row holds the request's `item` and `path`, an integer `status` from `0` to `255` other than `69`, `data` with the file's bytes in padded standard base64, and an optional `error` string.
  - `status` `0` is a read file, an empty one included; `2` is a missing file; any other status is a failed read with empty `data`.
  - A failed transport to one host fails only that host's rows.
  - Exit `0` only after every row is written.
  - Read each path as `cat` does, under the mailbox rule below.
- `status --item ID --harness claude|codex|pi|copilot`.
  - `running` on stdout while a process of the named harness of the item's lane runs, else `exited`, exit `0`, signalling nothing.
  - An item the host holds nothing of answers `exited`.
  - Exit `75` with `status-unowned item=ID` on stderr is a host whose sandbox for the item is not the lane's own.
- `stop --item ID --harness claude|codex|pi|copilot`.
  - Ends the named harness's processes of the item's lane and prints `stopped item=ID processes=COUNT`; `processes=0` where none ran.
  - Exit `4` with `stop-worktree-removed item=ID` on stderr is an item whose own close-out removed its worktree.
  - Exit `75` with `stop-unowned item=ID` is an item whose sandbox the host does not hold for the lane.
  - Never type a shell command into the lane's session.
- `close --item ID [--merged]`.
  - Ends the item's sandbox and removes its worktree.
  - Exit `0` is the provider's word that the sandbox ends, even where its teardown has yet to show in `list`. The close asks no `list` after it.
  - Exit `0` with `kept=PATH` on stdout names the archive of the lane's records the provider kept; no `kept=` line reads as `kept=none`.
  - An item the host holds no sandbox for answers exit `0` with `closed=absent item=ID`.
  - Exit `3` with `close-refused path=PATH` on stderr or stdout refuses and keeps the checkout at `PATH`.
  - `--merged` is the caller's word that the item's pull request merged; a provider may then keep less of the archive, and every provider accepts the flag.
- `stop-sandbox --item ID` or `stop-sandbox --check --item ID`.
  - Stops the sandbox's compute and keeps its disk whole: worktree, harness session store, mailbox and `tmp`.
  - Print exactly `sandbox-stopped item=ID`.
  - `--check` changes nothing and prints `sandbox-stoppable item=ID` where the provider implements `stop-sandbox` and `start` for the item; a provider without the pair exits `2`.
  - `stop` has already stopped the lane's harness.
- `start --item ID`.
  - Brings a sandbox `stop-sandbox` stopped back up on the same disk and prints `sandbox-started item=ID`, also for a sandbox already up, as a relaunch asks of one a close kept up.
  - It starts no harness: the relaunch's `create --relaunch` follows.
  - An item the host holds no sandbox for exits non-zero with `item-unknown item=ID` on stderr, after any provider prefix. The relaunch then asks `create` without `--relaunch` for a fresh sandbox.
- `list`, no arguments.
  - One tab-separated row per host of this repository: `OWNER/REPO/ITEM`, state, age, name.
  - State `available` marks a host holding no item.
  - A provider can append fields.
  - No row for an item is a sandbox gone, and so is a row in a teardown state, `destroying` or `destroyed`, or in `exited`.
- `list --json`, optional, asked only of a `park=verb` host.
  - One JSON array of objects on stdout, exit `0`; exit `2` is a provider without the form.
  - A row's `label` is `OWNER/REPO/ITEM`, the plain row's first field.
  - A row carries `stop` only while the provider holds the sandbox stopped after the lane's harness ended: `{"at": UTC, "why": WORD}`, or `{"unreadable": TEXT}` where the provider cannot read its own record of the stop.
- `capture --item ID`.
  - Asked only of a `pane=verb` host.
  - The harness's visible screen as plain text on stdout, exit `0`.
- `send --item ID --file PATH` or `send --item ID --key KEY`.
  - Asked only of a `pane=verb` host.
  - `--file`: type the text of `PATH`, a file on the control machine, into the harness and submit it.
  - `--key`: press the one key `KEY`; the runtime sends `C-c`.
  - Exit `0` only after delivery. The runtime never resends input after another status.
- `viewer-prefix --item ID`.
  - Optional, asked only of a `pane=verb` host.
  - One non-empty stdout line, exit `0`: the command that opens a person's viewer on the harness's session.
  - Exit `2`: no viewer.
- `validate --item ID --run-id RUN --commit SHA --source DIR --run-dir RUNDIR --into STAGE`, asked only of a `validate=verb` host that `ORCH_VALIDATE_HOST` names.
  - Runs the run the lane's start wrote at `RUNDIR` on the host, at `SHA`, the HEAD of the lane's worktree `DIR`. The lane's start resolved its proof and holds its stage; the host runs only its executor.
  - Each call takes one step of the unit: it prepares the unit, launches the host's copy of the run, or reads the run's state. It waits for no run inside the call.
  - Exit `3` with `state=preparing` on stdout is a unit still preparing: `step=tree` and `step=runtime` moved it a step, and `step=building` is a build still running. Exit `3` with `state=running` is a run still going. The caller asks again with the same arguments, at once after a step that moved the unit and after its poll otherwise.
  - Exit `0` is a run that ended. Its folder stands at `STAGE`, a folder the call creates on the control machine. The host removes its copy, and names on stderr one it could not remove.
  - Exit `4` is a run the host's runtime refused to launch, its cause on stderr. The host removes the unit, and names on stderr one it could not remove. The caller asks no more steps.
  - A launch that may have started a run keeps the unit, and the next call reads that run.
  - Preparing a unit first stops and removes the item's other units: a lane holds one run at a time, so another unit of its item is a run it no longer holds.
- `validate --item ID --run-id RUN --stop`.
  - Ends the unit's run on the host and removes the unit, then exits `0` with `stopped item=ID run-id=RUN` on stdout, also where the host holds no unit.
  - A unit whose tree a runtime build still reads is removed once that build ends, since a build that loses its sources records its key failed; its run is stopped all the same.
  - The executor asks it at each end of the run it did not take from a clean hand-back: a recorded stop, a host that answered no call for the start's quiet time, a refused launch, a folder an earlier call staged, or a unit a hand-back kept.
  - A stop of the run by its directory (`validate stop --run-dir`), or a lane close's or a round recovery's stop of its worktree, asks it whatever holds the run, until the host has answered `stopped` once. Any other answer refuses the stop `stop-failed`. A lane close and a round recovery wait on that answer.
  - Such a stop asks the provider the stopping process's `ORCH_VALIDATE_HOST` names, and the item and run id the run's start recorded. The run folder names only the host's kind.
  - `validate entry --stop --worktree DIR` reads its settings from the worktree, which the lane writes, so it asks no provider and refuses `stop-failed` for a host run its host may still hold.
  - Once the run has ended, `validate entry --stop --release-host --worktree DIR` releases it and asks no host: `host-released released=operator` with its stop's cause, which the run's log also names. A run that has not ended keeps the refusal.
- `accounts`, no arguments.
  - Optional.
  - One line per account the provider holds a credential for, in § Accounts rows.
  - Exit `2`: the verb is absent.

A provider puts no bytes of a file it carries, a credential among them, in an argument list or a diagnostic. The bytes travel on stdin.

A provider that confines transfers refuses paths outside its development root before attempting the transfer, including a probe of `/`. It exits `1` with `cat-path-outside-root` or `put-path-outside-root` as the first diagnostic key of its cause line, optionally after a provider name and `: `. Providers that support home-relative paths can serve the default account files in § Launch on a provider.

A provider refuses `cat`, `put` and `append` on a path under `tmp/lane-mail/` before reading or writing, with a status other than `2`, when its `tmp/lane-mail` or item directory is a symlink or not a directory, or the file is a symlink or not a regular file.

A provider that judges a Pi lane's session rows on the host runs `agent-runtime rows verdict --kind lane --file -` with the rows on stdin.

## Who calls each verb

- The launch (`launch-lane` request):
  - It asks `capabilities`; on a relaunch, `start` for a parked lane, and for any other one on a `park=verb` host `list`, then `start` where the list names the item's sandbox; then `create`, and `wait` after an accepted create.
  - It asks `cat` and `put` for the host files of § Launch on a provider and § Launch record.
  - On a `pane=verb` host it asks `status`, `capture`, `viewer-prefix` and, after a failure, `stop`.
- The watch asks only of lanes in flight, apart from the heartbeat's list read below.
  - Each pass reads each host's `capabilities` once and makes one `read-many` per host for the hosted lanes' mailbox files under `<lane root>/tmp/lane-mail/<item>/`.
  - Its lane duty asks `cat`, `touch`, `status` on a `status=verb` host and `capture` on a `pane=verb` host.
  - Before a hosted relaunch it asks `stop`.
  - Each heartbeat asks `capabilities` of each provider host of an item's latest `running` or `stopped` record whose item no tracker read answered ended, and `list --json` of each such host that declares `park=verb`.
- The wake:
  - It asks `status` of a lane on a `pane=local`, `status=verb` host, and sends a `pane=verb` lane its line through `send --file`.
  - On a `files=verb` host for Claude Code, Codex or Copilot, it also reads `<root>/tmp/lane-mail/<item>/session-rows.jsonl` through `cat` and `touch`.
- `lane-mail` reads a hosted mailbox through `cat`, `touch` and `list`, and writes a hosted lane's mailbox through `append`.
  - A hosted peer send or ask asks `capabilities` before it writes. The validated `peer-mail=verb` declaration selects `peer-append`; a line with `files=verb` and no `peer-mail` selects legacy `append`.
  - A failure of the selected verb, an exit `2` included, is reported on that route and never retried through the other verb.
- The close (`close-lane` request), whose procedure is [lane-reach.md § Lane close](../references/lane-reach.md#lane-close):
  - It asks `stop`, `cat`, `list` and `close`; a park asks `stop-sandbox --check`, then `stop-sandbox`.
  - A Copilot lane on a `pane=verb` host is first sent `C-c` and `/exit` through `send`.
  - A Copilot lane on a `pane=local` host gets them in its window after the close transition, then is asked `stop` and `status`.
- The account listing asks `accounts`.
- The executor of an admitted start that `validate entry --host` sent to the host asks `capabilities` at the start, then `validate`, one call at a time, until the host's run ends.

## Call bound

Every provider call except `capabilities` first takes a slot in one of two pools per home, shared by every overseer and checkout one user runs on the machine:

| Pool | Verbs | Cap | Wait |
|---|---|---|---|
| long | `create`, `wait`, `start`, `close`, `stop`, `stop-sandbox`, `validate` | `ORCH_LANE_HOST_MAX_CALLS` | `ORCH_LANE_HOST_BUSY_WAIT_SECS` |
| short | every other verb | `ORCH_LANE_HOST_SHORT_MAX_CALLS` | `ORCH_LANE_HOST_SHORT_BUSY_WAIT_SECS` |

[settings.md § Fleet lanes](../references/settings.md#fleet-lanes) holds the settings.

`validate` waits on no run inside its call, so its slot is held for one step: the call reads the run's state and returns, and its caller waits between calls with no slot taken.

## Launch on a provider

- The launch admits a provider host only on a `launch=ssh` line.
- Every create, a relaunch included, gets the account's config directory as `--account`.
- The launch adds no variable to the remote line: the provider's `remote-prefix` carries every variable the harness needs on the host, its credential among them.

After `create`, and after `wait` for an accepted create, the launch reads and writes these host files through `cat` and `put`:

- Claude, under full bypass:
  - On a provider with home-relative transfers, set `skipDangerousModePermissionPrompt` to `true` in `.claude/settings.json` where absent and keep every other key.
  - A recorded `false` refuses the launch.
  - On a confined provider, the operator's bypass posture supplies consent through Claude's per-launch `--settings` overlay and leaves the account settings untouched.
- Pi:
  - `settings.json` under the Pi root (`pi-root=`, else `.pi/agent`) and `.pi/settings.json` in the worktree, then the pi-hooks carrier they load ([pi-runtime.md](../references/pi-runtime.md)).
  - A confined provider must supply an in-root `pi-root` for these checks.
- Copilot:
  - Under the Copilot home (`copilot-home=`, else `.copilot`): the context reader extension `extensions/kendex-lane-context/extension.mjs` and `enabledFeatureFlags.EXTENSIONS` in `settings.json`; then the lane-mail hooks registered in the worktree or the home.
  - A confined provider must supply an in-root `copilot-home` for these checks.
- Codex: none. Every Codex command the launch builds carries `--dangerously-bypass-hook-trust`.

The launch then verifies the launch record (§ Launch record).

A Copilot launch naming a model next reads the host's Copilot model list, through its own ssh exec rather than `cat`:

```text
ssh -T -o BatchMode=yes -o ConnectTimeout=SECS -- TARGET 'READ_PREFIX LINE'
```

- `READ_PREFIX` is `read-prefix`, and `LINE` starts `copilot --headless --stdio --no-auto-update` in the worktree with the session's environment, shell-quoted as one word.
- The lane starts with `--context long_context` only where that list prices the model the same at both tiers.
- A create with no `read-prefix`, or a read that fails, starts the lane with no `--context`, on the host's own `contextTier`, and records the cause on the launch as `copilot_model_list_unavailable`.

The launch then builds the command:

```text
ssh -t|-T -o BatchMode=yes -o ConnectTimeout=SECS -- TARGET 'PREFIX LINE'
```

- `TARGET` is `ssh-target` and `PREFIX` is `remote-prefix`.
- `LINE` is the harness command for the worktree at `path`, shell-quoted as one word, with the brief inline.
- `SECS` is `AGENT_RUNTIME_TMUX_VERIFY_SECS`.
- The client answers no host-key, password or passphrase prompt.

Where the command runs:

- On a `pane=local` host, the command runs with `-t` in the lane's window on the fleet's tmux server.
- On a `pane=verb` host, the command runs with `-T` on the control machine; `PREFIX` starts the harness in a session the provider owns, and returns.
  1. The launch then confirms the harness through `status` and `capture`.
  2. It asks `viewer-prefix`.
  3. It opens the lane's window with its option `@lane-viewer-command` set to the viewer line.

  Any failure from the exec onward asks `stop`.

A Pi lane on a `github-copilot/` model copies these variables from the login shell into the pane's tmux session before the harness starts: each one the `github-copilot` provider in the Pi root's `models.json` names in its key or header values, and `HTTPS_PROXY`, `HTTP_PROXY`, `NO_PROXY`, `NODE_EXTRA_CA_CERTS`, `SSL_CERT_FILE` and `NODE_USE_ENV_PROXY`. A provider puts those variables in the host login profile.

Every hosted launch starts the harness fresh. The lane's context continues through the item's handoff record on the host.

## Launch record

`create` writes two records under the clone's common git directory, which the worktree's `.git` file names:

| Record | Holds |
|---|---|
| `lane-mail/<item in lower case>` | The worktree path, one line: the lane's root. |
| `lane-launch/<item in lower case>.json` | `runtime`, the absolute path of the orch runtime binary built for the clone's sources; `identity_file`, the absolute path of the record the prefix writes of the lane's process group. |

The orch turn end reads `identity_file` to know the lane is hosted.

The launch verifies, in order:

1. That `<path>/.git` names a linked worktree's git directory under `<clone>/.git/worktrees/`.
2. That the marker holds the worktree path, writing it through `put` where it does not.
3. That the launch fields record names an absolute `runtime`.

It then writes two records in the worktree's git directory through `put`, each holding the worktree path for a lane that is one and empty for any other:

| Record | Holds the path for |
|---|---|
| `lane-refresh` | A refresh lane. |
| `lane-read-only` | A `read_only` lane, whose `record-push` then refuses ([lane-directive.md § A read-only launch](../references/lane-directive.md#a-read-only-launch)). |

A put of either that fails or never answers refuses the launch before the harness starts.

The first `append` that reaches the worktree makes its mailbox directory `tmp/lane-mail/<item>`.

## Accounts rows

The account listing asks `accounts` under `ORCH_LANE_HOST_ACCOUNTS_TIMEOUT_S` ([settings.md § Fleet lanes](../references/settings.md#fleet-lanes)). Each line is tab-separated `key=value` fields; the listing leaves out a line it cannot read, with a note.

| Field | Value |
|---|---|
| `account` | Required: the config directory `create --account` receives. |
| `harness` | Required: `claude`, `codex`, `pi` or `copilot`. |
| `status` | The listing's status word; `ok` when absent. |
| `detail` | The provider's text for the status, carried into the record as written. |
| `weekly-pct`, `model-pct`, `monthly-pct` | Whole numbers `0` to `100`. |
| `model-label` | The model window's label. |
| `weekly-resets`, `model-resets`, `monthly-resets` | Each window's reset timestamp. |
| `plan-ends`, `reserved`, `seat` | Words the judge reads whatever the figures: the plan's end, a reservation, and `seat=1` for an account an overseer or Jarvis session holds on any machine. |
| `credit-limit`, `credit-spent`, `credit-remaining`, `credit-expires` | A Pi API grant. |
| `credit-remaining`, `credit-available`, `credit-overage-limit-reached`, `credit-spend-control-reached` | A Codex credit. |

- Only `ok` and `rate_limited` rows are measured. A row whose usage read backs off says `rate_limited`, with its last reading's percentages while that reading is fresh. Any other `status` word leaves the account unmeasured.
- A `detail` starting `api-credit-` marks a Pi row as an API grant.
- A Pi API grant sits on a `harness=pi` row with no `monthly-pct`: all four fields together, dollars as non-negative decimals with at most two places, a limit above zero, the expiry a timestamp.
- A Codex credit sits on a `harness=codex` row: all four fields together, the balance a non-negative decimal, each flag `1` or `0`.
- A credit field on any other row makes the line unreadable.
- A `harness=pi` row with `monthly-pct` is a Copilot pool; its `account` is the Pi root that a Pi lane on that pool receives as `create --account`.
- A provider can append fields.

## Static SSH provider

`scripts/lane-host-ssh` binds each item to one SSH target and clone from a JSON inventory. `lane-host-ssh --help` is its contract: the inventory, the account files, the host preparation, and what each verb does. It lacks `wait`, `capture`, `send`, `viewer-prefix`, `stop-sandbox`, `start` and `accounts`, so a park on it refuses.

- Every verb that brings the clone up to date runs the clone's orch and agent-runtime setups right after that update: `create` on a create, a reuse and a relaunch alike, and `close` after it refreshes the clone. No runtime call after an update comes before the setup for the tree it runs in.
- A host with no Rust toolchain holds the orch runtime and agent-runtime binaries in the setup cache (`AGENT_RUNTIME_CACHE`).
- `close` exits `3` on changes it cannot save as render drift. Check and preserve needed files before asking it to close.
- Static SSH declares `peer-mail=verb`.
- For peer mail, reserve one inventory row with `item` set to `overseer`, `target` set to the recipient's SSH alias and `clone` set to the absolute path of its main checkout with mailbox and agent-runtime installed. The sender passes that same path as `peer-append --repo`. Keep the `repo` field equal to the inventory's repository, including when the recipient checkout belongs to a different repository. The existing absolute `account` field is required by the inventory and peer mail does not use it.
- The `overseer` row serves `peer-append`, `touch`, and `cat` and `read-many` for files directly in that checkout's overseer mailbox directory. Reads outside the directory fail with status `1`. The row is omitted from lane listings.
- For validation units, reserve one inventory row with `item` set to `validation`, `target` set to the host and `clone` set to a clone of the repository that no lane row names. Keep the `repo` field equal to the inventory's repository, and set the absolute `account` field the inventory requires, which `validate` does not use. `validate` runs every item's unit on that row, in a detached worktree under `<clone>/tmp/validate-host/`. Without the row, `validate` exits `1` with `item-unconfigured item=validation`.
- A unit runs the orch runtime its own tree builds, through that tree's `setup --detach`, never the clone's.

## Test provider

`tests/fixtures/lane-host` implements the protocol with fixed answers and a call log, for suites that run without SSH or a provider account.
