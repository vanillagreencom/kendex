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
                     [LANE_WINDOW...] [-- OVERSEER_FLAGS...]
       oversee-watch --repeat SECS --state PATH [any option above]...

Blocks until the fleet needs the overseer, then prints every event it found
as one block, each line prefixed with its kind, and exits once. Re-run after
handling every line with the live fleet in scope.

Two passes run on one clock. The mail pass starts every
ORCH_WATCH_MAIL_INTERVAL seconds, reads every lane mailbox, the overseer
mailbox and the lane records one after another, and prints what it finds as
it finds it: lane-question, lane-notice, directive-read, directive-unread,
peer-note, owner-note and owner-ask-resolved. Before the overseer mailbox is
read, every owner ask past its deadline is resolved to its recommendation
through `lane-mail resolve --default`, so the pass reports the ruling it
made. A read that waits on a lock or a slow host delays
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
                             the OVERSEER's own pane — the $TMUX_PANE this
                             watch was started from — read `exited` by the
                             shared judge on N consecutive passes. Nothing
                             else notices an overseer that ended: its lanes
                             keep working, this watch keeps printing to a log
                             nobody reads, and the fleet runs unattended. The
                             line also goes to the fleet log and to the
                             overseer mailbox, where the successor reads it as
                             an owner-note. Unless ORCH_OVERSEER_SUCCESSION is
                             `off`, the watch then launches that successor
                             into the dead pane's window slot through
                             `oversee-succeed --dead-pane`, with the launch
                             line the fleet state recorded, and stops: the
                             successor runs a watch of its own
  EVENT overseer-walled <pane> window=<window> passes=<N> succession=<on|off>
                             the same pane read `walled` by the same judge on
                             N consecutive passes AND its own account judged
                             at or below its trigger: the harness is still
                             running and its ACCOUNT is spent. Such a session
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
                             banner's own window follows the line, as it does
                             for a lane's usage-limit. The line goes to the
                             same two channels. The successor is launched
                             through `oversee-succeed --walled-pane`, which
                             picks its account afresh and never reopens on the
                             spent one; the line it built is on the watch's
                             stderr under the event. Where no account
                             qualifies, one `overseer-recovery-blocked` notice
                             naming the account and when its binding bucket
                             frees up goes to both channels and the repeat
                             stops
  EVENT overseer-mark <pane> kind=<context|headroom|rate|qualifying> value=<N> mark=<N>
                             succession=<on|off>
                             the OVERSEER's own context use or account headroom
                             reached its own mark, judged by
                             `oversee-succeed --check-marks` so the rule is
                             stated once. It reaches an overseer BETWEEN turn
                             ends, where its own turn-end hook cannot: the hook
                             refuses at the same marks, and a session part way
                             through a long turn meets neither until this line.
                             The route follows on the next line. Emitted once
                             at the crossing and again every
                             ORCH_OVERSEER_MARK_REPEAT passes while it stands;
                             a reading that could not be taken leaves the
                             standing mark where it was and says so on stderr
  EVENT pr-watch rc=N        new review-gate attention; reducer output follows
  EVENT merged <PR> <branch> <repo>
                             an --item PR merged at or after --since, in any
                             --repo
  EVENT triage <item>        an item created at or after --since that is absent
                             from the first repository's persisted baseline
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
  EVENT window-gone <lane>   the tmux window no longer exists. Nothing follows
                             the line: the remedy is one relaunch, which
                             reads the item's worktree and PR, not a screen
  EVENT lane-exited <lane>   `pgrep -P` reports no child under a bare shell on
                             two passes; the lane's closing lines follow. An
                             unusable probe is not an answer and keeps the
                             lane watched
  EVENT lane-closed <item>   under a lane-exited whose window watches a --hosted
                             item already reported merged, once the pass finds
                             its worktree gone: `lane-close` succeeded;
                             the provider's output follows, then `kept=none`
                             when that output has no `kept=` line because the
                             close archived nothing. A lane exiting while its
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
                             pass this watch first saw the banner on
  EVENT usage-limit-passed <lane> [<config-dir>] resets=<utc>
                             the same banner, naming a reset that has gone by:
                             the screen is remembering a spent window that has
                             reopened. Bump the lane, never park it. A clause
                             naming only a clock or a weekday reaches this only
                             once this watch has seen that wall standing; one
                             naming a date is spent on sight
  EVENT lane-asking <lane>   a question or selection prompt differs from the
                             last one emitted for this lane; the dialog follows
  EVENT model-capacity <lane>
                             a Codex turn ended because its selected model is
                             at capacity. Nothing follows the line: the
                             remedy is one continuation line back to the lane
  EVENT idle-after-return <lane>
                             the live harness sits idle on two passes; the
                             lane's closing lines follow
  EVENT account <alias> config_dir=<dir> harness=<harness> through=<local|host>
                status=<status> verdict=<room|walled|unmeasured> headroom_pct=<N|->
                binding_bucket=<bucket|-> binding_resets_at=<utc|->
                change=<status|headroom|reset>[,...] was=<status>/<verdict>
                             an account the fleet can launch on changed since
                             the last pass that read it, as `lanes list --json`
                             reads it once per pass: its status word changed,
                             its verdict against ORCH_LANE_MAX_PCT crossed in
                             either direction, or the binding bucket reset the
                             last reading named has passed and the reading has
                             moved off it. `change=` names every one that
                             applies and `was=` the status and verdict before
                             it. `config_dir` names the credentials, since
                             two accounts can share an alias. The first
                             reading of an account is its baseline and an
                             unchanged account says nothing
  EVENT report-due reason=<minutes|issues> since=<utc> [landed=<N>]
                             the overseer's status report is due, as
                             `oversee-report due --state` judges it from the
                             newest owner progress report and the ORCH_REPORT
                             settings. Reported on every long pass while it
                             stays due, so it stops once a report is written;
                             read only with --state
  EVENT heartbeat            --max-loops long passes with no event. A line
                             `  failing <item> <key>` follows for every lane
                             of the current fleet whose failure still stands,
                             reported once and quiet since, then every
                             --repo's open PRs, each line prefixed with its
                             repo, then `account-roster accounts=<N>` and one
                             `account <alias> config_dir=...` line per
                             account, the fields the account event carries up
                             to `change=`, from the last long pass's reading.
                             `account-roster unread` replaces them when that
                             reading failed

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
  EVENT owner-ask-resolved <ask id> by=<text|default>
                             an owner ask of this overseer's is closed: by
                             the owner's own words, which `lane-mail resolve
                             --text` wrote, or by its recommendation, which
                             this watch wrote at the deadline; the ruling's
                             text follows. Reported once per ask, since an
                             ask resolves once.
                             Every text and `options:` line of these kinds
                             is indented two spaces, so a message line never
                             begins with EVENT
The overseer mailbox is read through its own to-lane.cursor, which a session
start's `lane-mail inbox --item overseer` moves too, acknowledged only once
its notes are printed, whatever state directory, --since or checkout this
watch runs with. A session start's read between the peek and the
acknowledgement reports a note twice.
Before every mail pass the overseer's own pane is read once; while it reads
exited, or walled with a wall its own account confirms, no mailbox is read,
so a successor finds what was sent in the meantime. A wall
the account refutes, or one no judgement could settle, reads live: its mail
is read, and the long pass starts no successor for it. Off tmux there is no
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
lane-exited, idle-after-return, handoff and account are keyed in that
baseline. Mail is reported at least once and never lost: lane-question,
lane-notice, directive-unread and, for a directive read after its lane is
first watched, directive-read are keyed in the mail pass's own file beside
it, owner-note, owner-ask-resolved and peer-note by the overseer mailbox's
cursor, each committed only once printed, so a stop between the two reports a line
twice: a repeated id is one already seen. A lane whose to-lane read
lane-mail reports `missed` has nothing reported or moved that pass; a cursor
below the one reported holds only its directive lines. Each repeats only when what it reports changes: another PR, a
different wall or a reset gone by, a replacement pane, a different screen, a
new record, another account state. An unchanged standing overseer-mark is the one keyed line that
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
                      beside it
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
                      A run carrying any hosted lane, from this option or a
                      state record with a host, while `lane-host resolve`
                      answers local is refused as hosted-without-host rather
                      than read on this disk
  --root ITEM=PATH    the item's lane worktree on this disk, where its
                      mailbox is read; a lane whose worktree sits outside
                      this checkout (a proposal sweep launched from a source
                      repository) is read nowhere else. Repeatable, once per
                      item; a --hosted entry for the same item wins
  --handoff PATH      the overseer handoff file a successor's brief names,
                      passed through to `oversee-succeed` when this watch
                      records the overseer's launch line (default
                      tmp/handoffs/OVERSEER-HANDOFF.md)
  LANE_WINDOW...      tmux window names to watch; requires $TMUX. A bare name
                      is a window in the session this watch started in, which
                      it resolves once through $TMUX_PANE and names on
                      stderr as session-resolved, so a pane that later dies
                      moves no lane into another session; `session:window`,
                      tmux's own target form, names one in another session.
                      A bare name with no session resolved is refused as
                      session-unresolved naming the lane and the --state file
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
                      stops at the first prompt nobody is there to answer
  --repeat SECS       the watch for a session: run one watch per pass with
                      the other options, sleep SECS after it exits, or
                      ORCH_WATCH_MAIL_INTERVAL where that is shorter and the
                      pass did not exit 2, and run the next. A successor launch, a
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
                      no restart.
                      The set is noted on stderr as fleet-read whenever a
                      read changes what the reader last carried, with the
                      count of records whose status is not running, so a
                      state that parses to no running lane is named rather
                      than watched in silence: a standalone run names the
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
  2  usage or global failure, including overseer-command publication, or a
     lane-local mailbox, clone or workflow-state read failed. A lane-local
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

When pr-watch.sh is installed, oversee-watch runs it with --heal on every pass.
Gate-stale dispatches PR_WATCH_WRITER_WORKFLOW, so its credential requires
actions:write. When pr-watch.sh is absent, the step is skipped with one stderr note.
Inside tmux, an --item with no LANE_WINDOW skips the pane checks with one
stderr note; outside tmux there is no pane to read and nothing is noted.

Environment:
  LINEAR_TEAM                 team the triage check reads under --since, from
                              kendex.settings.toml [env] unless the environment
                              sets it. Empty or absent skips triage, said once;
                              with a team a missing tracker CLI or
                              workflow-state exits 2 rather than dropping it
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
  ORCH_OVERSEER_DEAD_PASSES   consecutive passes the overseer pane must read
                              `exited` before overseer-dead goes out, and
                              `walled` before overseer-walled does (default
                              2). One pass is a poll that caught a live
                              session between its harness and its shell. The
                              walled case also needs its account judged at or
                              below ORCH_OVERSEER_HEADROOM_PCT; passes alone
                              never close a window whose harness is alive
  ORCH_OVERSEER_SUCCESSION    `off` leaves the overseer-dead and
                              overseer-walled notices and
                              launches no successor; `oversee-succeed` owns
                              every other value. An overseer-mark line still
                              goes out under it, carrying succession=off
  ORCH_OVERSEER_MARK_REPEAT   passes a standing overseer-mark waits before it
                              is reported again (default 5). The first crossing
                              is always reported; this only bounds how often a
                              mark the overseer has not yet acted on comes back.
                              The judgement itself runs every pass and reads
                              every account the fleet can launch on, under a 60
                              second ceiling where `timeout` is installed; a
                              read that passes it leaves the mark unjudged for
                              that pass, and on a host without `timeout` the
                              read runs unbounded
  PR_WATCH_WRITER_WORKFLOW    workflow dispatched by pr-watch --heal
  OVERSEE_WATCH_STATE_DIR     one baseline file per repository — reducer,
                              triage, lane-asking, usage-limit, handoff and
                              account rows — the mail pass's file beside the
                              first one, holding each lane mailbox's read
                              position and when the last long pass started,
                              plus claims/ and usage/, both shared across the
                              repositories that point here
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
USAGE
}
# stderr messages start `oversee-watch: REASON field=value ...`. Backslash,
# tab, carriage return and newline in field values are escaped. Tool error
# details and the English explanation follow the stable header.
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
    ask-due-unread) text='The owner asks past their deadline could not be listed, so none was resolved this pass. Fix what lane-mail names under this line.' ;;
    ask-resolve-failed) text='An owner ask past its deadline could not be resolved to its recommendation, so it stands unanswered and the overseer still waits. Fix what lane-mail names under this line; an ask with no recommendation is answered by hand with resolve --text.' ;;
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
