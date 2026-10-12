#!/usr/bin/env bash
# Pins for the run log scripts/commit-guards appends: one row per guard the
# batch runs, carrying the guard, the batch scope, its own outcome, a
# measured duration and the commit or range, appended under the common git
# directory and never inside a working tree. A log that cannot be written is
# named and leaves the verdict alone. A reader of the log parses the format
# ../CHECKS.md § The run log sets out.
#
# Marker words are assembled from split tokens so this file never contains
# a marker shape itself.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
GG="$SKILL_DIR/scripts/commit-guards"
# shellcheck source=lib/harness.bash
. "$TEST_DIR/lib/harness.bash"
unset CI GITHUB_ACTIONS COMMIT_GUARDS_CHECKS COMMIT_GUARDS_SETTINGS_FILE 2>/dev/null || true

TD="TO""DO"
TWO="COMMIT_GUARDS_CHECKS=todo-ban conflict-markers"

PASS=0
FAIL=0
assert_eq() { # LABEL EXPECT ACTUAL
  if [ "$2" = "$3" ]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$1"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        want: %s\n        got:  %s\n' "$1" "$2" "$3"
  fi
}

# A repository with one clean commit tagged base, then a staged work marker,
# so todo-ban fails the staged batch and conflict-markers passes it.
R=""
fixture() { # NAME
  R="$TMP/$1"
  mkdir -p "$R"
  git -C "$R" -c init.defaultBranch=main init -q
  git -C "$R" config user.email test@example.com
  git -C "$R" config user.name test
  git -C "$R" config gc.auto 0
  git -C "$R" config maintenance.auto false
  printf 'fn main() {}\n' >"$R/ok.rs"
  git -C "$R" add ok.rs
  git -C "$R" commit -qm seed
  git -C "$R" tag base
  printf '// %s: planted for the run log\n' "$TD" >"$R/planted.rs"
  git -C "$R" add planted.rs
}
run() { # DIR ENVS ARGS [GG] — the batch's exit status
  local rc=0
  # shellcheck disable=SC2086
  (cd "$1" && env -i PATH="$PATH" HOME="$HOME" TMPDIR="$TMPDIR" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$GIT_CONFIG_GLOBAL" "$2" "${4:-$GG}" $3 >"$TMP/last.out" 2>&1) || rc=$?
  printf '%s' "$rc"
}
log_of() { printf '%s/.git/commit-guards-runs.tsv' "$1"; } # REPO
# Each row as guard,scope,outcome,target; ';' between rows.
rows() { LC_ALL=C awk -F '\t' '{ printf "%s%s,%s,%s,%s", (NR > 1 ? ";" : ""), $2, $3, $4, $6 }' "$1"; } # LOG
# Rows whose duration is not a positive number of seconds, or whose start is
# not whole epoch seconds: empty when every row was measured.
unmeasured() { LC_ALL=C awk -F '\t' '!($5 ~ /^[0-9]+\.[0-9]+$/ && $5 + 0 > 0 && $1 ~ /^[0-9]+$/) { print NR ":" $2 ":" $5 }' "$1"; } # LOG

echo "=== a batch of two guards, one failing, writes one row per guard ==="
fixture two
head="$(git -C "$R" rev-parse HEAD)"
assert_eq "the batch keeps its verdict: todo-ban's violation is exit 1" 1 "$(run "$R" "$TWO" "all --staged")"
assert_eq "two rows, each guard's own outcome, the batch scope and the commit the run started on" \
  "todo-ban,staged,violations,$head;conflict-markers,staged,clean,$head" "$(rows "$(log_of "$R")")"
assert_eq "every row carries a nonzero duration and a start time" "" "$(unmeasured "$(log_of "$R")")"
assert_eq "the log stays out of the working tree: status shows only the staged marker" \
  "A  planted.rs" "$(git -C "$R" status --porcelain --untracked-files=all --ignored)"
assert_eq "a second run appends its own rows" 1 "$(run "$R" "$TWO" "all --staged")"
assert_eq "four rows after two runs" 4 "$(LC_ALL=C awk 'END { print NR }' "$(log_of "$R")")"

echo "=== a range batch records the range; a linked worktree logs beside its main checkout ==="
fixture range
git -C "$R" commit -qm 'add the marker'
head="$(git -C "$R" rev-parse HEAD)"
assert_eq "a range batch runs" 1 "$(run "$R" "COMMIT_GUARDS_CHECKS=todo-ban" "all --base base")"
assert_eq "the row names the range on byte-ceiling's dots" "todo-ban,base,violations,base...$head" "$(rows "$(log_of "$R")")"
git -C "$R" worktree add -q "$TMP/range-linked" base
assert_eq "a batch in the linked worktree runs" 0 "$(run "$TMP/range-linked" "COMMIT_GUARDS_CHECKS=todo-ban" "all --against base")"
assert_eq "its row lands in the common git directory" \
  "todo-ban,base,violations,base...$head;todo-ban,against,clean,base..$(git -C "$R" rev-parse base)" "$(rows "$(log_of "$R")")"

echo "=== a log that cannot be written is named and changes no verdict ==="
fixture unwritable
mkdir "$(log_of "$R")"
assert_eq "the verdict stands" 1 "$(run "$R" "$TWO" "all --staged")"
assert_eq "the unwritten log is named" "commit-guards: run-log-unwritten=.git/commit-guards-runs.tsv" \
  "$(LC_ALL=C awk '/^commit-guards: run-log-unwritten=/' "$TMP/last.out")"

echo "=== must-fail controls ==="
# A copy that reads the clock again before the guard runs measures nothing.
gg_mutant UNTIMED_GG commit-guards 'ended="$(clock)" || ended=""' 'ended="$started"'
fixture untimed
run "$R" "$TWO" "all --staged" "$UNTIMED_GG" >/dev/null
assert_eq "must-fail: a duration taken before the guard runs is not a measurement" \
  "1:todo-ban:0.000;2:conflict-markers:0.000" "$(unmeasured "$(log_of "$R")" | paste -sd ';' -)"
# A copy that writes under the work tree root.
gg_mutant INTREE_GG commit-guards 'gg_git_path RUN_LOG . rev-parse --git-common-dir' 'gg_git_path RUN_LOG . rev-parse --show-toplevel'
fixture intree
run "$R" "$TWO" "all --staged" "$INTREE_GG" >/dev/null
assert_eq "must-fail: a log under the work tree root shows in status" \
  "A  planted.rs;?? commit-guards-runs.tsv" "$(git -C "$R" status --porcelain --untracked-files=all --ignored | paste -sd ';' -)"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
