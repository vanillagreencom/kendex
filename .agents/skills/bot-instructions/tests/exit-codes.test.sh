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
git unable to answer exits 2 under the source key|rendered no-git|check|2|source|-
a spec copy with no doctrine source exits 2 under the spec key|rendered spec:no-doctrine|check|2|spec|-
flag misuse exits 2 before any read, under the usage key|rendered|render --staged|2|usage|--staged
an unknown verb exits 2 from the parser under the usage key|rendered|bogus|2|usage|-
"

# A row renders the key, so the value beside it is asserted here, on a world
# whose paths this case knows. One record, one line, key and value.
repo="$(bi_rendered_repo exit-record)" || exit 1
rm -rf -- "${repo:?}/.git"
record="$( ( cd "$BI_ROOT/skills/bot-instructions/scripts" \
  && python3 -m lib.main check --repo "$repo" ) 2>&1 >/dev/null || : )"
first="$(printf '%s\n' "$record" | sed -n '1p')"
if [ "$first" = "bot-instructions: source=$repo" ]; then
  ok 'the refusal record names the key and the repository it was about'
else
  bad 'the refusal record names the key and the repository it was about' "first line: $first"
fi
count="$(printf '%s\n' "$record" | grep -c '^bot-instructions: ' || :)"
if [ "$count" = 1 ]; then
  ok 'one condition prints one record'
else
  bad 'one condition prints one record' "printed $count"
fi

# Each branch below computes its own value, so each is pinned exactly:
# the whole first line and the status, not a fragment.
bi_record() { # -> the first line of a run's stderr, in $bi_first
  bi_first="$(printf '%s\n' "$1" | sed -n '1p')"
}

exact() { # LABEL EXPECTED-FIRST-LINE ACTUAL-FIRST-LINE ACTUAL-STATUS EXPECTED-STATUS
  if [ "$3" = "$2" ] && [ "$4" = "$5" ]; then
    ok "$1"
  else
    bad "$1" "first line: $3 (exit $4)"
  fi
}

# spec: its value is the spec root, chosen by a different branch than the repo.
spec_repo="$(bi_rendered_repo exit-spec-value)" || exit 1
spec_dir="$BI_TMP/spec-value-empty"
rm -rf -- "${spec_dir:?}"
mkdir -p "$spec_dir/schemas"
printf -- '---\nmetadata:\n  version: "x"\n---\n\n# no doctrine\n' > "$spec_dir/SKILL.md"
cp "$BI_ROOT/skills/bot-instructions/schemas/renders.md" "$spec_dir/schemas/renders.md"
status=0
out="$( ( cd "$BI_ROOT/skills/bot-instructions/scripts" \
  && python3 -m lib.main check --repo "$spec_repo" --spec "$spec_dir" ) 2>&1 >/dev/null )" || status=$?
bi_record "$out"
exact 'the spec record names the spec root, not the repository' \
  "bot-instructions: spec=$spec_dir" "$bi_first" "$status" 2

# usage: argparse exits before the handlers, so its own record is asserted.
status=0
out="$( ( cd "$BI_ROOT/skills/bot-instructions/scripts" \
  && python3 -m lib.main bogus ) 2>&1 >/dev/null )" || status=$?
bi_record "$out"
exact 'an unknown verb refuses with the usage record naming it' \
  "bot-instructions: usage=bogus" "$bi_first" "$status" 2

# usage: the flag-misuse branch, whose value is the flag.
status=0
out="$( ( cd "$BI_ROOT/skills/bot-instructions/scripts" \
  && python3 -m lib.main render --staged --repo "$spec_repo" ) 2>&1 >/dev/null )" || status=$?
bi_record "$out"
exact 'flag misuse refuses with the usage record naming the flag' \
  "bot-instructions: usage=--staged" "$bi_first" "$status" 2

# findings: the value is the count, which no other case pins.
drift_repo="$(bi_rendered_repo exit-findings-count)" || exit 1
printf '\nstale\n' >> "$drift_repo/.github/copilot-instructions.md"
status=0
out="$( ( cd "$BI_ROOT/skills/bot-instructions/scripts" \
  && python3 -m lib.main check --repo "$drift_repo" ) 2>&1 >/dev/null )" || status=$?
bi_record "$out"
exact 'the findings record carries the count and exits 1' \
  "bot-instructions: findings=1" "$bi_first" "$status" 1

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
