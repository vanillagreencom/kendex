#!/usr/bin/env bash
# The multi-lane review: with SECOND_OPINION_COUNT >= 2 the selected lanes run
# on one derived scope and write one union artifact (findings deduplicated by
# location and occurrence with every contributing lane in `sources`, a
# suggestion dropped where a blocker holds its slot, lane artifacts kept beside
# the union); one failed lane degrades coverage loudly, every lane failing
# leaves no artifact and exits in the no-verdict class; a forced target keeps
# the single-lane path; a shortfall against the requested count is stamped.
# One table, a row per scenario.
# shellcheck source=lib/roster-world.bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/roster-world.bash"

# A row's world starts from these: no harness in the process tree, a session
# with no model, the two built-in lanes stubbed, breadth two.
DEFAULTS="ps:none current:none models:codex+claude count:2 cmd:claude=claude cmd:codex=codex"

MULTI="multi:codex+claude:none"

# label|world|command|rc|out|err|calls art files
ROWS="
both lanes answer: the parse blocker is deduped with both lanes in sources, the blocker-covered suggestion is dropped, coverage is full|claude:parse codex:parse-db|review|0|<out>|$MULTI union:2|calls=claude:1,codex:1,extra:0 art=external-union(codex+claude)/action_required/b=parse(claude,codex),query(codex)/s=guide(codex),readme(claude)/cov=full/req=2/sel=2/lanes=codex:ok,claude:ok/dedupe=3/2/3/2/head=head/union=true files=out,out.claude,out.codex
one lane down: the survivor's findings, coverage degraded, the failed lane recorded with its exit code|claude:parse codex:down|review|0|<out>|$MULTI lane-failed:codex:5 union:1|calls=claude:1,codex:1,extra:0 art=external-union(claude)/action_required/b=parse(claude)/s=readme(claude)/cov=degraded/req=2/sel=2/lanes=claude:ok,codex:failed:5/dedupe=1/1/1/1/head=head/union=true files=out,out.claude,out.codex.failed
every lane down: no artifact, exit 5|claude:down codex:down|review|5|-|$MULTI lane-failed:codex:5 lane-failed:claude:5 all-failed:codex:failed:5,claude:failed:5|calls=claude:1,codex:1,extra:0 art=- files=out.claude.failed,out.codex.failed
every lane down clears a stale artifact at the output path|stale claude:down codex:down|review|5|-|$MULTI lane-failed:codex:5 lane-failed:claude:5 all-failed:codex:failed:5,claude:failed:5|calls=claude:1,codex:1,extra:0 art=- files=out.claude.failed,out.codex.failed
lanes that answer unusably, even after the retry, exit 4|claude:junk codex:junk|review|4|-|$MULTI lane-failed:codex:1 lane-failed:claude:1 all-failed:codex:failed:1,claude:failed:1|calls=claude:2,codex:2,extra:0 art=- files=out.claude.raw.txt,out.claude.retry.txt,out.codex.raw.txt,out.codex.retry.txt
a forced target keeps the single-lane path: the lane's own artifact, no sidecars, one opinion requested whatever COUNT says|target:claude|review|0|<out>|single:claude:review:none written|calls=claude:1,codex:0,extra:0 art=external-claude/pass/b=-/s=-/cov=null/req=1/sel=1/lanes=-/dedupe=-/head=head/union=null files=out
a third target is a settings entry: SECOND_OPINION_MODELS names it, its _CMD runs it, its artifact is kept beside the union|models:claude+my-model cmd:my-model=extra|review|0|<out>|multi:claude+my-model:none union:2|calls=claude:1,codex:0,extra:1 art=external-union(claude+my-model)/pass/b=-/s=-/cov=full/req=2/sel=2/lanes=claude:ok,my-model:ok/dedupe=0/0/0/0/head=head/union=true files=out,out.claude,out.my-model
two distinct findings at one location from one lane both survive; the other lane's merges with the first|claude:parse codex:parse2|review|0|<out>|$MULTI union:2|calls=claude:1,codex:1,extra:0 art=external-union(codex+claude)/action_required/b=parse(claude,codex),parse(codex)/s=readme(claude)/cov=full/req=2/sel=2/lanes=codex:ok,claude:ok/dedupe=3/2/1/1/head=head/union=true files=out,out.claude,out.codex
a lane named twice runs once and is recorded once|models:codex,+codex+claude|review|0|<out>|ns:codex:CODEX $MULTI union:2|calls=claude:1,codex:1,extra:0 art=external-union(codex+claude)/pass/b=-/s=-/cov=full/req=2/sel=2/lanes=codex:ok,claude:ok/dedupe=0/0/0/0/head=head/union=true files=out,out.claude,out.codex
hyphen and underscore names share one configuration and run once|models:my-model+my_model+claude cmd:my-model=extra|review|0|<out>|ns:my_model:MY_MODEL multi:my-model+claude:none union:2|calls=claude:1,codex:0,extra:1 art=external-union(my-model+claude)/pass/b=-/s=-/cov=full/req=2/sel=2/lanes=my-model:ok,claude:ok/dedupe=0/0/0/0/head=head/union=true files=out,out.claude,out.my-model
a shortfall against the requested count is stated and stamped on the single lane's artifact as degraded|current:codex|review|0|<out>|same:codex:codex shortfall:2:1 single:claude:review:codex written|calls=claude:1,codex:0,extra:0 art=external-claude/pass/b=-/s=-/cov=degraded/req=2/sel=1/lanes=-/dedupe=-/head=head/union=null files=out
a union short of the requested count is degraded with both lanes answered|count:3|review|0|<out>|shortfall:3:2 $MULTI union:2|calls=claude:1,codex:1,extra:0 art=external-union(codex+claude)/pass/b=-/s=-/cov=degraded/req=3/sel=2/lanes=codex:ok,claude:ok/dedupe=0/0/0/0/head=head/union=true files=out,out.claude,out.codex
"

run_table "the union" "$DEFAULTS" "$ROWS"
finish
