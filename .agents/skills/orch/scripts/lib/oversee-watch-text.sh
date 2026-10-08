# shellcheck shell=bash
#
# Owner: oversee-watch, the one script that sources this file.
#
# The prose oversee-watch prints: its --help text, which is also the reference
# for its EVENT records, settings and failure contracts, and its message
# catalog, every refusal and notice keyed by REASON. Sourced ahead of the
# argument parser, which answers a help request before any configuration is
# read.
#
# Sourced, never run.

usage() {
  cat <<'USAGE'
Usage: oversee-watch [--interval SECS] [--max-loops N] [--since ISO8601]
                     [--item ISSUE_ID]... [--repo OWNER/REPO]...
                     [--hosted ITEM=REMOTE_ROOT]... [--root ITEM=PATH]...
                     [--handoff PATH] [--state PATH [--skip-lane WINDOW]...]
                     [--harness claude|codex|copilot|pi] [LANE_WINDOW...] [-- OVERSEER_FLAGS...]
       oversee-watch --repeat SECS --state PATH [any option above]...

Blocks until the fleet needs the overseer, then prints every event it found
as one block, each line prefixed with its kind, and exits once. Re-run after
handling every line with the live fleet in scope.

Two passes run on one clock. The mail pass starts every
ORCH_WATCH_MAIL_INTERVAL seconds, reads every lane mailbox, the overseer
mailbox and the lane records one after another, and prints what it finds as
it finds it: lane-question, lane-notice, directive-read, directive-unread,
peer-note, owner-note, owner-ask-resolved and owner-ask-closed. Before the
overseer mailbox is read, `lane-mail resolve --default` closes due owner asks.
Only an unanswered ask receives a recommendation answer. The interval is
counted start to start and kept across runs in the state directory. Between
two mail passes, and through a --repeat sleep, the overseer mailbox's size is
checked once a second, and once it moves that mailbox alone is read, so a
note to the overseer is printed within about a second while the lane
mailboxes keep the interval; a run's first turn reads it alone too when no
mail pass is due. A run's first long pass follows a read of every mailbox in
that run, due or not. ORCH_WATCH_MAIL_INTERVAL 0 checks nothing between turns. A read that waits
on a lock or a slow host delays
the mailboxes after it past that interval, as do the overseer pane below and,
run in this loop, a run's one GitHub auth check before its first long pass
and the heartbeat's open-PR listing. The long pass reads everything else
every --interval seconds, counted start to start and kept across runs in the
state directory, so a run ending on mail news brings the next one no nearer. A long pass runs apart from the mail pass: one that overruns its
interval holds up no mail pass, the next one starts only once it has ended,
and its lines are printed together when it ends. A run with news starts no
further long pass past one already due on the turn the news came, and exits
once none is in flight. A block holding only mail news carries no pr-watch
context. The heartbeat reads the mail once more when a long pass ended after
the last mail pass.

The long pass's events, checked and reported in this order:
  EVENT overseer-dead <pane> window=<window> passes=<N> succession=<on|off>
        source=<record|rows|process|context|pane> [record=<server>:<pane>|none]
                             the OVERSEER's own session — the $TMUX_PANE this
                             watch was started from — read `exited` on N
                             consecutive passes. `source` names what settled
                             it: `context`, a harness still up whose context
                             fills its window, so it takes no turn again: a
                             StopFailure row naming a prompt-too-long error,
                             or its context record a reading at or past the
                             window it names with no Stop row after it, for
                             a claude, codex or pi reading only: a copilot
                             reading's window is where Copilot compacts;
                             `record`, the exit status `overseer-run`
                             wrote into the fleet state's overseer.exit once
                             the launch line returned, over a bare shell with
                             nothing but shells under it; `rows`, a SessionEnd
                             row its harness wrote to the file the fleet
                             state's overseer.session_rows names, over that
                             same bare shell; `process`, a pane whose process
                             is a bare shell with nothing but shells under it;
                             `pane`, the named fallback where no row can
                             judge, the pane captured and read by the shared
                             judge, with an overseer-fallback notice naming
                             the cause.
                             record= is carried where no successor is launched
                             for want of a line: the fleet state's overseer
                             record by its server and pane, or none. Nothing
                             else notices an overseer that ended: its lanes
                             keep working, this watch keeps printing to a log
                             nobody reads, and the fleet runs unattended. The
                             line also goes to the fleet log and to the
                             overseer mailbox, where the successor reads it as
                             an owner-note. Unless ORCH_OVERSEER_SUCCESSION is
                             `off`, the watch then launches that successor
                             into the dead pane's window slot through
                             `oversee-succeed --dead-pane`, with the launch
                             line the fleet state recorded (a succession's
                             pending successor line ahead of the session's
                             own), and stops: the successor runs a watch of
                             its own
  EVENT overseer-walled <pane> window=<window> passes=<N> succession=<on|off>
        source=<rows|account|pane>
                             the same session read `walled`: from `rows`, a
                             StopFailure row whose error is `rate_limit`,
                             standing unless its account measures room, its
                             message, or message=unrecorded, under the line; from `account`, a live
                             session whose own account judgement reads
                             mark-reached kind=headroom value=0, account
                             and reset under the line; both on the first pass that
                             reads them. Or, from the `pane` fallback, on N
                             consecutive passes read by the same judge AND
                             that judgement reading mark-reached
                             kind=headroom: the harness is still running
                             and its ACCOUNT is spent. Such a session
                             takes no turn, so it answers no lane, reads no
                             mail and cannot hand itself over — a fleet as
                             unattended as a death leaves, reached by the
                             other road. The account judgement is
                             `oversee-succeed --check-marks`, the same one
                             overseer-mark rests on, and it is required
                             because THIS pane carries the limit banners this
                             watch relays about other lanes: a wall the
                             account refutes is one of those, and the pane is
                             left alone under overseer-wall-unconfirmed. The
                             banner's own window follows a pane wall's line,
                             as it does for a lane's usage-limit. The line
                             goes to the
                             same two channels. The successor is launched
                             through `oversee-succeed --walled-pane`, which
                             picks its account afresh and never reopens on the
                             spent one; the line it built is on the watch's
                             stderr under the event. Where no account
                             qualifies, one `overseer-recovery-blocked` notice
                             naming the account and when its binding bucket
                             frees up goes to both channels and the repeat
                             stops
  EVENT overseer-mark <pane> kind=<headroom|rate|qualifying> value=<N> mark=<N>
                             succession=<on|off>
                             the OVERSEER's own account reached its mark,
                             judged by `oversee-succeed --check-marks`; who
                             judges its context mark is
                             references/oversee-events.md § Judgement rules,
                             the overseer's own case. It reaches an overseer
                             BETWEEN turn ends, where its lane-mail-check
                             hook judges no account mark: the hook refuses at
                             the same marks at a turn end, and a session part
                             way through a long turn meets neither until this
                             line.
                             The route follows on the next line. Emitted once
                             at the crossing and again every
                             ORCH_OVERSEER_MARK_REPEAT passes while it stands;
                             a reading that could not be taken leaves the
                             standing mark where it was and says so on stderr
  EVENT overseer-context-unmeasured <pane> gap=<reason>
                             this overseer's context record, context.json in
                             the overseer mailbox, carries no reading: its
                             lane-mail-check hook read nothing and
                             wrote why as the gap, a word that hook's
                             description lists. With no reading its context
                             mark is not judged (references/oversee-events.md
                             § Judgement rules). The route per gap is
                             references/overseer-session-events.md.
                             Emitted on the first long pass it stands; still
                             standing on the next, it goes to the owner
                             instead, as one `lane-mail notice --to owner`
                             and one fleet-log row, with an
                             overseer-context-alerted line on stderr; a
                             notice that fails is tried again the next pass,
                             and once it is sent neither is repeated while
                             that gap stands.
                             A record another session wrote, naming another
                             pane, a harness other than the fleet record's or
                             a session other than the pane's latest start,
                             prints neither context event
  EVENT overseer-context-stale <pane> age=<seconds>
                             this overseer's context record is more than an
                             hour old and a turn end its hook dated with a
                             Stop row came after it, so its turn ends record
                             nothing and its context mark is judged by
                             nothing; a session with no Stop row after the
                             record gets no such judgement. Emitted every long
                             pass it stands
  EVENT pr-watch rc=N        new review-gate attention; reducer output follows
                             refresh-ready wakes on the opening pass and
                             once per new head, including without a lane
  EVENT merged <PR> <branch> <repo>
                             an --item PR merged at or after --since, in any
                             --repo, <branch> being the item's own, its key
                             lower-cased. The PR is the item's by
                             lib/lane-state.sh's lane_own: the number a
                             parked record names, a head on that branch, or
                             the key in its title's conventional-commit scope
                             or right after Closes on a body line, as a
                             Claude cloud session's claude/ branch names no
                             item; a search for the key that fills its page
                             exits 2 as merged-search-truncated at 1000. A
                             parked record's item is an --item for
                             this check alone, and the merge of the pull
                             request its record names, in that repository,
                             is followed by parked-merged below. Another pull
                             request on the branch's name is reported and
                             hands nothing on, under a parked-merge-unmatched
                             note on stderr naming the recorded key and the
                             keys seen; the repository is matched in lower
                             case, GitHub's names being case-insensitive
  EVENT parked-merged <item> pr=<N> repo=<owner/repo>
                             the pull request a parked record names merged in
                             that repository, repo= in lower case: the
                             sandbox stays stopped, the record stays parked
                             and nothing is closed, since nothing here wakes a
                             parked sandbox and the record carries no launch
                             flags. The overseer relaunches the lane, which
                             runs its own post-merge. Printed in the pass
                             that reports the merge, and again ahead of every
                             heartbeat while the record still reads parked
                             and its merged row holds that pull request; the
                             relaunch rewriting the record stopped ends it
  EVENT triage <item>        an item created at or after --since that is absent
                             from the first repository's persisted baseline
  EVENT outside-contribution <repo>#<N> kind=<pr|issue> author=<login> [head=<sha>]
                             an open pull request in any --repo, or an open
                             issue in the first, whose author is outside the
                             fleet: not an app or bot account, and not a
                             login GitHub associates with the repository as
                             OWNER, MEMBER or COLLABORATOR. A pull request
                             carries head=, its head commit on the list.
                             Reported once while it stays open, and a pull
                             request again once per new head; a
                             first-repository baseline row keeps it quiet,
                             and closing it clears the row.
                             ORCH_EXTERNAL_TRIAGE=off lists nothing
  EVENT refresh-failing <repo> runs=2 last=<run-id> since=<time> report=initial|repeat cause=<line>
                             the last two completed kendex-refresh.yml runs
                             both failed. last= names the newer run and since=
                             is the older run's createdAt. report=initial starts
                             a new incident; report=repeat continues a standing
                             incident, including a cause change. cause= is the
                             newer run's failed-step log line of the highest
                             rank, read without gh's job, step and timestamp
                             prefix, the last such line on a tie: a failed:
                             row, a FAIL check= row, an Error: line, a
                             refresh-error= line, then the text from
                             kendex-hook- on in a hook warning; unread means
                             the log could not be read or held no ranked line.
                             Reported once, again when the
                             cause changes, and every ORCH_OVERSEER_MARK_REPEAT
                             long passes while it stands. A success clears it.
                             A new pair is reported only when its newer run is
                             the newest run the watch has read and not yet
                             judged. A pair that would open an incident, or
                             any pair with no run recorded, is reported only
                             when its newer run is also the newest completed
                             run in the unfiltered run list. A later attempt
                             of a re-run is newer. A page older than the
                             newest run read, or a pair that list does not
                             confirm, prints refresh-stale on stderr and
                             judges nothing.
                             A repository without that workflow is skipped.
                             A failed read prints refresh-unread on stderr,
                             leaves the failure pair intact when the run list
                             is unread, and keeps watching
  EVENT security-alert <repo> kind=<dependabot|code-scanning|secret-scanning>
        number=<N> [severity=<s>] <package|rule>=<name> [manifest=<path>]
        [scope=<scope>] [advisory=<GHSA>] [validity=<v>] url=<url> [pr=<N>]
        [report=repeat]
                             an open alert in any --repo that the fleet
                             state's alerts_triaged records no verdict for:
                             a Dependabot alert names its package, manifest,
                             scope and advisory, and pr= the open Dependabot
                             pull request that fixes it, manifest= being the
                             repository path percent-encoded, %20 a space
                             and %25 a percent sign; a code scanning
                             alert its rule; a secret its type and, where
                             GitHub checks it, its validity. Reported, then
                             printed again with report=repeat on every long
                             pass that reads alerts_triaged and the alert's
                             own list, until a record or the alert closing
                             clears its first-repository baseline row; a
                             read that fails or a scanning feature turned off
                             prints no repeat for that source. A repeat does
                             not itself end the run.
                             ORCH_SECURITY_ALERTS=off lists nothing
  EVENT security-alerts-unread reads=<source>:<cause>[,...]
                             an alert list or the alerts_triaged record could
                             not be read, or carried a line the check cannot
                             read. A source is <repo>/<kind>,
                             <repo>/dependabot-prs (the alert-to-pull-request
                             link), alerts_triaged or installation-token.
                             A cause is permission, vanillagreen-overseer
                             lacking that alert permission; credential, its
                             supplied token file unavailable or invalid;
                             feature-off, Dependabot alerts turned off on
                             that repository; http-<status> or
                             exit-<N> for any other failure; or invalid.
                             Printed on every long pass a read fails, and
                             ends the run only when the set of failed reads
                             changes. Code or secret scanning answering
                             feature-off, as on a repository without GitHub's
                             paid security products, is off: no line, on
                             stdout or stderr. The rows of a failed source stand
  EVENT lane-ready <item>    a lane open-terminal handed to a background job
                             while its host prepared it is launched: its
                             record reads running, and the watch carries it
  EVENT lane-prepare-failed <item> reason=<reason> log=<path>
                             that job failed and closed its window: reason
                             wait-failed is the host's preparation,
                             launch-failed a launch step, each named in the
                             job's log. The record reads stopped, which
                             lane-close closes
  EVENT lane-prepare-stuck <item> age=<secs>s log=<path>
                             that record has read preparing for longer than
                             ORCH_WATCH_PREPARE_SECS with no outcome written;
                             lane-close closes it.
                             These three are read from --state records and
                             reported once per preparation
  EVENT start-stalled <item> age=<secs>
                             a running --state record names a mail_root whose
                             tmp/lane-status-<item>.md does not exist
                             ORCH_WATCH_START_STALL_SECS after the record went
                             running, its running_at (launched_at on a record
                             with none), on every harness, a hosted one read
                             through `lane-host cat`: the lane never started
                             its workflow. age= counts from that stamp, which
                             a relaunch renews, so the line after a relaunch
                             is a second stall. Reported once and again every
                             ORCH_OVERSEER_MARK_REPEAT passes while it stands;
                             a record whose file once stood is never reported.
                             A record whose host kind declares files=none, a
                             cloud session, writes no file: its open pull
                             request on the item branch stands in for it
  EVENT lane-stalled <item> age=<secs>
                             a running record whose host kind declares
                             status=none, a cloud session, has an open pull
                             request on the item branch whose head commit and
                             body, its `## Lane status`, have not changed for
                             ORCH_WATCH_LANE_STALL_SECS: one `gh pr list` per
                             such lane per repository per long pass, shared
                             with the start-stall check, where a fork's pull
                             request on the branch name never counts, the
                             watch state keeping the last head and a body
                             digest. Reported once
                             and again every ORCH_OVERSEER_MARK_REPEAT passes
                             while it stands; a change starts a fresh window
  EVENT lane-long <item> age=<secs> review_rounds=<n> repeated_class_rounds=<n> stage=<step>
                             a running or parked --state record is
                             ORCH_WATCH_LANE_AGE_SECS past its launched_at,
                             which --relaunch and handoffs keep and a fresh
                             launch after lane-close renews. stage= is the Step line of its
                             status file, `parked`, `unread` where its read
                             failed, or `none`. Reported once per age interval
                             of ORCH_WATCH_LANE_AGE_SECS, including after a
                             relaunch; a late pass reports the current interval
                             review_rounds adds the first internal panel,
                             re-review cycles and comment-review iterations.
                             repeated_class_rounds counts later distinct patch
                             commits repeating a recorded cause, once per commit.
                             With no recorded cause that count is `-`.
                             Both counts are `-` for absent or unread state,
                             a file-less lane, or a parked lane whose stopped
                             disk is never read
  EVENT window-gone <lane>   the tmux window no longer exists. Nothing follows
                             the line: the remedy is one relaunch, which
                             reads the item's worktree and PR, not a screen
  EVENT lane-exited <lane>   local shell with nothing but shells under it on two
                             consecutive passes, or provider exit now despite
                             live SSH, for a listed hosted lane whose running
                             record names the harness.
                             Closing lines follow. Failed provider reads stay
                             unjudged; unusable local probes keep the lane watched
  EVENT lane-closed <item>   under a lane-exited whose window watches a --hosted
                             item already reported merged, once the pass finds
                             its worktree gone: `lane-close` succeeded; its
                             `kept=` line follows, its `closed=absent item=ID`
                             line where the host no longer held the item and
                             ran no archive pass, or else `kept=none` because
                             the close kept no archive. A lane exiting while its
                             worktree stands is not closed
  EVENT lane-close-refused <item>
                             the same close exited 3: its clone or worktree
                             has user-owned changes. Generated whole-file render
                             drift is archived and cleaned instead of refused.
                             `path=PATH` follows, taken from the
                             provider's `close-refused path=PATH` line, or
                             `path=unknown` without one; the sandbox stays.
                             Never retried, never --force
  EVENT handoff <item>       the --item's workflow state carries a `.handoff`
                             record with no `.resumed_at`; the record follows.
                             Emitted once per record, on every surface: it
                             reads the item's state, never a pane.
  EVENT usage-limit <lane> [<config-dir>] [resets=<utc>]
                             a live harness with no turn in flight shows a
                             limit banner below the last user turn on its screen.
                             The block that follows is a window AROUND that
                             banner, a few lines above it and the rest of the
                             cap below, so the banner is always in the block
                             and the sentence marking a quoted wall travels
                             with it.
                             `resets=` carries the reset time the banner
                             states; the wall is still standing. It is absent
                             when the banner states no reset in a shape the
                             harnesses draw OR names a time zone this host
                             cannot resolve. A clause naming a clock and no
                             day is pinned to the first occurrence after the
                             pass this watch first saw the banner on. The pass
                             that sees the banner gone, replaced or its window
                             gone keeps the wall, from that first pass, in the
                             `pauses` of the last fleet record naming the
                             window
  EVENT usage-limit-passed <lane> [<config-dir>] resets=<utc>
                             the same banner, naming a reset that has gone by:
                             the screen is remembering a spent window that has
                             reopened. Bump the lane, never park it. A clause
                             naming only a clock or a weekday reaches this only
                             once this watch has seen that wall standing; one
                             naming a date is spent on sight
  EVENT lane-asking <lane> [<copilot note>]
                             a question or selection prompt, or its copilot
                             note, differs from the last one emitted for this
                             lane; the dialog follows.
                             A Copilot lane launched with allow-all
                             carries stop-cause=<cause> or
                             session-record=<reason> where its session
                             record names one (lib/copilot-session.sh
                             copilot_session_lane_note)
  EVENT model-capacity <lane>
                             a Codex turn ended because its selected model is
                             at capacity. Nothing follows the line: the
                             remedy is one continuation line back to the lane
  EVENT idle-after-return <lane> [<copilot note>]
                             Codex sits idle on the first long pass; other
                             harnesses sit idle on two passes. The
                             lane's closing lines follow, and the note is
                             lane-asking's. A Pi lane is idle,
                             working or walled by the last row its own
                             lane-mail-check hook wrote under the pi-hooks
                             carrier, a Stop at its turn end or a PreToolUse
                             at the first tool call of a turn, never by its
                             pane: the lines under this event are the pane's,
                             read as payload alone, and a Pi lane with no row
                             is unjudged, never idle. Its usage-limit block is
                             that row's error message
  EVENT account <alias> config_dir=<dir> harness=<harness> through=<local|host>
                status=<status> verdict=<room|walled|unmeasured> headroom_pct=<N|->
                binding_bucket=<bucket|-> binding_resets_at=<utc|->
                change=<status|headroom|reset>[,...] was=<status>/<verdict>
                             an account the fleet can launch on changed since
                             the last pass that read it, as `lanes list --json`
                             reads it once per pass: its status word changed,
                             its verdict against ORCH_LANE_MAX_PCT crossed in
                             either direction (a Codex account on its credits
                             reads room, binding_bucket=credits: `lanes
                             --help`, pick), or the binding bucket reset the
                             last reading named has passed and the reading has
                             moved off it. `change=` names every one that
                             applies and `was=` the status and verdict before
                             it. `config_dir` names the credentials, since
                             two accounts can share an alias. The first
                             reading of an account is its baseline and an
                             unchanged account says nothing. A reading with
                             verdict=unmeasured under the status the
                             account's last unmeasured reading had says
                             nothing either and is not compared: the next
                             measured reading is compared with the last one
                             measured, so a hosted credential the provider
                             holds while a lane runs on it, unmeasured on
                             alternate passes, is news once. status=expired
                             is exempt: each expiry after a measured reading
                             is news. `was=` is the reading compared with
  EVENT report-due reason=<minutes|issues> since=<utc> [landed=<N>]
                             the overseer's status report is due, as
                             `oversee-report due --state` judges it from the
                             newest owner progress report and the ORCH_REPORT
                             settings. Reported on every long pass while it
                             stays due, so it stops once a report is written;
                             read only with --state
  EVENT verifying-deadline <item> box=<N> deadline=<UTC>
                             an open post-merge box reached its UTC deadline.
                             Read its evidence, tick it and complete the same
                             item, or comment failure and move it In Progress.
                             A deadline alone does not prove failure. Emitted
                             once per standing item/overdue-box set; ticking,
                             leaving Verifying or changing deadlines resets it.
  verifying <item> box=<N> deadline=<UTC> reading=<JSON> where=<JSON> why=<JSON>
                             every open post-merge box from the long pass's
                             tracker read, before active/queued lane filtering.
                             Printed with the event block or heartbeat. An item
                             with none prints verifying <item> boxes=0.
  EVENT heartbeat            --max-loops long passes with no event, after
                             the repeated parked-merged lines above. A line
                             `  failing <item> <key>` follows for every lane
                             of the current fleet whose failure still stands,
                             reported once and quiet since, then every
                             --repo's open PRs, each line prefixed with its
                             repo, a Dependabot pull request an alert links
                             as `bot-fix pr=<N> alert=<alerts|none>` from the
                             last long pass's reading while
                             ORCH_SECURITY_ALERTS is on: none where every
                             alert that links it has left the open list. One
                             no alert links, a version update or one opened
                             since, keeps its plain line. Then
                             `account-roster accounts=<N>` and one
                             `account <alias> config_dir=...` line per
                             account, the fields the account event carries up
                             to `change=`, from the last long pass's reading.
                             `account-roster unread` replaces them when that
                             reading failed. Last, with --state, one line
                             `owed <item> state=<in-progress|in-review|open-pr>
                             priority=<N|-> lane=<none|status> verdict=<queue|
                             merged pr=<N>|dated harness=<h> until=<reset|->|
                             unjudged harness=<h>>` per item the tracker holds
                             as work the fleet owes that launch_queue lacks:
                             with LINEAR_TEAM, the team's In Progress and In
                             Review items, from the long pass's one live read
                             that also supplies Verifying boxes. A priority of 0 (none)
                             printed `-`; with none, every open PR of the first
                             --repo on an issue-N branch, from a listing of its
                             own that exits 2 as owed-list-truncated at 1000.
                             A record running, preparing or parked owes
                             nothing; a parked one over its merge is named by
                             parked-merged instead. `merged` is a record carrying its merge's
                             `cycle`. A record with no harness is `queue`.
                             Every other verdict reads the accounts of the
                             record's host, its `host` or `local`, as
                             ORCH_LANE_HOST: a `lanes list` there that fails
                             is `unjudged`, named as owed-accounts-unread; one
                             listing no account of the harness is `queue`;
                             otherwise `lanes pick --harness <h> [--model <m>]`
                             with the record's harness and model decides:
                             room is `queue`, a wall `dated` until the
                             walled_resets_at that pick names, the earliest
                             reset of the window that decided each walled
                             account on that model and host, and every account
                             unmeasured or a failed pick `unjudged`, the
                             failure named as owed-wall-unjudged

The mail pass's events, in this order, lane by lane and the overseer's own
mailbox last:
  EVENT lane-question <item> <id>
                             the --item's lane appended an ask to its lane
                             mailbox; its text follows. Answer it with
                             `lane-mail send --re <id>`. Read from the
                             mailbox, never a pane, so it runs on every
                             surface, inside tmux or not
  EVENT lane-notice <item> <id>
                             the same, for a notice the lane wants read but
                             is not waiting on; its text follows
  EVENT directive-read <item> <id>
                             the lane's to-lane.cursor has passed a directive
                             sent to it: the lane has read it. The cursor is
                             the receipt, whichever of the lane's read paths
                             moved it. A lane first watched is taken as
                             having read up to its cursor, reported for
                             nothing already read; a cursor lane-mail
                             reports `missed` seeds nothing
  EVENT directive-unread <item> <id> age=<seconds>
                             a directive the cursor has not passed is older
                             than ORCH_DIRECTIVE_UNREAD_SECS; reported on
                             the first mail pass past that age, and again
                             as directive-read once the lane reads it
  EVENT peer-note <repo> <id> kind=<kind> [re=<ask id>]
                             a note, ask or answer another repository's
                             overseer sent to this one with `lane-mail peer`.
                             kind is ask, answer or directive, and only an ask
                             is owed a reply; `re=` names the ask of this
                             overseer's that an answer replies to
  EVENT owner-note <id>      a note in the overseer's own mailbox, sent with
                             `lane-mail send --item overseer --directive`;
                             its text follows. Read with or without --item.
  EVENT owner-ask-resolved <ask id> by=<text|default> id=<answer id>
                             an answer to an owner ask; its text follows.
                             Each answer has its own id and leaves the ask
                             open until resolve closes it. A default answer
                             supplies the recommendation only if unanswered.
  EVENT owner-ask-closed <ask id> by=<explicit|text|default>
                             the separate close record. The owner's words
                             stand when an answered ask reaches its deadline.
                             Every text and `options:` line of these kinds
                             is indented two spaces, so a message line never
                             begins with EVENT
The overseer mailbox is read through its own to-lane.cursor, which a session
start's `lane-mail inbox --item overseer` moves too, acknowledged only once
its notes are printed, whatever state directory, --since or checkout this
watch runs with. A session start's read between the peek and the
acknowledgement reports a note twice. The lane-mail hooks move it too, for
the session the fleet record names while no repeat watch holds the fleet
state: with single passes, the overseer itself. A line they take is not
reported here.
Before every mail pass the overseer's session is read once, as the long pass
reads it; while it reads exited, or walled, no mailbox is read, so a
successor finds what was sent in the meantime. A rows wall stands unless its
own account measures room; a screen wall stands only where its own account
confirms it, and one no judgement could settle reads live. A wall that reads
live has its mail read, and the long pass starts no successor for it. Off tmux there is no
such pane and the mail is read; a pane that cannot be read reads live too,
except while a long pass is in flight, which may be closing it in a
succession, and the mail waits for that pass to end.

Every pane payload above is the lines that event's handling reads and no
more, always taken from below the lane's last user turn and capped by
ORCH_WATCH_TAIL_LINES. A dialog and a closing report are drawn at the bottom
of a pane, so those keep the LAST lines of the slice and a longer slice
loses its top ones; nothing in the event recovers them, and only a larger
ORCH_WATCH_TAIL_LINES carries more. A usage-limit block is the exception: it
is a window around the banner rather than either end of the slice, so the one
line its handling needs is never the line the cap drops, and it arrives with
the lines on BOTH sides that say whose words they are.

Only lane-exited drops the prompt noise a removed worktree repeats
(`^Hook failed:` and `^bash: cd: ...: No such file or directory`), which
would otherwise be the whole payload of a lane that deleted its own tree; the
shell drawing those has the terminal back only once the harness is gone, so
no other kind can carry them. A slice that is nothing but that noise prints
`payload-noise-only lines=N` in place of the block, so silence and
suppression read apart. No other payload is filtered.

The latest pr-watch attention lines close the block when any exist and the
pr-watch event did not open it. Triage
reads the live tracker list and rebuilds only acknowledged triage keys in the
first repository's OVERSEE_WATCH_STATE_DIR baseline from kept or canceled
verdicts. Lane prompts use pane and turn.

A line already delivered is not delivered again by a re-run: overseer-dead,
overseer-walled, merged, lane-asking, usage-limit, model-capacity,
lane-exited, idle-after-return, handoff, account and outside-contribution
are keyed in that baseline. A security-alert is keyed there too, and a re-run
prints it again only as report=repeat while no verdict names it. Mail is reported at least once and never lost: lane-question,
lane-notice, directive-unread and, for a directive read after its lane is
first watched, directive-read are keyed in the mail pass's own file beside
it, owner-note, owner-ask-resolved and peer-note by the overseer mailbox's
cursor, each committed only once printed, so a stop between the two reports a line
twice: a repeated id is one already seen. A lane whose to-lane read
lane-mail reports `missed` has nothing reported or moved that pass; a cursor
below the one reported holds only its directive lines. Each repeats only when what it reports changes: another PR, a
different wall or a reset gone by, a replacement pane, a different screen, a
new record, another account state, a pull request's new head. An unchanged standing overseer-mark or refresh-failing
comes back on a timer: it is reported every ORCH_OVERSEER_MARK_REPEAT passes
while it stands, so a repeat there is the interval and never a new crossing.
A suppressed line still holds: a walled lane
stays walled, an overseer past its mark is still past it, and the
pass runs on to the remaining checks and the heartbeat. A lane mailbox read
that comes back shorter than the lines already drained from it, an empty one
included, is a read that missed lines rather than a replacement, and moves no
position: only a mailbox opening with another envelope, or one whose first
line carries no id and that holds fewer lines, is read whole again.

Options:
  --interval SECS     seconds from the start of one long pass to the start of
                      the next (default 240)
  --max-loops N       long passes before a heartbeat (default 25)
  --since ISO8601     UTC created/merged-at floor, with a Z suffix. Pass the
                      fleet's fixed start time on every run, never "now" — the
                      value names the state file, so a run given a different
                      one starts from no sightings and parks every walled lane
                      afresh; LINEAR_TEAM below arms the triage check
  --item ISSUE_ID     live item; repeatable. No values skips merged and
                      handoff with a note
  --repo OWNER/REPO   repository; repeatable and case-normalized. Every
                      check reads all of them; triage and lane rows persist
                      in the first one's baseline, mail rows in the file
                      beside it. ORCH_CONNECTED_REPOS below adds more after
                      them; with none given, the first is the repository
                      this checkout resolves to
  --hosted ITEM=REMOTE_ROOT
                      the item's lane lives on another host; its mailbox is
                      read through `lane-host` against REMOTE_ROOT rather
                      than this disk. Repeatable, once per item. An item with
                      no --hosted entry is read from `worktree path ITEM`,
                      and the project root when that reports none. The
                      clone root is learned from REMOTE_ROOT/.git and kept:
                      the item's workflow state is read from the clone, and
                      so is its mailbox once the worktree is gone. A window
                      watches the item it is named for, and gh-N watches
                      issue-N, as open-terminal names a GitHub item's lane.
                      A state record's lane is read under the host the
                      record names and routed by what that host kind
                      declares (lane-host capabilities): files=verb through
                      lane-host, files=local on this disk, files=none not
                      at all, only a channel=mailbox lane in the mail
                      pass, and the provider's status verb asked only of a
                      status=verb lane. A run carrying a lane passed with this option
                      while `lane-host resolve` answers local is refused as
                      hosted-without-host rather than read on this disk
  --root ITEM=PATH    the item's lane worktree on this disk, where its
                      mailbox is read; a lane whose worktree sits outside
                      this checkout is read nowhere else. Repeatable, once per
                      item; a --hosted entry for the same item wins
  --handoff PATH      the overseer handoff file a successor's brief names,
                      passed through to `oversee-succeed` when this watch
                      records the overseer's launch line (default
                      tmp/handoffs/OVERSEER-HANDOFF.md)
  LANE_WINDOW...      tmux window names to watch; requires $TMUX or
                      ORCH_TMUX_SESSION, which lets a watch outside tmux
                      reach the fleet's session. A bare name is a window in
                      that session, else the session this watch started in,
                      which it resolves once through $TMUX_PANE and names on
                      stderr as session-resolved, so a pane that later dies
                      moves no lane into another session; `session:window`,
                      tmux's own target form, names one in another session.
                      A bare name with no session resolved is refused as
                      session-unresolved naming the lane and the --state
                      file; a setting tmux does not hold as session-missing,
                      and a has-session call failing for any other reason,
                      no server at the socket among them, as tmux-failed
                      naming that socket
  --harness H         the OVERSEER's harness, claude, codex, copilot or pi,
                      handed to each oversee-succeed call, whose help states
                      when a pane needs it (`oversee-succeed --help`,
                      --harness)
  -- OVERSEER_FLAGS...
                      the flags the OVERSEER itself runs under — its
                      permission flags, plus its current model and effort
                      flags, regardless of ORCH_OVERSEER_PREFERENCE. These are
                      the same words `oversee-succeed -- ...` takes. This
                      watch replaces the fleet state's overseer.launch_line
                      once at startup, because a
                      dead pane can no longer be asked what it was launched
                      with. A watch started without them records a line with
                      no permission flags, and the successor it relaunches
                      stops at the first prompt nobody is there to answer.
                      A record naming this pane answers the line's harness
                      and account, and its model and effort as a pair where
                      it names a model (`oversee-succeed --help`).
                      A line this start cannot build or record is the
                      notice overseer-line-missing or overseer-unrecorded,
                      on stderr and in the fleet log, and the watch runs
                      on: the session is judged from the exit status and
                      rows file the record already holds for this pane, and
                      from the pane, the named fallback, where it names
                      none; a death relaunches from the line the fleet
                      state already holds where its record names this pane
                      by server, server start and pane id, the last line a
                      launch, a succession or a watch start recorded for
                      it, which a session restarted by hand may not have
                      been started with; a record naming another pane, or
                      none, reports the death with no successor, naming
                      that record
  --repeat SECS       the watch for a session: run one watch per pass with
                      the other options, sleep SECS after it exits, or
                      ORCH_WATCH_MAIL_INTERVAL where that is shorter and the
                      pass did not exit 2, and run the next, sooner once
                      the overseer mailbox moves. A successor launch, a
                      notice-only recovery or an exhausted retry stops the
                      repeat command with status 0. Requires --state. A
                      window that tmux does not list is carried until a pass
                      exits 0 having reported window-gone with one stderr
                      note; later passes name it --skip-lane until tmux lists
                      it again.
                      The repeat loop records itself beside the --state
                      file: its own pid, whatever launched it, the state
                      path, the pane it serves, its origin, its script and
                      directory in oversee-watch.pid, and its arguments
                      before -- in oversee-watch.argv. That record is the
                      watch's claim, which the start refusals below and a
                      succession's handover read; how an overseer launches,
                      finds and stops its watch is
                      references/watch-delivery.md's. However it is sent,
                      TERM on the loop removes the record at once, ends
                      the pass it is running and exits once that pass has;
                      a lane-close part way through is run to its end and
                      reported first, and a start that took that watch over
                      waits for it under a watch-finishing note. A start on a
                      state whose recorded watch still runs is refused as
                      watch-running naming that pid, except where that watch
                      is the one `oversee-succeed` restarted for this same
                      pane after a self-succession, or serves a pane tmux no
                      longer lists: that watch is stopped and replaced, under
                      a watch-taken-over note. Every start but a succession's
                      then prints, under a watch-replayed note, and removes
                      oversee-watch.log and oversee-watch.err beside the
                      state: what a restarted watch printed where no session
                      read it, and what the restart itself said; it removes
                      the restart's oversee-watch.runner with them. A watch
                      a succession started writes those two files, so it
                      never prints or removes them
  --state PATH        the oversee workflow-state file open-terminal records
                      every lane in (`workflow-state path oversee`), re-read
                      before every loop of the run and, in repeat mode,
                      before every pass as well. Repeat mode's automatic
                      close uses the directory containing this file. Each
                      `lanes[]` entry whose status is `running` is one
                      --item, its `window` one LANE_WINDOW when set, and its
                      `mail_root` one --hosted entry when `host` is set and
                      one --root entry otherwise, all added to any given on
                      the command line, the state's entry winning where both
                      name one item or window, so a lane launched, relaunched
                      or closed while the run loops joins or leaves it with
                      no restart. A `lanes[]` entry whose status is `parked`,
                      its sandbox stopped by `lane-close --park` with its disk
                      kept, is one --item for the merged check and the
                      lane-long age alone: its pane is gone and its mailbox
                      and state are on a stopped disk, so no other check
                      reads it, and the merge of the
                      pull request its `parked` names, in that repository,
                      prints parked-merged in the same pass and at every
                      heartbeat while the record reads parked, and closes
                      nothing.
                      The set is noted on stderr as fleet-read whenever a
                      read changes what the reader last carried, with the
                      count of records whose status is not running, so a
                      state that parses to no running lane is named rather
                      than watched in silence, and with the parked records
                      it carries for the merged check and the lane-long age:
                      a standalone run names the
                      fleet its own first read found, repeat mode names the
                      fleet it launches each pass with, and a pass names a
                      change one of its own loops found
  --skip-lane WINDOW  a lane window this run does not watch, whatever the
                      state says; its item stays watched. Repeat mode names
                      each window a pass already reported gone, so the record
                      that still carries it is not reported again every loop,
                      and hands every pass the windows given here besides.
                      Repeatable; requires --state

Exit codes:
  0  at least one EVENT line was printed
  3  overseer-dead or overseer-walled was reported and a successor took that
     overseer's
     window. This watch is done: the successor runs its own. Repeat mode
     stops on it and exits 0
  2  usage or global failure, or a lane-local mailbox, clone or
     workflow-state read failed. A lane-local
     failure is reported and the pass reads the remaining lanes before it
     exits. An unchanged lane-local failure, a provider-reported stopped state
     among them, stays quiet after its first report until a successful read or
     a different failure, and fails no run after that first one. A
     state write can fail after its event was printed. Pr-watch commits
     repository baselines in order, so earlier repository baselines may
     already have advanced when a later rename fails. Only baselines that did
     not advance repeat their events
Repeat mode prints each pass's output and ignores its exit code. It exits 2
only on a usage error, a state file it cannot read or parse, an argument a
pass would refuse (an item, a --hosted entry, a repeated --repo, a lane
outside tmux or outside any resolved session, a hosted lane with no host), a
tmux window list that fails, a watch already running on its state, a record
it cannot write, or a repeat delay it cannot sleep. TERM ends it at 143,
stopping the pass it was running and that pass's long pass; TERM is the stop
signal on every start. A watch started as a background job ignores INT from
its start, which no trap can take back; the orch job runner adds no ignore.

Which mode fits the overseer's harness:
  repeat       a harness that delivers a detached log's lines as they are
               written or holds a blocking follow of it inside the turn.
               The watch runs detached and outlives the session, so it
               reports overseer-dead
  single pass  a harness whose only wake is a background command's exit:
               each pass runs as that command and the next starts after
               every line is handled. Nothing reports overseer-dead
references/watch-delivery.md holds each harness's mechanism and re-arm rule.

When pr-watch.sh is installed, oversee-watch runs it on every pass for every
--repo; it reads GitHub's review state and writes nothing. When pr-watch.sh is
absent, the step is skipped with one stderr note.
Inside tmux, an --item with no LANE_WINDOW skips the pane checks with one
stderr note; outside tmux there is no pane to read and nothing is noted.

Environment:
  LINEAR_TEAM                 team the triage check reads under --since and
                              the heartbeat's owed items read with --state,
                              from kendex.settings.toml [env] unless the
                              environment sets it. Empty or absent skips
                              triage, said once, and reads the owed items from
                              open PRs; with a team a missing tracker CLI or
                              workflow-state exits 2 rather than dropping it
  ORCH_EXTERNAL_TRIAGE        `on` (default) runs the outside-contribution
                              check on every long pass, reading each --repo's
                              open pull requests and the first's open issues;
                              `off` lists nothing. Any other value exits 2
  ORCH_SECURITY_ALERTS        `on` (default) runs the security-alert check on
                              every long pass, reading each --repo's open
                              Dependabot, code scanning and secret scanning
                              alerts and the fleet state's alerts_triaged
                              through OVERSEE_WATCH_WORKFLOW_STATE, which must
                              then exist; `off` lists nothing. Any other value
                              exits 2
  ORCH_SECURITY_ALERT_TOKEN_FILE
                              path to the installation token supplied and
                              renewed by the control VM for a hosted
                              overseer, or by the fleet worker for a local
                              one, for vanillagreen-overseer, with alert
                              read and write permissions. No default. Read once each long
                              pass; only alert REST lists and the GraphQL
                              alert-to-PR link use it through GH_TOKEN.
                              Other watch reads keep their current credential.
                              An unset, unreadable, empty or whitespace-bearing
                              token produces security-alerts-unread with cause
                              credential, keeps prior rows and makes no alert
                              API call. With ORCH_SECURITY_ALERTS=off it is
                              not read
  ORCH_CONNECTED_REPOS        blank-separated OWNER/REPO list, read through
                              orch-env in this checkout, an inherited value
                              and KENDEX_ENV_FILE honored, since the watch
                              runs in the overseer's own checkout: each entry
                              is a watched repository after the --repo values,
                              an entry they already name skipped. Each one
                              adds its reads to every long pass, as a --repo
                              does. After a change, restart the watch: its
                              start exports the value it loaded, which every
                              repeat pass inherits. An unreadable setting
                              exits 2, in repeat mode before the first pass.
                              open-terminal reads it in the overseer's
                              directory without those two: open-terminal
                              --help. oversee-report reads it as this watch
                              does
  ORCH_STATE_DIR              workflow-state directory; relative paths join
                              the project root; absolute paths stay unchanged
  ORCH_WATCH_TAIL_LINES       most lines any one event's pane payload prints,
                              a positive whole number, default 12. At the
                              default the measured Claude Code permission and
                              AskUserQuestion dialogs and the Codex trust
                              dialog arrive whole; the Codex model picker's
                              slice is 19 lines, so it keeps its bottom 12 and
                              loses the startup box above them
  ORCH_WATCH_PREPARE_SECS     seconds a lane handed to a background launch
                              job may read preparing before
                              lane-prepare-stuck goes out, a positive whole
                              number, default 1800
  OVERSEE_WATCH_PR_WATCH      path to pr-watch.sh
  OVERSEE_WATCH_TRACKER       path to the Linear CLI
  OVERSEE_WATCH_WORKFLOW_STATE path to workflow-state; with an --item a
                              missing one exits 2 rather than dropping handoff
  OVERSEE_WATCH_LANE_MAIL     path to lane-mail; a missing one exits 2 rather
                              than dropping the mail pass
  OVERSEE_WATCH_LANES         path to lanes, whose `list --json` is the
                              account reading behind the account event and the
                              heartbeat roster; a missing one exits 2. The read
                              takes the same 60 second ceiling and usage age as
                              the overseer's own mark judgement
  OVERSEE_WATCH_REPORT        path to oversee-report, whose `due` judges the
                              report-due event; with --state a missing one
                              exits 2
  OVERSEE_WATCH_SUCCEED       path to oversee-succeed, which records the
                              overseer's launch line and relaunches a dead or
                              walled overseer. A missing one leaves the
                              overseer check to report and launch nothing,
                              said once
  ORCH_OVERSEER_DEAD_PASSES   consecutive passes the overseer must read
                              `exited` before overseer-dead goes out, and
                              its pane `walled` before a screen wall's
                              overseer-walled does (default 2). One pass is a
                              poll that caught a live session between its
                              harness and its shell. A screen wall also needs
                              its account judged mark-reached
                              kind=headroom; passes alone never
                              close a window whose harness is alive. A rows
                              wall, which stands unless its account measures
                              room, and an account wall at value=0 go
                              out on the first pass
  ORCH_OVERSEER_SUCCESSION    `off` leaves the overseer-dead and
                              overseer-walled notices and
                              launches no successor; `oversee-succeed` owns
                              every other value. An overseer-mark line still
                              goes out under it, carrying succession=off
  ORCH_OVERSEER_MARK_REPEAT   passes a standing overseer-mark, start-stalled
                              or refresh-failing waits before it is reported
                              again (default 5). The first event is always
                              reported. The overseer-mark judgement runs every
                              pass and reads
                              every account the fleet can launch on, under a 60
                              second ceiling where `timeout` is installed; a
                              read that passes it leaves the mark unjudged for
                              that pass, and on a host without `timeout` the
                              read runs unbounded
  OVERSEE_WATCH_STATE_DIR     one baseline file per repository — reducer,
                              triage, lane-asking, usage-limit, handoff,
                              account, outside-contribution, refresh-failing,
                              security-alert, bot-fix and
                              security-alerts-unread rows; the mail pass's
                              file beside the first one holds
                              each lane mailbox's read position and when the
                              last mail and long passes started, plus claims/ and
                              usage/, both shared across the repositories
                              that point here
  ORCH_WATCH_MAIL_INTERVAL    seconds from the start of one mail pass to the
                              next, a whole number, default 20, and the most
                              --repeat waits between two runs after one that
                              did not exit 2: a lane read failure first
                              reported, a hosted lane close that fails, or a
                              global failure. The mail pass paragraph above
                              names when a note lands later. 0 reads the mail
                              on every turn of the loop and waits out a long
                              pass in flight rather than polling it
  ORCH_DIRECTIVE_UNREAD_SECS  age in seconds past which a directive the lane
                              has not read is reported directive-unread, a
                              whole number, default 300
  ORCH_WATCH_START_STALL_SECS seconds after a record went running, its
                              running_at, its status file may still be missing before
                              start-stalled goes out, a positive whole number,
                              default 600
  ORCH_WATCH_LANE_STALL_SECS  seconds a status=none lane's open pull request
                              may hold its head and body unchanged before
                              lane-stalled goes out, a positive whole number,
                              default 3600, provisional until a cloud lane run
                              measures one
  ORCH_WATCH_LANE_AGE_SECS    seconds after a record's launched_at a running
                              or parked lane is reported lane-long, a positive
                              whole number, default 12600
USAGE
}
# stderr messages start `oversee-watch: REASON field=value ...`. Backslash,
# tab, carriage return and newline in field values are escaped. Tool error
# details and the English explanation follow the stable header.
# What a death replays after a start whose record failed: the rule itself is
# `overseer_record_read` in lib/watch-overseer-record.sh, its `ol_names` test
# on the fleet state's record, which check_overseer and the watch start both
# read through. This constant is the one copy of its wording the two start
# notices below and the fleet-log row overseer_record_notice writes compose;
# the `-- OVERSEER_FLAGS` help above, the overseer row of
# ../../schemas/workflow-state.md and ../../workflows/oversee.md § 4. Watch And Advance
# restate it in prose. Bounded in length by that row: the fleet log takes
# ORCH_FLEET_LOG_ROW_BYTES per row, and the row carries the notice's reason
# and pane ahead of this, never a path.
OW_REPLAY_RULE='A death replays the held line only where the record names this pane by server, server start and pane id: the last line a launch, a succession or a watch start recorded for it, which a session restarted by hand may not have started with. A record naming another pane, or no line, means a death with no successor.'

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
    start-stall-secs-invalid) text='ORCH_WATCH_START_STALL_SECS takes a positive whole number of seconds, with no leading zero.' ;;
    start-stall-unread) text='The lane status file could not be read through lane-host, so whether the lane started settles nothing this pass: no start-stalled goes out for it and its row stands. The exit is lane_host_fetch'"'"'s: 2 a failed read, 4 no lane-host slot.' ;;
    refresh-unread) text='The refresh run list or failed-step log could not be read. A failed run-list read leaves the baseline intact; a failed log read reports cause=unread. The watch continues.' ;;
    refresh-stale) text='GitHub answered the refresh run list with a page that judges nothing: newest= is the run it was checked against, the one the watch last read or, for a pair opening an incident or with none read, the newest completed run in the unfiltered list, none when it has none, and read= the newest run the page holds, none for an empty page. No pair is reported and none is cleared. The watch continues.' ;;
    refresh-order-unknown) text='The refresh run-list judgement named an order other than newer, same, older or unrecorded, so the run list cannot be judged.' ;;
    lane-rows-unread) text='The Pi lane session rows could not be read, so the lane reads unjudged this pass and its pane is not read in their place. The exit is lane_host_fetch'"'"'s for a hosted lane, 2 a failed read and 4 no lane-host slot; 0 is a file this read reached and could not read, or whose last row names an event no writer writes, and 2 on a local lane is a record naming no mail_root.' ;;
    unread-secs-invalid) text='ORCH_DIRECTIVE_UNREAD_SECS takes a whole number of seconds, with no leading zero.' ;;
    dead-passes-invalid) text='ORCH_OVERSEER_DEAD_PASSES must be a positive integer.' ;;
    mark-repeat-invalid) text='ORCH_OVERSEER_MARK_REPEAT must be a positive integer.' ;;
    overseer-mark-unjudged) text='The overseer own-mark judgement could not be made this pass, so its account marks settle nothing here. A standing mark is not cleared by a reading that failed; oversee-succeed owns the judgement and its own keyed line says why.' ;;
    overseer-wall-unjudged) text='The overseer pane read walled and the account judgement that would confirm it could not be made, so nothing is acted on: this pane carries the limit banners this watch relays about OTHER lanes, and the screen alone cannot tell those from the overseer own account running out. The reading is left to the next pass.' ;;
    overseer-wall-unconfirmed) text='The overseer pane read walled and its own account measures room, so the banner on that screen is one this watch relayed about another lane and the overseer is working. Nothing is launched and no window is closed. The fields name the judgement that refuted it.' ;;
    overseer-wall-lifted) text='The overseer session rows last recorded a usage-limit failure and its own account now measures room, so the wall has lifted and the session is read as live. Only a finished turn writes the row that clears it.' ;;
    overseer-context-alerted) text='The overseer context record carried the same gap on two consecutive long passes, so the owner was sent one notice naming the pane and the gap, or already held the same notice text from a send within the last 24 hours that lane-mail refused to repeat as owner-notice-repeated, and the fleet log took one row unless an overseer-notice-failed line for its channel precedes this one; the event is not repeated while that gap stands. A notice to the owner that fails prints no such line and is sent again the next pass.' ;;
    overseer-context-unread) text='The overseer context record, or the session rows file its staleness is judged against, could not be read or is not a shape the lane-mail-check hook writes, so neither overseer-context event nor a context wedge is judged on it this pass. A harness field names a record whose harness no context adapter reads.' ;;
    overseer-unwatched) text='The overseer pane is not being watched, so an overseer that dies is reported by nothing. The field names what is missing.' ;;
    overseer-unreadable) text='The overseer pane could not be read, so its state settles nothing this pass.' ;;
    overseer-fallback) text='The overseer session rows could not judge it, so this pass judges its pane, the named fallback, as the watch did before the rows existed. The cause names why: no rows file recorded for this pane (unrecorded), a fleet state that could not be read (state-unreadable), no row in the file yet (none), a row naming a harness that emits no session end or usage-limit event, or a Pi row that carries no end or failure evidence, being neither a session end nor a failure with its text (unsupported), or a file that could not be read (unreadable).' ;;
    overseer-line-missing) text='This start could not build the overseer launch line, so the fleet state keeps the line it already holds, or none. The pane is still watched. '"$OW_REPLAY_RULE"' The held field is that line, none where the record holds none for this pane, or unread where the record could not be read. The detail under this line is the refusal of oversee-succeed --print-launch-line.' ;;
    overseer-unrecorded) text='This start could not record the overseer pane in the fleet state, so the record stays as it was. The pane is still watched. '"$OW_REPLAY_RULE"' The held field is that line, none where the record holds none for this pane, or unread where the record, or the pane key or server start that names it, could not be read. The step field names what failed.' ;;
    overseer-notice-failed) text='An overseer notice could not be delivered on the channel the field names. A notice from a pass still had its event line printed; a notice from the watch start has none.' ;;
    overseer-relaunch-failed) text='oversee-succeed refused or failed the relaunch; the overseer is not replaced and this watch keeps running. Its own keyed line says why.' ;;
    overseer-recovery-blocked) text='No account in the fleet qualifies for a successor, so the recovery stops rather than retry the same accounts. The fields name the spent account and the reset its banner states; a notice carrying both went to the fleet log and the overseer mailbox.' ;;
    overseer-succeeded) text='A successor holds the dead overseer window and runs its own watch. This one stops rather than read the fleet twice.' ;;
    repeat-invalid) text='The repeat delay must be a non-negative integer.' ;;
    state-required) text='The option reads its lanes from the oversee workflow state. Add --state PATH.' ;;
    state-unreadable) text='The oversee state file could not be read. The watch stops rather than carry a partial fleet.' ;;
    state-invalid) text='The oversee state file is not workflow-state JSON with a lanes array of records naming their item, each status and harness one word, and a launch_queue of item keys. The watch stops rather than carry a partial fleet.' ;;
    window-absent) text='tmux does not list the window. Passes carry it until one reports it gone; later passes skip it until tmux lists it again.' ;;
    sleep-failed) text='The repeat delay could not be slept. Repeat mode stops rather than run passes back to back.' ;;
    fleet-read) text='The fleet this watch carries, as the last state read gave it; printed again when a re-read changes it. dropped counts every record whose status is not running, which the watch does not carry as a lane, and parked the records among those it carries for the merged check and the lane-long age alone.' ;;
    max-loops-invalid) text='The loop limit must be a positive integer.' ;;
    prepare-secs-invalid) text='ORCH_WATCH_PREPARE_SECS takes a positive whole number of seconds, with no leading zero.' ;;
    tail-lines-invalid) text='ORCH_WATCH_TAIL_LINES takes a positive whole number of lines, with no leading zero.' ;;
    limit-banner-missing) text='The pane was classified walled but its screen yields no limit banner to report. The classifier and the payload disagree, so the pass stops rather than send an event with nothing its handling can read. The field names the lane, or the overseer pane where the overseer is the one classified.' ;;
    tmux-missing) text='Run in the tmux session that owns these lanes, set ORCH_TMUX_SESSION, or omit the lanes.' ;;
    session-missing) text='ORCH_TMUX_SESSION names a session the server in the server field does not hold. Correct the setting or start that session.' ;;
    tmux-failed) text='The tmux call the operation field names failed on the server field'"'"'s socket for another reason than an absent session; tmux says why below.' ;;
    since-invalid) text='Use a UTC timestamp in YYYY-MM-DDTHH:MM:SSZ form.' ;;
    helper-missing) text='The required helper is not executable. Check the named setting.' ;;
    item-invalid) text='The work item is not a supported issue identifier.' ;;
    command-missing) text='The required command is not on PATH.' ;;
    auth-failed) text='No configured GitHub credential works. Run gh auth login.' ;;
    repo-unresolved) text='Specify a repository because GitHub could not resolve it.' ;;
    repo-duplicate) text='Name each repository once.' ;;
    connected-repos-unread) text='orch-env could not read ORCH_CONNECTED_REPOS in this checkout, so the watched repositories are unknown. Its own words are above.' ;;
    pr-list-failed) text='The GitHub PR list command failed.' ;;
    pr-list-invalid) text='The GitHub PR list output could not be parsed.' ;;
    outside-list-failed) text='The GitHub list of open issues and pull requests the outside-contribution check reads failed.' ;;
    outside-list-invalid) text='The GitHub list of open issues and pull requests carried a line the outside-contribution check cannot read: a number, a pr or issue kind, a login, and a pull request head commit.' ;;
    external-triage-invalid) text='ORCH_EXTERNAL_TRIAGE takes on or off.' ;;
    security-alerts-invalid) text='ORCH_SECURITY_ALERTS takes on or off.' ;;
    security-alerts-read-failed) text='A read the security-alert check needs failed, so the named source is not judged this pass and its baseline rows stand. Cause permission means vanillagreen-overseer lacks that alert permission; the owner adds it to the app and accepts it on each installation. Cause credential means ORCH_SECURITY_ALERT_TOKEN_FILE supplies no usable installation token; the control VM must supply and renew it for a hosted overseer, the fleet worker for a local one. Cause feature-off means Dependabot alerts are off on that repository. The failed reader'"'"'s own words follow where it printed any.' ;;
    triage-state-failed) text='The fleet triage verdict log could not be read.' ;;
    triage-item-invalid) text='The fleet triage log contains an invalid issue identifier.' ;;
    time-failed) text='The current UTC time could not be read.' ;;
    tracker-list-failed) text='The tracker list command failed.' ;;
    tracker-list-invalid) text='The tracker list output could not be parsed.' ;;
    missing-linear) text='The tracker path requires the linear skill checklist library beside orch.' ;;
    verifying-invalid) text='The Verifying item has invalid post-merge metadata or an open branch-provable box. Correct its checklist before verification.' ;;
    owed-roster-invalid) text='The account listing read for the owed items could not be put to them, so the heartbeat names none.' ;;
    owed-accounts-unread) text='lanes list failed under this host, so the owed items on it read unjudged this heartbeat. Its own words follow.' ;;
    merged-search-truncated) text='The merged pull requests naming the item in their title or body, since --since, reached the search limit, so the item'"'"'s own pull request may be past it and its merge unreported. No merged event is judged from a partial list.' ;;
    owed-list-truncated) text='The item repository open pull request listing reached its limit, so an owed issue-N pull request past it would be missing. The heartbeat names no owed item from a partial list.' ;;
    owed-wall-unjudged) text='lanes pick could not judge the wall for this host, harness and model, so the owed items on them read unjudged this heartbeat. Its own words follow.' ;;
    handoff-read-failed) text='The handoff record could not be read.' ;;
    lane-close-failed) text='lane-close failed before it completed the close. The next run reports the exit again and retries.' ;;
    parked-merge-unmatched) text='A pull request merged on the parked item'"'"'s branch name, reported above as merged, is not the one its record names, so no parked-merged follows it and the parked sandbox stays stopped: recorded= is the record'"'"'s <repo>#<number> in lower case and seen= the merged keys this pass found. parked-merged follows when the recorded pull request merges in that repository.' ;;
    hosted-invalid) text='Spell --hosted as ITEM=REMOTE_ROOT, with the item in letters, digits, dot, underscore and hyphen.' ;;
    hosted-unknown-item) text='The --hosted item is not one this run watches. Name it with --item, or drop the entry.' ;;
    root-invalid) text='Spell --root as ITEM=PATH, with the item in letters, digits, dot, underscore and hyphen.' ;;
    root-unknown-item) text='The --root item is not one this run watches. Name it with --item, or drop the entry.' ;;
    root-duplicate) text='Name each --root item once: two roots for one lane would read one mailbox and drain the other.' ;;
    hosted-duplicate) text='Name each hosted item once.' ;;
    host-capabilities-unread) text='lane-host could not declare the capability line of a host a lane record names, or declared a value this watch has no arm for, so nothing says where that lane is read or how it is judged; lane-host'"'"'s own words are above this line. Nothing of the fleet is carried.' ;;
    lane-age-secs-invalid) text='ORCH_WATCH_LANE_AGE_SECS takes a positive whole number of seconds, with no leading zero.' ;;
    lane-long-rounds-unread) text='The lane workflow state or its round counts could not be read. The lane-long event carries unavailable counts.' ;;
    lane-stall-secs-invalid) text='ORCH_WATCH_LANE_STALL_SECS takes a positive whole number of seconds, with no leading zero.' ;;
    lane-stall-unread) text='The digest of a lane pull request body could not be taken, so whether the lane moved is unknown. The watch stops rather than report a stall it did not measure.' ;;
    pr-read-failed) text='The open pull request on the item branch could not be listed, so this pass settles nothing about a lane whose kind writes no file this watch reads: no start-stalled or lane-stalled goes out for it and its rows stand. gh'"'"'s own words follow.' ;;
    hosted-without-host) text='A hosted lane is carried, and lane-host resolves this host to local, so its mailbox, state and close would be read on this disk where the lane is not. Set ORCH_LANE_HOST to the provider the lane was launched through, in kendex.settings.toml [env] or .env.local.' ;;
    host-resolve-failed) text='lane-host could not say which host the hosted lanes live on, so none of them is read. Its own words follow.' ;;
    session-resolved) text='The tmux session every bare lane window name is read in, and its server: ORCH_TMUX_SESSION, else the session of the pane that started this watch, resolved once while it exists.' ;;
    session-unresolved) text='A bare lane window name is carried and tmux named no session for this watch, so the name could resolve through whichever session tmux picks. Start the watch from the overseer pane, or record the window as SESSION:WINDOW.' ;;
    watch-running) text='Another watch already runs on this fleet state, and this start could not show its pane gone: tmux lists it, this start has no tmux server to ask, the record names no pane, or the pane list could not be read. Two watches would read one overseer mailbox and each replay what the other drained. Handle its events, or stop it as references/watch-delivery.md states and start again; pid is the watch that read finds.' ;;
    watch-replay-failed) text='The output a restarted watch left beside the fleet state could not be printed or removed, so the start stops rather than lose it or print it twice. The path names the file.' ;;
    watch-record-failed) text='The watch could not write its own record beside the fleet state, so a second watch could not be refused and a succession could not restart this one.' ;;
    watch-finishing) text='The watch taken over is finishing a lane-close. This start waits for it to exit, so the lane row is committed before this watch reads it and the output of a restarted watch is replayed whole. The close outcome is in the output of the old watch: for one references/waiter-launch.md started, the log in its run directory.' ;;
    watch-taken-over) text='A live watch on this fleet state was stopped and this one runs in its place. The reason field says why it could be: succession is the watch oversee-succeed restarted for this pane, pane-gone one whose pane tmux no longer lists.' ;;
    watch-replayed) text='A watch oversee-succeed restarted wrote output no session read, and the restart wrote how it went. Both follow, stdout here and stderr on stderr, and are then removed, so no event it reported and no refusal it ended on is lost.' ;;
    mail-read-failed) text='The lane mailbox could not be read. Fix what lane-mail names rather than reading the lane as silent.' ;;
    lane-host-busy) text='No lane-host slot freed; the next pass retries.' ;;
    mail-read-invalid) text='The lane mailbox reader did not open with its count line.' ;;
    ask-due-unread) text='The owner asks past their deadline could not be listed, so none was resolved this pass. Fix what lane-mail names under this line.' ;;
    ask-resolve-failed) text='An owner ask past its deadline could not be resolved to its recommendation, so it stands unanswered and the overseer still waits. Fix what lane-mail names under this line.' ;;
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
    wall-unrecorded) text='A wall this watch saw end on the lane could not be kept in its lane record, so oversee-cycle reads that walled time as the wait it fell in. The workflow-state refusal follows. Other watch checks continue.' ;;
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
