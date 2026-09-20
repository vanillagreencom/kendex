# shellcheck shell=bash
#
# The ONE answer to "what is this lane doing right now", shared by every
# script that has to tell a working lane from a parked, walled, asking, dead
# or absent one. A caller left to invent its own answer invents a different
# one: the watch read the pane screen, `open-terminal --wake` read /proc, and
# the two disagreed about the same lane inside one minute.
#
# `lane_state` is the whole judge. Nothing else may classify a lane.
#
# Sourced, never run.

# ---------------------------------------------------------------------------
# Pane predicates. One line each, matched with `grep -E` against
# `pane_below_last_turn`'s slice — never the whole capture. The exception is a
# launcher proving a launch took on a window it opened seconds ago: that pane
# has no earlier turn to slice from, so pane_working and pane_trust_dialog are
# also read there against the whole capture, and each says so where it is used.
# ---------------------------------------------------------------------------

# A turn in flight: the interrupt hint (both harnesses), the hint shown while
# a foreground shell runs, or the streaming token counter of the status line.
# Measured off running sessions of both harnesses.
#
# Deliberately NOT a spinner glyph. Claude Code animates one frame set
# (`· ✢ * ✶ ✻ ✽`) across every long-running screen, its OAuth sign-in
# included, so a spinner reads a lane parked at a login prompt as working;
# `·` is also its separator character and `*` is in its startup banner. `✻`
# additionally spells the idle end-of-turn line (`✻ Churned for 6s · done`),
# so it survives the turn that drew it exactly as `●` does. The token counter
# and the interrupt hint are drawn only while a turn is actually running.
#
# The counter appears a second or two INTO a turn, after streaming starts, so
# a turn caught in its first moments reads as not working. Callers that poll
# see it on a later pass; callers that must not act on a false negative say so
# where they read it.
#
# One more, measured off live Claude Code lanes. `Jump to bottom (ctrl+End) ↓`
# ends the frame of a pane scrolled up: the live turn is drawn below what is
# visible, so nothing on that screen can classify the lane, and an
# unclassifiable frame must never come back idle. The opening parenthesis of
# the key hint is matched with the words, so a transcript quoting the phrase
# in prose is not read as a scrolled frame; the key name is left out, since
# the hint differs by platform and a missed marker is the worse direction.
WORKING_RE='to interrupt|to run in background|↓ [0-9][0-9.]*[kKmM]? tokens|Jump to bottom [(]'

# A dialog waiting on an answer: the selected numbered row, drawn with each
# harness's marker, and Claude Code's question and key hints.
LANE_ASKING_RE='(❯|›) [0-9]+\. |Do you want to|Enter to select|Esc to cancel'
# The account is spent. Claude Code opens the banner with "You've hit your
# <bucket> limit" / "You've reached your…" and points at /usage-credits; Codex
# prints "Usage limit reached" and its out-of-credits wording. `.` stands in
# for the apostrophe: ASCII in the binaries, typographic once rendered.
USAGE_LIMIT_RE='You.(ve|re) (hit|reached) your [a-z ]*limit|[Uu]sage limit reached|hit usage limits|out of (usage )?credits|/usage-credits'
MODEL_CAPACITY='Selected model is at capacity'
# The marker each harness draws at column 0 for a submitted user message
# echoed into the transcript AND for the composer the lane sits at: Claude
# Code `❯`, Codex `›`. Spelled as an alternation of literals and NEVER as a
# bracket expression: a bracket expression holding a multibyte character is a
# set of its BYTES on every awk without multibyte support — mawk, one-true-awk
# under LC_ALL=C, gawk under LC_ALL=C — where `[❯›]` matches any line opening
# with an E2-lead character, which is most of a transcript.
PANE_MARKER_RE='^❯|^›'
# The live input a lane is sitting at, as opposed to a turn it already took:
# one signature per harness, both measured off a running session.
#   Claude Code draws its composer as the marker then U+00A0, draft or not.
#   Its permission dialog indents its rows; its AskUserQuestion dialog draws
#   the selected row at column 0, DIALOG_ROW_RE below.
#   Codex draws its composer, its placeholder, its draft AND its selected
#   dialog row all as the marker, a blank and text — the same shape as a turn —
#   and always draws one of them below the transcript. So every Codex screen
#   ends in a live-input marker line, and its marker alone is the signature.
# The last marker line is the live input when it carries any of the three
# signatures; pane_below_last_turn holds the rest of the rule.
# Byte escapes, never `\u`: bash leaves a `\u` escape unexpanded in the C
# locale, and an awk that does not expand one either then matches nothing.
# gawk does expand it, so no test on a gawk runner can catch that spelling.
CLAUDE_COMPOSER_RE=$'^\xe2\x9d\xaf\xc2\xa0'
CODEX_MARKER_RE='^›'
# A dialog's selected row, drawn at column 0: measured on Claude Code's
# AskUserQuestion screen (fixtures/oversee-watch/claude-dialog-askuserquestion),
# where `❯ 1. Yes` opens the row and the question sits ABOVE it, and on every
# Codex dialog. It is the live input the lane is waiting at, never a turn:
# read as a turn it becomes the boundary, and the question above it falls out
# of the slice. A submitted turn that itself opens with a numbered item reads
# as live input too and widens the slice by one turn: toward a stale banner
# or dialog above it, and, when a stale interrupt hint sits in that turn,
# toward lane_limit_banner reading a live banner as work in flight. Only a
# turn a human typed opens that way. `[.]`, not `\.`: awk expands escapes in
# a -v value.
DIALOG_ROW_RE='^(❯|›) [0-9]+[.] '

# The live input line with NOTHING typed into it, one signature per harness and
# both measured off the same running sessions as the signatures above. Claude
# Code's empty composer is the marker, U+00A0 and nothing else; Codex draws a
# fixed placeholder into its empty composer
# (fixtures/oversee-watch/codex-composer-idle.txt), which a draft replaces
# (codex-composer-draft.txt). Trailing blanks are tmux padding the row it drew,
# never typed text: `capture-pane -J` keeps them.
CLAUDE_COMPOSER_EMPTY_RE=$'^\xe2\x9d\xaf\xc2\xa0[[:blank:]]*$'
CODEX_COMPOSER_EMPTY_RE='^› Ask Codex to do anything[[:blank:]]*$'

# pane_working SCREEN — the turn-in-flight predicate over one captured pane.
pane_working() { grep -Eq -- "$WORKING_RE" <<<"$1"; }

# The folder-trust question, which STOPS a harness before it reads the
# arguments it was launched with. Claude Code asks it about a folder it holds
# no trust record for, so an unattended launch into one waits out its whole
# deadline while the screen shows a question nobody is watching.
#
# Narrower than LANE_ASKING_RE on purpose, and never a substitute for it. That
# one answers "a dialog is up" over a settled lane's slice, which is the
# `asking` rung; this one names the single dialog that can eat a launch brief,
# over the whole capture of a pane whose lane has no earlier turn to slice
# from, and prints the line so the caller reports the cause rather than a
# timeout that names nothing. Both spellings the dialog ships with are
# measured. Another first-run dialog is not covered and still reads as not
# working, which is the safe direction: a pane wrongly called a dialog would
# abandon a healthy successor.
TRUST_DIALOG_RE='Do you trust the files in this (folder|directory)'

# pane_trust_dialog SCREEN — prints the first matching line and succeeds when
# the pane is stopped at that dialog.
pane_trust_dialog() { grep -Em1 -- "$TRUST_DIALOG_RE" <<<"$1"; }

# The older Claude Code spelling of a live composer, kept because a lane may be
# running a build that still draws it. It says nothing about whether the
# composer under it holds text.
CLAUDE_FOOTER_RE='\? for shortcuts'

# THE HARNESS IS UP on this pane: it is running a turn, or it is holding live
# input. Either proof is the harness's own drawing, which is what an account
# read taken off the pane's process tree needs before it can be about the
# harness rather than about a wrapper still on its way to exec.
#
# A launcher's question, not a lane's: it asks whether a screen belongs to a
# harness at all, where lane_state asks what a harness already on the screen is
# doing. It is read against the whole capture for the reason pane_working is
# read that way at a launch — a pane opened seconds ago has no earlier turn to
# slice from.
#
# Both harnesses, deliberately: keyed on the Claude markers alone this answered
# no for every idle Codex pane, and a caller that treats no as "wait longer"
# then spent its whole bound on a pane that was up all along. Measured on the
# fixtures under orch/tests/fixtures/oversee-watch, where all 7 Codex captures
# answer yes and only codex-working.txt is a turn in flight.
#
# A Claude Code screen held by a dialog answers NO: its permission rows are
# indented and its AskUserQuestion row opens with the plain space, not the
# composer's U+00A0. A caller of this predicate waits such a pane out and says
# so, which is the safe direction — a dialog row is also the shape of a
# submitted turn that opens with a numbered item, and reading one as the
# harness's own live input would place a read on a screen that proves nothing.
HARNESS_UP_RE="$CLAUDE_COMPOSER_RE|$CODEX_MARKER_RE|$CLAUDE_FOOTER_RE"

# pane_harness_up SCREEN — the predicate over one captured pane.
pane_harness_up() { pane_working "$1" || grep -Eq -- "$HARNESS_UP_RE" <<<"$1"; }

# The pane lines strictly below the last user turn — the whole pane when the
# screen holds none. A banner the lane has since taken another turn past is
# scrollback, not the account's state now: after a reset the old banner stays
# on the visible screen, and reporting it every pass buries the live lanes.
#
# The boundary is the last marker line, unless that line is the live input the
# lane is sitting at — a composer or a dialog's selected row — in which case it
# is the marker line before it.
#
# A marker line that is the LAST line of the capture counts as live input
# whatever it looks like. Nothing sits after it, so the wider window costs
# nothing there, and the fallback is what keeps an unrecognized composer from
# becoming the boundary itself: that would empty the slice and turn
# usage-limit into a silent no-op for the lane. Unrecognized fails toward a
# stale banner, never toward silence.
pane_turn_slice() {
  awk -v mode="$2" -v marker="$PANE_MARKER_RE" -v composer="$CLAUDE_COMPOSER_RE" -v codex="$CODEX_MARKER_RE" -v dialog="$DIALOG_ROW_RE" '
    { line[NR] = $0; if ($0 ~ marker) { prev = last; last = NR } }
    END {
      live = (last > 0 && (last == NR || line[last] ~ composer || line[last] ~ codex || line[last] ~ dialog))
      turn = live ? prev : last
      first = mode == "before" ? 1 : turn + 1
      final = mode == "before" ? turn : NR
      for (i = first; i <= final; i++) print line[i]
    }
  ' <<<"$1"
}

pane_below_last_turn() { pane_turn_slice "$1" below; }
pane_turn_identity() { pane_turn_slice "$1" before | cksum; }

# Is the lane's live input line EMPTY — nothing typed and waiting unsent?
#
# The rule lives here, beside the composer signatures it reads, because the
# caller that needs it is about to TYPE into the pane: `lane-close` pastes
# `/exit` at the cursor, and a composer already holding a draft submits the
# draft together with it, starting a turn on a lane the fleet has called
# finished. Asking what a lane is doing needs none of this — `lane_state` calls
# a lane sitting at its composer idle, draft or no draft — so the two questions
# stay apart and no caller has to invent this one.
#
# The line read is the last marker line below the last turn: the same live
# input line pane_turn_slice refuses to take as the turn boundary.
#
#   0  the line is one of the two measured empty composers
#   1  the line carries a draft
#   2  no line below the last turn carries a marker, or the marker line matches
#      neither harness's composer. Nothing was measured, so a caller about to
#      type must refuse rather than read it as empty.
lane_composer_empty() { # SCREEN
  local slice matched line
  # Every failure below is status 2, the "nothing measured" answer: a slice the
  # scan could not take and a slice with no marker in it are equally no reading
  # of a composer, and neither may reach a caller as permission to type.
  slice="$(pane_below_last_turn "$1")" || return 2
  matched="$(grep -E -- "$PANE_MARKER_RE" <<<"$slice")" || return 2
  line="${matched##*$'\n'}"
  if grep -Eq -- "$CLAUDE_COMPOSER_EMPTY_RE|$CODEX_COMPOSER_EMPTY_RE" <<<"$line"; then return 0; fi
  if grep -Eq -- "$CLAUDE_COMPOSER_RE|$CODEX_MARKER_RE" <<<"$line"; then return 1; fi
  return 2
}

# The limit banner in SLICE as the ACCOUNT speaking, empty when it is not.
# A slice with no banner is empty, and so is one on a lane with a turn in
# flight: limit-shaped text a lane prints mid-turn is its own output, not its
# account's. ONE answer for every consumer of the banner — the row that records
# a sighting, the event that reports one, and the `walled` rung of lane_state —
# because a guard included at one of them and missed at the other is how this
# reopened twice.
#
# Exit 2 is the scan itself failing, which is no answer: the caller decides
# whether that ends its run. A grep miss is exit 1 and an empty banner.
lane_limit_banner() {
  local slice="$1" banner rc=0
  banner="$(grep -E -- "$USAGE_LIMIT_RE" <<<"$slice")" || rc=$?
  [[ "$rc" -le 1 ]] || return 2
  [[ -n "$banner" ]] || return 0
  ! pane_working "$slice" || return 0
  printf '%s\n' "$banner"
}

# ---------------------------------------------------------------------------
# Process predicates.
# ---------------------------------------------------------------------------

# A login shell reports itself as `-bash`; strip the dash before matching.
is_bare_shell() {
  case "${1#-}" in
    bash|zsh|fish|sh|dash) return 0 ;;
  esac
  return 1
}

# Does the pane's process have a child? A foreground shell does not mean the
# lane is over: a lane started by typing the wrapper at an interactive prompt
# (`hclaude --resume <id>`, the normal way to resume) keeps that shell as the
# pane process and the harness as its child, so the pane reads `fish` for the
# lane's whole life. Only a shell with nothing under it is finished.
#
# Returns 0 for a child and 1 for none — pgrep's own two answers — and 2 for
# anything else, which is not an answer at all: pgrep documents 2 for a syntax
# error and 3 for a fatal one, and a pgrep missing from PATH leaves 127. The
# raw status is kept in LANE_PROBE_RC so a caller's note can name what
# happened. `ps --ppid` is procps-only and BSD ps rejects it with status 1,
# the same status it uses for no match, which read every pane as childless.
# One probe per bare-shell lane per pass; no walking of the tree below.
LANE_PROBE_RC=0
pane_has_child() {
  LANE_PROBE_RC=0
  pgrep -P "$1" >/dev/null 2>&1 || LANE_PROBE_RC=$?
  [[ "$LANE_PROBE_RC" -le 1 ]] || return 2
  return "$LANE_PROBE_RC"
}

# The harness processes whose current directory is one worktree. This is the
# ownership read used before a wake starts a second harness and before a hosted
# stop signals one. The worktree path is canonical, and a process that still
# exists but whose cwd cannot be read makes the whole answer unreadable.
#
# On success LANE_OWNED_PROCESS_TABLE holds `pid ppid name` rows for the host,
# and LANE_OWNED_PROCESS_PIDS holds the matching top-level harness pids. A host
# with no matching harness is a successful empty answer. Status 2 means the
# process table or an existing candidate could not be read.
LANE_OWNED_PROCESS_TABLE=""
LANE_OWNED_PROCESS_PIDS=""
lane_owned_processes() { # WORKTREE HARNESS
  local root table candidates pid cwd
  LANE_OWNED_PROCESS_TABLE=""
  LANE_OWNED_PROCESS_PIDS=""
  root="$(cd -- "$1" && pwd -P)" || return 2
  table="$(ps -A -o pid= -o ppid= -o comm= | awk '{ pid = $1; ppid = $2; $1 = ""; $2 = ""; name = substr($0, 3); sub(/.*\//, "", name); print pid, ppid, name }')" \
    || return 2
  candidates="$(awk -v harness="$2" '$3 == harness { print $1 }' <<<"$table")" || return 2
  for pid in $candidates; do
    [[ -d /proc/self ]] || return 2
    if ! cwd="$(readlink -- "/proc/$pid/cwd" 2>/dev/null)"; then
      [[ -d "/proc/$pid" ]] || continue
      return 2
    fi
    [[ "$cwd" == "$root" ]] || continue
    LANE_OWNED_PROCESS_PIDS+="${LANE_OWNED_PROCESS_PIDS:+ }$pid"
  done
  LANE_OWNED_PROCESS_TABLE="$table"
}

# ---------------------------------------------------------------------------
# Pane observation.
# ---------------------------------------------------------------------------

# The pane a recorded window names, in either form tmux itself accepts as a
# target: a bare `KEN-1` is that window on whatever session of the caller's
# server carries it, and `kendex:KEN-1` is that window under exactly that
# session. ONE owner for the resolution, because `lanes state`, the wake and
# `lane-close` all start from a recorded window and a second matcher is how
# two of them come to point at different panes.
#
# The session is matched EXACTLY. tmux's own `-t` falls back to a prefix
# match, so a lane whose session died would silently resolve a sibling
# session's window of the same name and the close would act on someone else's
# harness.
#
# On exactly one match LANE_PANE_ID, LANE_PANE_PID and LANE_PANE_CMD hold that
# pane and the call succeeds. Otherwise the three are empty and
# LANE_PANE_COUNT says which silence it was: 0 is a window this server does
# not hold, and more than 1 is a name two windows share, where a guess acts on
# the wrong lane. Either is status 1. Status 2 is the pane list failing, or a
# matched row carrying no pane id — no answer at all rather than an absence.
LANE_PANE_ID=""
LANE_PANE_COUNT=0
lane_pane_resolve() { # WINDOW
  local rows matches fmt session="" name qualified=0
  LANE_PANE_ID=""; LANE_PANE_PID=""; LANE_PANE_CMD=""; LANE_PANE_COUNT=0
  # The separator is $'\t' and never "\t": tmux copies a format string through
  # unexpanded, so the double-quoted spelling puts a literal backslash-t
  # between the fields while awk splits on a real tab, and every window reads
  # as no match. The pane command is last because it absorbs the rest of the
  # line, which keeps a window or session named with a tab from shifting it.
  fmt="#{session_name}"$'\t'"#{window_name}"$'\t'"#{pane_id}"$'\t'"#{pane_pid}"$'\t'"#{pane_current_command}"
  rows="$(tmux list-panes -a -F "$fmt" 2>/dev/null)" || return 2
  name="$1"
  # The first colon splits, the way tmux splits its own target: a window name
  # is a tracker id and carries none.
  case "$1" in
    *:*) qualified=1; session="${1%%:*}"; name="${1#*:}" ;;
  esac
  matches="$(awk -F'\t' -v q="$qualified" -v s="$session" -v n="$name" \
    '(q == 0 || $1 == s) && $2 == n { print }' <<<"$rows")" || return 2
  LANE_PANE_COUNT="$(awk 'NF { c++ } END { print c + 0 }' <<<"$matches")" || return 2
  [[ "$LANE_PANE_COUNT" == 1 ]] || return 1
  IFS=$'\t' read -r _ _ LANE_PANE_ID LANE_PANE_PID LANE_PANE_CMD <<<"$matches"
  [[ -n "$LANE_PANE_ID" ]] || {
    LANE_PANE_ID=""; LANE_PANE_PID=""; LANE_PANE_CMD=""; LANE_PANE_COUNT=0
    return 2
  }
}

# The lane's tmux pane, as the three raw observations `lane_state` judges
# from: the pane's foreground command, its process id, and its screen, found
# through the resolution above. For a caller whose own window is on the lane's
# tmux server — `open-terminal --wake` and `lanes state` both are — this is the
# SAME pane oversee-watch reads, which is why the three now answer alike.
# oversee-watch keeps its own per-lane reads: it captures to a file per pass
# and stops the run on a failed capture, where these callers degrade instead.
#
# A window this server does not hold, a name it holds more than once, or a
# capture that fails leaves all three empty, and the count at none: nothing
# here can be acted on, whichever of the three it was. That is not an idle
# lane either — the judge then has only the harness process to go on, and
# answers `unjudged` where that is silent too, which the wake refuses on. A
# caller that must tell those silences apart — `lane-close` owes its operator
# one reason per cause — calls lane_pane_resolve and reads LANE_PANE_COUNT
# itself.
LANE_PANE_CMD=""
LANE_PANE_PID=""
LANE_PANE_SCREEN=""
lane_pane_observe() { # WINDOW
  LANE_PANE_SCREEN=""
  # The count belongs to the resolution, which answers three ways; this one
  # answers two, so a window two panes share leaves the same post-state here as
  # a window none carries.
  lane_pane_resolve "$1" || { LANE_PANE_COUNT=0; return 0; }
  LANE_PANE_SCREEN="$(tmux capture-pane -pJ -t "$LANE_PANE_ID" 2>/dev/null)" || {
    LANE_PANE_ID=""; LANE_PANE_PID=""; LANE_PANE_CMD=""; LANE_PANE_SCREEN=""
    LANE_PANE_COUNT=0
    return 0
  }
}

# ---------------------------------------------------------------------------
# The judge.
# ---------------------------------------------------------------------------

# lane_state OUT_VAR WINDOW CMD PID SCREEN [SESSION] — assigns OUT_VAR
# exactly one of:
#
#   gone      no window: there is no lane here to ask about
#   exited    the window outlived its harness — a bare shell with nothing
#             under it, the shape a session that quit, crashed or hit its
#             limit leaves behind
#   walled    the account is spent and said so below the lane's last turn
#   asking    a dialog is up and waiting on an answer
#   idle      the harness is at its input prompt with nothing in flight
#   working   a turn is in flight
#   unjudged  nothing observed settles it — NOT a synonym for idle, and every
#             caller that acts on a lane must refuse on it
#
# Inputs, each the raw observation and none of them a verdict:
#
#   WINDOW   `listed` or `gone` — whether the lane's tmux window exists
#   CMD      the pane's foreground process name, "" when it cannot be read
#   PID      the pane process id, "" when the child probe cannot run
#   SCREEN   the pane capture, whole
#   SESSION  `busy`, `idle` or `unjudged` from the harness process read
#            through /proc, and "" where the caller has no /proc to read
#
# THE PANE IS ASKED FIRST FOR EVERY RUNG THAT IS NOT `idle`, which the
# supplied process read decides; the session rule below carries that half.
# A lane whose harness runs on another machine — every hosted lane — has
# nothing in the reader's /proc by construction, and judging from /proc first
# made every such lane `unjudged`. Its ssh pane is on the reader's own tmux server and carries the
# same screen the harness draws, so the pane rungs answer for it exactly as
# they do for a local lane.
#
# Rung order is load-bearing and is the order the watch has always used:
# `walled` outranks `asking` because a limit banner can sit above a stale
# prompt and the spent account is the news; `asking` outranks `working`
# because a dialog is up whatever the transcript above it is doing; and
# `idle` demands the absence of a turn in flight, so a working lane can never
# take that rung.
#
# THE WHOLE SESSION RULE, in one sentence: a SUPPLIED SESSION that is not
# `idle` answers on its own and the pane's `idle` rung is never reached, so a
# lane only comes back `idle` when every reader the caller has agrees it is.
# WORKING_RE appears a second or two into a turn, after streaming starts, so a
# turn's first moments are an input marker with nothing above it —
# indistinguishable on the screen from a finished turn. `open-terminal --wake`
# is the caller that acts on `idle`, by starting a second session on the lane's
# worktree, and the only one that supplies SESSION. A process read that cannot
# settle the question is `unjudged`, and treating that as agreement is what
# would wake a live lane. Codex publishes no idle signal, so the wake's reader
# answers `busy` for a codex process with a shell under it and `unjudged` for
# every other one it finds in the lane's worktree: such a lane is never woken
# while that process lives. A caller that supplies no SESSION keeps every
# answer the pane gives.
#
# An OUT_VAR rather than a printed word: the child probe's raw status is the
# caller's to report, and LANE_PROBE_RC set inside a command substitution
# would never leave that subshell. Every local carries the `_ls_` prefix so a
# caller may name its output variable anything without the assignment landing
# in one of them.
#
# Exit 2, with OUT_VAR set to `unjudged`, means a scan failed rather than
# answered. The caller decides whether that ends its run.
lane_state() {
  local _ls_out="$1" _ls_window="$2" _ls_cmd="$3" _ls_pid="$4" _ls_screen="$5" _ls_session="${6:-}"
  local _ls_slice _ls_banner _ls_rc=0
  LANE_PROBE_RC=0
  if [[ "$_ls_window" != listed ]]; then printf -v "$_ls_out" gone; return 0; fi
  if is_bare_shell "$_ls_cmd" && [[ -n "$_ls_pid" ]]; then
    pane_has_child "$_ls_pid" || _ls_rc=$?
    # 1 is "no child" and the whole of `exited`. 2 is a probe that could not
    # run, never an answer: the pane rungs below still get their say, and
    # LANE_PROBE_RC carries the status for the caller's note.
    if [[ "$_ls_rc" -eq 1 ]]; then printf -v "$_ls_out" exited; return 0; fi
  fi
  _ls_slice="$(pane_below_last_turn "$_ls_screen")"
  _ls_rc=0
  _ls_banner="$(lane_limit_banner "$_ls_slice")" || _ls_rc=$?
  if [[ "$_ls_rc" -eq 2 ]]; then printf -v "$_ls_out" unjudged; return 2; fi
  if [[ -n "$_ls_banner" ]]; then printf -v "$_ls_out" walled; return 0; fi
  if grep -Eq -- "$LANE_ASKING_RE" <<<"$_ls_slice"; then printf -v "$_ls_out" asking; return 0; fi
  if pane_working "$_ls_slice"; then printf -v "$_ls_out" working; return 0; fi
  # The supplied process read, whole, before any rung that could answer `idle`.
  # Anything but `idle` here answers by itself: `busy` is a turn the screen has
  # not drawn yet, and `unjudged` is a reader that could not tell, which must
  # never become the caller's licence to act.
  case "$_ls_session" in
    "" | idle) ;;
    busy) printf -v "$_ls_out" working; return 0 ;;
    *) printf -v "$_ls_out" unjudged; return 0 ;;
  esac
  if grep -Eq -- "$PANE_MARKER_RE" <<<"$_ls_slice"; then printf -v "$_ls_out" idle; return 0; fi
  # The screen settles nothing: no marker of any kind, which is what a lane
  # mid-redraw, a lane running a full-screen program over its harness, and a
  # pane whose capture failed all look like. A caller that read the harness
  # process and found it idle has the last word here; one that read nothing has
  # no word at all.
  case "$_ls_session" in
    idle) printf -v "$_ls_out" idle ;;
    *) printf -v "$_ls_out" unjudged ;;
  esac
}
