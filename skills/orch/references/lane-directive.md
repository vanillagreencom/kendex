# Lane directive

Load from [oversee.md § Lane directive](../workflows/oversee.md#lane-directive) when a launch finds no lane or refuses, and from [oversee.md § Recovery relaunch](../workflows/oversee.md#recovery-relaunch) to resume a dead or walled lane.

## No lane has room

On `lanes pick` exit 3, read `lanes list`, wait only when its lanes are over the threshold, and report every `expired`, `unreachable`, `no_credentials`, `no_usage_data` or `error` lane, and every `rate_limited` lane with a null `headroom_pct`, to the operator. An `expired` lane is one whose token renewal failed on a login proven dead; its `detail` names why, and it is the only one of these an operator answers by logging in again. A `rate_limited` lane met an endpoint answering HTTP 429. A usage refresh refused while the host holds a figure younger than the 5-hour session window is reported on that figure, with its age in `usage_age_s`, and judged on it like an `ok` lane. A token renewal refused with 429, or a usage 429 with no such figure, carries no window. An `unreachable` one met an endpoint answering 5xx, an endpoint it could not reach, or a credentials lock another tool held. Both leave the login untested, so the answer is another lane and never a re-login. Where an endpoint answered, `detail` carries the code and the lane is left alone until the recorded window passes. An `error` lane failed a step on this machine, a renewal's included. Every Claude account `error` for a missing OAuth client id needs `ORCH_LANES_CLAUDE_CLIENT_ID`, set once per host.

## Launch gate

`open-terminal` refuses a lane launch on a harness its flag table names that names no model, and one that names no effort where that harness has an effort flag, one keyed refusal per missing half, because a harness default changes without notice.

`open-terminal` reads the model and the effort out of the one text the launch runs: the `--cmd` command where there is one, `--launch-flags` where there is not. It refuses a launch that names either nowhere, and refuses `--launch-flags` beside `--cmd`, which are appended to no command and reach nothing. It then judges the named lane on that model a second time, so a lane picked without `--model` can be refused here. A hosted `--relaunch` is judged on that window too; only an account nothing measured turns on the provider's answer, per `open-terminal --help` § `--host`. It still names a model and an effort. The gate emits eight refusals, each with its own answer:

- `launch-model-missing` and `launch-effort-missing` (naming `harness`, `lane` and the `spellings` that harness takes): the launch made only part of the choice of lane, model and effort. Add the missing word to the text the launch runs; never let the harness pick.
- `launch-question-tool-missing` (naming `harness` and one `word` per word): the `--cmd` command leaves that harness's question tool on. Add the words, in order, to the command; [skill-rules.md § Coordination](skill-rules.md#coordination) lists them.
- `launch-flags-unreachable` (naming the `flags`): the launch passed `--launch-flags` beside `--cmd`, which renders its template verbatim and appends nothing, so those words would have gated and been recorded while the harness ran its own default. Move them inside the `--cmd` command, or drop `--cmd`.
- `lane-model-walled` (naming `lane`, `model`, `pct`, and `bucket`): that account's deciding shared or model window is at or above the threshold. Re-run [oversee.md § Lane directive](../workflows/oversee.md#lane-directive) step 3 with `--model`, never retry the same lane. A hosted relaunch meets it too: the window belongs to the account, so resuming would spend the sandbox start to open on a usage banner.
- `lane-model-unreadable`: no window of that account measures the model, or its usage could not be read. An unread window is never an empty one, so the answer is the same re-pick.
- `host-credential-dead`: this machine's copy of the account expired and could not be renewed, and the provider reports holding that same account. Renew the login on this machine for that config dir; a provider that re-seeds the host from that directory at every `create` sends the dead copy again. Reported for claude lanes, the only ones whose local credential `lanes` reads an unrenewable expiry from. A relaunch onto that same account proceeds instead, on the copy the provider installed.
- `lane-judge-failed`: the judge refused before it answered, a malformed `--lane-max-pct` among the causes. The keyed `lanes:` line above it names which.

A fleet launch, one naming `--state-dir`, meets one more gate, which admits a harness only where the lane runs with its own compaction off and a harness adapter can name its window:

- `launch-compaction-missing` (naming `harness` and one `word` per word): the `--cmd` command leaves that harness's own compaction on. Add the words, in order; [skill-rules.md § Coordination](skill-rules.md#coordination) lists them.
- `launch-window-unknown` (naming the claude `model`): the claude adapter names no window for that model. Launch on a model its window table names.
- `unsupported-for-oversee` (naming `harness`, `none` for a launch naming none): no adapter reads that harness, or, with `reason=no-window-read`, the Pi carrier installed sends no `context_window`. Launch on claude, codex, or a Pi with the current pi-hooks.
- `compaction-on`, `pi-settings-unreadable` and `pi-compaction-unverified` (naming the `file` or `host`): Pi would compact the lane, its settings file could not be read, or the lane is hosted, whose Pi settings this machine cannot read. Set Pi's `compaction.enabled` to `false`, repair the file, or launch the Pi lane locally.

An unreadable in-flight claim store is not a refusal here: this gate asks for a wall, which no claim count enters, so `lanes` reports the store on stderr as `pick-lane-claims` and answers the wall anyway. Fix the claims directory, or set `OVERSEE_WATCH_STATE_DIR`, so the next `lanes pick` across the fleet can still see what is running.

`host-accounts-unanswered` is a notice, not a refusal: nothing said which accounts the host holds, so the launch is judged on this machine's reading as an unhosted one is. A keyed `lanes:` line above the notice names a provider failure, with the provider's own message above that line; no line above it means the read of the answer failed on this machine. Fix what that line names, or read the launch's outcome as a local measurement.

## Caps

The caps refuse a launch before its worktree; a `--relaunch` meets them only where it adds a lane or changes its account:

- `cap-reached`: launch once a lane closes.
- `account-cap-reached`: launch once a lane on that account closes, or with `--wait-slot`.
- `cap-unreadable`, `cap-lock-failed`, `cap-reserve-failed`, `claim-unrecorded`: fix what the line names; never launch around it.

A launch queued behind the caps, such as a chain script, passes `--wait-slot`, which waits for room; the overseer writes no counting loop. `--over-cap` admits one deliberate exception, recorded as the lane record's `over_cap`.

## Tmux session

Every lane window opens in one tmux session, named in the record's `window` as `SESSION:WINDOW`: `ORCH_TMUX_SESSION` when set, else the session the state records as `tmux.session`, else the launching pane's session. The first tmux launch records the session it opened in, `ORCH_TMUX_SESSION` or the pane's, once tmux confirms it exists. A launch with no live pane and neither refuses as `tmux-session-unresolved`, and a named session tmux does not hold refuses as `tmux-session-missing` with its source. A detached launch chain still needs `$TMUX` set, as a `setsid` chain or a `run-shell` job started inside tmux has; one without it refuses as `tmux-missing`. Set `ORCH_TMUX_SESSION` for such a chain.

## Recovery relaunch

A dead or walled terminal lane uses native resume. Start with the [handoff.md](../workflows/handoff.md) § 2 terminal command. Add `--relaunch`, the selected `--lane`, the chosen `--launch-flags` and `--state-dir [OVERSEE_STATE_DIR]`. Keep the tracker, repository, harness, and item arguments. Do not pass `--cmd`, because a custom command bypasses session lookup. A `micro` item relaunched this way demotes to `standard`: with no `--cmd` the launcher renders its `start` template, and the resumed session runs the full cycle on the branch the micro run left. A record carrying `host` adds `--host [HOST]`: the provider keeps its tree and the harness continues natively. A hosted relaunch is judged on the account's usage window like any other launch, and is refused as `lane-model-walled` when that window is at or above the threshold; `open-terminal --help` § `--host` holds what the provider's answer decides, which is the unreadable case alone. A relaunch the provider reports holding the account for proceeds there, reported as `host-relaunch-credential`, and the resumed session reports its own usage banner, which [oversee.md § 4](../workflows/oversee.md#4-watch-and-advance) reads as `usage-limit`. The launcher delivers the continuation line in the resumed command itself and keeps a merged item's tree as it stands, so nothing is pasted into the pane after the resume. A hosted codex lane is the exception: `codex resume` refuses a prompt beside `--last`, so it resumes with no line and the launcher reports `resume-lineless`. Paste that lane's continuation line into its pane through [oversee.md § Talking to a lane](../workflows/oversee.md#talking-to-a-lane), Pane paste, the way a walled lane gets its nudge.
