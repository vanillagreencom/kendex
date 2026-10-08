#!/usr/bin/env bash
# Tests for open-terminal's --lane launch through the lane's own launcher, and
# the account read back off the pane, which closes a window running on
# another account. Its rows race a real process tree on the wall clock, so
# run-all.sh runs this suite alone; the rest of the --lane wiring is
# open-terminal-lane-pick.sh and open-terminal-lane-hosted.sh.
#
# One case per behaviour surface; shaped input is one table per case, one
# asserted row per shape. Every run gets its own claim store, tmux log and
# pane counter, so no row reads another's launches. tmux, worktree and gh are
# stubs: run under a live session (TMUX set) open-terminal's default is tmux
# mode, and an unstubbed launch would open a real window per row. The world
# they share is lib/open-terminal-lane-world.sh.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
# Physical: on macOS the temp root sits under /var -> /private/var, and the
# scripts print the resolved path.
TMP_ROOT="$(mktemp -d)" || { echo "open-terminal-lane: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "open-terminal-lane: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "open-terminal-lane: scratch=resolve-failed" >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
# shellcheck source=lib/open-terminal-lane-world.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/open-terminal-lane-world.sh"

echo "=== a lane launches through its own launcher ==="
# A command named for the lane's config directory selects the account itself,
# and the dotfiles-style bare `claude` on PATH exports CLAUDE_CONFIG_DIR for
# its own name — so an env prefix in front of THAT is overwritten and the lane
# runs on another account with nothing on screen saying so. Where the launcher
# exists it replaces the prefix; where it does not, and where the name is the
# harness word itself, the prefix stands.
#
# These rows read the rendered launch line only, so they run on every platform.
# That matters most where the pane check below CANNOT run: there the launcher
# rule is the whole defence, and it is the leg with no second line of it.
LNBIN="$TMP_ROOT/ln-bin"; mkdir -p "$LNBIN"
# The shims: a bare `claude` and a bare `codex` that rewrite the variable for
# their own name. Nothing executes them here — tmux is a stub — but they are
# what makes the launcher the only selector that survives, and on PATH ahead of
# everything they seal the machine's own wrappers out of these rows.
cat > "$LNBIN/claude" <<'STUBEOF'
#!/usr/bin/env bash
export CLAUDE_CONFIG_DIR="$HOME/.claude"
exec true "$@"
STUBEOF
cp "$LNBIN/claude" "$LNBIN/1claude"
cp "$LNBIN/claude" "$LNBIN/codex"
cp "$LNBIN/claude" "$LNBIN/1codex"
chmod +x "$LNBIN/claude" "$LNBIN/1claude" "$LNBIN/codex" "$LNBIN/1codex"
LNLANE="$TMP_ROOT/.1claude"; mkdir -p "$LNLANE"        # `1claude` is on PATH
LNBARE="$TMP_ROOT/.lnbareclaude"; mkdir -p "$LNBARE"   # no such command exists
LNSELF="$TMP_ROOT/.claude"; mkdir -p "$LNSELF"         # named for the harness
LNCODEX="$TMP_ROOT/.1codex"; mkdir -p "$LNCODEX"       # `1codex` is on PATH
LNCODEXSELF="$TMP_ROOT/.codex"; mkdir -p "$LNCODEXSELF"

# The pane's process tree: its own process carries whatever the operator's
# shell had, its child carries $2 under the lane variable $1 the way
# `env VAR=<picked>` does, and the leaf carries $3 the way a wrapper that
# rewrote the variable does. A read that stopped at the first descendant would
# report $2 for a tree running on $3.
#
# With a trigger file in $4 the leaf appears only after that file does, which is
# how a wrapper that does work before its exec behaves: the first read then
# lands inside the window where only the picked value is on the tree.
cat > "$TMP_ROOT/lane-tree" <<'STUBEOF'
#!/usr/bin/env bash
OT_VAR="$1" OT_LEAF="$3" OT_TRIGGER="${4:-}" OT_GATE="${5:-}" env "$1=$2" bash -c '
  if [[ -n "$OT_TRIGGER" ]]; then
    while [[ ! -e "$OT_TRIGGER" ]]; do sleep 0.1; done
    sleep 0.3
  fi
  # A gated tree stands on the picked account for long enough that a reading
  # taken before the launch is verified settles on it, then hands over and only
  # then lets the pane look launched.
  [[ -z "$OT_GATE" ]] || sleep 2
  env "$OT_VAR=$OT_LEAF" sleep 30 &
  [[ -z "$OT_GATE" ]] || : > "$OT_GATE"
  wait' &
wait
STUBEOF
chmod +x "$TMP_ROOT/lane-tree"
# Depth first, so a parent is never killed before the children it would orphan.
kill_tree() { local p; for p in $(pgrep -P "$1" 2>/dev/null || true); do kill_tree "$p"; done; kill "$1" 2>/dev/null || true; }

# lane_launch SCRIPT NAME HARNESS LANE LEAF LATE|- FIELDS — one real-harness
# lane launch through SCRIPT, from a caller checkout of its own, with the
# launcher directory ahead of PATH and the process tree above standing in for
# the launched harness. LATE=late holds the leaf back until the check reads the
# pane pid. FIELDS names the facts to print, in its own order, so a row asserts
# exactly what it is about:
#   rc         exit status
#   form       `launcher` when the line names the launcher by the absolute path
#              the judge resolved, `prefix` under the env prefix, else `none`
#   bare       lines naming the launcher by the bare word a differently-PATHed
#              pane shell would resolve again for itself
# LATE=gated instead holds the handover, and the harness screen the pane draws
# with it, until after a reading taken the instant after the keystrokes would
# have settled.
#   verified   lane-verified lines; mismatch, lane-mismatch lines naming the
#              picked and observed dirs; closed, tmux kill-window calls
#   unobserved lane-unobserved lines
#   premise    lane-premise-unmet lines
#   unpremised lane-unobserved lines whose reason is the missing premise
#   resumed    launch lines carrying --resume, which is what a relaunch that
#              found a stored transcript renders in place of a fresh brief.
#              Read off the rendered command and not off the session-resumed
#              line, which the loop prints only after a launch that succeeded
#   probes     tmux capture-pane calls, which is how many times the premise
#              wait looked before it answered: 1 for a screen it knows, the
#              bound plus one for a screen it does not
#
# Trailing KEY=VALUE options, each optional:
#   cmd=       a --cmd template: the caller's own command, whose first word
#              open-terminal does not replace and whose pane it never reads back
#   flags=     further open-terminal flags, split on whitespace
#   text=      the pane screen the tmux stub draws, in place of the brief plus
#              the live-input marker the row's own harness draws
#   clock=virtual  the launch reads time through the virtual clock, seeded at
#              the real epoch, so its tmux waits and settle reads cost no wall
#              time. Only for a row whose tree carries one account throughout:
#              a row that races a handover keeps the real one.
#   clock=waived   the same stubs on PATH with the clock waived, and the
#              launch run under a two-second ceiling: the inverse control
LAUNCH_CLOCK="$TMP_ROOT/launch-clock"
lane_launch() {
  local script="$1" name="$2" harness="$3" lane="$4" leaf="$5" late="$6" fields="$7" item="KEN-50"
  shift 7
  local runs="$TMP_ROOT/$name-runs" caller="$TMP_ROOT/$name-caller" out rc=0 tree form=none launcher trigger="" var f value got=""
  # A row whose leaf names a path derived from the launch directory pins that
  # directory, since the stub otherwise makes a fresh one per run and no row
  # can spell it.
  local template="" flags="" text="" fixed_wt="" prefix_home="$lane" opt clock_path="" clock_file="" ceiling=()
  for opt in "$@"; do
    case "$opt" in
      clock=virtual)
        clock_path="$TMP_ROOT/clock-bin:"; clock_file="$LAUNCH_CLOCK"
        "$STUB_REAL_DATE" +%s > "$LAUNCH_CLOCK"; cp -- "$LAUNCH_CLOCK" "$LAUNCH_CLOCK.seed" ;;
      clock=waived) clock_path="$TMP_ROOT/clock-bin:"; ceiling=("$(command -v timeout || command -v gtimeout)" 2) ;;
      cmd=*) template="${opt#cmd=}" ;;
      flags=*) flags="${opt#flags=}" ;;
      text=*) text="${opt#text=}" ;;
      wt=*) fixed_wt="${opt#wt=}" ;;
      home=*) prefix_home="${opt#home=}" ;;
      *) printf 'lane_launch: unknown option %s\n' "$opt" >&2; exit 1 ;;
    esac
  done
  # Every lane launch names a model and an effort or nothing launches. These
  # rows are about the launcher form and their lanes are outside every lane
  # record, so the pair is passed in the spelling the row's harness takes and
  # nothing here turns on its value. It goes in the text the launch RUNS: inside
  # a row's own --cmd command where it has one, since --launch-flags beside a
  # template reach nothing and are refused, and in --launch-flags where it does
  # not. The question-tool words follow it, for the same reason. Appended, so the template's FIRST word, which is what the launcher form
  # is judged on, stays the row's own.
  local choice extra=()
  case "$harness" in
    codex) choice="-m gpt-6-astra -c model_reasoning_effort=high" ;;
    *) choice="--model opus --effort high" ;;
  esac
  if [[ -n "$template" ]]; then extra=(--cmd "$template $choice $QUESTION_OFF_ALL")
  else extra=(--launch-flags "$choice"); fi
  # shellcheck disable=SC2206  # a row's flags are its own words, split on purpose.
  [[ -z "$flags" ]] || extra+=($flags)
  # The screen a launched TUI draws: the brief it was given, and the live-input
  # marker that says the harness itself is up. Per harness, because that marker
  # is what the premise ahead of the account read waits for: a codex row given
  # the Claude footer would be pinning the premise against a screen only Claude
  # draws. A gated row holds the marker back with the handover, and an
  # unlaunched row is given a screen carrying neither.
  if [[ -z "$text" ]]; then
    case "$harness" in
      codex) text="/orch start $item"$'\n''› ' ;;
      *) text="/orch start $item"$'\n''? for shortcuts' ;;
    esac
  fi
  # The lane variable per harness, pinning open-terminal's own mapping.
  case "$harness" in codex) var=CODEX_HOME ;; *) var=CLAUDE_CONFIG_DIR ;; esac
  # `basename --`, the way the judge derives it: a trailing-slash row's expected
  # name has to come out of the same normalisation the row is pinning.
  launcher="$(basename -- "$lane")"; launcher="${launcher#.}"
  mkdir -p "$runs" "$caller"
  git -C "$caller" init -q
  git -C "$caller" config gc.auto 0
  git -C "$caller" config maintenance.auto false
  local gate=""
  [[ "$late" != late ]] || trigger="$runs/trigger"
  [[ "$late" != gated ]] || gate="$runs/gate"
  "$TMP_ROOT/lane-tree" "$var" "$lane" "$leaf" "$trigger" "$gate" & tree=$!
  out="$( cd "$caller" && env "${LANE_ENV_DEFAULTS[@]}" LANES_HOME="$H" ORCH_LANES_FETCH_CMD="$FETCHER" GH_ISSUE_PATTERN='[A-Z]+-[0-9]+' \
    TMUX=stub,1,0 ORCH_TMUX_SESSION=stub OT_TMUX_LOG="$runs/tmux.log" OT_TMUX_SERVER_PID="$$" OT_TMUX_PANES="$runs/panes" \
    OT_PANE_PID="$tree" OT_PANE_TEXT="$text" ORCH_TMUX_VERIFY_SECS=5 OT_PANE_PID_TRIGGER="$trigger" \
    OT_LAUNCHED_GATE="$gate" STUB_CLOCK="$clock_file" \
    OT_WT_LOG="$runs/worktree.log" OT_WT_FIXED="$fixed_wt" OVERSEE_WATCH_STATE_DIR="$runs/state" \
    PATH="$clock_path$LNBIN:$OT_STUB_BIN:$PATH" WORKTREE_CLI="$OT_STUB_BIN/worktree" \
    ${ceiling[@]+"${ceiling[@]}"} "$script" --harness "$harness" --lane "$lane" ${extra[@]+"${extra[@]}"} "$item" 2>&1 )" || rc=$?
  kill_tree "$tree"
  # Under a template the first word after the prefix is the caller's own
  # command, not the harness word, so the prefix is all this row matches on.
  # The value the prefix must name: the lane itself, or the home `home=` gives
  # a row whose launch builds one.
  local want="clear; env $var='$prefix_home' "
  if [[ -z "$template" ]]; then
    [[ "$harness" != codex ]] || want+="ORCH_COMPACTION_OVERRIDES='$CODEX_COMPACTION' "
    want+="$harness "
  fi
  grep -qF "$want" "$runs/tmux.log" && form=prefix
  grep -qF "clear; '$LNBIN/$launcher' " "$runs/tmux.log" && form=launcher
  for f in $fields; do
    case "$f" in
      rc) value="$rc" ;;
      form) value="$form" ;;
      bare) value="$(grep -cF "clear; '$launcher' " "$runs/tmux.log" || true)" ;;
      verified) value="$(grep -c "^open-terminal: lane-verified item=$item " <<<"$out" || true)" ;;
      mismatch) value="$(grep -c "^open-terminal: lane-mismatch item=$item picked=$lane observed=" <<<"$out" || true)" ;;
      closed) value="$(grep -c '^kill-window' "$runs/tmux.log" || true)" ;;
      unobserved) value="$(grep -c "^open-terminal: lane-unobserved item=$item " <<<"$out" || true)" ;;
      premise) value="$(grep -c "^open-terminal: lane-premise-unmet item=$item reason=no-harness-screen$" <<<"$out" || true)" ;;
      unpremised) value="$(grep -c "^open-terminal: lane-unobserved item=$item reason=unpremised$" <<<"$out" || true)" ;;
      resumed) value="$(grep -c -- '--resume ' "$runs/tmux.log" || true)" ;;
      probes) value="$(grep -c '^capture-pane' "$runs/tmux.log" || true)" ;;
      *) value=UNKNOWN_FIELD ;;
    esac
    got="$got $f=$value"
  done
  printf '%s' "${got# }"
}

assert_eq "$(lane_launch "$OPEN_TERMINAL" launcher claude "$LNLANE" "$LNLANE" - "rc form bare" clock=virtual)" \
  "rc=0 form=launcher bare=0" \
  "a lane whose launcher is on PATH launches through it by the absolute path the judge resolved, with no env prefix"
assert_eq "$(lane_launch "$OPEN_TERMINAL" bare claude "$LNBARE" "$LNBARE" - "rc form bare" clock=virtual)" \
  "rc=0 form=prefix bare=0" \
  "a lane with no launcher on PATH keeps the env prefix"
assert_eq "$(lane_launch "$OPEN_TERMINAL" self claude "$LNSELF" "$LNSELF" - "rc form bare" clock=virtual)" \
  "rc=0 form=prefix bare=0" \
  "a lane named for the harness itself keeps the env prefix: the harness binary picks its own default account"
# A codex launch runs under the home it builds for its worktree, and that home
# is reached by the variable that names it whatever else is on PATH: an account
# launcher exports CODEX_HOME for its OWN name, which would put the launch back
# on the shared config with no trust entry in it. So the launcher form is what
# these two rows say a codex lane must NOT take, where the claude rows above
# say a lane with a launcher takes it. Each row pins its worktree, since the
# home it must name is derived from that path.
CODEXLAUNCHWT="$TMP_ROOT/codex-launcher-wt"
CODEXSELFWT="$TMP_ROOT/codex-self-wt"
codex_home_for() { ( source "$SCRIPTS_DIR/lib/lane-launch.sh" && lane_codex_home_path "$1" "$2" ); }
assert_eq "$(lane_launch "$OPEN_TERMINAL" codex-launcher codex "$LNCODEX" "$LNCODEX" - "rc form bare" clock=virtual \
  "wt=$CODEXLAUNCHWT" "home=$(codex_home_for "$LNCODEX" "$CODEXLAUNCHWT")")" \
  "rc=0 form=prefix bare=0" \
  "a codex lane keeps the prefix even where its launcher is on PATH: the launcher would overwrite the home carrying the launch's folder trust"
assert_eq "$(lane_launch "$OPEN_TERMINAL" codex-self codex "$LNCODEXSELF" "$LNCODEXSELF" - "rc form bare" clock=virtual \
  "wt=$CODEXSELFWT" "home=$(codex_home_for "$LNCODEXSELF" "$CODEXSELFWT")")" \
  "rc=0 form=prefix bare=0" \
  "a codex lane named for the harness itself keeps the CODEX_HOME prefix"
assert_eq "$(lane_launch "$OPEN_TERMINAL" trailing claude "$LNLANE/" "$LNLANE" - "rc form bare" clock=virtual)" \
  "rc=0 form=launcher bare=0" \
  "a lane path written with a trailing slash reaches the same launcher, the spelling --lane and ORCH_LANE_DIRS both carry through"

# A --cmd template is the caller's own command: its first word is not replaced
# even on a lane whose launcher IS on PATH, and its pane is read back by
# nothing, so neither account verdict appears. Without the template term in the
# judge this launch would be read back against a command nobody here built.
# The pane draws no harness screen, so a wait taken here would run to its whole
# bound: at zero probes this launch never looked, which is the guard. That bound
# is the hard-coded 15 here, not ORCH_TMUX_VERIFY_SECS: a --cmd template reads
# none of the waits the setting is validated for, so the setting is not read for
# it either.
assert_eq "$(lane_launch "$OPEN_TERMINAL" template claude "$LNLANE" "$LNLANE" - "rc form verified unobserved probes" "cmd=true {item}" "text=dev@lane:~$" clock=virtual)" \
  "rc=0 form=prefix verified=0 unobserved=0 probes=0" \
  "a --cmd template keeps the env prefix on a launcher-named lane and is read back by nothing"

# The suite's one must-fail control is on the model rule, on the same arguments
# as the green row beside it. run_ot reads $OPEN_TERMINAL, so the mutant takes
# that name for its row and the shipped path is restored after. OUTSIDE_LANE is
# a config dir no lane record covers, so a launch that gets past the refusal
# meets no usage verdict and the row reads the refusal alone.
OPEN_TERMINAL_SHIPPED="$OPEN_TERMINAL"
run_ot "" --harness claude --lane "$OUTSIDE_LANE" --cmd true KEN-90
assert_eq "$(observe "rc=1 launched=nolog modelmissing=harness=claude,lane=$OUTSIDE_LANE,spellings=--model")" \
  "rc=1 launched=nolog modelmissing=harness=claude,lane=$OUTSIDE_LANE,spellings=--model" \
  "a lane launch naming no model is refused for it"
OPEN_TERMINAL="$(mutant_scripts ctl-model-rule/orch open-terminal)/open-terminal" || exit 1
orch_fixture_shared_libs "$TMP_ROOT/ctl-model-rule/orch"
mutate_file "$OPEN_TERMINAL" 'if [[ -z "$LAUNCH_MODEL" ]]; then' 'if [[ -n "$LAUNCH_MODEL" ]]; then'
run_ot "" --harness claude --lane "$OUTSIDE_LANE" --cmd true KEN-91
assert_eq "$(observe "modelmissing=none effortmissing=harness=claude,lane=$OUTSIDE_LANE,spellings=--effort")" \
  "modelmissing=none effortmissing=harness=claude,lane=$OUTSIDE_LANE,spellings=--effort" \
  "control: without the model rule a launch naming no model is not refused for it"
OPEN_TERMINAL="$OPEN_TERMINAL_SHIPPED"

run_ot "cmd=true --model opus" --harness claude --lane "$OUTSIDE_LANE" KEN-92
assert_eq "$(observe "rc=1 launched=nolog effortmissing=harness=claude,lane=$OUTSIDE_LANE,spellings=--effort")" \
  "rc=1 launched=nolog effortmissing=harness=claude,lane=$OUTSIDE_LANE,spellings=--effort" \
  "a lane launch naming no effort is refused for it"

# A space-spelled choice takes its value from the NEXT token: `--model sonnet`
# names a model, and the launch is judged against the window it named.
claude_usage 10 20 95 'Fable 5.1' > "$FIXTURE_DIR/.claude.json"
# The lane its own gate row left the home is removed again after that row, so
# this row builds it back: one scoped window for Opus and nothing else, which
# has binding-bucket room and measures nothing for sonnet.
make_lane "$H" uclaude 3600
jq -n '{limits: [{kind: "weekly_scoped", percent: 10, resets_at: "2099-08-01T06:00:00Z",
                  scope: {model: {display_name: "Opus"}}}]}' > "$FIXTURE_DIR/.uclaude.json"
run_ot "cmd=true --model sonnet --effort high" --harness claude --lane "$H/.uclaude" KEN-80
assert_eq "$(observe "rc=1 launched=nolog modelmissing=none unreadable=lane=$H/.uclaude,model=sonnet,step=windows")" \
  "rc=1 launched=nolog modelmissing=none unreadable=lane=$H/.uclaude,model=sonnet,step=windows" \
  "the space-spelled model is judged against that lane's own window, which measures nothing for it"
rm -rf -- "${H:?}/.uclaude" "${FIXTURE_DIR:?}/.uclaude.json"
claude_usage 10 20 5 Opus > "$FIXTURE_DIR/.claude.json"

echo "=== the pane is read back, and a disagreement closes the window ==="
# The check needs a readable per-process environment. Where the platform has
# none, lane_account_ok reports that by name and the launch stands, which these
# rows cannot tell apart from the pass they are pinning — so only they skip.
# The rows above still run there, which is the point of the split.
# The condition is the reader's own predicate, asked in a subshell because the
# lib's claims sibling sets errexit as it loads and this suite runs without it.
if ! ( source "$SCRIPTS_DIR/lib/lane-launch.sh" && lane_process_env_readable ); then
  printf '  skip  pane-check rows (no readable per-process environment)\n'
else
  assert_eq "$(lane_launch "$OPEN_TERMINAL" ok-launcher claude "$LNLANE" "$LNLANE" - "rc verified mismatch closed")" \
    "rc=0 verified=1 mismatch=0 closed=0" \
    "the pane confirms the account under the launcher form"
  assert_eq "$(lane_launch "$OPEN_TERMINAL" ok-prefix claude "$LNBARE" "$LNBARE" - "rc verified mismatch closed")" \
    "rc=0 verified=1 mismatch=0 closed=0" \
    "the pane confirms the account under the env-prefix form"
  assert_eq "$(lane_launch "$OPEN_TERMINAL" wrong claude "$LNBARE" "$LNLANE" - "rc verified mismatch closed")" \
    "rc=1 verified=0 mismatch=1 closed=1" \
    "a pane observed running another account than the one picked is closed and the item fails"
  assert_eq "$(lane_launch "$OPEN_TERMINAL" late claude "$LNBARE" "$LNLANE" late "rc verified mismatch closed")" \
    "rc=1 verified=0 mismatch=1 closed=1" \
    "a wrapper that rewrites the account after the first read is still caught: an observation counts only once it settles"

  # A wrapper that holds the picked account while it comes up and hands over
  # only as the harness starts. Read the instant after the keystrokes, this
  # settles on the wrapper and the item is announced on an account the pane is
  # about to stop running.
  #
  # Three launch shapes, because the premise the read rests on must not be a
  # side effect of any one of them: a claude launch that carries a brief, a
  # codex launch that carries none, and a claude relaunch that resumes a
  # session and so carries none either. The last two reach the read with no
  # brief to verify, which is where they were being read too early.
  assert_eq "$(lane_launch "$OPEN_TERMINAL" gated claude "$LNBARE" "$LNLANE" gated "rc verified mismatch closed")" \
    "rc=1 verified=0 mismatch=1 closed=1" \
    "a wrapper that hands the account over as the harness starts is caught on a claude launch"
  assert_eq "$(lane_launch "$OPEN_TERMINAL" gated-codex codex "$LNCODEXSELF" "$LNLANE" gated "rc verified mismatch closed")" \
    "rc=1 verified=0 mismatch=1 closed=1" \
    "the same handover is caught on a codex launch, which carries no brief to verify"
  # The transcript a relaunch resumes. Staged here and removed after, so no
  # other row's launch finds a session it never asked for.
  RESUME_ROOT="$H/.claude-shared/projects/lane-resume"
  RESUME_WT="$TMP_ROOT/claude-resume-wt"
  mkdir -p "$RESUME_ROOT" "$RESUME_WT"
  printf '%s\n' "{\"type\":\"user\",\"cwd\":\"$RESUME_WT\",\"isSidechain\":false,\"message\":{\"content\":\"Continue.\"}}" > "$RESUME_ROOT/session.jsonl"
  # `resumed` is what makes this row the relaunch it claims to be: without it a
  # transcript that stopped matching would render a fresh claude carrying a
  # brief, which is the row above, and this assertion would not notice.
  assert_eq "$(lane_launch "$OPEN_TERMINAL" gated-resume claude "$LNBARE" "$LNLANE" gated "rc verified mismatch closed resumed" flags=--relaunch "wt=$RESUME_WT")" \
    "rc=1 verified=0 mismatch=1 closed=1 resumed=1" \
    "and on a claude relaunch that resumes a session, which carries none either"
  rm -rf -- "${RESUME_ROOT:?}"

  # The premise knows BOTH harnesses. A resumed codex pane draws its own
  # marker and no Claude one: the wait must answer on the first look, and the
  # read that follows is a premised one that reports the account it confirms.
  assert_eq "$(lane_launch "$OPEN_TERMINAL" codex-screen codex "$LNCODEXSELF" "$LNCODEXSELF" - "rc verified premise unpremised probes" "text=› ")" \
    "rc=0 verified=1 premise=0 unpremised=0 probes=1" \
    "a codex pane drawing only its own marker meets the premise on the first look"

  # A screen the predicate does not know: the wait cannot refuse it, so it
  # stalls for the whole bound — ORCH_TMUX_VERIFY_SECS=5 above, one look per
  # second plus the look that finds the budget spent. The read still happens,
  # and both the launch and the read say it was taken without the premise.
  # The tree carries one account throughout, so the row reads time through the
  # virtual clock: the bound is spent there, and its control reads how far the
  # clock moved against the wall time the launch took.
  no_screen_real="$(date +%s)"
  assert_eq "$(lane_launch "$OPEN_TERMINAL" no-screen codex "$LNCODEXSELF" "$LNCODEXSELF" - "rc verified premise unpremised probes" "text=dev@lane:~$" clock=virtual)" \
    "rc=0 verified=0 premise=1 unpremised=1 probes=6" \
    "a screen the premise does not know stalls for the whole bound, and the read that follows is reported unpremised"
  no_screen_real=$(( $(date +%s) - no_screen_real ))
  assert_eq "$(( $(cat "$LAUNCH_CLOCK") - $(cat "$LAUNCH_CLOCK.seed") >= 5 )) $(( no_screen_real < 5 ))" "1 1" \
    "control: the five-second premise bound is reached on the virtual clock with less than that in wall time"
  assert_eq "$(lane_launch "$OPEN_TERMINAL" no-screen-waived codex "$LNCODEXSELF" "$LNCODEXSELF" - "rc" "text=dev@lane:~$" clock=waived)" \
    "rc=124" "control: with the clock waived the same bound is real and outlasts a two-second ceiling"

  # A codex launch runs under the home it built for its worktree, so what the
  # pane carries is that home and not the account directory. The check's
  # question is which ACCOUNT the pane is spending, and a home built under one
  # is that account; a pane on some other account still disagrees, which the
  # `wrong` row above pins. The worktree is pinned because the leaf here is
  # derived from it, and the home path comes from the builder itself rather
  # than a second spelling of its shape.
  CODEXTRUSTWT="$TMP_ROOT/codex-trust-wt"
  CODEXTRUSTHOME="$( source "$SCRIPTS_DIR/lib/lane-launch.sh" && lane_codex_home_path "$LNCODEXSELF" "$CODEXTRUSTWT" )"
  assert_eq "$(lane_launch "$OPEN_TERMINAL" codex-trust codex "$LNCODEXSELF" "$CODEXTRUSTHOME" - "rc verified mismatch closed" "wt=$CODEXTRUSTWT")" \
    "rc=0 verified=1 mismatch=0 closed=0" \
    "a pane carrying the home this launch built confirms the account it was built under"

  # A launch whose verification FAILS leaves this pane open with its claim
  # live, so the account it is really running on still has to be the picked
  # one. The pane draws neither the brief nor a ready composer, which is the
  # screen a stuck launch shows.
  # The premise is unmet here too, and a disagreement still refuses on it: the
  # guard fails closed on what it observed, whatever drew the screen.
  assert_eq "$(lane_launch "$OPEN_TERMINAL" stuck claude "$LNBARE" "$LNLANE" - "rc verified mismatch closed premise" "text=dev@lane:~$")" \
    "rc=1 verified=0 mismatch=1 closed=1 premise=1" \
    "a pane whose launch never verified is still read back, and a disagreement closes it"
fi

echo "=== with no threshold flag the launcher forwards none and lanes decides ==="
# The bound lives in `lanes` alone. A launch passing no --lane-max-pct is judged
# on exactly the number the oversee directive's own `lanes pick` used; a second
# default here is what handed the overseer an account this gate then refused,
# so the item never launched and the same lane was picked again next cycle.
#
# The rows run against a copy of the scripts placed outside every checkout, and
# that is what isolates them: open-terminal takes its project root from `git -C`
# on its OWN directory, not from the working directory, so the shipped script
# loads this repository's kendex.settings.toml and exports its threshold to the
# `lanes` it spawns. The copy loads no settings file, run_ot's pin is dropped,
# and the suite unsets the variable, so the number that decides is the one
# `lanes` holds. The whole scripts directory is copied because open-terminal
# resolves its libraries and `lanes` beside itself, and the github libs are laid
# beside the copy because an orch lib reaches them by a fixed relative path.
new_home lanes-default
make_lane "$H" claude 3600
make_lane "$H" eclaude 3600
claude_usage 10 92 5 Opus > "$FIXTURE_DIR/.claude.json"
claude_usage 10 97 5 Opus > "$FIXTURE_DIR/.eclaude.json"
OUTSIDE_ROOT="$TMP_ROOT/outside-checkout/orch"; OUTSIDE_SCRIPTS="$OUTSIDE_ROOT/scripts"
mkdir -p "$OUTSIDE_SCRIPTS"
cp -R "$SCRIPTS_DIR/." "$OUTSIDE_SCRIPTS/" || { printf 'outside copy failed\n' >&2; exit 1; }
orch_fixture_shared_libs "$OUTSIDE_ROOT"
OT_REAL="$OPEN_TERMINAL"; OPEN_TERMINAL="$OUTSIDE_SCRIPTS/open-terminal"
table \
  "a named lane at 92 percent used launches, the launcher forwarding no threshold of its own|max_pct=unset;cwd=$NOSETTINGS;$CHOICE_CMD|--harness claude --lane $H/.claude KEN-75|rc=0 launched=1 cmd_lane=claude walled=none" \
  "--lane auto is judged on the same bound, passing over the account above it|max_pct=unset;cwd=$NOSETTINGS;$CHOICE_CMD|--harness claude --lane auto KEN-76|rc=0 launched=1 cmd_lane=claude"
OPEN_TERMINAL="$OT_REAL"

lane_suite_end
