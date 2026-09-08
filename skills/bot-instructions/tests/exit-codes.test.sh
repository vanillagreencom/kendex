#!/usr/bin/env bash
# The exit convention the commit-guards pre-commit lane reads: 0 clean, 1
# findings, 2 could not complete.
#
# The silent misreport: a run that could not answer — git would not run, the
# spec copy is unusable — exiting 1 reads as a violation in the tree, and a
# lane that sorts its verdicts by code files a tool outage under "fix your
# repo". The lane blocks either way; what it tells the operator is wrong.
#
# One table: a world, a verb, the exact status and what the first line names
# (`bi_render` in lib/harness.sh). A crash outside the package's error family
# is the one world no verb reaches from the command line, so it is driven
# in-process below the table.

. "$(dirname "$0")/lib/harness.sh"

# `rendered` is a fresh repo that checks clean; the words after it move it
# off that state: `stale-copilot` appends to a generated file, `no-git`
# deletes the repository, `spec:no-doctrine` names a spec copy whose SKILL.md
# carries a version and no `## Doctrine` section.
bi_world() {
  local word
  repo="$(bi_rendered_repo "exit-$1-$$-$RANDOM")" || return 1
  shift
  for word in "$@"; do
    case "$word" in
      stale-copilot) printf '\nstale\n' >> "$repo/.github/copilot-instructions.md" ;;
      no-git) rm -rf -- "${repo:?}/.git" ;;
      spec:no-doctrine)
        BI_SPEC="$BI_TMP/spec-no-doctrine"
        rm -rf -- "${BI_SPEC:?}"
        mkdir -p "$BI_SPEC/schemas"
        printf -- '---\nmetadata:\n  version: "x"\n---\n\n# no doctrine here\n' > "$BI_SPEC/SKILL.md"
        cp "$BI_ROOT/skills/bot-instructions/schemas/renders.md" "$BI_SPEC/schemas/renders.md"
        ;;
      *) printf 'unknown world word: %s\n' "$word" >&2; return 1 ;;
    esac
  done
}

bi_table "the status, and what the first line names" "\
a clean repo checks with exit 0|rendered|check|0|clean|-
a drift finding exits 1|rendered stale-copilot|check|1|drift|-
git unable to answer exits 2, naming the command that could not|rendered no-git|check|2|git ls-files -z|-
a spec copy with no doctrine source exits 2, naming the file|rendered spec:no-doctrine|check|2|SKILL.md|-
flag misuse exits 2 before any read, naming the flag|rendered|render --staged|2|--staged|-
an unknown verb exits 2 from the parser|rendered|bogus|2|usage|-
"

# A crash is 2 as well: the tool failed, nothing in the tree is wrong, and
# Python's own exit for an uncaught exception is 1. A dispatched dependency
# raising something outside the package's error family reaches the last
# handler, and the traceback still prints.
repo="$(bi_rendered_repo exit-crash)" || exit 1
crash_out="$(cd "$BI_ROOT/skills/bot-instructions/scripts" && python3 - "$repo" <<'PY' 2>&1
import sys
sys.path.insert(0, ".")
from lib import cli, tree
def boom(*args, **kwargs):
    raise RuntimeError("dispatched dependency failed")
tree.open_tree = boom
sys.exit(cli.main(["check", "--repo", sys.argv[1]]))
PY
)" && crash_status=0 || crash_status=$?
if [ "$crash_status" -eq 2 ] && printf '%s\n' "$crash_out" | grep -q 'RuntimeError: dispatched dependency failed'; then
  ok 'a crash outside the package error family exits 2 with its traceback'
else
  bad 'a crash outside the package error family exits 2 with its traceback' \
      "exit $crash_status: $(printf '%s' "$crash_out" | tail -2 | tr '\n' ' ')"
fi

bi_summary
