#!/usr/bin/env bash
# The skill-tests workflow step `changelog-entries` holds a pull request to
# the package version rule at merge, whatever commit-guards copy its commits
# passed through. The step's working directory and command are read from the
# workflow and run in a fixture shaped as the job's checkout: the candidate
# tree at a merge commit of the branch into a base that moved, with this
# repository's commit-guards scripts and settings, and BASE at the base tip,
# or at the branch point for the pull request run of a stacked branch. The
# step's BASE expression is read from the workflow too and evaluated on a
# pull request's and a merge group's payload, the two events
# tools/tests/ci-aggregate.test.sh holds the step to running on.
set -euo pipefail
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORKFLOW="$REPO/.github/workflows/skill-tests.yml"

TMP_ROOT="$(mktemp -d)" || { echo "changelog-entries-ci: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "changelog-entries-ci: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "changelog-entries-ci: scratch=resolve-failed" >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; [ $# -lt 2 ] || printf '        %s\n' "$2"; }

# shellcheck source=../../skills/harness-ci/tests/lib/workflow.sh
. "$REPO/skills/harness-ci/tests/lib/workflow.sh"
[ -f "$GH_EVAL" ] || { echo "changelog-entries-ci: evaluator=missing path=$GH_EVAL" >&2; exit 1; }

step="$(awk '
  $1 == "-" && $2 == "id:" && $3 == "changelog-entries" { selected = 1; next }
  selected && $1 == "-" { exit 1 }
  selected && $1 == "working-directory:" { wd = $2 }
  selected && $1 == "BASE:" {
    base = $0
    sub(/^[[:space:]]*BASE:[[:space:]]*/, "", base)
    if (substr(base, 1, 3) == "${{") { base = substr(base, 4); sub(/}}[[:space:]]*$/, "", base) }
  }
  selected && $1 == "run:" { sub(/^[[:space:]]*run:[[:space:]]*/, ""); print wd "\t" base "\t" $0; found++; selected = 0 }
  END { if (found != 1) exit 1 }
' "$WORKFLOW")" || { echo "changelog-entries-ci: step=unreadable workflow=$WORKFLOW" >&2; exit 1; }
WD="${step%%$'\t'*}"
rest="${step#*$'\t'}"
BASE_EXPR="${rest%%$'\t'*}"
COMMAND="${rest#*$'\t'}"
[ -n "$WD" ] && [ -n "$BASE_EXPR" ] && [ -n "$COMMAND" ] ||
  { echo "changelog-entries-ci: step=incomplete value=[$step]" >&2; exit 1; }

# EVENT | the event payload GitHub sends | its base
# Each payload carries both a base and a head commit; BASE must be the base,
# the commit the range starts from.
BASE_ROWS='pull_request|{"github":{"event":{"pull_request":{"base":{"sha":"pr-base"},"head":{"sha":"pr-head"}}}}}|pr-base
merge_group|{"github":{"event":{"merge_group":{"base_sha":"group-base","head_sha":"group-head"}}}}|group-base'

base_ok() { # EXPR CONTEXT BASE — sets GOT
  GOT="$(gh_eval value "$2" "$1")"
  [ "$GOT" = "\"$3\"" ]
}

while IFS='|' read -r event context base; do
  if base_ok "$BASE_EXPR" "$context" "$base"; then
    ok "base: $event"
  else
    bad "base: $event" "expr [$BASE_EXPR] gave [$GOT], want \"$base\""
  fi
done <<<"$BASE_ROWS"

# Control: the same expression reading the head fields fails each row.
HEAD_EXPR="${BASE_EXPR//.base.sha/.head.sha}"
swapped_pr="$HEAD_EXPR"
HEAD_EXPR="${HEAD_EXPR//.base_sha/.head_sha}"
if [ "$swapped_pr" = "$BASE_EXPR" ] || [ "$HEAD_EXPR" = "$swapped_pr" ]; then
  bad "control: the head fields fail the base rows" "substitution changed nothing in [$BASE_EXPR]"
else
  while IFS='|' read -r event context base; do
    if base_ok "$HEAD_EXPR" "$context" "$base"; then
      bad "control: the head fields fail the base rows: $event" "expr [$HEAD_EXPR] gave [$GOT]"
    else
      ok "control: the head fields fail the base rows: $event"
    fi
  done <<<"$BASE_ROWS"
fi

g() { git -C "$R" -c user.email=test@example.com -c user.name=test "$@"; }

# The versioned package's two changes. The parent's raise adds a script, the
# branch's own change edits another, so a base and a branch can each carry
# one and merge cleanly.
parent_raise() {
  printf 'echo extra\n' >"$R/skills/demo/scripts/extra"
  sed 's/"1.0.0"/"1.0.1"/' "$R/skills/demo/SKILL.md" >"$R/skills/demo/SKILL.md.new"
  mv "$R/skills/demo/SKILL.md.new" "$R/skills/demo/SKILL.md"
  mkdir -p "$R/changelog.d/demo/fixed"
  printf -- '- Demo runs its extra step.\n' >"$R/changelog.d/demo/fixed/demo-extra.md"
  g add -A
  g commit -qm "raise demo"
}
change_run() { # RAISE
  printf 'echo two\n' >"$R/skills/demo/scripts/run"
  if [ "$1" = yes ]; then
    sed 's/"1.0.0"/"1.0.1"/' "$R/skills/demo/SKILL.md" >"$R/skills/demo/SKILL.md.new"
    mv "$R/skills/demo/SKILL.md.new" "$R/skills/demo/SKILL.md"
    mkdir -p "$R/changelog.d/demo/fixed"
    printf -- '- Demo prints two.\n' >"$R/changelog.d/demo/fixed/demo-two.md"
  fi
  g add -A
  g commit -qm "change demo"
}

# A base holding one versioned package at 1.0.0, and a branch cut from it.
# The base then moves, MOVE: `other` adds an unrelated file, `raise` lands
# the parent's raise. The branch, BRANCH: `change` edits the package with no
# raise, `raise` edits it and raises it to 1.0.1, `stacked` carries the
# parent's raise and then edits the package with no raise of its own. The
# branch is merged into the moved base, as the job's checkout is. CUT is the
# branch point, MOVED the moved base.
fixture() { # NAME MOVE BRANCH
  R="$TMP_ROOT/$1/$WD"
  mkdir -p "$R/skills/commit-guards" "$R/skills/demo/scripts"
  g -c init.defaultBranch=main init -q
  cp -R "$REPO/skills/commit-guards/scripts" "$R/skills/commit-guards/scripts"
  cp "$REPO/kendex.settings.toml" "$R/kendex.settings.toml"
  printf -- '---\nname: demo\nmetadata:\n  version: "1.0.0"\n---\n\n# Demo\n' >"$R/skills/demo/SKILL.md"
  printf 'echo one\n' >"$R/skills/demo/scripts/run"
  g add -A
  g commit -qm base
  CUT="$(g rev-parse HEAD)"
  g checkout -qb topic
  case "$3" in
    change) change_run no ;;
    raise) change_run yes ;;
    stacked) parent_raise && change_run no ;;
  esac
  g checkout -q main
  case "$2" in
    other)
      printf 'elsewhere\n' >"$R/other.txt"
      g add -A
      g commit -qm "base moves"
      ;;
    raise) parent_raise ;;
  esac
  MOVED="$(g rev-parse HEAD)"
  g merge -q --no-ff -m merge topic
}

run_step() { # COMMAND — sets RC and OUT
  RC=0
  OUT="$(cd "$R" && env -i PATH="$PATH" HOME="$HOME" BASE="$BASE" bash -c "$1" 2>&1)" || RC=$?
}

# NAME | MOVE | BRANCH | BASE | EXIT | the record the run must print
# The stacked pair is one pull request's two runs over one tree: its pull
# request run before the parent merged, BASE at the branch point, and its
# merge group after, BASE at the base the parent's raise moved. The second
# fails where the first passed, which is why tools/ci-job-set lets no proof
# from the first stand this step's job down in the second.
while IFS='|' read -r name move branch at want record; do
  [ -n "$name" ] || continue
  fixture "$name" "$move" "$branch"
  case "$at" in
    cut) BASE="$CUT" ;;
    moved) BASE="$MOVED" ;;
  esac
  run_step "$COMMAND"
  if [ "$RC" -eq "$want" ] && grep -qxF -- "$record" <<<"$OUT"; then
    ok "$name"
  else
    bad "$name" "exit $RC: $OUT"
  fi
done <<'ROWS'
unraised|other|change|moved|1|changelog-entries: package-unbumped=skills/demo/SKILL.md:1.0.0
raised|other|raise|moved|0|changelog-entries: checked=1
collision|raise|raise|moved|1|changelog-entries: package-unbumped=skills/demo/SKILL.md:1.0.1
stacked-pull-request|raise|stacked|cut|0|changelog-entries: checked=1
stacked-merge-group|raise|stacked|moved|1|changelog-entries: package-unbumped=skills/demo/SKILL.md:1.0.1
ROWS

# The stacked pair's premise: the pull request's own merge into the branch
# point, its branch tip, has the merge group's tree, the key a proof is
# found by.
R="$TMP_ROOT/stacked-merge-group/$WD"
if [ "$(g rev-parse 'topic^{tree}')" = "$(g rev-parse 'HEAD^{tree}')" ]; then
  ok "stacked: the merge group tests the pull request's tree"
else
  bad "stacked: the merge group tests the pull request's tree"
fi

# Control: the commit chain's own scope, the index against HEAD, sees nothing
# of the merged branch, so the unraised row is red only through the range.
R="$TMP_ROOT/unraised/$WD"
run_step "${COMMAND/--base \"\$BASE\"/--staged}"
if [ "$COMMAND" != "${COMMAND/--base \"\$BASE\"/--staged}" ] && [ "$RC" -eq 0 ]; then
  ok "control: without the range the unraised change passes"
else
  bad "control: without the range the unraised change passes" "exit $RC: $OUT"
fi

printf '\npass: %d   fail: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
