#!/usr/bin/env bash
# Tests for qa-signals, the script ../workflows/review-pr.md § 5 runs to
# record the round's QA routing in workflow state as qa_decision.
#
# Each row builds a branch over one changed file in a fresh repository, sets
# the QA path settings in that checkout's kendex.settings.toml, and reads the
# recorded qa_decision back from workflow state: its signals, and the agent it
# names for needs-ui-review. A UI diff must record needs-ui-review with
# reviewer-quality, so the § 6 UI-lens pass runs whatever the reader recalls.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

QA_SIGNALS="$TEST_DIR/../scripts/qa-signals"
# shellcheck source=lib/assertions.sh
source "$TEST_DIR/lib/assertions.sh"
# mutant_scripts and mutate_file, for the control at the end.
# shellcheck source=lib/growth-state.sh
source "$TEST_DIR/lib/growth-state.sh"

echo "=== qa-signals ==="

# fixture NAME UI_PATHS PERF_PATHS CHANGED DEV_LABELS — a repository on branch
# `item` with one commit changing CHANGED over `main`, an initialized state
# carrying DEV_LABELS, and the two settings, `-` leaving one unset. Prints the
# repository path.
fixture() {
  local repo="$TMP_ROOT/$1"
  git init -q -b main "$repo"
  git -C "$repo" config gc.auto 0
  git -C "$repo" config maintenance.auto false
  git -C "$repo" config user.email t@example.com
  git -C "$repo" config user.name t
  printf 'tmp/\nkendex.settings.toml\n' > "$repo/.gitignore"
  git -C "$repo" add .gitignore
  git -C "$repo" commit -q -m base
  git -C "$repo" checkout -q -b item
  mkdir -p "$repo/$(dirname "$4")"
  printf 'changed\n' > "$repo/$4"
  git -C "$repo" add "$4"
  git -C "$repo" commit -q -m change
  {
    printf '[env]\n'
    [[ "$2" == - ]] || printf 'QA_UI_PATHS = "%s"\n' "$2"
    [[ "$3" == - ]] || printf 'QA_PERF_PATHS = "%s"\n' "$3"
  } > "$repo/kendex.settings.toml"
  (cd "$repo" && run_env "$TEST_DIR/../scripts/workflow-state" init ISSUE-1 \
    --worktree "$repo" --branch item --qa-labels "$5" >/dev/null)
  printf '%s\n' "$repo"
}

run_env() { env -u QA_UI_PATHS -u QA_PERF_PATHS -u ORCH_STATE_DIR "$@"; }

# record SCRIPT REPO [JUDGMENT...] — runs SCRIPT in REPO, then prints the
# exit, the recorded signals and the needs-ui-review agent as the state holds
# them after the run.
record() {
  local script="$1" repo="$2" status=0
  shift 2
  (cd "$repo" && run_env "$script" ISSUE-1 --worktree "$repo" --base main "$@" \
    >"$TMP_ROOT/out" 2>"$TMP_ROOT/err") || status=$?
  printf '%s|%s\n' "$status" "$(cd "$repo" && run_env "$TEST_DIR/../scripts/workflow-state" get ISSUE-1 \
    '(.qa_decision.signals // [] | join(",")) + "|" + (.qa_decision.agents["needs-ui-review"] // "none")')"
}

# name|QA_UI_PATHS|QA_PERF_PATHS|changed file|dev labels|judgment|expected
ROWS='ui-glob-hit|ui/src/*|-|ui/src/view/Panel.tsx|[]||0|needs-ui-review|reviewer-quality
ui-glob-miss|ui/src/*|-|crates/core/lib.rs|[]||0||none
ui-unset|-|-|ui/src/view/Panel.tsx|[]||0||none
second-glob-hit|docs/* ui/src/*|-|ui/src/a.css|[]||0|needs-ui-review|reviewer-quality
dev-and-ui|ui/src/*|-|ui/src/a.tsx|["needs-review","needs-ui-review"]||0|needs-review,needs-ui-review|reviewer-quality
perf-not-ui|-|crates/*|crates/core/lib.rs|[]||0|needs-perf-test|none
judged-drop|ui/src/*|-|ui/src/a.tsx|[]|--drop needs-ui-review --reason test-only|0||none
drop-without-reason|ui/src/*|-|ui/src/a.tsx|[]|--drop needs-ui-review|2||none'

while IFS='|' read -r name ui perf changed labels judgment want_rc want_signals want_agent; do
  repo="$(fixture "$name" "$ui" "$perf" "$changed" "$labels")"
  # shellcheck disable=SC2086 # the judgment cell is a word list
  got="$(record "$QA_SIGNALS" "$repo" $judgment)"
  assert_eq "$got" "$want_rc|$want_signals|$want_agent" "row $name" "$TMP_ROOT/err"
done <<<"$ROWS"

# stdout is the object the state holds.
repo="$(fixture stdout 'ui/src/*' - ui/src/a.tsx '[]')"
record "$QA_SIGNALS" "$repo" >/dev/null
state="$(cd "$repo" && run_env "$TEST_DIR/../scripts/workflow-state" get ISSUE-1 '.qa_decision | tojson')"
assert_eq "$(jq -c . "$TMP_ROOT/out")" "$state" "stdout matches the recorded qa_decision"

# Must-fail control: a private copy with the path match removed must miss the
# ui-glob-hit row's signal.
MUTANT="$(mutant_scripts mutant qa-signals)/qa-signals" || exit 1
mutate_file "$MUTANT" 'if [[ -n "$path" && "$path" == $glob ]]; then' \
  'if false && [[ -n "$path" && "$path" == $glob ]]; then'
repo="$(fixture mutant-ui-glob-hit 'ui/src/*' - ui/src/view/Panel.tsx '[]')"
got="$(record "$MUTANT" "$repo")"
assert_eq "$got" "0||none" "must-fail control: without the path match the ui-glob-hit row records no signal"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
