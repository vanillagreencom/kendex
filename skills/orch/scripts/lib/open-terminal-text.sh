# shellcheck shell=bash
#
# Owner: open-terminal, the one script that sources this file.
#
# The prose open-terminal prints: its message catalog, every refusal and
# notice keyed by REASON, and its --help text. The message header protocol is
# stated where open-terminal sources this file, ahead of its argument parser,
# which answers a help request before any configuration is read.
#
# Sourced, never run.

ot_message() { # REASON FIELD=VALUE...
  local reason="$1" text field
  shift
  case "$reason" in
    missing-value) text='The option requires a value.' ;;
    helper-missing) text='The required helper is not executable.' ;;
    items-missing) text='Specify a work item.' ;;
    tracker-invalid) text='The tracker must be linear or github.' ;;
    command-missing) text='Select a harness or a custom command.' ;;
    cmd-unbalanced-quote) text='Put the brief in a file and reference it, or escape the quote.' ;;
    desktop-harness) text='Use the Codex Desktop thread tools for this harness.' ;;
    mode-override) text='The explicit GUI option overrides the detected tmux mode.' ;;
    verify-seconds-invalid) text='The verification timeout must be a positive integer in seconds.' ;;
    verify-seconds-clamped) text='The verification timeout was limited to the maximum.' ;;
    flags-invalid) text='Launch flags must contain plain flag words without shell metacharacters.' ;;
    permission-prompt) text='The unattended harness can stop at a permission prompt with these flags.' ;;
    lane-quote) text='A quote in the lane path cannot be embedded safely in the launch command.' ;;
    lane-separator) text='A tab or newline in the lane path cannot be stored in a claim.' ;;
    lane-harness-missing) text='Select a harness for automatic lane selection.' ;;
    lane-unavailable) text='No lane meets the usage threshold. Wait for a reset, raise the threshold or select a lane. The keyed lanes: line above names what each lane was and, where a threshold applied, the threshold.' ;;
    lane-resolution-failed) text='The lanes helper failed to select an account.' ;;
    lane-directory-missing) text='The specified lane directory does not exist.' ;;
    lane-unknown) text='The lane is neither a known alias nor a directory.' ;;
    lane-refused) text='A lane setting excludes or retires this lane. No window was opened.' ;;
    launch-flags-unreachable) text='These launch flags reach nothing. A --cmd launch runs its template as the whole command and no flag is appended to it, so a model, an effort or a permission word left here would be judged and recorded while the harness ran its own default. Nothing was launched. Name them inside the --cmd command, or drop --cmd and let this launcher build the harness command from --launch-flags.' ;;
    launch-model-missing) text='This lane launch names no model, so the harness would run whatever its own default is, and that default changes without notice. Nothing was launched. Name the model in the --cmd command where the launch carries its own harness argv, and in --launch-flags where it does not; spellings holds the flags this harness takes.' ;;
    launch-question-tool-missing) text='This lane launch leaves the harness question tool on, and a lane that calls it stops at a dialog nobody at the pane answers. Nothing was launched. Put the words this line names, in that order, inside the --cmd command; a launch without --cmd is given them by this launcher. A lane asks its overseer through lane-mail ask.' ;;
    launch-effort-missing) text='This lane launch names no reasoning effort, so the harness would run whatever its own default is, and that default changes without notice. Nothing was launched. Name the effort in the --cmd command where the launch carries its own harness argv, and in --launch-flags where it does not; spellings holds the flags this harness takes, one ending in = being a whole token with its value attached.' ;;
    lane-selected) text='The launch account is selected.' ;;
    launch-trusted) text='The launch directory is trusted in the config this codex launch will read, so the harness starts into it rather than onto the folder-trust question. route=preapproved is the account config already carrying the entry; route=launch-home is a CODEX_HOME built for this launch under the account, holding the account files by link and a config of its own, because the account config is a link the account shim repoints at every launch.' ;;
    launch-trust-missing) text='The folder-trust entry for this launch directory could not be made in the config this codex launch would read. Nothing was launched: the harness would open on the folder-trust question and wait there for an answer nobody at the pane gives. Remedy by reason: trust-refused is an answer already recorded for this directory that is not trust, which this will not overwrite, so change it where it was written or launch somewhere else; config-unreadable is the account config present and unreadable, a dangling shim link being the usual cause, so relink it; account-store is the account transcript directory that could not be made; home-path, home-create, home-link and home-entry are the private CODEX_HOME under the account that could not be built, so check that the account directory is writable, home-entry naming a real file or directory sitting where a link to the account belongs; config-write and config-install are that home config.toml, the same; entry-unreadable is the entry written and not read back. The lane host provider makes this entry for a sandboxed lane instead.' ;;
    lane-model-walled) text='The account has no usage window left for the model this launch passes; bucket names the shared or model window that decided, and pct names how much of it is used. Nothing was launched: the session would open on a usage banner. A window nobody could measure is lane-model-unreadable instead. The threshold that judged is on the keyed lanes: line above.' ;;
    lane-model-unreadable) text='The lane could not be read for the model this launch passes. Nothing was launched: an unread window is not an empty one.' ;;
    host-credential-dead) text='The credential this machine holds for the account has expired and could not be renewed, and the lane host reports holding that same account. Nothing was launched. Remedy: log in again on this machine for that config directory; a provider that re-seeds the host from that directory at every create, as the reference provider does, sends this dead copy again. Reported for claude lanes: an expiry that could not be renewed is the one state read here, and only a claude credential carries it. A RELAUNCH onto this same account proceeds instead, on the copy the provider installed; a window this machine can read walls either shape.' ;;
    host-relaunch-credential) text='Nothing here measured this account, and the lane host reports holding it, so the relaunch proceeds on the copy the provider installed. Nothing checked that copy is live. The resumed session reports its own usage banner, which the watch reads as usage-limit. A window this machine CAN read still walls a relaunch: an account at or above --lane-max-pct is refused as lane-model-walled, hosted or not.' ;;
    host-accounts-unanswered) text='The lane host could not say which accounts it holds, so this launch is judged on the usage windows this machine reads, exactly as an unhosted one is. Where a keyed lanes: line sits above this one, it names the provider failure; where none does, the read of that answer failed here. A provider that does not implement the optional accounts verb is not reported at all.' ;;
    lane-judge-failed) text='The lane judge refused before it answered for this lane. Nothing was launched. The keyed lanes: line above names the cause.' ;;
    lane-premise-unmet) text='The pane never drew either harness at its own screen inside the verification timeout, so nothing places the account read after the harness started. The launch stands and that read is reported as unobserved rather than as a verified account.' ;;
    lane-verified) text='The pane runs the account that was picked.' ;;
    lane-mismatch) text='The pane runs another account than the one picked, so a wrapper on PATH replaced the selection. The item failed. The window is closed unless a tmux-failed line follows.' ;;
    lane-unobserved) text='The account the pane runs on could not be established. The launch stands: this check refuses on a disagreement it observed, never on an observation it could not make.' ;;
    lane-result-unknown) text='The account check returned an outcome this script does not know. The window is closed: an unreadable verdict is not a pass.' ;;
    harness-unsupported) text='This terminal harness is not supported.' ;;
    directory-missing) text='The working directory does not exist. No window was opened.' ;;
    tmux-missing) text='This launch requires a tmux server to reach: run it inside tmux, or set ORCH_TMUX_SESSION to the fleet session on your own tmux server.' ;;
    tmux-failed) text='The tmux operation failed.' ;;
    pane-refused) text='The pane writer refused to type into the window this launch opened, and typed nothing: the window is not the one opened, or it does not run the process the step expects. Its own pane-write line above names which.' ;;
    session-record-failed) text='The tmux session this fleet opens lane windows in could not be read from or recorded into the oversee workflow state. Nothing was opened; fix what workflow-state names.' ;;
    tmux-session-unresolved) text='No tmux session is named for the lane window. consulted lists the sources this launch read, in order, and none of them named a session. pane is what the TMUX_PANE read found: unset is no TMUX_PANE; none is an empty answer, which is how tmux answers for a pane it does not hold; read-failed is the read itself failing, and tmux names that failure on the line above. Nothing was opened: a window with no named session lands in whichever session tmux calls current, where the watch does not look for it. Set ORCH_TMUX_SESSION, or launch from a pane in the fleet session.' ;;
    tmux-session-missing) text='The tmux session this launch resolved does not exist on the server this launch reaches, which the server field names. Nothing was opened and nothing was recorded. source says where the name came from: ORCH_TMUX_SESSION is the setting, so correct it; tmux.session is the fleet state, which a renamed session or a restarted server leaves stale, so set ORCH_TMUX_SESSION to the live fleet session, or clear the record with .agents/skills/orch/scripts/workflow-state --state-dir [OVERSEE_STATE_DIR] update oversee '\''del(.tmux)'\'' and launch from a pane in that session; pane is the launching pane, whose session closed during the launch.' ;;
    claim-write-failed) text='The lane launched, but its claim could not be recorded. Check OVERSEE_WATCH_STATE_DIR.' ;;
    record-write-failed) text='The lane launched and its window stands, but its record could not be written to the oversee workflow state, so the watch cannot carry it. Fix what workflow-state names, then record the lane by hand per oversee.md § 3 Lane record, or close the window before relaunching the item with --relaunch.' ;;
    record-missing) text='No lane record names the item, so this launcher never launched it and the wake recorded nothing; the woken session runs. Record the lane per oversee.md § 3 Lane record, or close its window and relaunch the item with --relaunch.' ;;
    state-unwritable) text='The oversee workflow state could not be created, so no lane would be watched. Nothing launched; fix what workflow-state names.' ;;
    cap-reached) text='A launch here would put the fleet over ORCH_OVERSEER_LANES. cap names that setting, running the lane records in the fleet state whose status is running or preparing, and claims the live launch claims and reservations this fleet wrote that name the window of no such record: a lane whose record is neither while its pane still runs, or a launch not yet recorded. Nothing was launched. Wait for a lane to close, launch with --wait-slot to wait for one here, or pass --over-cap for one deliberate exception.' ;;
    account-cap-reached) text='A launch here would put the account over ORCH_LANE_ACCOUNT_CLAIMS. lane names the account, cap that setting, and claims the lanes on that account: records, the running or preparing records of this fleet on it, plus claims-other, the live launch claims and reservations on it that are not the claims of those records, lanes of other fleets among them. A claim is the claim of a record where it names the window and account of that record and this fleet or none. Nothing was launched. Wait for a lane on that account to close, launch with --wait-slot to wait for one here (under --lane auto it moves to an account with room), name a lane on another account, or pass --over-cap for one deliberate exception. 0 turns this cap off.' ;;
    cap-unreadable) text='The lanes in flight could not be counted, so neither cap can be judged. Nothing was launched. source=state is the fleet state named by --state-dir; source=claims is the claim store, whose own keyed lane-claims line above names what failed.' ;;
    cap-lock-failed) text='A launch lock, the fleet one or the claim store one that lock names, was not taken inside its bound, so the count and the reservation write cannot be one step. Nothing was launched. Another launch holds it; the lock line above names a stale mutex where flock is absent.' ;;
    cap-reserve-failed) text='The reservation that holds this launch'"'"'s place in the count could not be written to the claim store that store names, so the next count would not see this launch. Nothing was launched. Check that directory: a store that cannot take a reservation cannot take the claim that follows it either.' ;;
    reserve-unremoved) text='The reservation this launch wrote could not be removed. Until the lane record is written the count holds this lane twice; after the lane stops, the reservation still counts as a lane in flight until this launcher exits, when it lapses.' ;;
    cap-option-unanchored) text='This option answers the fleet caps, which a launch meets only where --state-dir names its fleet. Nothing was launched. Pass --state-dir, or drop the option.' ;;
    over-cap-items) text='--over-cap admits one launch past a cap. Nothing was launched. Pass one item.' ;;
    over-cap-admitted) text='The launch goes past the caps named in passed on --over-cap, and its lane record carries them as over_cap.' ;;
    lock-waiting) text='Another launch into this fleet, or onto this claim store from any fleet, holds the launch lock that lock names, so this one waits for it, at most wait-s seconds.' ;;
    slot-waiting) text='A cap is reached, so this launch waits under --wait-slot: it counts again every few seconds without holding the launch lock, judges its lane again, and counts and reserves under the lock once both caps have room. The fields are the count it waits on, printed again whenever that count changes.' ;;
    state-absent) text='No oversee workflow state exists at the address this wake resolved, so nothing was ever launched into it. Nothing woken. Point the wake at the fleet state with --state-dir, the directory holding the file workflow-state path oversee prints from the overseer checkout.' ;;
    tmux-opened) text='The tmux window is open.' ;;
    launch-confirmed) text='The lane started while its composer was checked. No further text was sent.' ;;
    composer-stuck) text='The composer did not become ready. Attach to the session and start the brief manually.' ;;
    brief-redelivered) text='The brief was sent again after the initial prompt was consumed.' ;;
    brief-undelivered) text='The brief is still undelivered. Attach to the session and start it manually.' ;;
    terminal-missing) text='Set TERMINAL to an installed terminal or install xdg-terminal-exec.' ;;
    terminal-fallback) text='The requested terminal is unavailable. The selected terminal will open the lane.' ;;
    terminal-opened) text='The GUI terminal launch was started.' ;;
    issue-invalid) text='The issue identifier does not match the configured pattern.' ;;
    issue-canonical-failed) text='The git-context helper could not canonicalize the issue identifier. Nothing was created.' ;;
    github-item-invalid) text='A GitHub work item must be an issue number.' ;;
    repo-missing) text='Specify a repository when GitHub cannot resolve it.' ;;
    claim-unrecorded) text='The previous claim is missing, so under --lane auto the next item cannot be spread off its account. The batch stops.' ;;
    item-owned) text='Another session owns this work item. Its worktree was skipped.' ;;
    worktree-failed) text='The worktree helper failed to create this item.' ;;
    worktree-reuse-merged) text='The item pull request merged, so its tree is kept as it stands and no rebase is attempted.' ;;
    worktree-links-failed) text='The kept tree has configured symlinks the repair could not restore, so the lane could not reach its own .agents scripts. The item was not launched.' ;;
    resume-lineless) text='The hosted codex resume carries no continuation line, because codex resume refuses a prompt beside --last. The lane is up and idle: paste its continuation line into the pane per oversee.md section Talking to a lane, Pane paste.' ;;
    host-resolve-failed) text='The lane-host helper could not resolve the host.' ;;
    host-invalid) text='A hosted launch needs tmux mode, a resolved lane and --harness claude, codex or pi. Nothing was created.' ;;
    host-create-failed) text='The lane host failed to create this item. No local lane was started.' ;;
    lane-host-busy) text='lane-host refused the call step names at its per-home cap on provider calls, after waiting ORCH_LANE_HOST_BUSY_WAIT_SECS for a slot; its own line is above and the provider ran nothing. After a refused create nothing was made: launch the item again. After a refused wait or marker call the host holds the item: relaunch it with --relaunch.' ;;
    host-line-invalid) text='The lane host create output lacks ssh-target, path or remote-prefix on one line, or names a state other than preparing.' ;;
    host-prepare-failed) text='The lane host accepted this item and its wait reported the preparation failed; the provider says why above. No lane was started. The host keeps what it made until lane-host close or a --relaunch.' ;;
    lane-preparing) text='The lane host accepted this item and is still preparing it. A background job waits for the host, launches the lane in the window opened for it and records the outcome, which oversee-watch reports as lane-ready or lane-prepare-failed. log is the job output.' ;;
    lane-prepare-failed) text='The background launch of this lane failed and its window is closed unless a tmux-failed line precedes this one, so no remedy above that names the window applies. reason wait-failed is the host wait, which says why above; launch-failed is a launch step, whose keyed line is above. The record is stopped: lane-close closes the host and the record, or relaunch the item.' ;;
    prepare-unrecorded) text='The record of a lane handed to a background job could not be written to the oversee workflow state. At the hand-off the job was stopped and the window closed, and the host holds the item. In the job, the record still reads preparing, which oversee-watch reports as lane-prepare-stuck. Either way lane-close closes the lane once the state can be written.' ;;
    prepare-stop-failed) text='The background job the hand-off started could not be stopped after its record failed. Stop the process group pid names by hand.' ;;
    remote-prompt-missing) text='The ssh session showed no shell prompt in time. Attach to the window and start the lane manually. The reason says which pane state the spent bound ended on: prompt-silent is ssh still holding the pane, session-gone is the pane running no ssh, a session that died or never started. The ssh lines this launcher typed are counted in attempts.' ;;
    host-gitfile-unread) text='The .git of the lane worktree could not be read on the host, so the clone its launch marker belongs under is unknown. The item was not launched.' ;;
    host-gitfile-invalid) text='The .git of the lane worktree does not name a linked worktree git directory, so the clone its launch marker belongs under is unknown. The item was not launched.' ;;
    marker-failed) text='The lane launch marker could not be written, or did not read back holding the root the lane opens in, so the lane mail hook would never hand this lane its messages. The item was not launched.' ;;
    session-scan-failed) text='The harness session store could not be read.' ;;
    session-resumed) text='The harness resumed the matching session.' ;;
    wake-invalid) text='The wake option takes --harness claude, codex or pi, and no --cmd, --relaunch or lane host.' ;;
    session-missing) text='No session of this harness names the item. Nothing was started.' ;;
    wake-failed) text='The delivering command exited non-zero before the wake window closed. The lane was not woken; the log says why.' ;;
    wake-refused) text='The lane is not idle: the reason names the state the shared judge read from its pane and its harness process, and a resume would run a second session beside a live one. Nothing was started. A refusal is a state and not a remedy: the refusal table in the orch lane-reach reference, under Wake refusals, says how mail still reaches the lane for each reason.' ;;
    lane-woken) text='The line that reads the lane inbox is on its way to the session. The delivering command runs detached; its output goes to the log.' ;;
    summary) text='The launch batch is complete.' ;;
    *) printf 'open-terminal: message-invalid reason=%s\n' "$reason" >&2; return 2 ;;
  esac
  printf 'open-terminal: %s' "$reason"
  for field in "$@"; do
    field="${field//\\/\\\\}"
    field="${field//$'\t'/\\t}"
    field="${field//$'\r'/\\r}"
    field="${field//$'\n'/\\n}"
    printf ' %s' "$field"
  done
  printf '\n%s\n' "$text"
}

usage() {
  cat <<'USAGE'
Usage: open-terminal [--tracker linear|github] [--repo OWNER/REPO] ITEM... [options]

Options:
  --harness <name>  claude, codex, opencode, pi
  --tmux            Open tmux windows in the fleet's tmux session: the
                    session ORCH_TMUX_SESSION names; else, under --state-dir,
                    the session the fleet state records as tmux.session;
                    else the session of the pane $TMUX_PANE names. The
                    fleet's first tmux launch records the session it
                    resolved, once tmux confirms it exists. A launch that
                    resolves none of the three, one with $TMUX set, no live
                    pane and no recorded session among them, refuses as
                    tmux-session-unresolved; a resolved session tmux does
                    not hold refuses as tmux-session-missing, naming it and
                    its source. Either opens nothing, and a launch with
                    neither $TMUX nor ORCH_TMUX_SESSION refuses as
                    tmux-missing: with the setting alone the launch reaches
                    the person's own tmux server from outside tmux. The lane
                    record's window is SESSION:WINDOW.
  --ghostty         Open GUI terminals ($TERMINAL, xdg-terminal-exec, ghostty)
                    With neither mode flag the mode is auto-detected: tmux
                    when $TMUX or ORCH_TMUX_SESSION is set, otherwise a GUI
                    terminal. Both flags
                    are overrides; --ghostty inside tmux warns that the flag
                    overrides the auto-detected tmux mode and still opens GUI
                    terminals, which receive no TMUX or TMUX_PANE.
  --cmd "..."       Custom command; {issue}, {item}, and {repo} are replaced.
                    It is the WHOLE command: it is rendered verbatim and no
                    launch flag is appended to it, so a --cmd launch names its
                    own model, reasoning effort, permission posture and
                    question-tool words (see --launch-flags) inside the
                    command. --launch-flags beside it reach nothing and are
                    refused as launch-flags-unreachable, rather than gating and
                    recording a model the harness never runs.
  --lane <spec>     Launch under a chosen harness account. `auto` picks the
                    qualifying account with the fewest launches in flight for
                    --harness; `auto:<h>` picks for harness <h>; a config dir
                    is used literally; any other value is looked up as a lane
                    alias. A named lane (alias or config dir) that
                    ORCH_LANE_EXCLUDE or ORCH_LANE_RETIRE covers is refused,
                    as `lanes check` decides. Refuses to launch when no lane
                    is under the usage threshold, rather than launching into
                    a wall. EVERY lane launch on a harness the flag table names
                    is asked for its model, and for its reasoning effort where
                    that harness has an effort flag, on a relaunch as much as a
                    fresh launch: one naming neither is refused as
                    launch-model-missing and launch-effort-missing before any
                    lane is judged — see --launch-flags, whose table holds each
                    harness's spellings and marks the one with no effort flag.
                    The two words are read out of the text the launch RUNS: the
                    --cmd command where there is one, --launch-flags where there
                    is not, and they are judged by the row of the harness the
                    launch NAMES: --harness, or the <h> of `auto:<h>` where no
                    --harness is given. Only a launch naming a harness NOWHERE —
                    a --cmd launch on a named config dir or alias, with no
                    --harness — has no row there and reaches no such gate, its
                    argv being the caller's own. A NAMED lane is then judged
                    on the window for that model, claude and codex only:
                    refused when it is at or above --lane-max-pct, and
                    refused as unreadable when nothing measures it. A config
                    dir no lane record covers is used as given, there being no
                    record to judge it by. THE WALL BINDS
                    EVERY LAUNCH SHAPE, a hosted --relaunch included: a usage
                    window belongs to the account, so a window this machine
                    reads at the threshold is the window the sandbox meets, and
                    a refused relaunch costs nothing where a walled one spends
                    the sandbox start and the resume to open on a usage banner.
                    Only the UNREADABLE answer turns on the host: a relaunch
                    onto an account the provider reports holding proceeds there,
                    reported as host-relaunch-credential — see --host. On tmux
                    lanes only: every window launched under a lane records a
                    claim (see `lanes --help`), live while its pane is, and
                    `auto` re-picks before each further item, so a batch
                    spreads across accounts instead of stacking on one. A
                    re-pick that qualifies no lane stops the batch, leaving
                    the items already launched alone. A GUI launch has no
                    pane to keep a claim alive, so a GUI batch stays on the
                    lane resolved up front. `lanes --help` states the
                    launcher-first rule and the pane check that follows it.
                    Claims line up only while this command, `lanes` and
                    `oversee-watch` resolve the same $OVERSEE_WATCH_STATE_DIR;
                    set it explicitly when they do not share one project
                    configuration.
  --host <spec>     Launch on a lane host: `local`, or a provider script path.
                    Without it ORCH_LANE_HOST decides, as `lane-host resolve`
                    prints it. A hosted launch needs tmux mode, a resolved --lane
                    and --harness claude, codex or pi. It creates no local worktree: `lane-host create`
                    receives the lane's config dir as --account, the window
                    types `ssh` to the returned target, waits for the remote
                    prompt, then types the remote prefix running the harness
                    in the remote worktree, with no lane env prefix. A create
                    line carrying state=preparing is a host still preparing
                    the item it accepted. Under --state-dir the window and its
                    claim open, the record reads preparing and the launch
                    moves on: a background job runs `lane-host wait`, then the
                    rest of the launch, and records the lane running, or
                    stopped with its reason, logging to
                    lane-prepare-ITEM.log in the state directory; the summary
                    counts it as preparing. Without --state-dir, and for a
                    codex --relaunch, the launch runs `lane-host wait` itself.
                    lane-close closes a record still preparing. With
                    --relaunch the provider keeps its tree and the harness
                    continues natively: claude --continue, codex resume
                    --last, pi -c. The claude and pi forms carry the
                    continuation line. The codex form does not: its prompt
                    argument is declared as conflicting with --last, so
                    `codex resume --last a b` is a parse error and a lone
                    positional beside --last is the session id. A hosted codex
                    lane therefore resumes with no line, reported as
                    resume-lineless; paste its line into the pane per
                    oversee.md § Talking to a lane, Pane paste.
                    WHICH CREDENTIAL RUNS THE LANE: the copy the provider
                    installed on the host. `create` receives the lane's config
                    dir as --account on every call, a relaunch included, and
                    where the provider re-seeds the host from it each time — the
                    shipped reference lane-host-ssh copies setup-token (claude)
                    or auth.json (codex, pi) at each create — the copy on the
                    host is this machine's, sent again. The provider's
                    `accounts` answer is what says which accounts it holds, and
                    nothing here reads the secret itself.
                    WHAT THE ANSWER DECIDES is the named lane's UNREADABLE case
                    and nothing else. A window this machine reads walls every
                    launch shape alike, hosted relaunch included — see --lane.
                    Where nothing measured the account:
                      a --relaunch on an account the provider reports holding
                        proceeds, reported as host-relaunch-credential, because
                        the copy running that session is the provider's and the
                        harness's own banner after the resume is the gate
                        oversee-watch reads as usage-limit;
                      a FRESH launch on an account the provider reports holding,
                        whose copy here expired and cannot be renewed, is refused
                        as host-credential-dead, the remedy being to log in again
                        on this machine for that config dir. That refusal reaches
                        claude lanes: an unrenewable expiry is the one local
                        state `lanes` names and only a claude credential carries
                        it, so a codex lane whose own auth.json is dead reads as
                        a window that could not be read;
                      anything else is refused as lane-model-unreadable, an
                        unread window being neither a full one nor an empty one.
  --lane-max-pct N  Usage threshold, applied both when --lane auto chooses an
                    account and when a named lane is judged. The window judged
                    is the one walling the model the launch runs, named in the
                    --cmd command where there is one and in --launch-flags where
                    there is not; with no model named there it is the account's
                    binding bucket. Forwarded to `lanes`, which owns the bound,
                    its default and $ORCH_LANE_MAX_PCT; without this flag that
                    setting decides.
  --state-dir PATH  The workflow-state directory the lane record is written
                    to, passed to workflow-state as its own --state-dir. An
                    absolute path is one address for the whole fleet however
                    each launch's directory is placed: a fleet passes the
                    directory holding the file `workflow-state path oversee`
                    prints from the overseer's checkout, so a launch run
                    from another repository (a proposal sweep) records into
                    the state the watch reads. Without it the launch names
                    no fleet: no lane record is written and no state is
                    created, which is what a launch-only handoff wants
                    (handoff.md § 2).
  --launch-flags S  Flags for the harness command THIS LAUNCHER BUILDS, chosen
                    per task by the caller (model, effort, permission posture).
                    They reach a harness only through that command, so a --cmd
                    launch, whose command is rendered verbatim, names those
                    words inside the command instead and these flags beside it
                    are refused as launch-flags-unreachable. Plain
                    flag words only — the string is interpolated into a
                    shell-executed launch command. Nothing is hardcoded here or
                    in settings. A harness row that names an unattended
                    permission posture warns when the flags carry none of its
                    spellings, because a prompting mode stalls the lane at its
                    first tool call. A --cmd launch carries its own argv and is
                    not warned about.
                    A LANE LAUNCH NAMES A MODEL, AND AN EFFORT WHERE ITS HARNESS
                    HAS AN EFFORT FLAG, in the one text the launch runs: here
                    where there is no --cmd, and inside the --cmd command where
                    there is one. A harness default is whatever it happens to be
                    that week, and the account is spent either way, so a launch
                    making only part of the choice is refused, one keyed refusal
                    per missing half.
                    The spellings, a flag word also taking its value attached
                    with `=`:
                      claude    --model, --effort
                      codex     -m or --model, and -c model_reasoning_effort=
                      opencode  -m or --model; its launch form has no effort
                                flag, so the model alone is asked
                      pi        --model, --thinking; pi also spells the level on
                                the model value, `--model sonnet:high`, which
                                names both choices in one token
                    The model also gates the lane, which is judged on that
                    model's own window rather than the account's binding one.
                    Every codex command built here, fresh launch, relaunch
                    and wake alike, also carries -c
                    check_for_update_on_startup=false ahead of these flags,
                    so Codex never opens its startup update prompt, where a
                    pasted line would install the update and end the session.
                    EVERY COMMAND BUILT HERE TAKES THE HARNESS QUESTION TOOL
                    AWAY, ahead of these flags; a lane asks through lane-mail.
                      claude    --disallowedTools=AskUserQuestion,EnterPlanMode
                      codex     -c features.default_mode_request_user_input=false
                      pi        --exclude-tools question
                    An opencode lane keeps its tool: no flag turns it off. A
                    --cmd launch on a harness with words carries them in its
                    command, --lane or not, or is refused as
                    launch-question-tool-missing, one word= field per word.
  --relaunch        Replace a dead session on items that may already have a
                    worktree: an existing tree is reused instead of being read
                    as another session's claim. The newest matching Claude,
                    Codex, or Pi session resumes natively, and the resumed
                    command carries one continuation line telling the lane to
                    resume its orch workflow and read `lane-mail inbox`, and a
                    claude or pi lane to re-arm its mailbox monitor
                    (`lane-mail watch`), so no follow-up is pasted into the
                    pane. A codex lane arms no monitor: Codex starts no turn
                    for its output. A hosted codex lane is
                    the exception: it resumes with no line, reported as
                    resume-lineless, and its line is pasted into the pane
                    afterwards — see --host. With no match the normal brief
                    starts fresh. Before the worktree step an existing tree is asked whether its pull
                    request merged (`worktree merged`). A merged item keeps its
                    tree as it stands and is reported as worktree-reuse-merged
                    with the merge commit; its links are re-asserted with
                    `worktree fix-links`, which the skipped create would
                    otherwise have done, because the continuation line tells
                    the lane to run a script under .agents. An unmerged answer
                    and a lookup that could not answer both take
                    `create --reuse`, which judges the question again for
                    itself. The merged item never asks create for its guard
                    lease: nothing rewrites the tree, and the relaunch runs on
                    a lane the overseer has already judged dead, so the claim
                    it would assert is one nobody still holds. An item on the
                    reuse path is still skipped on a lease held under another
                    owner.
  --wake            Wake an idle lane in its existing worktree: resume its
                    newest matching Claude or Codex session in print mode, or
                    send to its live Pi session through pi-bridge, with one
                    line telling it to read `lane-mail inbox`. A Pi wake goes
                    to the live session and is never put to the lane judge,
                    so none of the state refusals below apply to it. No
                    worktree is created, no window opens, and no session
                    match is a refusal, never a fresh start. The turn runs
                    detached; its output goes to tmp/lane-wake-ITEM.log in
                    the worktree. A delivery that exits non-zero within its
                    first 5 seconds is refused as wake-failed. A Claude or
                    Codex lane wakes only when the one lane judge
                    (lib/lane-state.sh), which oversee-watch also asks, calls
                    it idle. The judge asks the lane's tmux pane first for
                    every state but idle, so a lane whose harness runs on
                    another machine is still judged from its pane; the
                    harness process under /proc decides idle. The wake is the
                    one caller that hands the judge a process read, and an
                    `idle` pane stands only while that read is idle too: a
                    read that says busy answers working, and one that could
                    not tell answers unjudged. Codex publishes no idle
                    signal, so a local codex lane is never judged idle from
                    its process: while a codex process runs in that worktree
                    the wake refuses the lane, as working where that process
                    has a shell under it and as unjudged in every other case.
                    A harness process another user owns, root among them,
                    likewise refuses the whole lane as unjudged for as long
                    as it runs. On a host with no /proc the read answers
                    unjudged as soon as ps names one process for that
                    harness, the lane's own session among them, and for a
                    claude lane the overseer's own Claude Code process is
                    one; where the box runs none, the read answers idle and
                    the wake goes through. Anything but idle is refused as
                    wake-refused with the state as the reason: working,
                    asking, walled, exited or unjudged. A refusal is a state
                    and not a remedy: the refusal table in the orch
                    lane-reach reference, under Wake refusals, says how mail
                    still reaches the lane for each reason.

A Linear ITEM is accepted in whichever case GH_ISSUE_PATTERN matches and
launched under the tracker's canonical spelling, TEAM-N, which names the
window, the brief, the lane's mailbox and its workflow-state key. A GitHub
item's window is gh-N and its brief names github OWNER/REPO#N, while its
mailbox and workflow-state key are issue-N. The worktree path and its branch
stay lower case.

On tmux lanes the launch is verified against the pane and the brief re-sent
once if a first-run dialog consumed it ($ORCH_TMUX_VERIFY_SECS per pass,
default 15, positive integer clamped to 120). A pane already running a turn
counts as launched and is not typed into.

A hosted lane's wait for the remote shell prompt is its own bound,
$ORCH_LANE_SSH_PROMPT_SECS (default 60, positive integer clamped to 300),
because it measures a route and another machine's login rather than a program
starting here. A bound spent with ssh still holding the pane interrupts that
client, waits the bound again for the pane to come back to its own shell, and
only then types the ssh line a second time and waits for a prompt; a host that
came up meanwhile answers that second connection. The interrupt is what makes
the retry a connection at all: while ssh holds the pane its terminal is that
client's, so a line pasted into it is typed into the session rather than run.
remote-prompt-missing names the bound, the attempts, and the reason, which is
the pane state the spent bound ended on: prompt-silent for ssh still holding
the pane, session-gone for a pane running no ssh, a session that died or never
started. The count of ssh lines typed is attempts, and the reason carries none
of it. A pane read that fails on this machine is reported as tmux-failed with
the operation, never as a host that showed no prompt.

Each item's worktree is created here (worktree create, or create --reuse
under --relaunch when the item's tree already exists). An item whose worktree
is owned by another session (create exit 75) is skipped and the remaining
items still launch. A hosted item takes the same skip on lane-host create
exit 75; a create lane-host refused at its per-home cap is lane-host-busy, and
any other create failure is host-create-failed. The final summary line reports
launched, skipped, and failed counts, and preparing where a hosted launch was handed to a background job.

Every launch that stands under --state-dir is recorded in the oversee
workflow state that flag names (`workflow-state get oversee .lanes`, created
when absent); a launch with no --state-dir names no fleet, records nothing
and creates no state. A record is one entry per
item, keyed by its workflow-state id, the Linear id for a Linear item and
issue-N for a GitHub item, carrying the tracker, repository, harness, window,
account dir, host, mail_root, surface, model, session_id, launched_at,
status `running`, or `preparing` with its `prepare` record for a hosted lane
handed to a background job (see --host), and over_cap, the caps an
--over-cap launch passed;
schemas/workflow-state.md § Oversee state is the shape. `oversee-watch
--state` reads the live fleet from it. A launch rewrites every field of an
entry that already names the item; --relaunch rewrites every field but item,
launched_at and over_cap and sets status back to running; --wake rewrites session_id
and status, and an item no entry names is record-missing, since this launcher
never launched it. A state that cannot be created refuses the whole launch as
state-unwritable before any window opens; a wake creates no state, and one
against an address holding none refuses the whole batch as state-absent,
naming the file it looked for, before waking anything. A record that cannot
be written
into it is record-write-failed: the window stands, the item counts as failed,
and the watch will not carry it until the record is written, by hand per
oversee.md § 3 Lane record or by a relaunch once the window is closed.

Every launch and relaunch under --state-dir is judged on two caps before its
worktree, under two locks taken in this order, one beside the fleet state and
one beside the claim store the account cap counts, both held from the count
through a reservation written into the claim store, which every later count
sees as this launch's lane until its claim or record stands, or the item
ends, so two launchers cannot both pass on one count, fleets sharing a claim
store included; a launch that finds a lock held prints lock-waiting and waits
for it. The worktree and host creates run with no lock held. A reservation
that cannot be written refuses the launch as cap-reserve-failed.
The fleet cap, ORCH_OVERSEER_LANES (default 3), counts the records whose
status is running or preparing (a hosted lane handed to a background job,
see --host) plus the live launch claims and reservations this fleet wrote
that no such record names (a claim store several fleets share counts each
fleet's own claims here, and every fleet's toward an account); a
launch that would pass it is refused as cap-reached, naming the cap, those
records and the claims. The account cap, ORCH_LANE_ACCOUNT_CLAIMS
(default 3, 0 turns it off), counts the lanes on the account the launch
would use: this fleet's running or preparing records on it, which count a
GUI lane and one whose claim was never written, plus the live launch claims
and reservations on it that are not those records' own, other fleets' lanes
among them (a claim is a record's own where it names the record's window and
account and this fleet or none); a launch that would pass it is refused as
account-cap-reached, naming the lane, the cap, that count as claims, and its
two parts as records and claims-other. Both settings are read through
orch-env. A refusal stops the batch, and so does a claim this run failed to
write under --lane auto, whose re-pick reads claims, as claim-unrecorded. A store that cannot be read refuses as cap-unreadable, and
a lock not taken as cap-lock-failed. A --relaunch meets the fleet cap where
the item has no running or preparing record, and the account cap where it
has none or moves to another account. --wake is not judged. Both flags below need
--state-dir, and are refused as cap-option-unanchored without it:
  --wait-slot       Wait for room instead of refusing: count again every 5
                    seconds, holding no lock between counts, and count and
                    reserve under the lock once both caps have room. The
                    lane is judged again first: `--lane auto` picks again,
                    also on each count where only the account cap is full,
                    and a named lane is refused as lane-model-walled if its
                    window walled during the wait. slot-waiting prints the
                    count waited on, again whenever it changes.
  --over-cap        Admit one launch past whichever caps it would pass, printed
                    as over-cap-admitted and recorded in its lane record as
                    over_cap (fleet, account, or fleet,account). One item
                    only, refused as over-cap-items otherwise.

Exit codes:
  0   at least one lane launched or handed to a background job and none
      failed (skipped items allowed)
  75  every item was skipped as owned by another session; nothing launched
  1   any lane failed (worktree create error, launch error), or usage error
USAGE
}
