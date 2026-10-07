#!/usr/bin/env bash
# Room checks: a target with SECOND_OPINION_<NAME>_ROOM_CMD is taken only when
# that command exits 0, and its command then runs under the NAME=value env
# prefix the check printed, the account it judged. A walled or unmeasured
# target is skipped with its reason and the walk goes on, so a Copilot entry
# stands in for a walled codex and codex is taken again once its check reads
# room. A check is spent only on a target every other rule would take (the
# `a target whose CLI is missing` row is the control for that check running
# last, after the CLI lookup right before it), runs
# from the project root with stdin closed, and a stdout line that is no
# assignment skips the target rather than reaching its environment. One table,
# a row per scenario; each row also renders the account every lane stub ran
# under and how often each room check ran. A refusing check's stderr is passed
# through whole: the unmeasured row's stub prints two lines and both appear.
# shellcheck source=lib/roster-world.bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/roster-world.bash"

# A Claude session whose roster names claude, codex and a Copilot entry on an
# OpenAI model, the lanes stubbed, one opinion.
DEFAULTS="ps:none current:claude models:claude+codex+copilot count:1 cmd:claude=claude cmd:codex=codex cmd:copilot=extra model:copilot=gpt-6.1-sol"

OWN="pass/b=-/s=-/cov=null/req=1/sel=1/lanes=-/dedupe=-/head=head/union=null"
NONE="calls=claude:0,codex:0,extra:0 art=- files=-"

# label|world|command|rc|out|err|calls art files seat rooms
ROWS="
a walled codex seat is skipped with its reason and the Copilot entry reviews on the account its check picked|room:codex=walled room:copilot=room|review|0|<out>|same:claude:claude roomsaid:codex:walled roomrefused:codex:CODEX:3 room:copilot:COPILOT:copilot-seat single:copilot:review:claude written|calls=claude:0,codex:0,extra:1 art=external-copilot/$OWN files=out seat=claude:none,codex:none,extra:copilot-seat rooms=codex:1,copilot:1
codex is taken again once its seat reads room, on the seat its check picked, and the Copilot check is never spent|room:codex=room room:copilot=room|review|0|<out>|same:claude:claude room:codex:CODEX:codex-seat single:codex:review:claude written|calls=claude:0,codex:1,extra:0 art=external-codex/$OWN files=out seat=claude:none,codex:codex-seat,extra:none rooms=codex:1
an unmeasured seat is skipped the same way|room:codex=unmeasured room:copilot=room|review|0|<out>|same:claude:claude roomsaid:codex:unmeasured roomsaid:codex:detail roomrefused:codex:CODEX:5 room:copilot:COPILOT:copilot-seat single:copilot:review:claude written|calls=claude:0,codex:0,extra:1 art=external-copilot/$OWN files=out seat=claude:none,codex:none,extra:copilot-seat rooms=codex:1,copilot:1
every account walled refuses naming each, with no availability verdict|room:codex=walled room:copilot=walled|review|1|-|same:claude:claude roomsaid:codex:walled roomrefused:codex:CODEX:3 roomsaid:copilot:walled roomrefused:copilot:COPILOT:3 refused:claude:3|$NONE seat=claude:none,codex:none,extra:none rooms=codex:1,copilot:1
a check printing a record rather than a prefix skips its target: the record never reaches an environment|room:codex=json room:copilot=room|review|0|<out>|same:claude:claude noassign:codex:CODEX room:copilot:COPILOT:copilot-seat single:copilot:review:claude written|calls=claude:0,codex:0,extra:1 art=external-copilot/$OWN files=out seat=claude:none,codex:none,extra:copilot-seat rooms=codex:1,copilot:1
a check that exits 0 printing nothing is room on the target's own account|room:codex=bare|review|0|<out>|same:claude:claude room:codex:CODEX:- single:codex:review:claude written|calls=claude:0,codex:1,extra:0 art=external-codex/$OWN files=out seat=claude:none,codex:-,extra:none rooms=codex:1
a target with no check keeps today's behaviour|-|review|0|<out>|same:claude:claude single:codex:review:claude written|calls=claude:0,codex:1,extra:0 art=external-codex/$OWN files=out seat=claude:none,codex:-,extra:none rooms=-
a target skipped for the session's model never spends its check|room:claude=room|review|0|<out>|same:claude:claude single:codex:review:claude written|calls=claude:0,codex:1,extra:0 art=external-codex/$OWN files=out seat=claude:none,codex:-,extra:none rooms=-
a target whose CLI is missing never spends its check, and the next entry is taken on its own|cmd:codex=missing room:codex=room room:copilot=room|review|0|<out>|same:claude:claude nocli:codex:CODEX room:copilot:COPILOT:copilot-seat single:copilot:review:claude written|calls=claude:0,codex:0,extra:1 art=external-copilot/$OWN files=out seat=claude:none,codex:none,extra:copilot-seat rooms=copilot:1
a target whose model is already selected never spends its check|count:2 current:none models:codex+copilot room:codex=room room:copilot=room|review|0|<out>|room:codex:CODEX:codex-seat multi:codex:none selected:copilot:codex union:1|calls=claude:0,codex:1,extra:0 art=external-union(codex)/pass/b=-/s=-/cov=degraded/req=2/sel=1/lanes=codex:ok/dedupe=0/0/0/0/head=head/union=true files=out,out.codex seat=claude:none,codex:codex-seat,extra:none rooms=codex:2
a forced target is held to its check too|room:codex=walled|review --target codex|1|-|roomsaid:codex:walled roomrefused:codex:CODEX:3 refused:claude:1|$NONE seat=claude:none,codex:none,extra:none rooms=codex:1
detect names the target the room checks leave|room:codex=walled room:copilot=room|detect|0|copilot|same:claude:claude roomsaid:codex:walled roomrefused:codex:CODEX:3 room:copilot:COPILOT:copilot-seat|$NONE seat=claude:none,codex:none,extra:none rooms=codex:1,copilot:1
quick runs on the account its check picked|room:codex=room|quick|0|answer:external-codex|same:claude:claude room:codex:CODEX:codex-seat single:codex:quick:claude|calls=claude:0,codex:1,extra:0 art=- files=- seat=claude:none,codex:codex-seat,extra:none rooms=codex:1
a relative check resolves against the project root, not the caller's directory|room-rel:codex=room|review|0|<out>|same:claude:claude room:codex:CODEX:codex-seat single:codex:review:claude written|calls=claude:0,codex:1,extra:0 art=external-codex/$OWN files=out seat=claude:none,codex:codex-seat,extra:none rooms=codex:1
a check that drains its stdin takes none of the roster entries still to walk|count:2 current:none models:codex+claude room:codex=drain|review|0|<out>|room:codex:CODEX:codex-seat multi:codex+claude:none union:2|calls=claude:1,codex:1,extra:0 art=external-union(codex+claude)/pass/b=-/s=-/cov=full/req=2/sel=2/lanes=codex:ok,claude:ok/dedupe=0/0/0/0/head=head/union=true files=out,out.claude,out.codex seat=claude:-,codex:codex-seat,extra:none rooms=codex:2
a multi-lane review runs each lane on its own account: the lane re-judges its room before it runs|count:2 current:none models:codex+claude room:codex=room|review|0|<out>|room:codex:CODEX:codex-seat multi:codex+claude:none union:2|calls=claude:1,codex:1,extra:0 art=external-union(codex+claude)/pass/b=-/s=-/cov=full/req=2/sel=2/lanes=codex:ok,claude:ok/dedupe=0/0/0/0/head=head/union=true files=out,out.claude,out.codex seat=claude:-,codex:codex-seat,extra:none rooms=codex:2
"

run_table "room checks" "$DEFAULTS" "$ROWS" room_state

# Under a forced target the caller's stdin reaches the check, and a prompt piped
# there is still whole when the check has run, even one that drains its stdin.
echo "=== a room check never reads the prompt ==="
# shellcheck disable=SC2086 # DEFAULTS is a word list
build stdin $DEFAULTS room:codex=drain
rc=0
printf 'is this safe?\n' | (cd "$TMP_ROOT" && env PATH="$ROW/bin:$PATH" "${W_ENV[@]}" "$SO" quick --target codex --cwd "$WORK" >"$ROW/stdout" 2>"$ROW/stderr") || rc=$?
assert_eq "$rc" 0 "a quick prompt piped on stdin reaches the target after a check that drains stdin"
assert_eq "$(count codex):$(cat "$ROW/seat-codex" 2>/dev/null || printf none)" 1:codex-seat "the target ran once, on the seat the check picked"

# Exercise the fleet command with the real chooser. Only the usage endpoint
# and the review CLI are fixtures; account selection and prefix delivery run
# in production. The CLI records its actual account in its review metadata.
# shellcheck source=../../orch/tests/lib/lanes-fixture.sh
. "$SKILL_DIR/../orch/tests/lib/lanes-fixture.sh"
CLAUDE_ROOM_CMD="$(sed -n 's/^SECOND_OPINION_CLAUDE_ROOM_CMD = "\(.*\)"$/\1/p' "$SKILL_DIR/../../kendex.settings.toml")"
assert_eq "$(sed -n 's/^# SECOND_OPINION_CLAUDE_ROOM_CMD = "\(.*\)"$/\1/p' "$SKILL_DIR/kendex.settings.toml.example")" "$CLAUDE_ROOM_CMD" "the fleet example uses the project's Claude room command"

# label|second account weekly usage|room command enabled|reviewer|account
CLAUDE_ROWS='
Claude chooses the second account after the first reaches its weekly wall|20|yes|claude|second
Claude account metadata survives collection with another opinion|20|union|claude,my-model|second
control: removing the room command leaves the review on the walled account|20|no|claude|first
Claude pool exhaustion selects the next cross-model reviewer|100|yes|my-model|none
control: ignoring a refused room check runs the walled Claude account|100|ignore-refusal|claude|first
control: omitting the production account field rejects the selected account assertion|20|omit-account|claude|second
'
claude_row=0
while IFS='|' read -r label weekly checked reviewer account; do
  [[ -n "$label" ]] || continue
  claude_row=$((claude_row + 1))
  build "claude-pool-$claude_row" ps:none current:codex models:claude+codex+my-model count:1 \
    cmd:claude=claude cmd:codex=codex cmd:my-model=extra model:my-model=deepseek claude:parse extra:parse
  H="$ROW/home"
  FIXTURE_DIR="$ROW/usage"
  mkdir -p "$FIXTURE_DIR" "$PROJ/.agents/skills"
  ln -s "$SKILL_DIR/../orch" "$PROJ/.agents/skills/orch"
  make_lane "$H" firstclaude
  make_lane "$H" secondclaude
  claude_usage 0 100 0 Opus > "$FIXTURE_DIR/.firstclaude.json"
  claude_usage 0 "$weekly" 0 Opus > "$FIXTURE_DIR/.secondclaude.json"
  make_fetcher "$ROW/bin/fetch-usage"
  # Keep the stub's stdin and invocation accounting while its response names
  # the CLAUDE_CONFIG_DIR passed to the process, not the expected selection.
  mv "$ROW/bin/lane-claude" "$ROW/bin/claude-response"
  cat > "$ROW/bin/lane-claude" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
"${0%/*}/claude-response" | jq --arg account "$CLAUDE_CONFIG_DIR" '.qa_metadata.account = $account'
SH
  chmod +x "$ROW/bin/lane-claude"
  W_ENV+=("LANES_HOME=$H" "ORCH_LANE_DIRS=$H/.firstclaude:$H/.secondclaude"
    "ORCH_LANES_FETCH_CMD=$ROW/bin/fetch-usage" "FIXTURE_DIR=$FIXTURE_DIR"
    "OVERSEE_WATCH_STATE_DIR=$ROW/state" "CLAUDE_CONFIG_DIR=$H/.firstclaude")
  room_cmd="$CLAUDE_ROOM_CMD"
  [[ "$checked" != no ]] || room_cmd=""
  W_ENV+=("SECOND_OPINION_CLAUDE_ROOM_CMD=$room_cmd")
  [[ "$checked" != union ]] || W_ENV+=("SECOND_OPINION_COUNT=2")
  if [[ "$checked" == ignore-refusal ]]; then
    mutate_script "$SO" '  target_room "$t" || return 1' '  target_room "$t" || :'
  elif [[ "$checked" == omit-account ]]; then
    mutate_script "$SO" '{account: $account}' '{account: null}'
  fi
  got="$(run review)"
  assert_eq "${got%% *}" rc=0 "$label: review completes"
  assert_eq "$(jq -r '.qa_metadata.attempts | map(.name) | join(",")' "$ROW/out/out.json")" "$reviewer" "$label: artifact names the executed reviewer"
  actual_account="$(jq -r '.qa_metadata.attempts | map(select(.name == "claude") | .account // "none") | if length == 0 then "none" else join(",") end' "$ROW/out/out.json")"
  expected_account=none
  [[ "$account" == none ]] || expected_account=".${account}claude"
  if [[ "$checked" == omit-account ]]; then
    assert_eq "$([[ "$actual_account" != "$expected_account" ]] && printf red || printf green)" red "control: missing production account turns the selected account assertion red"
  else
    assert_eq "$actual_account" "$expected_account" "$label: production attempt names the selected account"
  fi
  cli_artifact="$ROW/out/out.json"
  [[ "$checked" != union ]] || cli_artifact="${cli_artifact}.claude.json"
  cli_account="$(jq -r '.qa_metadata.account // "none"' "$cli_artifact")"
  expected_cli_account=none
  [[ "$account" == none ]] || expected_cli_account="$H/.${account}claude"
  assert_eq "$cli_account" "$expected_cli_account" "$label: the CLI uses the selected configuration directory"
  assert_eq "$(jq '[.blockers[]] | length > 0' "$ROW/out/out.json")" true "$label: the artifact retains findings"
  if [[ "$checked" == no ]]; then
    assert_eq "$([[ "$actual_account" != .secondclaude ]] && printf red || printf green)" red "control: the account-selection assertion turns red without the room command"
  elif [[ "$checked" == ignore-refusal ]]; then
    assert_eq "$([[ "$reviewer" != my-model && "$(count extra)" == 0 ]] && printf red || printf green)" red "control: ignoring the refusal turns the roster-fallback assertion red"
  elif [[ "$account" == none ]]; then
    assert_eq "$(count claude)" 0 "$label: the refused Claude CLI never runs"
    # This selection diagnostic is the room-check caller's program-readable
    # classification; the existing room table also checks its full record.
    assert_eq "$(grep -c 'skipping claude: room check refused' "$ROW/stderr")" 1 "$label: selection records the room refusal"
  fi
done <<<"$CLAUDE_ROWS"
finish
