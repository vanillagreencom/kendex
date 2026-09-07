#!/usr/bin/env bash
# Option parsing: a caller-supplied value beginning with '-' is accepted in
# the `=` form and reaches its consumer intact (--prompt lands in cat, --cwd
# is canonicalized once); a split-form option must be followed by a value, so
# a following flag or the end of argv is a named parse error rather than a
# swallowed option, for every split-form option. One table, a row per
# scenario.
# shellcheck source=lib/stub-cli-world.bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/stub-cli-world.bash"

DEFAULTS="output:- rc:0 stdout:good stderr:-"

NONE="calls=0 files=- home=absent tmp=0 dirty=-"

# label|world|argv|rc|out|err|calls files home tmp dirty
ROWS="
dash-leading --prompt and --cwd in the = form are accepted and the prompt reaches the CLI intact|cwd:dash|quick --prompt=-dash-prompt.txt --cwd=-dashcwd|0|prompt-echoed|header:quick|calls=1 files=- home=absent tmp=0 dirty=-
--timeout followed by --output does not swallow it: a parse error, and the caller's file at that path is untouched|plant:report|review --timeout --output @out|1|-|requires:--timeout|calls=0 files=out=mine home=absent tmp=0 dirty=-
--prompt followed by a flag is rejected|-|review --prompt --range HEAD|1|-|requires:--prompt|$NONE
--prompt at the end of argv is rejected|-|review --prompt|1|-|requires:--prompt|$NONE
--output followed by a flag is rejected|-|review --output --range HEAD|1|-|requires:--output|$NONE
--output at the end of argv is rejected|-|review --output|1|-|requires:--output|$NONE
--target followed by a flag is rejected|-|review --target --range HEAD|1|-|requires:--target|$NONE
--target at the end of argv is rejected|-|review --target|1|-|requires:--target|$NONE
--provider followed by a flag is rejected|-|review --provider --range HEAD|1|-|requires:--provider|$NONE
--provider at the end of argv is rejected|-|review --provider|1|-|requires:--provider|$NONE
--range followed by a flag is rejected|-|review --range --range HEAD|1|-|requires:--range|$NONE
--range at the end of argv is rejected|-|review --range|1|-|requires:--range|$NONE
--cwd followed by a flag is rejected|-|review --cwd --range HEAD|1|-|requires:--cwd|$NONE
--cwd at the end of argv is rejected|-|review --cwd|1|-|requires:--cwd|$NONE
--timeout followed by a flag is rejected|-|review --timeout --range HEAD|1|-|requires:--timeout|$NONE
--timeout at the end of argv is rejected|-|review --timeout|1|-|requires:--timeout|$NONE
"

run_table "option parsing" "$DEFAULTS" "$ROWS"
finish
