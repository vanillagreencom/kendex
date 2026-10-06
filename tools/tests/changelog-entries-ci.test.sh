#!/usr/bin/env bash
# The skill-tests workflow step `changelog-entries` holds a pull request to
# the package version rule at merge, whatever commit-guards copy its commits
# passed through. The step's working directory and command are read from the
# workflow and run in a fixture shaped as the job's checkout: the candidate
# tree at a merge commit of the branch into a base that moved, with this
# repository's commit-guards scripts and settings, and BASE at the base tip.
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

step="$(awk '
  $1 == "-" && $2 == "id:" && $3 == "changelog-entries" { selected = 1; next }
  selected && $1 == "-" { exit 1 }
  selected && $1 == "working-directory:" { wd = $2 }
  selected && $1 == "run:" { sub(/^[[:space:]]*run:[[:space:]]*/, ""); print wd "\t" $0; found++; selected = 0 }
  END { if (found != 1) exit 1 }
' "$WORKFLOW")" || { echo "changelog-entries-ci: step=unreadable workflow=$WORKFLOW" >&2; exit 1; }
WD="${step%%$'\t'*}"
COMMAND="${step#*$'\t'}"
[ -n "$WD" ] && [ -n "$COMMAND" ] || { echo "changelog-entries-ci: step=incomplete value=[$step]" >&2; exit 1; }

g() { git -C "$R" -c user.email=test@example.com -c user.name=test "$@"; }

# A base holding one versioned package, and a branch whose one commit changes
# it, raising its version or not as the row says. The base moves after the
# branch is cut, and the branch is merged into it, as the job's checkout is.
fixture() { # NAME RAISE
  R="$TMP_ROOT/$1/$WD"
  mkdir -p "$R/skills/commit-guards" "$R/skills/demo/scripts"
  g -c init.defaultBranch=main init -q
  cp -R "$REPO/skills/commit-guards/scripts" "$R/skills/commit-guards/scripts"
  cp "$REPO/kendex.settings.toml" "$R/kendex.settings.toml"
  printf -- '---\nname: demo\nmetadata:\n  version: "1.0.0"\n---\n\n# Demo\n' >"$R/skills/demo/SKILL.md"
  printf 'echo one\n' >"$R/skills/demo/scripts/run"
  g add -A
  g commit -qm base
  g checkout -qb topic
  printf 'echo two\n' >"$R/skills/demo/scripts/run"
  if [ "$2" = yes ]; then
    sed 's/"1.0.0"/"1.0.1"/' "$R/skills/demo/SKILL.md" >"$R/skills/demo/SKILL.md.new"
    mv "$R/skills/demo/SKILL.md.new" "$R/skills/demo/SKILL.md"
    mkdir -p "$R/changelog.d/demo/fixed"
    printf -- '- Demo prints two.\n' >"$R/changelog.d/demo/fixed/demo-two.md"
  fi
  g add -A
  g commit -qm "change demo"
  g checkout -q main
  printf 'elsewhere\n' >"$R/other.txt"
  g add -A
  g commit -qm "base moves"
  BASE="$(g rev-parse HEAD)"
  g merge -q --no-ff -m merge topic
}

run_step() { # COMMAND — sets RC and OUT
  RC=0
  OUT="$(cd "$R" && env -i PATH="$PATH" HOME="$HOME" BASE="$BASE" bash -c "$1" 2>&1)" || RC=$?
}

# NAME | RAISE | EXIT | the record the run must print
while IFS='|' read -r name raise want record; do
  [ -n "$name" ] || continue
  fixture "$name" "$raise"
  run_step "$COMMAND"
  if [ "$RC" -eq "$want" ] && grep -qxF -- "$record" <<<"$OUT"; then
    ok "$name"
  else
    bad "$name" "exit $RC: $OUT"
  fi
done <<'ROWS'
unraised|no|1|changelog-entries: package-unbumped=skills/demo/SKILL.md:1.0.0
raised|yes|0|changelog-entries: checked=1
ROWS

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
