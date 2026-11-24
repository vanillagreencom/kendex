#!/usr/bin/env bash
# The skill-tests workflow step `changelog-entries` holds a pull request to
# the package version rule at merge, whatever commit-guards copy its commits
# passed through. The step's working directory and command are read from the
# workflow and run in a fixture shaped as the job's checkout: the candidate
# tree at a merge commit of the branch into a base that moved, with this
# repository's commit-guards scripts and explicit package settings, and BASE
# at the moved base tip. The workflow's BASE expression is evaluated on a
# merge-group payload.
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

# GitHub hands both endpoints to the job. BASE must start the range.
group='{"github":{"event":{"merge_group":{"base_sha":"group-base","head_sha":"group-head"}}}}'
got="$(gh_eval value "$group" "$BASE_EXPR")"
if [ "$got" = '"group-base"' ]; then
  ok "base: merge_group"
else
  bad "base: merge_group" "expr [$BASE_EXPR] gave [$got], want group-base"
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
# branch is merged into the moved base, as the job's checkout is.
fixture() { # NAME MOVE BRANCH
  R="$TMP_ROOT/$1/$WD"
  mkdir -p "$R/skills/commit-guards" "$R/skills/demo/scripts"
  g -c init.defaultBranch=main init -q
  cp -R "$REPO/skills/commit-guards/scripts" "$R/skills/commit-guards/scripts"
  # The generic package scenarios need their own policy, independent of this
  # repository's program-only release policy.
  cat >"$R/kendex.settings.toml" <<'SETTINGS'
[env]
COMMIT_GUARDS_CHANGELOG_PATHS = "changelog.d/*/*.md changelog.d/*/*/*.md"
COMMIT_GUARDS_CHANGELOG_PACKAGE_PATHS = "skills/*/SKILL.md"
SETTINGS
  printf -- '---\nname: demo\nmetadata:\n  version: "1.0.0"\n---\n\n# Demo\n' >"$R/skills/demo/SKILL.md"
  printf 'echo one\n' >"$R/skills/demo/scripts/run"
  g add -A
  g commit -qm base
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
  BASE="$(g rev-parse HEAD)"
  g merge -q --no-ff -m merge topic
}

run_step() { # COMMAND — sets RC and OUT
  RC=0
  OUT="$(cd "$R" && env -i PATH="$PATH" HOME="$HOME" BASE="$BASE" bash -c "$1" 2>&1)" || RC=$?
}

# NAME | MOVE | BRANCH | EXIT | the record the run must print
while IFS='|' read -r name move branch want record; do
  [ -n "$name" ] || continue
  fixture "$name" "$move" "$branch"
  run_step "$COMMAND"
  if [ "$RC" -eq "$want" ] && grep -qxF -- "$record" <<<"$OUT"; then
    ok "$name"
  else
    bad "$name" "exit $RC: $OUT"
  fi
done <<'ROWS'
unraised|other|change|1|changelog-entries: package-unbumped=skills/demo/SKILL.md:1.0.0
raised|other|raise|0|changelog-entries: checked=1
collision|raise|raise|1|changelog-entries: package-unbumped=skills/demo/SKILL.md:1.0.1
stacked-merge-group|raise|stacked|1|changelog-entries: package-unbumped=skills/demo/SKILL.md:1.0.1
ROWS

printf '\npass: %d   fail: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
