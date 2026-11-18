# Lane directive

Read the matching section when [oversee.md § Lane directive](../workflows/oversee.md#lane-directive) cannot choose an account or launch a lane, and § Recovery relaunch when [oversee.md § Recovery relaunch](../workflows/oversee.md#recovery-relaunch) brings back a dead, walled or handed-off lane. A refusal prints `orch-runtime: KEY field=value ...` on stderr; a launch that failed after it was recorded carries the same key as its observation's `cause`. This reference gives each key's remedy. The settings named here are documented in [kendex.settings.toml.example](../kendex.settings.toml.example).

## No lane has room

The account judge is `.agents/skills/orch/scripts/orch-runtime lane pick --fleet --harness [HARNESS] --native-model [MODEL]`, with `--lane [CONFIG_DIR]` to judge one named account. Every launch, turn-end mark and succession pick asks the same judge. Read `.result.answer` and `.result.exit`:

| Answer | Exit | Meaning |
|---|---|---|
| `lane` | 0 | An account has room; `.result.record.config_dir` names it. |
| `none`, `walled`, `reserved`, `retired`, `excluded` | 3 | No eligible account, or the named one is refused. |
| `no-record` | 4 | No listed account is the named directory. |
| `unmeasured` | 5 | Nothing measured the account, or nothing bills the model's provider. |
| `cloud-repo-unset` | 7 | A cloud-session account has no access to this checkout's repository under `ORCH_LANE_CLOUD_REPOS`. |
| `unjudged` | 1 | The judge could not read its inputs; `.result.record.cause` names what. Never a verdict. |

The candidates are the accounts `AGENT_RUNTIME_ACCOUNT_DIRS` lists. With none set, the roster notes `accounts-unconfigured key=AGENT_RUNTIME_ACCOUNT_DIRS`. A listed directory the listing cannot read refuses as `account-dir-unreadable path= cause=`. Room is judged on the account's weekly, monthly or per-model plan windows and on its API or Codex credits. The 5-hour window is no wall.

On a walled answer, read the roster, `.agents/skills/orch/scripts/orch-runtime lane roster`. Each `account` line carries `status=`, `verdict=` and `headroom_pct=`. Wait only for accounts over the threshold whose status is `ok`. Answer every other status as this table says, and report it to the operator:

| Status | Remedy |
|---|---|
| `expired` | The login is dead, or a Codex renewal failed in a way the renewal table of [renewal.rs](../../agent-runtime/runtime/src/accounts/renewal.rs) lists as `expired`. Log in again, or run the command `detail` names. |
| `plan_ended` | The plan ended or the organization disabled subscription access. It reads `walled` with no reset: never wait on it. Only the owner restoring the plan or the access, or taking the account out of the fleet, brings it back. |
| `rate_limited` | An endpoint answered HTTP 429. Where the host holds an eligible figure, the account is judged on it, with its age in `usage_age_s`. With a null `headroom_pct` it has no usable figure: launch on another account. Never log in again. |
| `unreachable` | An endpoint answered 5xx or could not be reached, or another tool held the credentials lock. Launch on another account. Never log in again. |
| `refused` | A usage endpoint answered another code outside 2xx, 401 and 403 among them; `detail` carries it. Launch on another account. Never log in again. |
| `no_credentials`, `no_usage_data` | The listing found no credential or no usage reading. Report it; launch on another account. |
| `error` | A step on this machine failed, a renewal among them. A Claude account's `error` for a missing OAuth client id needs `AGENT_RUNTIME_CLAUDE_CLIENT_ID`, set once per host. |

An account with room on the roster can still be refused by its projection. The judge charges the binding window with the burn of the fleet's lanes live on the account and the candidate lane, up to the window's reset; the record's `projected_headroom_pct` carries the result. API and cloud grants carry no projection. Wait for a lane on that account to close, or launch on another account.

A seat is the account this fleet's overseer runs on, or a provider row marked `seat=1`. The judge keeps room on a seat for its overseer, and a seat with too little reads `seat-reserve`. A `none` answer's `seats` names each seat it left out, with `need`, the room the seat keeps, and its `projected_headroom_pct`. Wait until that projected room passes `need`, or launch on another account. A Copilot pool pick, through Copilot or Pi, never takes an account as a seat.

A Codex account past its plan windows still has room while its credit balance is above `AGENT_RUNTIME_CODEX_CREDIT_FLOOR` and it has reached neither its overage limit nor its spend control: its `account` line reads `verdict=room binding_bucket=credits`. A Codex account read walled has failed one of those; the record's `credits` carries the balance and the three judgements. Its windows still reopen at `binding_resets_at`.

### Pi picks

A Pi pick on a `github-copilot/` model is judged on the Copilot pool, read from the lane host's `accounts` row for the Pi root ([lane-host.md § Provider protocol](../schemas/lane-host.md#provider-protocol)). Read `orch-runtime lane pick --fleet --harness pi --native-model [MODEL]` with `--lane [PI_ROOT]`; its record carries the pool's `monthly_pct`, `headroom_pct` and `measured_through`. `AGENT_RUNTIME_COPILOT_POOL` states a pool for a Pi root no provider row reads, used where the root's own Copilot login yields no reading. An `unmeasured` answer whose `refusal.cause` is `provider-unmeasured` means no reading measured the pool: repair the provider's read, whose row `orch-runtime lane roster` shows with its `status` and `detail`, or state the pool. Never wait it out. A walled pool reopens at its `binding_resets_at`. A walled stated pool moves only when the owner restates it: report it to the operator.

A Pi pick on a `pi-claude/` model is a Claude pick on the Claude seats. A Pi pick on an `anthropic/` model reads only the provider's API-credit rows and spends the grant with the earliest expiry above `AGENT_RUNTIME_CLOUD_CREDIT_FLOOR`. A refused grant carries `cause=api-credit` and no retry time. A local host reads no API credit. An `unmeasured` answer with no `refusal`, naming `harness` and `model`, is a model whose provider nothing bills: launch it on a model of a billed provider.

## Lane preference

`ORCH_LANE_PREFERENCE` lists `harness[@host]:model:effort` entries in order, under the grammar of [kendex.settings.toml.example](../kendex.settings.toml.example). The walk is `.agents/skills/orch/scripts/orch-runtime lane walk --fleet`. It classifies each entry's model through `kendex tier-model`, judges the entry's account through the account judge on its harness, host and model, and takes the first entry the judge gives an account. An entry with `@host` is judged on that host; one without it on `ORCH_LANE_HOST`.

| Option | Use |
|---|---|
| `--lane [DIR]` | Judge every entry on one account, a directory or a listed alias. |
| `--replaces [ITEM_KEY]` | On a relaunch: leave that lane's charge out and take no cloud session. |
| `--source-harness [HARNESS]`, `--source-flags [WORDS]` | Pass over an entry whose harness cannot carry the permission posture of the asking session: `entry-permission-unwritable` or `entry-permission-untransferable`. |

Read `.result.answer`:

- `lane`: `.result.chosen` names the entry's `harness`, `host`, `model`, `class`, `effort`, `account` and the judge's `record`. The launch request takes them.
- `none`: every entry was passed over. `.result.skipped` lists each with the judge's word as `reason`. `.result.walled` and `.result.unmeasured` count what the judge read. `.result.unread` names the entries it could not read; a reset does not answer those, so repair the readings they name.
- `held`: the final entry is marked `:last`, a last choice such as a costlier seat. The walk asked each earlier passed-over entry again at `--max-pct 100`, and one had room or was unread. `.result.last_choice` names the marked entry and `.result.room` the earlier one with room. Wait as § No lane has room says.

An entry the judge reads walled, reserved, retired or excluded is passed over. One it could not read, unmeasured or with no repository access is passed over and listed in `unread`. A judge that answers nothing refuses the walk as `account-unjudged`, naming the entry and the step. An invalid entry refuses as `preference-invalid` before any pick.

A cloud-session entry is taken only for a Claude launch, under the judge's credit floor and repository rule. A Codex entry returns an account on its credits only when no Codex account has plan room: plan windows reset and credits do not, so the judge ranks every account with plan room first.

The request carries the chosen `harness`, `model`, `effort` and `account`, the `class` with its `class_reason`, and the entry's `host` where it names one other than `local`. A request naming an `account` must name its `model` and its `effort` (§ Launch gate). A request naming no `account` and no `model` runs the harness's default and records none.

## Launch gate

A launch request is judged in one transition before anything is written. Its effect then prepares and opens the lane. The two refuse in different places.

### Before anything is written

The transition's refusals end the `op` at exit 1 with `ok: false` and the refusal line on stderr. Nothing is recorded.

| Key (fields) | Meaning | Remedy |
|---|---|---|
| `request-invalid` | The request does not parse; an `obligation` of another shape among the causes. | Write the request again (§ Obligation lineage). |
| `host-unsupported` (`kind`, `surface`) | The kind is none of `local`, `ssh`, `claude-cloud`, or the surface is not `tmux`. | Launch on a supported host. |
| `harness-unknown` (`harness`, `supported`) | The harness is none of `claude`, `codex`, `copilot`, `pi`. | Name one of the four. |
| `permission-unrepresentable` (`harness`, `permission`) | The `permission` word is none of the harness's spellings, or part of a two-word spelling. | Name a spelling the harness takes, or leave `permission` out to run the `AGENT_RUNTIME_LAUNCH_PERMISSION` posture. |
| `launch-model-missing`, `launch-effort-missing` (`harness`, `lane`, `spellings`) | A request naming an `account` names no model, or no effort. A Pi model `provider/id:level` names its effort. | Name the model and effort the account was judged on. |
| `repo-invalid` (`repo`) | The `repo` is no repository GitHub issues. | Name `OWNER/REPO`. |
| `launch-class-missing` (`item`, `harness`) | A first launch names no `class` and `class_reason` pair, or names one alone, or a word that is no class. | Name both, under [skill-rules.md § Model class](skill-rules.md#model-class). A relaunch naming neither keeps the record's. |
| `class-unverified` (`class`, `harness`) | The request names no `model`, so no model shows the class. | Name the model. |
| `launch-class-missed` (`item`, `class`, `cause`) | A launch below `standard` of an item whose attempt below it missed. | Launch at `standard` or above. |
| `cap-reached`, `cap-unreadable` | The cap (§ Caps). | § Caps. |
| `account-spent` (`item`, `account`) | The `account` is the request's own `exclude_account`, the account a wall spent. | Choose another account. |
| `obligation-conflict` (`item`) | The `obligation` differs from the record's binding. | Report the contradiction to root (§ Obligation lineage). Never rewrite the binding. |
| `lane-live` (`item`, `status`) | The item's record is `preparing` or `running`. | End the lane first (§ Recovery relaunch). |
| `harness-live` (`item`, `pid`), `harness-unreadable` (`item`, `pid`, `cause`) | The recorded harness, or the detached turn its `wake` names, still runs or cannot be read. | End it first; a launch never starts a second session beside one. |
| `overseer-foreign` (`item`, `repo`, `overseer`, `route`) | The `mail_root` is a checkout of another repository than the fleet's, and `ORCH_CONNECTED_REPOS` does not list it. | Launch from that repository's fleet, or list it in `ORCH_CONNECTED_REPOS`, as `route` says. |
| `overseer-unjudged` (`cause`, `path`) | The binding could not be read. | Repair what `cause` names. Never launch around it. |
| `item-foreign` (`repo`, `route`) | A `github` item of another repository than the checkout's, or a `linear` item whose key is not the `LINEAR_TEAM`'s. | File it in its own tracker and follow `route` and [peer-mail.md](peer-mail.md#addressing). |
| `item-repo-unresolved` (`tracker`, `team`) | The checkout's repository or the team's key could not be read. | Repair that read. |
| `item-ineligible` (`item`, `cause`) | The item is a container, by its children or its `agent:multi` label outside an in-PR bundle. | Launch its unblocked children. |
| `launch-blocked` (`item`, `blockers`), `launch-blocked-unread` (`item`, `read`) | The [Ancestor gate](skill-rules.md#ancestor-gate) found an open blocker on a `linear` item or a container ancestor, or could not read one. | Merge or complete the blockers, or repair the tracker read. Never launch around it. |
| `launch-overlap` (`item`, `file`, `holder`) | A live lane of the same repository holds the file and is in its review, or owns a pull request. | Launch once that lane stops, or name the file in `in_scope` where the brief adds to it append-only. |
| `holder-unreadable` (`holder`, `read`), `holders-unreadable` (`repo`, `read`), `touched-unreadable` (`read`) | A holder's identity, touched set or stage, the repository's open pull requests, or the candidate's own touched set could not be read. | Repair the read the key names. |
| `join-unreachable` (`item`, `holder`, `route`) | The holder a launch would join is hosted or a cloud session. | Launch once that lane stops. |
| `join-unsent`, `join-tier-narrower` | The join's brief did not reach the holder's mailbox, or the joined set needs a wider cycle than the holder's tier. | Repair the mailbox, or launch once the holder stops. |
| `tier-narrower` (`item`, `requested`, `judged`, `cause`), `tier-unjudged` (`item`, `requested`, `cause`) | The brief requests a cycle narrower than its touched set earns, or the tier arm could not answer. | Brief the judged cycle, or repair the cause. |
| `account-walled`, `account-reserved`, `account-retired`, `account-unmeasured`, `account-unjudged` (`item`, `account`, what the judge read) | A request with `judge_account: true` named an account the judge refuses for its model. `account-unjudged` also carries `account-excluded`, `cloud-repo-unset` or the judge's own cause. | Read the answer as § No lane has room does, then choose another account through [oversee.md § Lane directive](../workflows/oversee.md#lane-directive) step 3. Never the same one. |
| `brief-unreadable` (`path`, `cause`) | The `brief_file` could not be read. | Write the brief and pass that path. |

### A joined launch

A first launch whose touched set meets a live lane of the same repository before that lane's review joins it: the reply's `op` is `joined`, naming `item` and `holder`. Nothing is launched and no slot is charged. The holder's record carries the joined item, and the brief reaches the holder's mailbox as a directive opening `joined item=[ITEM] holder=[HOLDER]`. The holder ships both items.

### After the lane is recorded `preparing`

The effect's refusals come after the transition recorded the lane `preparing` with its launch intent. The intent settles `failed`, the record reads `stopped`, and the intent's observation carries the key as `cause` with the values it acted on. Under `--effect-exit` the reply's `settled` intent carries that observation; `.agents/skills/orch/scripts/orch-runtime state inspect --fleet` shows it among the fleet's intents. Fix what it names, then send the same request again: it relaunches over the stopped record.

| Cause (fields) | Remedy |
|---|---|
| `cwd-missing`, `home-missing` (`path`) | The `mail_root`, or the home the account or the Pi root names, is no directory. Create or repair it. |
| `harness-binary-missing` (`program`) | Install the harness, or name it in `AGENT_RUNTIME_HARNESS_BINARIES` as `harness=/absolute/path`. |
| `config-unreadable`, `home-path`, `trust-refused`, `home-link`, `home-entry` (`harness`, `path`) | The launch could not record the worktree's trust in the account home. Repair the home at `path`. |
| `bypass-refused` (`harness`, `path`) | A Claude launch under the bypass posture whose `settings.json` records `skipDangerousModePermissionPrompt: false`. The account's owner removes that answer, or the lane launches without the bypass word. |
| `home-relative` (`home`), `no-context-reader` (`file`, `detail`, `detail_cause`) | A Copilot home that is no absolute path, or whose context reader could not be installed ([copilot-runtime.md § Account setup](copilot-runtime.md#account-setup)). Repair what `file` names. |
| `permission-mismatch` (`harness`, `posture`, `word`) | The `permission` is the harness's bypass word under `AGENT_RUNTIME_LAUNCH_PERMISSION=native`. Drop the word or name a narrower one. |
| `tmux-session-unresolved`, `tmux-session-missing` (`session`, `socket`) | § Tmux session. |
| `session-owned-elsewhere`, `session-store-unreadable` | A relaunch's bound session belongs to another directory, or the destination home's store could not be read. The same request meets the same refusal: repair the store, or report the session to the operator. |
| `marker-item-invalid`, `marker-git-failed`, `marker-unsafe` and the marker's write refusals (`item`, `path`) | The lane's marker under the worktree's common git directory could not be written. Repair that git directory. |

### Harness gate

A `cause` that begins with a harness gate's word is the gate that admits only a lane whose compaction is off and whose turns its hooks record (agent-runtime `effects/prepare/gate.rs`). The repairs live with each harness:

- Pi, [pi-runtime.md § Lane mailbox wake (Pi)](pi-runtime.md#lane-mailbox-wake-pi): `compaction-on`, `pi-settings-unreadable`, `pi-carrier-unreadable`, `pi-carrier-unresolved`, `pi-selection-unresolved`, `unsupported-for-oversee harness=pi reason=no-window-read`, `pi-mail-wake-missing` and `pi-mail-wake-off`. After the repair, send the item's `launch-lane` request again, as `retry=launch-lane` says.
- Copilot, [copilot-runtime.md § Account setup](copilot-runtime.md#account-setup): `unsupported-for-oversee harness=copilot` with `reason=no-context-hooks`, `hooks-disabled`, `hooks-unjudged` or `hooks-unreadable`. Install the three lane-mail hooks through kendex, switch them back on, or repair kendex.
- `host-pi-claude-seat`: a hosted Pi lane on a `pi-claude/` model, for which the host protocol carries no Claude seat. Launch it locally, or on a `github-copilot/` or `anthropic/` model.
- `home-unresolved`: a local Copilot or Pi launch resolved no home to judge. Name the account.

### Hosted launch

A hosted launch reads the provider's capability line first; a line that does not declare `launch=ssh` fails as `host-capabilities-failed`, `kind-unbuilt kind=codex-cloud` or `cloud-session-invalid host=provider`. A request naming no `account` or no `repo` fails `host-request-incomplete` before the provider's `create`. After `create`, the provider's refusal is the `cause` as the provider gave it, and a hosted Pi or Copilot lane meets the harness gate on the host's own files. `marker-failed`, `host-gitfile-unread`, `host-gitfile-invalid` and `host-runtime-unbuilt` (`path`, `cause`) name a launch record on the host that the provider's `create` did not leave whole: report it to the provider's owner.

A provider step that gave no answer holds the launch open instead of failing it: the observation's `note` is `host-start-unknown`, `host-create-unknown` or `host-exec-unknown`, with the `cause` and the provider `at`. The provider may hold the item's worktree. Launch the item again, and the provider's `create` reuses it, or close the lane through [lane-reach.md § Lane close](lane-reach.md#lane-close). A launch that failed after the provider started or created the sandbox records `sandbox: standing`, and the lane keeps charging the cap until a close confirms the sandbox gone.

### Cloud launch

A cloud request fails `cloud-brief-missing` with no `brief_file`, and `cloud-create-refused` with the CLI's first line where it created no session. A cloud launch held as `cloud-create-unknown`, `worktree-create-unknown` or `worktree-push-unknown` has no process left to answer it, and its intent stays open. Read the held launch with `orch-runtime state inspect --fleet`. Where its observation or `CloudCreate` phase carries `answer_by`, wait until that time before checking claude.ai/code for a session on the item's branch. Check again immediately before relaunching the item. A close that answers `intent-open` leaves the launch standing: wait for its owner to end and reconcile it; do not launch beside it. Settle the lane with the runtime close, which supersedes the held launch:

```json
{"op": "close-owned-resources", "item": "[ITEM_KEY]", "terminal": {"verdict": "[completed|canceled]", "source": "[SOURCE]"}}
```

Use `terminal` where the item is finished, and the `no_landing` ground of § Recovery relaunch to relaunch it.

## Brief file

A launch's brief is a file. Write it with the harness's file tool under the checkout's `tmp/` and name its absolute path as the request's `brief_file`. Keep the file until the launch settles. A launch with no `brief_file` starts the lane on the start workflow for its item, which continues from the item's handoff record.

The launch closes a local or hosted lane's brief with three texts, each on a line of its own, each once; text the brief already carries is left as written:

1. The unattended words, `runtime/src/watch/unattended.txt`.
2. For Claude Code and Copilot CLI, the line that arms the lane's mailbox monitor ([watch-delivery.md § Lane mailbox monitor](watch-delivery.md#lane-mailbox-monitor)). Codex and Pi get none.
3. The output-mode sentence of [skill-rules.md § Lane Output](skill-rules.md#lane-output), for the mode the launch's settings resolve; a hosted lane's is its control host's.

A hosted relaunch whose provider kept the item's tree on its own head (observation `tree: unrebased`) also closes the brief with the sentence that the retained work is not rebased and the restack is the lane's. A cloud launch sends the brief as the session's description, closed by the cloud session words, `runtime/src/effects/cloud-session.txt`, in place of the unattended words.

The brief is every harness's first message: Claude Code, Codex and Pi take it as the line's last word, and Copilot CLI as the value of `-i`. It opens the lane's workflow, `/orch start [ITEM]` or the tier's verb, in the form its harness takes ([oversee.md § Lane directive](../workflows/oversee.md#lane-directive)). A first launch reads the tier the brief states, its verb or its one `item-tier` line, into the record's `tier` and `tier_inputs`; a relaunch keeps the record's.

## Obligation lineage

The root launch or continuity directive supplies the item's original obligation and its accepted parent mapping: the four-field object of [workflow-state.md § Oversee state](../schemas/workflow-state.md#oversee-state) `lanes[].obligation`, with `repo` and `item`, and `parent_repo` and `parent_item` named together or null together. Carry it as the `launch-lane` request's `obligation`.

- A record that binds none takes the stated object. A request naming none keeps the record's binding.
- A first launch naming `repo` and no `obligation` records the item as its own parent: a fresh item.
- A request naming another object than the record's binding refuses `obligation-conflict`. An object missing a key, naming another key, or naming one parent field alone refuses `request-invalid`. Both refuse before anything is written.
- A record with no accepted mapping stays unknown. Never reconstruct one from a title, a current parent or the checkout's repository.
- A surface-2 record carries the binding as [oversee.md § Lane record](../workflows/oversee.md#lane-record) writes it.

Keep the binding through same-item launches, retries, relaunches, park and resume, account or model recovery, and context handoff. Reparenting does not rewrite the original parent. A replacement item names its predecessor's complete object as its launch request's `obligation`, or in its surface-2 record; its own item key stays separate. A cross-fleet transfer carries its accepted mapping where no retained record reaches the successor. Report a contradiction to root rather than rewriting a known binding. A separate obligation needs a new tracker item or an explicit root disposition. The close copies the lane's binding to its merge cycle's `cycle.obligation`, null for unknown lineage.

## Caps

The transition counts its cap before it writes anything: a `claude-cloud` request against `ORCH_OVERSEER_CLOUD_LANES`, default 10, and every other kind, a cloud session's landing lane included, against `ORCH_OVERSEER_LANES`, default 4. Each count reads its own kind alone. No cap bounds the lanes on one account: the account judge chooses by headroom.

A lane charges one slot while one of these holds, and the reply's `admission` lists each charge with its `reason`:

| Reason | The lane's record |
|---|---|
| `live` | Its recorded `launch` harness runs. |
| `wake` | The detached turn its `wake` names runs. |
| `preparing` | It reads `preparing` under an open launch intent. |
| `reservation` | An unexpired `reservation` stands. |
| `sandbox` | Its hosted launch failed after the provider started or created a sandbox, and no close confirmed the sandbox gone. |
| `session` | A cloud session reads `running`. |
| `unknown` | An identity cannot be read, or a `running` or `preparing` record names none. |

A `stopped`, `parked` or `done` record charges nothing beyond those. A relaunch leaves its own record's `launch` and `reservation` out of the count, so it replaces the lane it holds.

- `cap-reached` (`occupancy`, `cap`, `lanes`, `setting`): launch once a lane that cap counts closes. The overseer writes no counting loop: it sends the request again once a lane closes.
- `cap-unreadable` (`source`, `path`): a source the count reads failed. Fix it; never launch around it.

A request's `over_cap` admits one deliberate launch past its cap, and the record keeps the word.

## Tmux session

Every lane window opens on the fleet's tmux server, the socket the runtime's own `$TMUX` names or the user's default, in one session: the one `AGENT_RUNTIME_TMUX_SESSION` names, else the fleet state's `tmux.session`, which the first confirmed launch records. The record's `window` names it as `SESSION:WINDOW`, the window named for the item. kendex creates no session. A launch with neither refuses `tmux-session-unresolved`, and a session the server does not hold refuses `tmux-session-missing`, naming `session` and `socket`: set `AGENT_RUNTIME_TMUX_SESSION`, or create that session.

## Recovery relaunch

A relaunch is the item's `launch-lane` request sent again over its standing record, from the checkout the launch ran from.

1. End the lane. The record must not be in flight, and no recorded harness or detached turn may still run: a relaunch over one refuses `lane-live`, `harness-live` or `harness-unreadable` before anything is written. End it through its own close-out, [lane-reach.md § Mail the wake cannot deliver](lane-reach.md#mail-the-wake-cannot-deliver), or the runtime close in step 2.
2. Run the runtime close where the lane still stands. It retires the attempt and keeps the item's work, the worktree and its validation runs among it. Write the request with the harness file tool:

   ```json
   {"op": "close-owned-resources", "item": "[ITEM_KEY]", "no_landing": {"reason": "[REASON]", "source": "overseer"}}
   ```

   ```bash
   .agents/skills/orch/scripts/orch-runtime op --fleet --effect-exit --request [REQUEST_FILE]
   ```

   Exit 0 is a stop confirmed, the record `stopped`. Exit 3 is a close that failed, its cause in the observation. Exit 75 is a close still open, which its reconcile settles. The close stops the harness only on proof that it is idle or gone: a working lane fails `not-idle`, and a lane holding an unanswered ask fails `ask-unanswered` whatever it reads. Add `"interrupt": true` inside `no_landing` only for a session that is unusable, as after a model switch; it waives the idle proof alone. An open close lists what still stands in its observation's `remaining`. A `pane` row marked `unaddressable: true` names a pane with no tmux server: find it with `tmux list-panes -a`, end what it runs by hand, and report the open intent to the operator.

3. Compose the relaunch request from the record and send it as § Launch gate's request is sent:

| Field | Value |
|---|---|
| `item`, `harness`, `tracker`, `repo`, `model`, `effort`, `permission` | The record's, or the replacement's choice. |
| `mail_root` | The record's; a hosted record's `checkout`. |
| `host`, `kind` | Together, where the replacement runs where the record's lane ran. A request naming neither opens a window on this machine and records a local lane. |
| `account` | The account `lane walk --fleet --replaces [ITEM_KEY]` or `lane pick --fleet --replaces [ITEM_KEY]` chose. |
| `class`, `class_reason` | Both, or neither to keep the record's. |
| `refresh` | `true` for a refresh lane: a relaunch without it drops the record's `refresh`. |
| `brief_file` | The continuation (§ Brief file). |

The confirmed launch writes `harness`, `account`, `model` and `effort` from the request, each null where the request names none, so carry each one the replacement keeps. `tracker`, `repo`, `over_cap`, `permission`, `obligation` and `desktop` left out keep the record's value. A relaunch naming no `permission` keeps the recorded word while its line runs the `AGENT_RUNTIME_LAUNCH_PERMISSION` posture, so carry the record's word.

A relaunch is bound again by `overseer-foreign` and `item-foreign` on its `mail_root` and on its tracker and repository, else the record's, before anything is written. It is judged neither by the Ancestor gate nor by the file-overlap hold: the record keeps its `touched`, `in_scope` and `rebase` sets, its `tier` and `tier_inputs`. A record that reads `done` takes the request as the item's next phase instead, judged as a first launch over the record's slot, its `tier` read from the new brief.

### Resume or fresh

A local relaunch over a record that binds a session under the same harness and account resumes that session by its id, under the home it was found in, with the brief as its next prompt. The first of these that holds starts the harness fresh on the brief instead, and the observation names it as `route_cause`:

| `route_cause` | Condition |
|---|---|
| none | The record binds no session. |
| `harness-switched` | The harness differs. |
| `resume-file-unknown` | The lane runs Pi, which resumes by a session file the record does not carry. |
| `account-switched` | The account differs. |
| `session-absent` | The destination home does not hold the session by its id, or holds a Copilot session with no event. |
| `session-retired` | The item's handoff record stands with `relaunch` `fresh` or none. |

A session whose file records another directory, or a store that cannot be read, fails the launch before any window, whatever the handoff record says (§ Launch gate). A hosted relaunch always starts the harness fresh. A fresh start continues through the handoff record: its brief is the `start` brief, whose [start.md § 0](../workflows/start.md#0-resume-from-a-handoff) continues from the record, and a harness switch's brief also carries the transcript sentence of [handoff.md § 2](../workflows/handoff.md#2-launch). The brief carries the continuation either way, so nothing is pasted into the pane after a relaunch.

### Parked record

A record whose status is `parked` ([oversee-lanes.md § Parking a merge wait](oversee-lanes.md#parking-a-merge-wait)) is relaunched with the same request. The launch asks the provider's `start` for the stopped sandbox before its `create`. A start that fails fails the launch as `host-start-failed`; one that gave no answer holds it as `host-start-unknown`. The relaunch moves the parked pull request into `pending_pr` ([workflow-state.md § Oversee state](../schemas/workflow-state.md#oversee-state)), so an OPEN pull request still prevents the terminal close. A parked record holds a slot only while a live identity or a reservation stands (§ Caps), so its relaunch can meet `cap-reached`.

The model-switch recovery, `runtime/src/effects/lane_model.rs`, and the watch's wall relaunch ([oversee-events.md § Event kinds](oversee-events.md#event-kinds), `lane-relaunched`) compose this same request from the record after the runtime close.
