#!/usr/bin/env bash
# Multi-lane scratch durability and lane-artifact handling: the parent creates
# exactly one directory under TMPDIR and everything in it is disposable, so
# losing it mid-run costs the stderr replay and nothing else, in --output and
# stdout mode alike; a healthy lane's log and a failing lane's own cause reach
# the operator lane-prefixed; an artifact is usable only when it holds exactly
# one JSON object shaped the way the merge consumes it, every other shape
# being that lane answering unusably (exit 4, coverage degraded, the union
# still shipped) and never a healthy lane contributing nothing; a lane that
# exits 0 without an artifact never answered (5), which keeps the all-lanes-
# failed aggregate at 5 unless somebody answered unusably (4); lane artifacts
# and sidecars in the home are owner-only while live and gone after, the CLI's
# own files keep the caller's umask; a cleanup that cannot unlink an entry
# never changes the run's exit status. One table, a row per scenario; every
# row is a two-lane review (roster codex claude, count 2).
# shellcheck source=lib/lane-world.bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/lane-world.bash"

DEFAULTS="output:out claude:answer:claude codex:answer:codex"

# the two healthy lanes, and the union they make
BOTH="external-union(codex+claude)/action_required/b=parse/cov=full/lanes=codex:ok,claude:ok"
# a sabotaged claude lane beside a codex lane carrying its own blocker
CLAUDE_LOST="external-union(codex)/action_required/b=get/cov=degraded/lanes=codex:ok,claude:failed:4"
# a failing codex lane beside the healthy claude lane
CODEX_LOST="external-union(claude)/action_required/b=parse/cov=degraded/lanes=claude:ok,codex:failed:5"
OUT_ALL="out(644),out.claude(600),out.codex(600)"
# --output mode never resolves the home; stdout mode leaves it empty
CLEAN="home=absent scratch=-"
CLEAN_HOME="home=- scratch=-"

# label|world|rc|out|err|relay art files home scratch [state probe]
ROWS="
scratch removed mid-run in --output mode: the union is still written with both lanes, coverage full, only the replay lost|codex:reap|0|<out>|header replay-lost:codex replay-lost:claude union:2|relay=codex:-,claude:- art=$BOTH files=$OUT_ALL $CLEAN
scratch removed mid-run in stdout mode: the union is still printed with both lanes' findings, nothing left behind|output:- codex:reap:wait|0|json|header replay-lost:codex replay-lost:claude|relay=codex:-,claude:- art=$BOTH files=- $CLEAN_HOME
a lane that exits 0 with its artifact gone never answered: exit 5 in the stamp, named on stderr, the count drops it|codex:sabotage:steal:0|0|<out>|header no-artifact:claude lane-failed:claude:5 union:1|relay=codex:written,claude:written art=external-union(codex)/action_required/b=get/cov=degraded/lanes=codex:ok,claude:failed:5 files=out(644),out.codex(600) $CLEAN
a zero-byte artifact is no answer at all: never-answered (5), not answered-unusably|codex:sabotage:empty:0|0|<out>|header no-artifact:claude lane-failed:claude:5 union:1|relay=codex:written,claude:written art=external-union(codex)/action_required/b=get/cov=degraded/lanes=codex:ok,claude:failed:5 files=$OUT_ALL $CLEAN
a whitespace-only artifact holds no JSON value: that lane answered unusably (4), the surviving blocker ships|codex:sabotage:blank:0|0|<out>|header unusable:claude:novalue lane-failed:claude:4 union:1|relay=codex:written,claude:written art=$CLAUDE_LOST files=$OUT_ALL $CLEAN
every lane fails and none answered: exit 5, no artifact|codex:sabotage:steal:1|5|-|header lane-failed:codex:5 no-artifact:claude lane-failed:claude:5 all-failed:5:5|relay=codex:failed,claude:written art=- files=out.codex.failed.json(600) $CLEAN
every lane fails and one answered unusably: exit 4|codex:sabotage:blank:1|4|-|header lane-failed:codex:5 unusable:claude:novalue lane-failed:claude:4 all-failed:5:4|relay=codex:failed,claude:written art=- files=out.claude(600),out.codex.failed.json(600) $CLEAN
two healthy lanes over a stale 0644 lane family: both logs replayed, the lane artifacts owner-only, the stale sidecar gone, the caller's file kept|stale:family|0|<out>|header union:2|relay=codex:written,claude:written art=$BOTH files=out(644),out.claude(600),out.codex(600),out.codex.notes(644) $CLEAN
a failing lane's own cause text reaches the parent, lane-prefixed|codex:fail:QUOTA-EXCEEDED-XYZ:1|0|<out>|header lane-failed:codex:5 union:1|relay=codex:failed:QUOTA-EXCEEDED-XYZ,claude:written art=$CODEX_LOST files=out(644),out.claude(600),out.codex.failed.json(600) $CLEAN
a lane child killed by a signal is recorded killed, not failed; the survivor keeps the run at exit 0|codex:kill|0|<out>|header lane-killed:codex:SIGTERM:143 union:1|relay=codex:-,claude:written art=external-union(claude)/action_required/b=parse/cov=degraded/lanes=claude:ok,codex:killed:143 files=out(644),out.claude(600) $CLEAN
a lane whose CLI died to a signal is recorded killed by the child's own classification, its record beside the output|codex:die|0|<out>|header lane-cli-killed:codex:6 union:1|relay=codex:killed:killed from outside,claude:written art=external-union(claude)/action_required/b=parse/cov=degraded/lanes=claude:ok,codex:killed:6 files=out(644),out.claude(600),out.codex.failed.json(600) $CLEAN
every lane killed: exit 6 outranks the plain lane failure, no artifact|codex:kill claude:kill|6|-|header lane-killed:codex:SIGTERM:143 lane-killed:claude:SIGTERM:143 all-killed:143:143|relay=codex:-,claude:- art=- files=- $CLEAN
a finding that is not an object: that lane is unusable, the healthy lane's own finding ships|codex:sabotage:poison:0|0|<out>|header unusable:claude:nonobject lane-failed:claude:4 union:1|relay=codex:written,claude:written art=$CLAUDE_LOST files=$OUT_ALL $CLEAN
a truncated artifact reports jq's own reason, not the fallback|codex:sabotage:trunc:0|0|<out>|header unusable:claude:unfinished lane-failed:claude:4 union:1|relay=codex:written,claude:written art=$CLAUDE_LOST files=$OUT_ALL $CLEAN
stdout-mode sidecars are owner-only while live and gone after|output:- claude:probe-perms codex:answer:prose|0|json|header lane-failed:codex:1|relay=codex:raw-preserved,claude:written art=external-union(claude)/action_required/b=parse/cov=degraded/lanes=claude:ok,codex:failed:1 files=- $CLEAN_HOME probe=-
a cleanup that cannot unlink a planted entry still exits 0 with the union delivered|output:- codex:plant-dir|0|json|header rm-isdir:review-lane-claude.*.evil|relay=codex:written,claude:written art=$BOTH files=- home=review-lane-claude.*.evil(755) scratch=-
gate: a suggestion that is not an object|codex:sabotage:poison-sugg:0|0|<out>|header unusable:claude:sugg lane-failed:claude:4 union:1|relay=codex:written,claude:written art=$CLAUDE_LOST files=$OUT_ALL $CLEAN
gate: a blocker with a non-string location|codex:sabotage:bad-loc:0|0|<out>|header unusable:claude:loc lane-failed:claude:4 union:1|relay=codex:written,claude:written art=$CLAUDE_LOST files=$OUT_ALL $CLEAN
gate: questions that are not an array|codex:sabotage:bad-questions:0|0|<out>|header unusable:claude:questions lane-failed:claude:4 union:1|relay=codex:written,claude:written art=$CLAUDE_LOST files=$OUT_ALL $CLEAN
gate: a summary that is not a string|codex:sabotage:bad-summary:0|0|<out>|header unusable:claude:summary lane-failed:claude:4 union:1|relay=codex:written,claude:written art=$CLAUDE_LOST files=$OUT_ALL $CLEAN
gate: a newline-only artifact reaches the gate as no JSON value, not as nothing there|codex:sabotage:newline:0|0|<out>|header unusable:claude:novalue lane-failed:claude:4 union:1|relay=codex:written,claude:written art=$CLAUDE_LOST files=$OUT_ALL $CLEAN
gate: a single NUL is an answer the bytes refuse, with the parse error they earn|codex:sabotage:nul:0|0|<out>|header unusable:claude:numeric lane-failed:claude:4 union:1|relay=codex:written,claude:written art=$CLAUDE_LOST files=$OUT_ALL $CLEAN
gate: a complete review with a NUL appended is refused, not read through a shell string as healthy|codex:sabotage:nul-tail:0|0|<out>|header unusable:claude:numeric lane-failed:claude:4 union:1|relay=codex:written,claude:written art=$CLAUDE_LOST files=$OUT_ALL $CLEAN
gate: a directory in the artifact's place passes the size test and can never be read, so it is answered-unusably|fs:dirsize codex:sabotage:unread:0|0|<out>|header unusable:claude:numeric lane-failed:claude:4 union:1|relay=codex:written,claude:written art=$CLAUDE_LOST files=out(644),out.claude(755),out.codex(600) $CLEAN
gate: two concatenated reviews are one lane trying to be two|codex:sabotage:double:0|0|<out>|header unusable:claude:two lane-failed:claude:4 union:1|relay=codex:written,claude:written art=$CLAUDE_LOST files=$OUT_ALL $CLEAN
an unremovable entry inside the scratch directory: exit 0, the artifact cleanup below the failing removal still runs|output:- mode:deny codex:plant-locked|0|json|header rm-denied:locked/inner|relay=codex:written,claude:written art=$BOTH files=- home=- scratch=second-opinion.*,second-opinion.*/locked,second-opinion.*/locked/inner
a bare dash-leading --output in the = form works end to end, parent and lanes|output:dash|0|<out>|header union:2|relay=codex:written,claude:written art=$BOTH files=$OUT_ALL $CLEAN
an unusable stderr capture costs the log, never the lane|capture:blocked|0|<out>|header capture-lost:claude replay-lost:claude union:2|relay=codex:written,claude:- art=$BOTH files=$OUT_ALL $CLEAN
a reaper unlinking temp files mid-run in stdout mode: the union intact, the replay is what it cost|output:- codex:reap-files:scratch|0|json|header replay-lost:codex replay-lost:claude|relay=codex:-,claude:- art=$BOTH files=- $CLEAN_HOME
control: the same reaper pointed at the artifact home does cost that lane, loudly|output:- codex:reap-files:home|0|json|header no-artifact:claude lane-failed:claude:5|relay=codex:written,claude:written art=external-union(codex)/pass/b=-/cov=degraded/lanes=codex:ok,claude:failed:5 files=- $CLEAN_HOME
lane artifacts are owner-only through a reappeared inode; the CLI's own session and cache keep the caller's umask|claude:cli-state:multi-claude:reappear codex:cli-state:multi-codex:reappear|0|<out>|header union:2|relay=codex:written,claude:written art=$BOTH files=$OUT_ALL $CLEAN state=multi-claude.cache(755),multi-claude.session(644),multi-codex.cache(755),multi-codex.session(644)
control: single-lane leaves the CLI's files and the caller's --output at the caller's umask|single codex:cli-state:single|0|<out>|header:single written|relay=codex:-,claude:- art=external-codex/pass/b=-/cov=null/lanes=- files=out(644) $CLEAN state=single.cache(755),single.session(644)
a home that exists but denies writes: both lanes fall back, the home is dropped after the first refusal, the union ships|output:- home:ro|0|json|header home-unusable|relay=codex:written,claude:written art=$BOTH files=- home=absent scratch=-
"

run_table "multi-lane scratch durability" "$DEFAULTS" "$ROWS"
finish
