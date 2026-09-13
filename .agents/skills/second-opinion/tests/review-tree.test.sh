#!/usr/bin/env bash
# Single and union review producers preserve the starting worktree snapshot.
. "$(dirname "${BASH_SOURCE[0]}")/lib/roster-world.bash"

artifact() {
  jq -c --arg head "$HEAD_SHA" '{head:(.head == $head),dirty_paths}' "$ROW/out/out.json"
}

DEFAULTS="ps:none current:none models:codex+claude count:2 cmd:claude=claude cmd:codex=codex"
expected='{"head":true,"dirty_paths":["file.txt"]}'
ROWS="
single lane starting tree|target:claude|review|0|<out>|single:claude:review:none written|calls=claude:1,codex:0,extra:0 art=$expected files=out
union starting tree|count:2|review|0|<out>|multi:codex+claude:none union:2|calls=claude:1,codex:1,extra:0 art=$expected files=out,out.claude,out.codex
"
run_table "starting snapshot" "$DEFAULTS" "$ROWS"
finish
