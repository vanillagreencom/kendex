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
DEFAULTS="ps:none current:claude models:claude+codex+copilot count:1 cmd:claude=claude cmd:codex=codex cmd:copilot=extra model:copilot=gpt-6-astra"

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
finish
