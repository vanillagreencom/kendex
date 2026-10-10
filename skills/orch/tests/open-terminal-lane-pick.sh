#!/usr/bin/env bash
# Tests for open-terminal's --lane wiring: how a lane is resolved (auto, an
# alias, a directory), judged on the model it passes, applied to the launched
# command, and claimed in the in-flight store so the next pick of a batch
# charges its projected room; the claim store a launch writes, the repository
# it names, and the marker binding an item to the tree it made. The `lanes`
# helper itself is lanes.sh; the two share lib/lanes-fixture.sh.
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
TMP_ROOT="$(mktemp -d)" || { echo "open-terminal-lane-pick: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "open-terminal-lane-pick: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "open-terminal-lane-pick: scratch=resolve-failed" >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
# shellcheck source=lib/open-terminal-lane-world.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/open-terminal-lane-world.sh"

echo "=== a lane is resolved before anything launches ==="
# --help needs no git repository: a PROJECT_ROOT substitution under `set -e`
# before argument parsing would die with git's 128 and no output. A refusal
# from `lanes` stops the launch before a worktree exists: discovering "every
# account is full" after spawning worktrees has already done the expensive
# half. An explicit --lane that is not a directory is a typo, not a config
# dir; one carrying the claim record's field separator can never be counted.
# A named lane ORCH_LANE_EXCLUDE or ORCH_LANE_RETIRE covers is refused, by
# alias or by path alike, and an excluded lane's alias before a same-named cwd
# directory can stand in for it. A lanes check that fails for another reason
# (a malformed setting) is reported as that failure, never as a covered lane.
table \
  "--help exits 0 outside a git repository|cwd=$NOREPO|--help|rc=0 stdout=line" \
  "no lane under the threshold: nothing launched, no worktree created|$CHOICE_CMD|--harness claude --lane auto --lane-max-pct 15 KEN-1|rc=1 launched=nolog creates=nolog" \
  "an explicit --lane that is not a directory is refused|$CHOICE|--harness claude --lane /nonexistent/lane KEN-1|rc=1 launched=nolog" \
  "an unknown --lane alias is refused|ORCH_LANE_ALIASES=eclaude=work;$CHOICE_CMD|--harness claude --lane nosuchlane KEN-1|rc=1 launched=nolog" \
  "a shared alias launches its first account when a later account is excluded|ORCH_LANE_ALIASES=claude=work,eclaude=work;ORCH_LANE_EXCLUDE=eclaude;$CHOICE_CMD|--harness claude --lane work KEN-1|rc=0 launched=1 cmd_lane=claude refused=none" \
  "a shared alias launches its first account when a later account is retired|ORCH_LANE_ALIASES=claude=work,eclaude=work;ORCH_LANE_RETIRE=eclaude=2000-01-01;$CHOICE_CMD|--harness claude --lane work KEN-1|rc=0 launched=1 cmd_lane=claude refused=none" \
  "a shared alias skips an excluded first account|ORCH_LANE_ALIASES=claude=work,eclaude=work;ORCH_LANE_EXCLUDE=claude;$CHOICE_CMD|--harness claude --lane work KEN-1|rc=0 launched=1 cmd_lane=eclaude refused=none" \
  "a retired lane named by its alias is refused before anything launches|ORCH_LANE_ALIASES=eclaude=work;ORCH_LANE_RETIRE=eclaude=2000-01-01;$CHOICE_CMD|--harness claude --lane work KEN-1|rc=1 launched=nolog refused=lane=work" \
  "an excluded lane named by its config dir is refused before anything launches|ORCH_LANE_EXCLUDE=eclaude;$CHOICE_CMD|--harness claude --lane $H/.eclaude KEN-1|rc=1 launched=nolog refused=lane=$H/.eclaude" \
  "an excluded lane's alias is refused even beside a same-named cwd directory|ORCH_LANE_ALIASES=eclaude=work;ORCH_LANE_EXCLUDE=eclaude;cwd=$COLLIDE;$CHOICE_CMD|--harness claude --lane work KEN-1|rc=1 launched=nolog refused=lane=work" \
  "an excluded lane's alias with no same-named directory is refused, not unknown|ORCH_LANE_ALIASES=eclaude=work;ORCH_LANE_EXCLUDE=eclaude;cwd=$BARE;$CHOICE_CMD|--harness claude --lane work KEN-1|rc=1 launched=nolog refused=lane=work" \
  "a named lane whose check fails on a malformed setting is a resolution failure, not a refusal|ORCH_LANES_USAGE_TTL=soon;$CHOICE_CMD|--harness claude --lane $H/.eclaude KEN-1|rc=1 launched=nolog refused=none failed=exit=1" \
  "an ALIAS-spelled lane whose lookup fails on the same setting is that failure too, never an unknown alias|ORCH_LANE_ALIASES=eclaude=work;ORCH_LANES_USAGE_TTL=soon;$CHOICE_CMD|--harness claude --lane work KEN-1|rc=1 launched=nolog refused=none failed=exit=1"

# The launcher still judges the resolved account with pick. Resolving its
# alias must not measure every account through list first.
alias_cli="$TMP_ROOT/alias-lanes"
cat > "$alias_cli" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$ALIAS_LANES_LOG"
exec "$ALIAS_LANES_SCRIPT" "$@"
STUB
chmod +x "$alias_cli"
alias_env="ORCH_LANE_ALIASES=eclaude=work;LANES_CLI=$alias_cli;ALIAS_LANES_LOG=$TMP_ROOT/alias-lanes.log;ALIAS_LANES_SCRIPT=$SCRIPTS_DIR/lanes;$CHOICE_CMD"
run_ot "$alias_env" --harness claude --lane work KEN-1
assert_eq "$(observe 'rc=0 launched=1 cmd_lane=eclaude')|$(grep -c '^list ' "$TMP_ROOT/alias-lanes.log" || true)" \
  'rc=0 launched=1 cmd_lane=eclaude|0' 'alias resolution launches the same account without list'

alias_scripts="$(mutant_scripts alias-list/orch open-terminal)" || exit 1
orch_fixture_shared_libs "$TMP_ROOT/alias-list/orch"
mutate_file "$alias_scripts/open-terminal" \
  'lane_dir="$("$LANES_CLI" check "$LANE")"' \
  'lane_dir="$("$LANES_CLI" list --local --json | jq -r --arg a "$LANE" '\''map(select(.alias == $a)) | first | .config_dir // empty'\'')"'
OPEN_TERMINAL="$alias_scripts/open-terminal"
: > "$TMP_ROOT/alias-lanes.log"
run_ot "$alias_env" --harness claude --lane work KEN-1
control_rc=0
( FAIL=0; assert_eq "$(grep -c '^list ' "$TMP_ROOT/alias-lanes.log" || true)" 0 'no alias list'; [[ "$FAIL" == 0 ]] ) \
  > "$TMP_ROOT/alias-list-control.log" || control_rc=$?
assert_eq "$RC:$control_rc:$(grep -cx 'list --local --json' "$TMP_ROOT/alias-lanes.log" || true)" '0:1:1' \
  "the alias assertion rejects the base behavior's list call"
OPEN_TERMINAL="$SCRIPTS_DIR/open-terminal"

# The same resolution owner handles check's direct callers and the launcher.
shared_scripts="$(mutant_scripts shared-alias lanes)" || exit 1
mutate_file "$shared_scripts/lanes" 'check_names="${check_dir:-$LANE_ARG}"' 'check_names="$LANE_ARG"'
mutate_file "$shared_scripts/lanes" '[[ -z "$check_dir" && "$LANE_ARG" != */* ]]' '[[ "$LANE_ARG" != */* ]]'
for sibling_policy in 'ORCH_LANE_EXCLUDE=eclaude' 'ORCH_LANE_RETIRE=eclaude=2000-01-01'; do
  run_ot "ORCH_LANE_ALIASES=claude=work,eclaude=work;$sibling_policy;LANES_CLI=$shared_scripts/lanes;$CHOICE_CMD" \
    --harness claude --lane work KEN-1
  control_rc=0
  ( FAIL=0; assert_eq "$(observe 'rc=0 launched=1 cmd_lane=claude')" 'rc=0 launched=1 cmd_lane=claude' 'shared alias launch'; [[ "$FAIL" == 0 ]] ) \
    > "$TMP_ROOT/shared-alias-control.log" || control_rc=$?
  assert_eq "$RC:$control_rc" '1:1' "the shared alias launch assertion rejects broad refusal under $sibling_policy"
done

# The separator-bearing path cannot ride through a table row's word split.
run_ot "$CHOICE_CMD" --harness claude --lane "$TABBED" KEN-21
assert_eq "$(observe "rc=1 launched=nolog")" "rc=1 launched=nolog" "a tab-bearing lane config dir is refused"

echo "=== a lane launch names a model and an effort, or nothing launches ==="
# A harness default is whatever that harness happens to ship this week, and the
# account the launch opens on is spent either way, so a lane, a model and an
# effort are one purposeful choice: a launch making only part of it is refused
# before any lane is judged, and is never judged on the account's binding bucket
# instead. One keyed refusal per missing half, so the key says which. Every
# harness the flag table names, a relaunch as much as a fresh launch.
#
# The spellings each row pins are the table's own, which is why a harness whose
# CLI spells the pair differently is one row there: codex takes `-m` and a
# `model_reasoning_effort=` config token, pi `--model` and `--thinking`, and
# opencode's launch form has no effort flag at all, so it asks the model alone.
table \
  "a launch naming a model and no effort is refused, naming the flag that harness takes|cmd=true --model opus|--harness claude --lane $H/.claude KEN-81|rc=1 launched=nolog creates=nolog modelmissing=none effortmissing=harness=claude,lane=$H/.claude,spellings=--effort" \
  "a launch naming neither is refused for both, one keyed line each||--harness claude --lane $H/.claude --cmd true KEN-82|rc=1 launched=nolog creates=nolog modelmissing=harness=claude,lane=$H/.claude,spellings=--model effortmissing=harness=claude,lane=$H/.claude,spellings=--effort" \
  "a pi launch naming neither is refused the same way, on pi's own spellings||--harness pi --lane $H/.claude --cmd true KEN-83|rc=1 launched=nolog creates=nolog modelmissing=harness=pi,lane=$H/.claude,spellings=--model effortmissing=harness=pi,lane=$H/.claude,spellings=--thinking" \
  "a codex launch naming neither is refused on codex's config-token spelling of the effort||--harness codex --lane $H/.claude --cmd true KEN-84|rc=1 launched=nolog creates=nolog modelmissing=harness=codex,lane=$H/.claude,spellings=-m,--model effortmissing=harness=codex,lane=$H/.claude,spellings=model_reasoning_effort=" \
  "a copilot launch naming neither is refused on copilot's own spellings||--harness copilot --lane $H/.claude --cmd true KEN-184|rc=1 launched=nolog creates=nolog modelmissing=harness=copilot,lane=$H/.claude,spellings=--model effortmissing=harness=copilot,lane=$H/.claude,spellings=--reasoning-effort" \
  "a relaunch naming neither is refused too, the choice being the launch's and not the session's||--harness claude --relaunch --lane $H/.claude --cmd true KEN-85|rc=1 launched=nolog modelmissing=harness=claude,lane=$H/.claude,spellings=--model" \
  "a launch naming both launches, which is what the usage gate below then judges|$CHOICE_CMD|--harness claude --lane $H/.claude KEN-86|rc=0 launched=1 modelmissing=none effortmissing=none" \
  "opencode has no effort flag to name, so its launch asks the model alone|cmd=true --model anthropic/claude-opus-5|--harness opencode --lane $H/.claude KEN-87|rc=0 launched=1 modelmissing=none effortmissing=none"

# The --cmd template carries the same two words for the same reason: a launch
# writing its own harness argv still made the choice, and a template a row
# cannot spell inside a word-split args field is passed through run_ot's argv.
run_ot "" --harness claude --lane "$H/.claude" --cmd "claude --model opus --effort high $QUESTION_OFF_ALL" KEN-88
assert_eq "$(observe "rc=0 launched=1 modelmissing=none effortmissing=none")" \
  "rc=0 launched=1 modelmissing=none effortmissing=none" \
  "a model and an effort named only in the --cmd template are named"
run_ot "" --harness claude --lane "$H/.claude" --cmd "claude --model opus $QUESTION_OFF_ALL" KEN-89
assert_eq "$(observe "rc=1 launched=nolog effortmissing=harness=claude,lane=$H/.claude,spellings=--effort")" \
  "rc=1 launched=nolog effortmissing=harness=claude,lane=$H/.claude,spellings=--effort" \
  "a --cmd template naming a model and no effort is refused for the effort"

# THE LANE SPEC NAMES THE HARNESS TOO. `--lane auto:<h>` resolves a real <h>
# account through `lanes pick --harness <h>`, so a launch that passed no
# --harness has still named the harness whose row judges its choice words, and
# that row judges it. Keyed on --harness alone the gate skipped exactly this
# shape: the launch was accepted with no model named and the lane started on
# whatever default the harness ships.
#
# Only a launch naming a harness NOWHERE stays exempt — a named config dir or
# alias with no --harness — because nothing in that argv says which harness
# reads the words in the caller's own command.
table \
  "a launch naming its harness only in the lane spec is judged by that harness's row|cmd=true|--lane auto:claude KEN-114|rc=1 launched=nolog creates=nolog modelmissing=harness=claude,lane=auto:claude,spellings=--model effortmissing=harness=claude,lane=auto:claude,spellings=--effort" \
  "the same launch naming both words inside its command launches|$CHOICE_CMD|--lane auto:claude KEN-115|rc=0 launched=1 modelmissing=none effortmissing=none" \
  "a named lane with no --harness names no harness anywhere, and is the one shape left exempt|cmd=true|--lane $H/.claude KEN-116|rc=0 launched=1 modelmissing=none effortmissing=none"

# --launch-flags beside a --cmd template reach NOTHING: start_cmd renders the
# template verbatim and appends no flag to it. Left ungated, the choice words
# there would be read, judged and recorded while the harness ran its own
# default. The refusal is the launch's, not the lane's, so it lands on a launch
# with no --lane too, and the model or effort the flags name is never read.
run_ot "flags=--model opus --effort high" --harness claude --lane "$H/.claude" --cmd true KEN-99
assert_eq "$(observe "rc=1 launched=nolog creates=nolog flagsunreachable=option=--launch-flags,flags=--model,opus,--effort,high modelmissing=none effortmissing=none")" \
  "rc=1 launched=nolog creates=nolog flagsunreachable=option=--launch-flags,flags=--model,opus,--effort,high modelmissing=none effortmissing=none" \
  "launch flags beside a --cmd template refuse the launch, naming the flags that reach nothing"
run_ot "flags=--model opus --effort high" --cmd true KEN-112
assert_eq "$(observe "rc=1 launched=nolog flagsunreachable=option=--launch-flags,flags=--model,opus,--effort,high")" \
  "rc=1 launched=nolog flagsunreachable=option=--launch-flags,flags=--model,opus,--effort,high" \
  "a wholly custom launch with no harness and no lane is refused for the same unreachable flags"

# A fleet lane is a --lane --cmd launch, so its command carries the harness's
# question-tool words itself, and one that leaves them out is refused before
# its worktree, its window or its claim. Called without run_ot's cmd= item,
# which appends the words every other row here needs.
run_ot "" --harness claude --lane "$H/.claude" --cmd "true --model opus --effort high" KEN-140
assert_eq "$(observe "rc=1 launched=nolog creates=nolog claims=nolog questionmissing=harness=claude,word=--disallowedTools=AskUserQuestion,EnterPlanMode")" \
  "rc=1 launched=nolog creates=nolog claims=nolog questionmissing=harness=claude,word=--disallowedTools=AskUserQuestion,EnterPlanMode" \
  "a --lane --cmd launch without the question-tool words is refused before anything launches or is claimed"

# pi spells the thinking level on the model value too, `--model sonnet:high`,
# which its own --help documents. A launch passing that has made both choices, so
# asking it for a --thinking it already named would refuse a launch that named
# everything. The table row's fourth field carries the separator, `-` for the
# harness that has none, so this is one row rule and not a branch per harness:
# the claude rows above pass `opus` with no level and are still asked for
# --effort. A separator with nothing after it names no level.
#
# The last row is the inverse: an arbitrary value carrying the same character on
# a harness whose row names no separator is a model value and nothing more.
table \
  "pi's level on the model value names the effort, so the launch is not asked for it again|cmd=true --model pi-claude/sonnet:high|--harness pi --lane $H/.claude KEN-95|rc=0 launched=1 modelmissing=none effortmissing=none" \
  "a separator with no level after it names no effort, so that launch is still refused|cmd=true --model sonnet:|--harness pi --lane $H/.claude KEN-97|rc=1 launched=nolog modelmissing=none effortmissing=harness=pi,lane=$H/.claude,spellings=--thinking" \
  "a claude launch whose model value carries a colon is still asked for its effort, its row naming no separator|cmd=true --model opus:1m|--harness claude --lane $H/.claude KEN-98|rc=1 launched=nolog modelmissing=none effortmissing=harness=claude,lane=$H/.claude,spellings=--effort"
# The same value inside a --cmd template, which a word-split args field cannot
# spell.
run_ot "" --harness pi --lane "$H/.claude" --cmd "pi --model pi-claude/sonnet:high $QUESTION_OFF_ALL" KEN-96
assert_eq "$(observe "rc=0 launched=1 modelmissing=none effortmissing=none")" \
  "rc=0 launched=1 modelmissing=none effortmissing=none" \
  "pi's level named on the model value inside the --cmd template names the effort too"

echo "=== a named Copilot CLI lane uses its pool reading ==="
mkdir -p "$H/.namedcopilot/session-state"
CP_CMD='cmd=true --model claude-opus-5.5 --reasoning-effort high'
table \
  "a measured Copilot pool launches without a model window|ORCH_LANE_COPILOT_POOL=$H/.namedcopilot=10/100;$CP_CMD|--harness copilot --lane $H/.namedcopilot CC-1690|rc=0 launched=1 copilot_home=namedcopilot unreadable=none" \
  "an unread Copilot pool names status and login cause after the existing fields|$CP_CMD|--harness copilot --lane $H/.namedcopilot CC-1691|rc=1 launched=nolog creates=nolog unreadable=lane=$H/.namedcopilot,model=claude-opus-5.5,step=windows unread_status=status=no_credentials unread_reason=config-missing"
CTRL_CP="$(mutant_scripts ctl-copilot-unread open-terminal)" || exit 1
# shellcheck disable=SC2016
mutate_file "$CTRL_CP/open-terminal" '"status=${lane_status:-none}" "detail=${lane_detail:-none}"' '"status=none" "detail=none"'
LIVE_OT="$OPEN_TERMINAL"
OPEN_TERMINAL="$CTRL_CP/open-terminal" run_ot "$CP_CMD" --harness copilot --lane "$H/.namedcopilot" CC-1691
assert_eq "$(observe 'rc=1 unread_status=none unread_reason=none')" 'rc=1 unread_status=none unread_reason=none' \
  "control: omitting the record fields loses the unread Copilot account's cause"
OPEN_TERMINAL="$LIVE_OT"
rm -rf -- "${H:?}/.namedcopilot"

echo "=== a Pi launch on a Copilot model qualifies on the stated Copilot pool ==="
# Such a launch spends Copilot credits and no Claude window, so a bound that
# walls every Claude seat here (claude 20, eclaude 80, nclaude 95 against 15)
# leaves it launching on a pool ORCH_LANE_COPILOT_POOL states with room, under
# Pi's own root variable naming that account, and a pool nothing states or
# every stated pool spent refuses it by a cause naming the setting, auto and
# named alike. A named Pi lane on the pool is judged by the same `lanes pick
# --lane` a claude lane is, its model read with the provider Pi's own flag
# names; a Pi lane on a provider nothing measures is refused as unmeasured.
mkdir -p "$H/.pi1"
PI_POOL="ORCH_LANE_COPILOT_POOL=$H/.pi1"
PI_COPILOT='cmd=true --model github-copilot/claude-sonnet-5:high'
PI_PROVIDER='cmd=true --provider github-copilot --model claude-sonnet-5 --thinking high'
table \
  "auto launches on the stated pool under Pi's root variable while every Claude seat is walled|$PI_POOL=100000/1000000;$PI_COPILOT|--harness pi --lane auto --lane-max-pct 15 KEN-1660|rc=0 launched=1 pi_root=pi1 cmd_lane=none claim_lanes=pi1" \
  "auto with no stated pool refuses by the setting, before anything launches, naming the repair once|$PI_COPILOT|--harness pi --lane auto KEN-1661|rc=1 launched=nolog creates=nolog pickrefusal=copilot-pool-unstated,setting=ORCH_LANE_COPILOT_POOL poolfix=local:any_Pi_root" \
  "auto with every stated pool spent refuses as the owner's reading, not a reset to wait for|$PI_POOL=1000000/1000000;$PI_COPILOT|--harness pi --lane auto KEN-1666|rc=1 launched=nolog creates=nolog pickrefusal=copilot-pool-walled,setting=ORCH_LANE_COPILOT_POOL" \
  "a named account the pool reading does not cover is refused as unmeasured, naming the repair|$PI_POOL=100000/1000000;$PI_COPILOT|--harness pi --lane $H/.eclaude KEN-1662|rc=1 launched=nolog unreadable=lane=$H/.eclaude,model=github-copilot/claude-sonnet-5:high,step=windows poolfix=local:$H/.eclaude" \
  "a named account whose pool is spent is refused on the monthly bucket|$PI_POOL=1000000/1000000;$PI_COPILOT|--harness pi --lane $H/.pi1 KEN-1663|rc=1 launched=nolog walled=lane=$H/.pi1,model=github-copilot/claude-sonnet-5:high,pct=100,bucket=monthly,projected-headroom=0" \
  "a named account whose pool has room launches under Pi's root variable while every Claude seat is walled|$PI_POOL=100000/1000000;$PI_COPILOT|--harness pi --lane $H/.pi1 --lane-max-pct 15 KEN-1664|rc=0 launched=1 pi_root=pi1 cmd_lane=none walled=none unreadable=none poolfix=none" \
  "the provider on Pi's own flag is the Copilot pool too, judged on the named account|$PI_POOL=100000/1000000;$PI_PROVIDER|--harness pi --lane $H/.eclaude KEN-1667|rc=1 launched=nolog unreadable=lane=$H/.eclaude,model=github-copilot/claude-sonnet-5,step=windows" \
  "a named Pi lane on a model naming no provider is refused by that cause, never launched|cmd=true --model sonnet:high|--harness pi --lane $H/.eclaude KEN-1668|rc=1 launched=nolog unreadable=none pickrefusal=lane-provider-unmeasured,harness=pi,model=sonnet:high"
# Controls, one per rule: the named gate back on claude and codex alone
# launches the unmeasured account unjudged; the prefix back on the Claude
# variable for the pool starts Pi on a root nobody picked; and the provider
# flag unread judges its Copilot model as one naming no provider.
pi_control ctl-pi-gate open-terminal '"$LANE_AUTO" == true || -z "$(lane_pick_harness "$LAUNCH_HARNESS" "$LAUNCH_MODEL")"' \
  '"$LANE_AUTO" == true || ! "$LAUNCH_HARNESS" =~ ^(claude|codex)$' "$PI_POOL=100000/1000000;$PI_COPILOT" --harness pi --lane "$H/.eclaude" KEN-1662
assert_eq "$(observe "rc=0 launched=1 unreadable=none")" "rc=0 launched=1 unreadable=none" \
  "control: a named-lane gate for claude and codex alone launches a Pi lane on an unmeasured Copilot pool"
pi_control ctl-pi-root lib/lane-launch.sh '[[ "$(lane_pick_harness "$1" "${3:-}")" != pi ]] || var=PI_CODING_AGENT_DIR' ':' \
  "$PI_POOL=100000/1000000;$PI_COPILOT" --harness pi --lane "$H/.pi1" KEN-1664
assert_eq "$(observe "rc=0 pi_root=none cmd_lane=pi1")" "rc=0 pi_root=none cmd_lane=pi1" \
  "control: the Claude variable for a Pi lane on the pool leaves Pi on a root nobody picked"
pi_control ctl-pi-provider lib/lane-launch.sh '[[ -z "$provider" ]] || model="$provider/$model"' ':' \
  "$PI_POOL=100000/1000000;$PI_PROVIDER" --harness pi --lane "$H/.eclaude" KEN-1667
assert_eq "$(observe "rc=1 pickrefusal=lane-provider-unmeasured,harness=pi,model=claude-sonnet-5")" \
  "rc=1 pickrefusal=lane-provider-unmeasured,harness=pi,model=claude-sonnet-5" \
  "control: the provider flag unread judges a Pi lane on the Copilot pool as a model naming no provider"

# A fleet batch on the pool re-picks each item after the first, and the Pi root
# that re-pick names is the one the fleet gate reads: here pi1 (10) takes the
# first item. Both pools have 90 room and no known reset, so each scores 90.
# A claim costs 5 * 5 / 720 monthly points: pi1 then scores less than pi2.
# The second item moves onto pi2, whose own settings turn
# compaction on, so the second is refused naming that file. Its control drops
# the re-pick's root and gate, and the second item launches unchecked.
pi_fleet_root() { # DIR COMPACTION
  mkdir -p "$1/packages/@vanillagreen/pi-hooks/extensions"
  printf 'export const f = { context_window: 1 };\n' > "$1/packages/@vanillagreen/pi-hooks/extensions/vocab.ts"
  printf '%s\n' '{"pi":{"extensions":["./extensions/hooks.ts","./extensions/lane-mail-wake.ts"]}}' > "$1/packages/@vanillagreen/pi-hooks/package.json"
  printf '{"compaction":{"enabled":%s}}\n' "$2" > "$1/settings.json"
}
pi_fleet_root "$H/.pi1" false
pi_fleet_root "$H/.pi2" true
# Each batch's fleet state records the suite's own checkout, the one every
# launch runs from, as its overseer's directory.
PI_BATCH="ORCH_LANE_COPILOT_POOL=$H/.pi1=100000/1000000,$H/.pi2=100000/1000000;ORCH_LANE_BURN_PCT_PER_HOUR=5;STUB_CLOCK=$TMP_ROOT/pick-clock;$PI_COPILOT"
ot_fleet_state "$SCRIPTS_DIR/workflow-state" "$TMP_ROOT/pi-fleet-1" "$PWD" || exit 1
run_ot "$PI_BATCH" --harness pi --lane auto --state-dir "$TMP_ROOT/pi-fleet-1" KEN-1670 KEN-1671
assert_eq "$(observe "launched=1 pi_root=pi1 compactionon=file=$H/.pi2/settings.json")" \
  "launched=1 pi_root=pi1 compactionon=file=$H/.pi2/settings.json" \
  "a fleet batch's re-pick onto a second pool account is gated on that account's own settings"
ot_fleet_state "$SCRIPTS_DIR/workflow-state" "$TMP_ROOT/pi-fleet-2" "$PWD" || exit 1
pi_control ctl-pi-repick open-terminal 'ot_message lane-selected "lane=$LANE_ENV"; pi_lane_root_apply && copilot_fleet_gate || return 1; }' \
  'ot_message lane-selected "lane=$LANE_ENV"; copilot_fleet_gate || return 1; }' "$PI_BATCH" --harness pi --lane auto --state-dir "$TMP_ROOT/pi-fleet-2" KEN-1670 KEN-1671
assert_eq "$(observe "launched=2 pi_root=pi1,pi2 compactionon=none")" "launched=2 pi_root=pi1,pi2 compactionon=none" \
  "control: a re-pick that keeps the first root launches the second item on an account nobody gated"
rm -f -- "${H:?}/.pi1/settings.json" "${H:?}/.pi2/settings.json"

# The same re-pick on the Copilot pool is gated on the second account's own
# context reader: copilot1 (10) takes the first item, the extension reader
# installed in its home and the hooks in its global scope. Both pools have
# 90 room and unknown resets. A claim costs 5 * 5 / 720 monthly points,
# so the second item moves onto copilot2, whose settings turn extensions off and run no
# status line for the fallback reader, so the second is refused. Its control
# drops the re-pick's gate, and the second item launches with neither reader.
# Both homes hold the hooks in their global scope and the kendex stub answers
# the hooks gate that none is switched off, so the context reader is the one
# gate the two accounts differ on. The batch runs with HOME the fixture's, so
# the reader's pending directory the gate makes lands there.
mkdir -p "$H/.copilot1/hooks" "$H/.copilot2/hooks"
printf '{}\n' > "$H/.copilot1/config.json"
printf '{}\n' > "$H/.copilot2/config.json"
for hook in lane-mail-check lane-mail-compact lane-mail-start; do
  for home in "$H/.copilot1" "$H/.copilot2"; do
    printf '#!/bin/sh\n' > "$home/hooks/$hook.sh"
    printf '{"version":1,"hooks":{}}\n' > "$home/hooks/$hook.json"
  done
done
printf '{"enabledFeatureFlags":{"EXTENSIONS":false}}\n' > "$H/.copilot2/settings.json"
printf '#!/bin/sh\nprintf '"'"'{"switched_off_by":null}\\n'"'"'\n' > "$OT_STUB_BIN/kendex"
chmod +x "$OT_STUB_BIN/kendex"
CP_BATCH="HOME=$H;ORCH_LANE_COPILOT_POOL=$H/.copilot1=100000/1000000,$H/.copilot2=100000/1000000;ORCH_LANE_BURN_PCT_PER_HOUR=5;STUB_CLOCK=$TMP_ROOT/pick-clock;cmd=true --model claude-sonnet-5 --reasoning-effort high"
ot_fleet_state "$SCRIPTS_DIR/workflow-state" "$TMP_ROOT/cp-fleet-1" "$PWD" || exit 1
run_ot "$CP_BATCH" --harness copilot --lane auto --state-dir "$TMP_ROOT/cp-fleet-1" KEN-1680 KEN-1681
assert_eq "$(observe "launched=1 copilot_home=copilot1 statusline=file=$H/.copilot2/settings.json,detail=disabled,cause=no-status-line")" \
  "launched=1 copilot_home=copilot1 statusline=file=$H/.copilot2/settings.json,detail=disabled,cause=no-status-line" \
  "a Copilot batch's re-pick onto a second pool account is gated on that account's own context reader"
ot_fleet_state "$SCRIPTS_DIR/workflow-state" "$TMP_ROOT/cp-fleet-2" "$PWD" || exit 1
pi_control ctl-copilot-repick open-terminal 'pi_lane_root_apply && copilot_fleet_gate || return 1; }' \
  'pi_lane_root_apply || return 1; }' "$CP_BATCH" --harness copilot --lane auto --state-dir "$TMP_ROOT/cp-fleet-2" KEN-1680 KEN-1681
assert_eq "$(observe "launched=2 copilot_home=copilot1,copilot2 statusline=none")" "launched=2 copilot_home=copilot1,copilot2 statusline=none" \
  "control: a re-pick with no Copilot gate launches the second item on an account whose context reader nobody set up"
rm -rf -- "${H:?}/.copilot1" "${H:?}/.copilot2"
rm -f -- "${OT_STUB_BIN:?}/kendex"

echo "=== a Pi launch on a pi-claude model is judged on the Claude seat it spends ==="
# pi-claude-bridge runs Claude Code on the Claude seat CLAUDE_CONFIG_DIR names,
# so `auto` picks such a launch a seat with room as a claude launch on that
# model and refuses when every seat is walled, a named seat is judged on the
# window that model draws on, and an `auto` pick on a provider nothing
# measures is refused by its own cause before anything launches.
PI_CLAUDE='cmd=true --model pi-claude/claude-opus-5-5:high'
table \
  "auto launches a pi-claude model on the Claude seat with room, under the Claude variable|$PI_CLAUDE|--harness pi --lane auto KEN-1680|rc=0 launched=1 cmd_lane=claude pi_root=none claim_lanes=claude" \
  "auto refuses a pi-claude model when every Claude seat is walled|$PI_CLAUDE|--harness pi --lane auto --lane-max-pct 15 KEN-1681|rc=1 launched=nolog creates=nolog pickrefusal=lane-unavailable,harness=pi" \
  "a named walled Claude seat is refused for a pi-claude model|$PI_CLAUDE|--harness pi --lane $H/.nclaude KEN-1682|rc=1 launched=nolog walled=lane=$H/.nclaude,model=pi-claude/claude-opus-5-5:high,pct=95,bucket=weekly,projected-headroom=5" \
  "a named Claude seat with room launches a pi-claude model under the Claude variable|$PI_CLAUDE|--harness pi --lane $H/.claude KEN-1683|rc=0 launched=1 cmd_lane=claude pi_root=none walled=none" \
  "auto refuses a provider nothing measures by its own cause|cmd=true --model openai/gpt-6:high|--harness pi --lane auto KEN-1684|rc=1 launched=nolog creates=nolog pickrefusal=lane-provider-unmeasured,harness=pi,model=openai/gpt-6:high"
# The controls drop the unmeasured arm of the auto refusal, which then names
# lanes failing rather than the provider, and the named judge's, which then
# names a window nobody read.
pi_control ctl-pi-unmeasured open-terminal '5:unmeasured)' '5:unmeasured-dropped)' \
  "cmd=true --model openai/gpt-6:high" --harness pi --lane auto KEN-1684
assert_eq "$(observe "rc=1 pickrefusal=none failed=exit=5")" "rc=1 pickrefusal=none failed=exit=5" \
  "control: without its arm an auto pick on an unmeasured provider is reported as lanes failing"
pi_control ctl-pi-named-unmeasured open-terminal '"$LAUNCH_MODEL")" == unmeasured ]]; then' '"$LAUNCH_MODEL")" == unmeasured-dropped ]]; then' \
  "cmd=true --model sonnet:high" --harness pi --lane "$H/.eclaude" KEN-1668
assert_eq "$(observe "rc=1 pickrefusal=none unreadable=lane=$H/.eclaude,model=sonnet:high,step=windows")" \
  "rc=1 pickrefusal=none unreadable=lane=$H/.eclaude,model=sonnet:high,step=windows" \
  "control: without its arm a named Pi lane naming no provider is refused as an unread window"

echo "=== a launch is refused when the model it passes has no window left ==="
# An account with plan-wide weekly room can still have none left for ONE model.
# The binding bucket never shows it, so a --wake or --relaunch onto a named
# account opens its first turn on a usage banner instead of the session it
# resumed. The model comes from the text the launch RUNS: the --cmd command
# where there is one, --launch-flags where there is not, so the wall judged is
# always the wall of the model the harness will really be started on.
# The refusal sits in lane resolution, ahead of the branch that tells a wake
# from a relaunch from a plain launch, so every launch mode meets the same
# clause and the relaunch row below is the shaped input for all of them.
claude_usage 10 20 95 'Fable 5.1' > "$FIXTURE_DIR/.claude.json"
table \
  "a named lane whose window for this model is walled is refused before anything launches|cmd=true --model=fable --effort=high|--harness claude --lane $H/.claude KEN-60|rc=1 launched=nolog creates=nolog walled=lane=$H/.claude,model=fable,pct=95,bucket=model,projected-headroom=5" \
  "a relaunch onto that same lane is refused the same way|cmd=true --model=fable --effort=high|--harness claude --relaunch --lane $H/.claude KEN-61|rc=1 launched=nolog walled=lane=$H/.claude,model=fable,pct=95,bucket=model,projected-headroom=5" \
  "the same lane launches for a model whose own window has room|$CHOICE_CMD|--harness claude --lane $H/.claude KEN-62|rc=0 launched=1 walled=none" \
  "--lane auto takes the account with the most room for the model being passed|$CHOICE_CMD|--harness claude --lane auto KEN-64|rc=0 cmd_lane=claude walled=none" \
  "--lane auto moves off the account whose window for that model is walled|cmd=true --model=fable --effort=high|--harness claude --lane auto KEN-65|rc=0 cmd_lane=eclaude walled=none"

# The named lane is judged on the projection `lanes pick` drops a lane on: its
# 5-hour window at 60 with room, but the one lane already live on it charged
# 50 an hour, which projects 110. The second row is the inverse, the same lane
# with nothing live on it.
claude_usage 60 20 10 'Fable 5.1' > "$FIXTURE_DIR/.claude.json"
table \
  "a named lane with room whose live lanes project past the threshold is refused|cmd=true --model=fable --effort=high;prep=claude_claim;ORCH_LANE_BURN_PCT_PER_HOUR=50|--harness claude --lane $H/.claude KEN-1641|rc=1 launched=0 creates=nolog walled=lane=$H/.claude,model=fable,pct=60,bucket=session,projected-headroom=-10" \
  "the same lane with nothing live on it launches|cmd=true --model=fable --effort=high;ORCH_LANE_BURN_PCT_PER_HOUR=50|--harness claude --lane $H/.claude KEN-1642|rc=0 launched=1 walled=none"
# Fable's weekly window sits below the launch threshold until a live claim
# charges the burn scaled by 5/168. Opus spends only the shared windows, which
# still have room after the charge. `run_ot` seeds the same real claim as above.
claude_usage 10 20 94 'Fable 5.1' > "$FIXTURE_DIR/.claude.json"
NAMED_PREFERENCE='ORCH_LANE_PREFERENCE=claude:fable:high,claude:opus:high;cmd=claude;ORCH_LANE_BURN_PCT_PER_HOUR=50'
table \
  "a preference resolves a named alias before its pick|$NAMED_PREFERENCE;ORCH_LANE_ALIASES=claude=work;cwd=$COLLIDE|--harness claude --lane work KEN-1643|rc=0 launched=1 cmd_lane=claude cmd_model=fable" \
  "a preference skips the model its live claim projects past the wall|$NAMED_PREFERENCE;prep=claude_claim|--harness claude --lane $H/.claude KEN-1644|rc=0 launched=1 cmd_lane=claude cmd_model=opus" \
  "a preference checks an excluded alias before a same-named directory|$NAMED_PREFERENCE;ORCH_LANE_ALIASES=claude=work;ORCH_LANE_EXCLUDE=claude;cwd=$COLLIDE|--harness claude --lane work KEN-1645|rc=1 launched=nolog refused=lane=work"
pi_control ctl-preference-projected open-terminal 'preference_pick_args=(--lane "$lane_dir" --projected)' 'preference_pick_args=(--lane "$lane_dir")' \
  "$NAMED_PREFERENCE;prep=claude_claim" --harness claude --lane "$H/.claude" KEN-1644
assert_eq "$(observe "rc=0 launched=1 cmd_model=fable")" "rc=0 launched=1 cmd_model=fable" \
  "control: without projected use the preference launches the walled first model"
claude_usage 10 20 95 'Fable 5.1' > "$FIXTURE_DIR/.claude.json"

# A model can be spelled three ways and the gate reads all three. The rows above
# spell `--model=X`; these spell `--model X` and codex's `-m X`, so deleting the
# arm that takes the value from the NEXT token reddens a row instead of silently
# unguarding every space-form and codex launch.
run_ot "cmd=true --model fable --effort high" --harness claude --lane "$H/.claude" KEN-67
assert_eq "$(observe "rc=1 launched=nolog walled=lane=$H/.claude,model=fable,pct=95,bucket=model,projected-headroom=5")" \
  "rc=1 launched=nolog walled=lane=$H/.claude,model=fable,pct=95,bucket=model,projected-headroom=5" \
  "the space-spelled --model in the launch command gates the lane too"

# A launch that carries its own harness argv is gated on the model INSIDE that
# argv, which is the model it will really run: the template is read rather than
# waved through, and the same wall is judged as for a launch whose command this
# launcher builds. The second row is the inverse, a model with room in the same
# template still launching.
run_ot "" --harness claude --lane "$H/.claude" --cmd "claude --model fable --effort high $QUESTION_OFF_ALL" KEN-75
assert_eq "$(observe "rc=1 launched=nolog walled=lane=$H/.claude,model=fable,pct=95,bucket=model,projected-headroom=5")" \
  "rc=1 launched=nolog walled=lane=$H/.claude,model=fable,pct=95,bucket=model,projected-headroom=5" \
  "a model named inside the --cmd command gates the lane on that model's wall"
# cmd_home beside the launch: a claude lane names no CODEX_HOME and builds no
# home of its own, since the folder-trust record that harness reads is its
# own config dir's .claude.json, which the launch writes the entry into.
run_ot "" --harness claude --lane "$H/.claude" --cmd "claude --model opus --effort high $QUESTION_OFF_ALL" KEN-76
assert_eq "$(observe "rc=0 launched=1 walled=none cmd_home=none trust_route=account-config")" \
  "rc=0 launched=1 walled=none cmd_home=none trust_route=account-config" \
  "a --cmd naming a model with room still launches, under no CODEX_HOME, trusted in its own config dir"
# A claude config dir whose .claude.json does not parse refuses the item, and
# the refusal carries the parser's own words under its keyed line, the
# position the operator repairs the file at. A lane of its own with room.
make_lane "$H" jclaude 3600
claude_usage 10 20 5 Opus > "$FIXTURE_DIR/.jclaude.json"
printf '{"projects": ' > "$H/.jclaude/.claude.json"
run_ot "" --harness claude --lane "$H/.jclaude" --cmd "claude --model opus --effort high $QUESTION_OFF_ALL" KEN-93
assert_eq "$(observe "rc=1 launched=nolog trustfail=1 trustdetail=1")" \
  "rc=1 launched=nolog trustfail=1 trustdetail=1" \
  "a claude config that does not parse refuses the item with the parser's words under the refusal"
rm -rf -- "${H:?}/.jclaude" "${FIXTURE_DIR:?}/.jclaude.json"

make_codex_lane "$H/.codex"
jq -n '{rate_limit: {primary_window: {used_percent: 95, reset_at: 1785000000,
                                      limit_window_seconds: 18000}}}' > "$FIXTURE_DIR/.codex.json"
run_ot "cmd=true -m fable -c model_reasoning_effort=high" --harness codex --lane "$H/.codex" KEN-68
assert_eq "$(observe "rc=1 launched=nolog walled=lane=$H/.codex,model=fable,pct=95,bucket=session,projected-headroom=5")" \
  "rc=1 launched=nolog walled=lane=$H/.codex,model=fable,pct=95,bucket=session,projected-headroom=5" \
  "codex spells the model -m, and that launch is gated on the same wall"

# A Codex session started into a directory its config does not trust stops on
# the folder-trust question and waits there, and a lane launch has nobody at
# the pane to answer it. The entry is made before the window opens, in a
# CODEX_HOME of the launch's own under the account, because the account's own
# config.toml is a link its shim repoints at every launch. The preparation
# itself is lane-launch-trust.sh; these rows are the wiring, and what the
# launched command ends up running under.
make_codex_lane "$H/.tcodex"
jq -n '{rate_limit: {primary_window: {used_percent: 5, reset_at: 1785000000,
                                      limit_window_seconds: 18000}}}' > "$FIXTURE_DIR/.tcodex.json"
run_ot "cmd=true -m gpt-5 -c model_reasoning_effort=high" --harness codex --lane "$H/.tcodex" KEN-1632
assert_eq "$(observe "rc=0 launched=1 cmd_home=private home_trusts=yes trust_route=launch-home")" \
  "rc=0 launched=1 cmd_home=private home_trusts=yes trust_route=launch-home" \
  "a codex launch runs under a home whose config trusts the worktree it opens in, and names that route"
# A codex launch with NO --lane opens into the same untrusted worktree and is
# prepared the same way: folder trust belongs to the directory, not to the
# account a launch was aimed at, and the command shape handoff.md section 2
# documents passes no --lane at all.
#
# WHICH account such a launch lands on is the one the pane would have opened on
# by itself. Under tmux that is the tmux SERVER's environment, and CODEX_HOME is
# not on tmux's default update-environment list, so a value set in the
# launcher's own environment never reaches the pane. An orch agent running
# inside a codex lane launches handoff items this way, and reading its own
# variable would move every one of them onto its own account, with no claim
# taken on it and the account check skipped.
#
# ENV|ITEM|ACCOUNT|WHAT, one row per place the value can sit. No HOME is
# pinned: the default account is derived from LANES_HOME like every other
# reader's, so a row that had to set HOME would be saying the derivation is
# somewhere else.
#
# WHICH tmux scope holds it is the second half of that question. tmux keeps a
# session environment beside a global one and a pane takes the session entry
# wherever it has one; the environment the SERVER was started with lands in the
# GLOBAL scope alone, and nothing here writes a session entry, so on a fleet
# host the account a pane inherits is the global one. A read without -g answers
# `unknown variable` there and sends the launch to the harness default instead.
for row in \
  "|KEN-1634|.codex|the default account under LANES_HOME" \
  "CODEX_HOME=$H/.tcodex;|KEN-1636|.codex|the launcher's own CODEX_HOME, which no pane inherits" \
  "OT_TMUX_ENV_GLOBAL_CODEX_HOME=$H/.tcodex;|KEN-1637|.tcodex|the tmux GLOBAL scope, where a server's own environment lands" \
  "OT_TMUX_ENV_SESSION_CODEX_HOME=$H/.tcodex;|KEN-1638|.tcodex|the tmux SESSION scope, which a set-environment writes" \
  "OT_TMUX_ENV_SESSION_CODEX_HOME=$H/.tcodex;OT_TMUX_ENV_GLOBAL_CODEX_HOME=$H/.codex;|KEN-1639|.tcodex|a session entry, which the pane takes over the global one" \
  "OT_TMUX_ENV_SESSION_CODEX_HOME=-;OT_TMUX_ENV_GLOBAL_CODEX_HOME=$H/.tcodex;|KEN-1640|.codex|a session removal marker, which hides the global value from the pane" \
  ; do
  extra="${row%%|*}"; rest="${row#*|}"
  item="${rest%%|*}"; rest="${rest#*|}"
  account="${rest%%|*}"; what="${rest#*|}"
  want="rc=0 launched=1 cmd_home=private cmd_account=$account home_trusts=yes trust_route=launch-home"
  run_ot "${extra}cmd=true -m gpt-5 -c model_reasoning_effort=high" --harness codex "$item"
  assert_eq "$(observe "$want")" "$want" \
    "a codex launch with no --lane is prepared under $what"
done

# An account whose config exists and cannot be read refuses the item: the
# launch would otherwise start with every table the account was approved for
# gone. Nothing opens, and the batch exits on the failed count. The config is
# replaced with a dangling link, which is the shape a numbered account's shim
# leaves behind when the render it points at is not there.
DANGLING_LANE="$H/.dcodex"
make_codex_lane "$DANGLING_LANE"
jq -n '{rate_limit: {primary_window: {used_percent: 5, reset_at: 1785000000,
                                      limit_window_seconds: 18000}}}' > "$FIXTURE_DIR/.dcodex.json"
ln -sfn "$H/no-such-render.toml" "${DANGLING_LANE:?}/config.toml"
run_ot "cmd=true -m gpt-5 -c model_reasoning_effort=high" --harness codex --lane "$DANGLING_LANE" KEN-1635
assert_eq "$(observe "rc=1 launched=nolog trustfail=1")" "rc=1 launched=nolog trustfail=1" \
  "an account config that cannot be read refuses the item and opens no window"

# The account answering for the worktree already is the other route: nothing is
# built and the launch runs under the account directory itself. The worktree is
# pinned for this row, since a config can only name a directory that exists
# before the launch reads it.
TRUSTED_WT="$TMP_ROOT/trusted-wt"
printf '[projects."%s"]\ntrust_level = "trusted"\n' "$TRUSTED_WT" > "$H/.tcodex/config.toml"
run_ot "OT_WT_FIXED=$TRUSTED_WT;cmd=true -m gpt-5 -c model_reasoning_effort=high" \
  --harness codex --lane "$H/.tcodex" KEN-1633
assert_eq "$(observe "rc=0 launched=1 cmd_home=.tcodex home_trusts=yes trust_route=preapproved")" \
  "rc=0 launched=1 cmd_home=.tcodex home_trusts=yes trust_route=preapproved" \
  "an account config that already trusts the worktree launches on the account itself, under the other route"

# The model-scoped window has room, but the shared 5-hour window walls every
# model on the account. The launcher reports that shared bucket as the cause.
claude_usage 85 20 10 'Fable 5.1' > "$FIXTURE_DIR/.claude.json"
run_ot "ORCH_LANE_MAX_PCT=80;cmd=true --model fable --effort high" --harness claude --lane "$H/.claude" KEN-118
assert_eq "$(observe "rc=1 launched=nolog walled=lane=$H/.claude,model=fable,pct=85,bucket=session,projected-headroom=15")" \
  "rc=1 launched=nolog walled=lane=$H/.claude,model=fable,pct=85,bucket=session,projected-headroom=15" \
  "a shared 5-hour wall refuses a launch whose model-scoped bucket has room"

claude_usage 10 20 95 'Fable 5.1' > "$FIXTURE_DIR/.claude.json"

# A lane the inventory HAS but whose windows answer nothing for this model is
# a lane nobody measured, not a lane that is full: the key says so. Telling an
# operator the allowance is gone would send them to wait for a reset that is
# not coming.
make_lane "$H" uclaude 3600
jq -n '{limits: [{kind: "weekly_scoped", percent: 10, resets_at: "2099-08-01T06:00:00Z",
                  scope: {model: {display_name: "Opus"}}}]}' > "$FIXTURE_DIR/.uclaude.json"
run_ot "cmd=true --model sonnet --effort high" --harness claude --lane "$H/.uclaude" KEN-69
assert_eq "$(observe "rc=1 launched=nolog unreadable=lane=$H/.uclaude,model=sonnet,step=windows walled=none")" \
  "rc=1 launched=nolog unreadable=lane=$H/.uclaude,model=sonnet,step=windows walled=none" \
  "a lane whose windows name no such model is unreadable, never reported as full"

# A lane whose usage could not be fetched at all is the same answer for the same
# reason: nobody read a window, so nobody may say the allowance is gone. The
# openclaude dir is discovered as a lane and has no credentials to measure.
run_ot "cmd=true --model fable --effort high" --harness claude --lane "$H/.openclaude" KEN-73
assert_eq "$(observe "rc=1 launched=nolog unreadable=lane=$H/.openclaude,model=fable,step=windows walled=none poolfix=none")" \
  "rc=1 launched=nolog unreadable=lane=$H/.openclaude,model=fable,step=windows walled=none poolfix=none" \
  "a lane whose usage could not be read is unreadable, never reported as full, and names no Copilot pool repair"

# A config dir no lane record covers is judged by nothing, because there is
# nothing to judge it by and there never was. --help says such a dir is used as
# given, and this gate does not take that away.
run_ot "cmd=true --model fable --effort high" --harness claude --lane "$OUTSIDE_LANE" KEN-70
assert_eq "$(observe "rc=0 launched=1 walled=none unreadable=none")" \
  "rc=0 launched=1 walled=none unreadable=none" \
  "a config dir outside every lane record launches, the gate holding no record to judge it by"

# The threshold is forwarded, never evaluated here: a value this script once
# fed to bash arithmetic is now refused by the one parser that owns it, and the
# launch stops rather than proceeding on a comparison that errored.
run_ot "cmd=true --model fable --effort high" --harness claude --lane "$H/.claude" --lane-max-pct '90%' KEN-71
assert_eq "$(observe "rc=1 launched=nolog judgefailed=lane=$H/.claude,model=fable,exit=1 unreadable=none")" \
  "rc=1 launched=nolog judgefailed=lane=$H/.claude,model=fable,exit=1 unreadable=none" \
  "a malformed --lane-max-pct on a named lane refuses the launch, named as the judge failing and not as an unread window"

# A claims path that is not a directory refuses the named lane as it refuses
# `--lane auto`: this gate charges the lanes already on the account, and a
# store nobody could read is not an account running none.
run_ot "prep=claims_file;$CHOICE_CMD" --harness claude --lane "$H/.claude" KEN-74
assert_eq "$(observe "rc=1 launched=nolog claimsnotice=0 walled=none judgefailed=none") refused=$(grep -c "^open-terminal: lane-claims-unreadable lane=$H/.claude\$" <<<"$OUT" || true)" \
  "rc=1 launched=nolog claimsnotice=0 walled=none judgefailed=none refused=1" \
  "an unreadable claim store refuses the named lane, naming the store as the cause"

rm -rf -- "${H:?}/.uclaude" "${FIXTURE_DIR:?}/.uclaude.json"

# The shared home is neutral again for the rows below; the space-spelled model
# row further down stages this fixture once more for itself.
claude_usage 10 20 5 Opus > "$FIXTURE_DIR/.claude.json"

echo "=== a bare --lane word is an alias first, then a directory ==="
# The alias owns the bare word: a cwd directory with the same name would
# otherwise win and launch under a config dir nobody configured, silently. A
# word no alias claims still resolves as a directory.
table \
  "a cwd directory does not shadow the alias it collides with|ORCH_LANE_ALIASES=eclaude=work;cwd=$COLLIDE;$CHOICE_CMD|--harness claude --lane work KEN-1|rc=0 out_lanes=eclaude" \
  "a bare word no alias claims falls back to the directory|ORCH_LANE_ALIASES=eclaude=work;cwd=$BARE;$CHOICE_CMD|--harness claude --lane somelane KEN-1|rc=0 out_lanes=somelane"

echo "=== a tmux launch under a lane runs under it and records its claim ==="
# The launched command carries the lane as a single-quoted env prefix; the
# claim names the lane's config dir, the window, and the pane id that keeps
# it prunable; a launch with no lane has no account to claim; a GUI
# launch has no pane to keep a claim alive, so a GUI batch records nothing
# and stays on the lane resolved up front.
table \
  "--lane <alias> launches under that lane's env prefix and records one claim naming lane, window and pane|ORCH_LANE_ALIASES=eclaude=work;$CHOICE_CMD|--harness claude --lane work KEN-2|rc=0 cmd_lane=eclaude claims=1 claim_lanes=eclaude claim_window=KEN-2 claim_pane=%1" \
  'a launch with no --lane still opens its window and records no claim|cmd=true|--harness claude KEN-3|launched=1 claims=nolog' \
  "a GUI batch launches, records no claim, and reports the one lane it resolved|TERMINAL=ghostty;$CHOICE_CMD|--ghostty --harness claude --lane auto KEN-10 KEN-11|rc=0 claims=nolog summary=lane=claude"

echo "=== --lane auto over a batch re-picks on projected room and reset ==="
# In the private score-crossing world, a claim moves the next item off its lane; a window created and
# then failed still holds its account (the trigger is an attempted item); the
# summary counts distinct lanes. A claim that could not be written, a claims
# path that is not a directory, a re-picked lane carrying the separator, or a
# re-pick that cannot place its item stops the batch instead of launching the
# next item blind; an item another session owns never carried a session and
# is not a lane the batch ran on.
BATCH_SHARED_HOME="$H"
H="$SPREADHOME"
table \
  "a two-item batch spreads across two accounts, reset-weighted room first|$SPREAD_ENV;$CHOICE_CMD| --harness claude --lane auto KEN-4 KEN-5|rc=0 launched=2 claim_lanes=claude,eclaude out_lanes=claude,eclaude summary=spread=2" \
  "a claimed window whose launch failed still moves the next item off that lane|$SPREAD_ENV;OT_TMUX_FAIL=send-keys;$CHOICE_CMD|--harness claude --lane auto KEN-8 KEN-9|launched=2 claim_lanes=claude,eclaude out_lanes=claude,eclaude" \
  "a third item returning to a used lane still reports two distinct lanes|$SPREAD_ENV;$CHOICE_CMD|--harness claude --lane auto KEN-12 KEN-13 KEN-14|launched=3 summary=spread=2"

# The old ordering reverses the batch: its first pick ignores the sooner
# reset and takes eclaude's greater unweighted room instead.
pi_control ctl-batch-claims-first lib/lane-model.sh \
  'sort_by([._seat, ._tier, ._expires, (._score | neg), .claims, (.projected_headroom_pct | neg), .wall])' \
  'sort_by([.claims, (.projected_headroom_pct | neg), .wall])' \
  "$SPREAD_ENV;$CHOICE_CMD" --harness claude --lane auto KEN-4 KEN-5
assert_eq "$(observe "rc=0 launched=2 claim_lanes=claude,eclaude out_lanes=eclaude,claude")" \
  "rc=0 launched=2 claim_lanes=claude,eclaude out_lanes=eclaude,claude" \
  "control: claims-first ordering turns the reset-weighted batch order red"

# Each item's fleet record keeps the pick its own launch was judged on: the
# second item's re-pick names eclaude and the first item's claim on claude.
# Its control keeps the first pick's record through the re-pick, and the
# second record names the account the first item took.
batch_picks() { # STATE_DIR
  "$SCRIPTS_DIR/workflow-state" --state-dir "$1" get oversee \
    '[.lanes[] | "\(.item):\(.account | split("/") | last)=\(.pick.account // "none" | split("/") | last):\(.pick.claims)"] | join(",")' | tr -d '"'
}
SPREAD_FLEET_CMD="cmd=true --model opus --effort high $COMPACTION_OFF_ALL"
ot_fleet_state "$SCRIPTS_DIR/workflow-state" "$TMP_ROOT/spread-fleet-1" "$PWD" || exit 1
run_ot "$SPREAD_ENV;$SPREAD_FLEET_CMD" --harness claude --lane auto --state-dir "$TMP_ROOT/spread-fleet-1" KEN-4 KEN-5
assert_eq "rc=$RC picks=$(batch_picks "$TMP_ROOT/spread-fleet-1")" "rc=0 picks=KEN-4:.claude=.claude:0,KEN-5:.eclaude=.eclaude:0" \
  "each item of a batch records the pick its own launch was judged on"
ot_fleet_state "$SCRIPTS_DIR/workflow-state" "$TMP_ROOT/spread-fleet-2" "$PWD" || exit 1
pi_control ctl-batch-pick-kept open-terminal '    LANE_PICK_RECORD="$record"
' '' "$SPREAD_ENV;$SPREAD_FLEET_CMD" --harness claude --lane auto --state-dir "$TMP_ROOT/spread-fleet-2" KEN-4 KEN-5
assert_eq "rc=$RC picks=$(batch_picks "$TMP_ROOT/spread-fleet-2")" "rc=0 picks=KEN-4:.claude=.claude:0,KEN-5:.eclaude=.claude:0" \
  "control: a re-pick whose reading is not kept records the first item's pick on the second"
H="$BATCH_SHARED_HOME"

table \
  "a re-picked lane carrying a separator stops the batch after the first launch|LANES_HOME=$TABHOME;FIXTURE_DIR=$TABFIX;ORCH_LANE_BURN_PCT_PER_HOUR=20;STUB_CLOCK=$TMP_ROOT/pick-clock;$CHOICE_CMD|--harness claude --lane auto KEN-22 KEN-23|rc=1 launched=1 claims=1" \
  "a re-pick that cannot place its item stops the batch after the first launch|ORCH_LANES_FETCH_CMD=$TMP_ROOT/fetch-flaky;FLAKY_COUNT=$TMP_ROOT/flaky-count;FLAKY_OK=3;ORCH_LANES_USAGE_TTL=0;$CHOICE_CMD|--harness claude --lane auto KEN-6 KEN-7|rc=1 launched=1 claims=1" \
  "a lane picked for an item another session owns is not one the batch ran on|WORKTREE_CLI=$OWNED_STUB;OWNED_COUNT=$TMP_ROOT/owned-count;OWNED_ROOT=$TMP_ROOT;$CHOICE_CMD|--harness claude --lane auto KEN-17 KEN-18|launched=1 summary=lane=claude"

# A claims path that is not a directory is a misconfiguration, not an empty
# store: the pick refuses before anything launches.
table \
  "a non-directory claims path refuses the launch|prep=claims_file;$CHOICE_CMD|--harness claude --lane auto KEN-19|rc=1 launched=nolog"

# Root writes into a mode-555 directory, so the row cannot fail a write there.
if [[ "$(id -u)" -eq 0 ]]; then
  printf '  skip  unwritable claim store (running as root)\n'
else
  table \
    "a claim that could not be recorded stops the batch after the launch that stands|prep=store_ro;$CHOICE_CMD|--harness claude --lane auto KEN-15 KEN-16|rc=1 launched=1"
fi

echo "=== the claim store belongs to the caller's checkout ==="
# `.agents` in a worktree points back at the main checkout, so a root derived
# from the script's own path would write where `lanes` never looks.
SCRIPTREPO="$TMP_ROOT/scriptrepo"; CALLERREPO="$TMP_ROOT/callerrepo"
mutant_scripts scriptrepo >/dev/null || exit 1
mkdir -p "$CALLERREPO"
orch_fixture_shared_libs "$SCRIPTREPO"
git -C "$SCRIPTREPO" init -q
git -C "$SCRIPTREPO" config gc.auto 0
git -C "$SCRIPTREPO" config maintenance.auto false
git -C "$CALLERREPO" init -q
git -C "$CALLERREPO" config gc.auto 0
git -C "$CALLERREPO" config maintenance.auto false
( cd "$CALLERREPO" && env "${LANE_ENV_DEFAULTS[@]}" LANES_HOME="$H" ORCH_LANES_FETCH_CMD="$FETCHER" GH_ISSUE_PATTERN='[A-Z]+-[0-9]+' \
  TMUX=stub,1,0 ORCH_TMUX_SESSION=stub OT_TMUX_LOG="$TMP_ROOT/caller.tmux.log" OT_TMUX_SERVER_PID="$$" OT_TMUX_PANES="$TMP_ROOT/caller.panes" \
  OT_WT_LOG="$TMP_ROOT/caller.worktree.log" PATH="$OT_STUB_BIN:$PATH" WORKTREE_CLI="$OT_STUB_BIN/worktree" \
  "$SCRIPTREPO/scripts/open-terminal" --harness claude --lane auto \
  --cmd "true --model opus --effort high $QUESTION_OFF_ALL" KEN-20 ) >/dev/null 2>&1
assert_eq "caller=$(ls -1 "$CALLERREPO"/tmp/oversee-watch/claims 2>/dev/null | wc -l | tr -d '[:space:]') script=$(ls -1 "$SCRIPTREPO"/tmp/oversee-watch/claims 2>/dev/null | wc -l | tr -d '[:space:]')" \
  "caller=1 script=0" "the claim lands in the caller checkout, where lanes reads it, never under the script's"

# The repository the launch line renders splits the same way. The resolver's
# first rung, `gh repo view`, answers for the caller's cwd, so its origin-remote
# fallback must read the caller's checkout too — reading the script's would
# brief the lane on whichever repository the kendex install happens to sit in.
# gh exits 1 here, which is the rung that answers nothing.
git -C "$SCRIPTREPO" remote add origin git@github.com:script-owner/script-repo.git
git -C "$CALLERREPO" remote add origin git@github.com:caller-owner/caller-repo.git
REPO_LOG="$TMP_ROOT/caller.repo.tmux.log"
( cd "$CALLERREPO" && env "${LANE_ENV_DEFAULTS[@]}" LANES_HOME="$H" ORCH_LANES_FETCH_CMD="$FETCHER" GH_ISSUE_PATTERN='[A-Z]+-[0-9]+' \
  TMUX=stub,1,0 ORCH_TMUX_SESSION=stub OT_TMUX_LOG="$REPO_LOG" OT_TMUX_SERVER_PID="$$" OT_TMUX_PANES="$TMP_ROOT/caller.repo.panes" \
  OT_CHECKOUT_REPO= OT_WT_LOG="$TMP_ROOT/caller.repo.worktree.log" PATH="$OT_STUB_BIN:$PATH" WORKTREE_CLI="$OT_STUB_BIN/worktree" \
  "$SCRIPTREPO/scripts/open-terminal" --harness claude --lane auto \
  --cmd "true {repo} --model opus --effort high $QUESTION_OFF_ALL" KEN-21 ) >/dev/null 2>&1
assert_eq "caller=$(grep -c '^clear; .*true caller-owner/caller-repo ' "$REPO_LOG" || true) script=$(grep -c 'script-owner/script-repo' "$REPO_LOG" || true)" \
  "caller=1 script=0" "the launch line names the caller checkout's repository, never the script checkout's"
assert_eq "$(sed -n 's/^set-option -w -t [^ ]* @kendex_lane //p' "$REPO_LOG" | jq -r '.[1]')" \
  "caller-owner/caller-repo" "the window identity carries the caller checkout's repository"

echo "=== a GH_REPO the resolver refuses never reaches the launch line ==="
# The resolver returns status 2 for a value that is not owner/name and PRINTS
# it anyway, so the value is on stdout whether it was accepted or rejected.
# resolve_repo is where that distinction is kept: a consumer reading the
# output without the status types a quote-bearing GH_REPO into the pane shell
# that runs the rendered line. gh-repo-resolve.test.sh pins the refusal; this
# pins what open-terminal does with it.
BAD_REPO="o/r';id;'"

# run_bad_repo SCRIPT NAME — one launch under the refused GH_REPO, from a
# caller checkout of its own so the claim store starts empty. Prints
# `launched=<n> rejected=<n>`: the windows opened, and the tmux lines carrying
# the refused value. Both halves matter — a run that launched nothing would
# report rejected=0 for the wrong reason.
run_bad_repo() {
  local script="$1" name="$2"
  local caller="$TMP_ROOT/$name-caller" log="$TMP_ROOT/$name.tmux.log"
  mkdir -p "$caller"
  git -C "$caller" init -q
  git -C "$caller" config gc.auto 0
  git -C "$caller" config maintenance.auto false
  ( cd "$caller" && env "${LANE_ENV_DEFAULTS[@]}" LANES_HOME="$H" ORCH_LANES_FETCH_CMD="$FETCHER" GH_ISSUE_PATTERN='[A-Z]+-[0-9]+' \
    GH_REPO="$BAD_REPO" TMUX=stub,1,0 ORCH_TMUX_SESSION=stub OT_TMUX_LOG="$log" OT_TMUX_SERVER_PID="$$" \
    OT_TMUX_PANES="$TMP_ROOT/$name.panes" OT_WT_LOG="$TMP_ROOT/$name.worktree.log" \
    PATH="$OT_STUB_BIN:$PATH" WORKTREE_CLI="$OT_STUB_BIN/worktree" \
    "$script" --harness claude --lane auto \
      --cmd "true {repo} --model opus --effort high $QUESTION_OFF_ALL" KEN-30 ) >/dev/null 2>&1
  printf 'launched=%s rejected=%s' \
    "$(grep -c '^new-window' "$log" || true)" "$(grep -cF "$BAD_REPO" "$log" || true)"
}

assert_eq "$(run_bad_repo "$SCRIPTREPO/scripts/open-terminal" refused)" "launched=1 rejected=0" \
  "a GH_REPO the resolver refuses renders no repository into the launch line"

echo "=== a launch binds its item to the tree it made, or fails the item ==="
# lane-mail-check hands a lane its mail only where this marker names the tree's
# root. A tree git cannot mark fails the item rather than launching a lane the
# hook never reaches. The unmarkable tree sits outside every repository, and the
# ceiling keeps git from finding the one the suite's temp root may sit in.
#
# `lane-marker` owns the record and the containment over it, and lane-marker.sh
# pins those; what these rows pin is that a launch calls it and fails the item
# on what it says.
NOGIT_STUB="$TMP_ROOT/worktree-nogit"
cat > "$NOGIT_STUB" <<'STUBEOF'
#!/usr/bin/env bash
[[ "${1:-}" == "create" ]] && { mktemp -d "$(dirname "$OT_WT_LOG")/wt.XXXXXX"; exit 0; }
exit 0
STUBEOF
chmod +x "$NOGIT_STUB"

# marked SCRIPT NAME WORKTREE_CLI [OPTION] — one launch of KEN-40 from a caller
# checkout of its own. Prints `rc=<rc> marker=<root|none|other> box=<made|none>
# refresh=<root|none|other> refused=<marker-failed lines>`. `box` is the lane's
# own mailbox directory, which the launch makes in the item's own spelling:
# lane-mail-check resolves the item by it, so a lane nobody has messaged is
# still judged on its handoff marks. `refresh` is the refresh record
# --lane-refresh asks lane-marker for.
marked() {
  local script="$1" name="$2" runs="$TMP_ROOT/$2-runs" caller="$TMP_ROOT/$2-caller" out rc=0 wt marker=none box=none refresh=none
  local option=()
  [[ -z "${4:-}" ]] || option=("$4")
  mkdir -p "$runs" "$caller"
  git -C "$caller" init -q
  git -C "$caller" config gc.auto 0
  git -C "$caller" config maintenance.auto false
  out="$( cd "$caller" && env "${LANE_ENV_DEFAULTS[@]}" GIT_CEILING_DIRECTORIES="$TMP_ROOT" LANES_HOME="$H" ORCH_LANES_FETCH_CMD="$FETCHER" \
    GH_ISSUE_PATTERN='[A-Z]+-[0-9]+' TMUX=stub,1,0 ORCH_TMUX_SESSION=stub OT_TMUX_LOG="$runs/tmux.log" OT_TMUX_SERVER_PID="$$" \
    OT_TMUX_PANES="$runs/panes" OT_WT_LOG="$runs/worktree.log" PATH="$OT_STUB_BIN:$PATH" WORKTREE_CLI="$3" \
    "$script" --harness claude --cmd "true $QUESTION_OFF_ALL" ${option[@]+"${option[@]}"} KEN-40 2>&1 )" || rc=$?
  wt="$(find "$runs" -maxdepth 1 -type d -name 'wt.*')"
  if [[ -f "$wt/.git/lane-mail/ken-40" ]]; then
    marker=other
    [[ "$(cat "$wt/.git/lane-mail/ken-40")" != "$wt" ]] || marker=root
  fi
  # A plain directory, never a link a row planted: -d alone follows one.
  { [[ -L "$wt/tmp/lane-mail/KEN-40" ]] || [[ ! -d "$wt/tmp/lane-mail/KEN-40" ]]; } || box=made
  if [[ -f "$wt/.git/lane-refresh" ]]; then
    refresh=other
    [[ "$(cat "$wt/.git/lane-refresh")" != "$wt" ]] || refresh=root
  fi
  printf 'rc=%s marker=%s box=%s refresh=%s refused=%s' "$rc" "$marker" "$box" "$refresh" "$(grep -c '^open-terminal: marker-failed item=KEN-40 ' <<<"$out" || true)"
}

assert_eq "$(marked "$OPEN_TERMINAL" marked "$OT_STUB_BIN/worktree")" "rc=0 marker=root box=made refresh=none refused=0" \
  "a launch binds its lowercased item to the root of the tree it made and opens the lane's mailbox there"
assert_eq "$(marked "$OPEN_TERMINAL" refresh "$OT_STUB_BIN/worktree" --lane-refresh)" "rc=0 marker=root box=made refresh=root refused=0" \
  "a --lane-refresh launch also writes the refresh record holding the lane's root"
assert_eq "$(marked "$OPEN_TERMINAL" unmarkable "$NOGIT_STUB")" "rc=1 marker=none box=none refresh=none refused=1" \
  "a tree git cannot mark fails the item instead of launching it"

# The must-fail control for the option: a copy that reads --lane-refresh and
# hands lane-marker nothing for it, so the refresh row above turns red.
REFRESH_DROPPED="$(mutant_scripts ctl-refresh-dropped open-terminal)/open-terminal" || exit 1
mutate_file "$REFRESH_DROPPED" '|| refresh=(--lane-refresh)' '|| refresh=()'
assert_eq "$(marked "$REFRESH_DROPPED" refresh-dropped "$OT_STUB_BIN/worktree" --lane-refresh)" "rc=0 marker=root box=made refresh=none refused=0" \
  "control: an option handed to no lane-marker call leaves no refresh record"

# A worktree whose tmp is a symlink, which skills/worktree's WORKTREE_SYMLINKS
# makes: the launch marks it and opens its mailbox through the link, because
# containment starts at tmp/lane-mail, where lane-mail's own reader starts it.
TMPLINK_STUB="$TMP_ROOT/worktree-tmplink"
cat > "$TMPLINK_STUB" <<'STUBEOF'
#!/usr/bin/env bash
[[ "${1:-}" == "create" ]] || exit 0
d="$(mktemp -d "$(dirname "$OT_WT_LOG")/wt.XXXXXX")" || exit 1
git init -q "$d"
git -C "$d" config gc.auto 0
git -C "$d" config maintenance.auto false
scratch="$(mktemp -d "$(dirname "$OT_WT_LOG")/scratch.XXXXXX")" || exit 1
ln -s "$scratch" "$d/tmp"
printf '%s\n' "$d"
STUBEOF
chmod +x "$TMPLINK_STUB"
assert_eq "$(marked "$OPEN_TERMINAL" tmplink "$TMPLINK_STUB")" "rc=0 marker=root box=made refresh=none refused=0" \
  "a launch into a worktree whose tmp is a symlink writes the marker and the mailbox"

# A symlink already at the marker path fails the item and writes through nothing.
LINKED_STUB="$TMP_ROOT/worktree-linked"
cat > "$LINKED_STUB" <<'STUBEOF'
#!/usr/bin/env bash
[[ "${1:-}" == "create" ]] || exit 0
d="$(mktemp -d "$(dirname "$OT_WT_LOG")/wt.XXXXXX")" || exit 1
git init -q "$d"
git -C "$d" config gc.auto 0
git -C "$d" config maintenance.auto false
mkdir -p "$d/.git/lane-mail"
ln -s "$(dirname "$OT_WT_LOG")/marker-target" "$d/.git/lane-mail/ken-40"
printf '%s\n' "$d"
STUBEOF
chmod +x "$LINKED_STUB"
LINKED="$(marked "$OPEN_TERMINAL" linked "$LINKED_STUB")"
assert_eq "$LINKED target=$([[ -e "$TMP_ROOT/linked-runs/marker-target" ]] && echo written || echo untouched)" \
  "rc=1 marker=none box=none refresh=none refused=1 target=untouched" "a symlink at the marker path fails the item and writes through nothing"

lane_suite_end
