# shellcheck shell=bash
#
# Owner: oversee-watch, the one script that sources this file.
#
# The prose oversee-watch prints: its message catalog, every refusal and
# notice keyed by REASON. The message header protocol is stated where
# oversee-watch sources this file.
#
# Sourced, never run.

ow_message() { # REASON FIELD=VALUE...
  local reason="$1" text field
  shift
  case "$reason" in
    missing-value) text='The option requires a value.' ;;
    option-unknown) text='The option is not supported. Use --help for supported options.' ;;
    state-directory-create-failed) text='The watch state directory could not be created. Check OVERSEE_WATCH_STATE_DIR.' ;;
    state-directory-unwritable) text='The watch state directory is not writable. Check OVERSEE_WATCH_STATE_DIR.' ;;
    interval-invalid) text='The interval must be a non-negative integer.' ;;
    handoff-invalid) text='The handoff path takes letters, digits and ./_- only, as oversee-succeed reads it.' ;;
    mail-interval-invalid) text='ORCH_WATCH_MAIL_INTERVAL takes a whole number of seconds, with no leading zero.' ;;
    unread-secs-invalid) text='ORCH_DIRECTIVE_UNREAD_SECS takes a whole number of seconds, with no leading zero.' ;;
    dead-passes-invalid) text='ORCH_OVERSEER_DEAD_PASSES must be a positive integer.' ;;
    mark-repeat-invalid) text='ORCH_OVERSEER_MARK_REPEAT must be a positive integer.' ;;
    overseer-mark-unjudged) text='The overseer own-mark judgement could not be made this pass, so its context use and account headroom settle nothing here. A standing mark is not cleared by a reading that failed; oversee-succeed owns the judgement and its own keyed line says why.' ;;
    overseer-wall-unjudged) text='The overseer pane read walled and the account judgement that would confirm it could not be made, so nothing is acted on: this pane carries the limit banners this watch relays about OTHER lanes, and the screen alone cannot tell those from the overseer own account running out. The reading is left to the next pass.' ;;
    overseer-wall-unconfirmed) text='The overseer pane read walled and its own account measures room, so the banner on that screen is one this watch relayed about another lane and the overseer is working. Nothing is launched and no window is closed. The fields name the judgement that refuted it.' ;;
    overseer-unwatched) text='The overseer pane is not being watched, so an overseer that dies is reported by nothing. The field names what is missing.' ;;
    overseer-unreadable) text='The overseer pane could not be read, so its state settles nothing this pass.' ;;
    overseer-line-missing) text='The fleet state records no overseer launch line, so a dead overseer cannot be relaunched. Start the watch with -- and the overseer flags while the overseer is alive.' ;;
    overseer-unrecorded) text='The overseer pane could not be recorded in the fleet state. A relaunch reads that record, so this watch reports a death it cannot act on.' ;;
    overseer-notice-failed) text='The overseer-dead notice could not be delivered. The field names the channel; the event line still went out.' ;;
    overseer-relaunch-failed) text='oversee-succeed refused or failed the relaunch; the overseer is not replaced and this watch keeps running. Its own keyed line says why.' ;;
    overseer-recovery-blocked) text='No account in the fleet qualifies for a successor, so the recovery stops rather than retry the same accounts. The fields name the spent account and the reset its banner states; a notice carrying both went to the fleet log and the overseer mailbox.' ;;
    overseer-succeeded) text='A successor holds the dead overseer window and runs its own watch. This one stops rather than read the fleet twice.' ;;
    repeat-invalid) text='The repeat delay must be a non-negative integer.' ;;
    state-required) text='The option reads its lanes from the oversee workflow state. Add --state PATH.' ;;
    state-unreadable) text='The oversee state file could not be read. The watch stops rather than carry a partial fleet.' ;;
    state-invalid) text='The oversee state file is not workflow-state JSON with a lanes array of records naming their item. The watch stops rather than carry a partial fleet.' ;;
    window-absent) text='tmux does not list the window. Passes carry it until one reports it gone; later passes skip it until tmux lists it again.' ;;
    sleep-failed) text='The repeat delay could not be slept. Repeat mode stops rather than run passes back to back.' ;;
    fleet-read) text='The fleet this watch carries, as the last state read gave it; printed again when a re-read changes it. dropped counts records whose status is not running, which the watch does not carry.' ;;
    max-loops-invalid) text='The loop limit must be a positive integer.' ;;
    prepare-secs-invalid) text='ORCH_WATCH_PREPARE_SECS takes a positive whole number of seconds, with no leading zero.' ;;
    tail-lines-invalid) text='ORCH_WATCH_TAIL_LINES takes a positive whole number of lines, with no leading zero.' ;;
    limit-banner-missing) text='The pane was classified walled but its screen yields no limit banner to report. The classifier and the payload disagree, so the pass stops rather than send an event with nothing its handling can read. The field names the lane, or the overseer pane where the overseer is the one classified.' ;;
    tmux-missing) text='Run in the tmux session that owns these lanes, or omit the lanes.' ;;
    since-invalid) text='Use a UTC timestamp in YYYY-MM-DDTHH:MM:SSZ form.' ;;
    helper-missing) text='The required helper is not executable. Check the named setting.' ;;
    item-invalid) text='The work item is not a supported issue identifier.' ;;
    command-missing) text='The required command is not on PATH.' ;;
    auth-failed) text='No configured GitHub credential works. Run gh auth login.' ;;
    repo-unresolved) text='Specify a repository because GitHub could not resolve it.' ;;
    repo-duplicate) text='Name each repository once.' ;;
    pr-list-failed) text='The GitHub PR list command failed.' ;;
    pr-list-invalid) text='The GitHub PR list output could not be parsed.' ;;
    triage-state-failed) text='The fleet triage verdict log could not be read.' ;;
    triage-item-invalid) text='The fleet triage log contains an invalid issue identifier.' ;;
    time-failed) text='The current UTC time could not be read.' ;;
    tracker-list-failed) text='The tracker list command failed.' ;;
    tracker-list-invalid) text='The tracker list output could not be parsed.' ;;
    handoff-read-failed) text='The handoff record could not be read.' ;;
    lane-close-failed) text='lane-close failed before it completed the close. The next run reports the exit again and retries.' ;;
    hosted-invalid) text='Spell --hosted as ITEM=REMOTE_ROOT, with the item in letters, digits, dot, underscore and hyphen.' ;;
    hosted-unknown-item) text='The --hosted item is not one this run watches. Name it with --item, or drop the entry.' ;;
    root-invalid) text='Spell --root as ITEM=PATH, with the item in letters, digits, dot, underscore and hyphen.' ;;
    root-unknown-item) text='The --root item is not one this run watches. Name it with --item, or drop the entry.' ;;
    root-duplicate) text='Name each --root item once: two roots for one lane would read one mailbox and drain the other.' ;;
    hosted-duplicate) text='Name each hosted item once.' ;;
    hosted-without-host) text='A hosted lane is carried, and lane-host resolves this host to local, so its mailbox, state and close would be read on this disk where the lane is not. Set ORCH_LANE_HOST to the provider the lane was launched through, in kendex.settings.toml [env] or .env.local.' ;;
    host-resolve-failed) text='lane-host could not say which host the hosted lanes live on, so none of them is read. Its own words follow.' ;;
    session-resolved) text='The tmux session every bare lane window name is read in, resolved once while the pane that started this watch still exists.' ;;
    session-unresolved) text='A bare lane window name is carried and tmux named no session for this watch, so the name could resolve through whichever session tmux picks. Start the watch from the overseer pane, or record the window as SESSION:WINDOW.' ;;
    watch-running) text='Another watch already runs on this fleet state, and this start could not show its pane gone: tmux lists it, or this start runs outside tmux, the record names no pane, or the pane list could not be read. Two watches would read one overseer mailbox and each replay what the other drained. Handle its events, or stop it as references/watch-delivery.md states and start again; the pid field is the watch that read finds.' ;;
    watch-replay-failed) text='The output a restarted watch left beside the fleet state could not be printed or removed, so the start stops rather than lose it or print it twice. The path names the file.' ;;
    watch-record-failed) text='The watch could not write its own record beside the fleet state, so a second watch could not be refused and a succession could not restart this one.' ;;
    watch-finishing) text='The watch taken over is finishing a lane-close. This start waits for it to exit, so the lane row is committed before this watch reads it and the output of a restarted watch is replayed whole. The close outcome is in the output of the old watch: for one references/waiter-launch.md started, the log in its run directory.' ;;
    watch-taken-over) text='A live watch on this fleet state was stopped and this one runs in its place. The reason field says why it could be: succession is the watch oversee-succeed restarted for this pane, pane-gone one whose pane tmux no longer lists.' ;;
    watch-replayed) text='A watch oversee-succeed restarted wrote output no session read, and the restart wrote how it went. Both follow, stdout here and stderr on stderr, and are then removed, so no event it reported and no refusal it ended on is lost.' ;;
    mail-read-failed) text='The lane mailbox could not be read. Fix what lane-mail names rather than reading the lane as silent.' ;;
    lane-host-busy) text='No lane-host slot freed; the next pass retries.' ;;
    mail-read-invalid) text='The lane mailbox reader did not open with its count line.' ;;
    limit-scan-failed) text='The screen could not be searched for a usage limit. The field names the lane, or the overseer pane where the overseer is the one being read.' ;;
    reset-scan-failed) text='The limit banner could not be searched for its reset clause.' ;;
    window-list-failed) text='The tmux window list could not be read.' ;;
    pane-command-failed) text='The pane command could not be read.' ;;
    pane-command-invalid) text='The pane command reply is malformed.' ;;
    pane-identity-failed) text='The pane identity could not be read.' ;;
    pane-identity-invalid) text='The pane identity reply is malformed.' ;;
    pane-capture-failed) text='The pane could not be captured.' ;;
    pane-publish-failed) text='The pane capture could not be published.' ;;
    state-write-failed) text='The watch state file could not be written. Check OVERSEE_WATCH_STATE_DIR.' ;;
    state-replace-failed) text='The watch state file could not be replaced. Check OVERSEE_WATCH_STATE_DIR.' ;;
    state-read-failed) text='The watch state file could not be read. Check OVERSEE_WATCH_STATE_DIR.' ;;
    reducer-failed) text='The PR reducer failed without per-PR output.' ;;
    triage-disabled) text='Team triage is skipped because LINEAR_TEAM is empty. Other watch checks continue.' ;;
    reducer-missing) text='The PR reducer is missing. Other watch checks continue.' ;;
    items-omitted) text='No work items were supplied. Merged and handoff checks are skipped.' ;;
    lanes-omitted) text='No lane windows were supplied. Pane checks are skipped; the named checks continue.' ;;
    child-probe-failed) text='The child-process probe could not run. Shell panes remain watched.' ;;
    report-unjudged) text='oversee-report could not judge whether a report is due, so the pass says nothing about it and exits 2. Its own keyed lines follow.' ;;
    account-unread) text='The account roster could not be read this pass, so no account event is judged and a heartbeat carries account-roster unread in place of the roster. The baseline stands for the next read. The field names the exit, the seconds the ceiling allowed, or parse=failed when the listing or a record in it could not be read.' ;;
    account-reset-unparsed) text='The binding_resets_at the baseline held could not be parsed into a time, so whether that bucket reset settles nothing, and the baseline has already moved to the new reading: that reset is not reported. Status and headroom changes on the account are still judged.' ;;
    claim-missing) text='The pane has no live lane claim. The usage event names no account.' ;;
    reducer-baseline) text='The initial PR attention is the baseline. Only new attention produces events.' ;;
    state-target-invalid) text='The watch state target is not a regular file.' ;;
    long-pass-unfinished) text='The long pass exited 0 without writing its status, so whether it found news is unknown.' ;;
    *) printf 'oversee-watch: message-invalid reason=%s\n' "$reason" >&2; return 2 ;;
  esac
  printf 'oversee-watch: %s' "$reason"
  for field in "$@"; do
    field="${field//\\/\\\\}"
    field="${field//$'\t'/\\t}"
    field="${field//$'\r'/\\r}"
    field="${field//$'\n'/\\n}"
    printf ' %s' "$field"
  done
  printf '\n%s\n' "$text"
}
