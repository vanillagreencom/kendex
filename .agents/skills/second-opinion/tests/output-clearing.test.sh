#!/usr/bin/env bash
# The output clearing: a run that reaches its output tail (review, audit,
# challenge, quick) first removes what a previous run left at --output and the
# sidecars this mode can write, so a caller continuing past the advisory
# non-zero exit never reads a stale verdict as this run's; a refusal and a
# parse error clear too, detect never writes and so clears nothing. Every
# other path under the prefix is deleted only when it proves to be this
# skill's own review (the schema plus the external- agent marker, which the
# writer stamps): a retired lane's artifact and its family go, the caller's
# files survive whatever their name, a sweep without jq is stated. The
# parent that cannot be created, a directory at --output and an artifact that
# cannot be cleared are named causes, not bare tool errors. One table, a row
# per scenario.
# shellcheck source=lib/stub-cli-world.bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/stub-cli-world.bash"

DEFAULTS="output:out rc:1 stdout:- stderr:quota"

FAILED="out.failed.json=failed(exited with code 1|claude stderr|quota)"
GATE="header:review failed:exit:out:1 cause:stderr preserved:out"
CLEAN="home=absent tmp=0 dirty=-"
NONE="calls=0 files=- $CLEAN"
# the caller's files under the prefix, in the sweep's own (glob) order, `+` where this run's record lands
BYSTANDERS_HEAD="out.anon.json=anon,out.bak=mine,out.correctness.json=foreign,out.data.json=json:?"
BYSTANDERS_TAIL="out.notes.json=mine,out.notes.md=mine,out.orphan-lane.json.raw.txt=stale,out.two.words.json=mine,outX=mine"

# label|world|argv|rc|out|err|calls files home tmp dirty
ROWS="
a provider failure clears the stale artifact, its sidecars and both lane families, and writes only this run's record|plant:family|review|5|-|$GATE|calls=1 files=$FAILED $CLEAN
a same-model refusal clears the family before any invocation|plant:family target:- current:claude models:claude+codex lane:codex env:SECOND_OPINION_CODEX_MODEL=claude|review|1|-|same:claude:claude same:codex:claude refused:claude:both|$NONE
an invalid --timeout clears the family too|plant:family|review --timeout=abc|1|-|timeout-invalid|$NONE
an unknown flag clears the family too|plant:family|review --bogus|1|-|bogus|$NONE
a retired lane's artifact and its family are reclaimed; every bystander under the prefix survives byte-identical, an orphaned sidecar included|plant:retired plant:bystanders|review|5|-|$GATE|calls=1 files=$BYSTANDERS_HEAD,$FAILED,$BYSTANDERS_TAIL $CLEAN
a bad-flag run still reclaims a retired lane and still destroys no bystander|plant:retired plant:bystanders|review --bogus|1|-|bogus|calls=0 files=$BYSTANDERS_HEAD,$BYSTANDERS_TAIL $CLEAN
a dash-leading --output is cleared and swept, its bystander kept|output:dash plant:stale plant:ours:retired-model.json plant:mine:bak|review|5|-|$GATE|calls=1 files=out.bak=mine,$FAILED $CLEAN
glob metacharacters in --output match literally in the sweep|output:glob plant:stale plant:ours:retired-model.json plant:mine:bak|review|5|-|$GATE|calls=1 files=out.bak=mine,$FAILED $CLEAN
a dash-leading (relative) TMPDIR leaves no temp files behind; the class is kept, though the relative path is lost after the script's own cd and the CLI never runs|tmpdir:dash|review|5|-|header:review dashtmp-lost failed:exit:out:1 preserved:out|calls=0 files=out.failed.json=failed(exited with code 1|-|-) home=absent tmp=0 dashtmp=0 dirty=-
a failing quick run leaves no stale answer at --output; a roster-named sibling and the five sidecar names, the caller's here, survive|plant:previous plant:mine:claude.json plant:sidecars-mine|quick|1|-|header:quick generic:exit:1|calls=1 files=out.claude.json=mine,out.failed.json=mine,out.incomplete.json=mine,out.noreview.json=mine,out.raw.txt=mine,out.retry.txt=mine $CLEAN
a failing challenge run likewise|plant:previous plant:mine:claude.json plant:sidecars-mine|challenge|1|-|header:challenge generic:exit:1|calls=1 files=out.claude.json=mine,out.failed.json=mine,out.incomplete.json=mine,out.noreview.json=mine,out.raw.txt=mine,out.retry.txt=mine $CLEAN
a quick refusal, which never reaches the CLI, clears --output too|plant:previous target:- current:claude models:claude|quick|1|-|same:claude:claude refused:claude:claude|$NONE
a challenge refusal likewise|plant:previous target:- current:claude models:claude|challenge|1|-|same:claude:claude refused:claude:claude|$NONE
control: a successful quick run writes the fresh answer to --output|plant:previous rc:0 stdout:answer|quick|0|<out>|header:quick written|calls=1 files=out=answer $CLEAN
detect has no output slot and clears nothing|plant:previous|detect|0|claude|-|calls=0 files=out=previous $CLEAN
audit clears its own slot, keeps a roster-named sibling holding the caller's data, and reclaims one carrying our marker|plant:stale plant:mine:claude.json plant:ours:ours.json|audit|5|-|header:audit failed:exit:out:1 cause:stderr preserved:out|calls=1 files=out.claude.json=mine,$FAILED $CLEAN
a response with a null agent is written with this skill's own marker, the rest untouched|rc:0 stdout:agent-null|review|0|<out>|header:review written|calls=1 files=out=review:external-claude:provider text $CLEAN
a response with a foreign agent is stamped the same way|rc:0 stdout:agent-foreign|review|0|<out>|header:review written|calls=1 files=out=review:external-claude:provider text $CLEAN
a stamped artifact is reclaimed once its target has left the roster|plant:stamped-retired|review|5|-|$GATE|calls=1 files=$FAILED $CLEAN
at COUNT=1 a roster-named sibling holding user data survives, the same name carrying our marker is reclaimed|plant:mine:codex.json plant:ours:claude.json|review|5|-|$GATE|calls=1 files=out.codex.json=mine,$FAILED $CLEAN
a multi-lane run clears the lane paths it is about to write, unconditionally|plant:text:lane-a.json target:- models:lane-a+lane-b count:2 lane:lane-a lane:lane-b rc:0 stdout:stale|review|0|<out>|multi:lane-a+lane-b union:2|calls=2 files=out=review:external-union(lane-a+lane-b):union,out.lane-a.json=review:external-lane-a:STALE ARTIFACT FROM A PREVIOUS RUN,out.lane-b.json=review:external-lane-b:STALE ARTIFACT FROM A PREVIOUS RUN $CLEAN
control: a successful run over a stale artifact replaces it|plant:stale rc:0 stdout:good|review|0|<out>|header:review written|calls=1 files=out=review:external-claude:Clean $CLEAN
an uncreatable --output parent is a named pre-flight error carrying mkdir's reason, before any CLI|output:ro-parent|review|1|-|parent-error|calls=0 files=ro=dir $CLEAN
a directory at --output is a named error, not a bare rm error|output:dir|review|1|-|output-dir|calls=0 files=out=dir $CLEAN
an unclearable previous artifact is a named cause carrying the path and rm's reason|output:ro-dir|review|1|-|clear-error|calls=0 files=ro=dir $CLEAN
without jq the designated output is still cleared, the skipped sweep is stated, and a sibling is left alone|nojq plant:previous plant:ours:retired.json|review|1|-|no-jq|calls=0 files=out.retired.json=stale $CLEAN
"

run_table "the output clearing" "$DEFAULTS" "$ROWS"
finish
