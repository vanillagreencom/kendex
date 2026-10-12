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

# The production clock reads date in separate processes. A file carries its
# deterministic input across those reads, including command substitutions.
CLOCK_BIN="$TMP/clock-bin"
mkdir -p "$CLOCK_BIN" "$TMP/whole-clock"
cat >"$CLOCK_BIN/date" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
tick=0
read -r tick <"$LOG_CLOCK_STATE" || tick=0
tick=$((tick + 1))
printf '%s\n' "$tick" >"$LOG_CLOCK_STATE"
LC_ALL=C awk -v tick="$tick" 'BEGIN { printf "%.3f\n", 1700000000 + tick / 8 }'
EOF
# BSD date plus an unusable Time::HiRes reaches the whole-second fallback.
cat >"$TMP/whole-clock/date" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
  +%s.%N) printf '1700000000.N\n' ;;
  +%s) printf '1700000000\n' ;;
  *) exit 2 ;;
esac
EOF
cat >"$TMP/whole-clock/perl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 1
EOF
# gitleaks accepts the capability probe but fails the real scan. The shipped
# secrets guard must return its dependency error to the batch.
cat >"$CLOCK_BIN/gitleaks" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "$1" = dir ] && [ "${2:-}" = --help ] && exit 0
exit 2
EOF
chmod +x "$CLOCK_BIN/date" "$CLOCK_BIN/gitleaks" "$TMP/whole-clock/date" "$TMP/whole-clock/perl"

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
  : >"$TMP/clock-state"
  # shellcheck disable=SC2086
  (cd "$1" && env -i PATH="$CLOCK_BIN:$PATH" LOG_CLOCK_STATE="$TMP/clock-state" HOME="$HOME" TMPDIR="$TMPDIR" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$GIT_CONFIG_GLOBAL" "$2" "${4:-$GG}" $3 >"$TMP/last.out" 2>&1) || rc=$?
  printf '%s' "$rc"
}
log_of() { printf '%s/.git/commit-guards-runs.tsv' "$1"; } # REPO
# Each row as guard,scope,outcome,target; ';' between rows.
rows() { LC_ALL=C awk -F '\t' '{ printf "%s%s,%s,%s,%s", (NR > 1 ? ";" : ""), $2, $3, $4, $6 }' "$1"; } # LOG
# Rows that do not carry the elapsed time the deterministic clock supplies.
unmeasured() { LC_ALL=C awk -F '\t' '!($5 == "0.125" && $1 ~ /^[0-9]+$/) { print NR ":" $2 ":" $5 }' "$1"; } # LOG
times() { LC_ALL=C awk -F '\t' '{ printf "%s%s,%s", (NR > 1 ? ";" : ""), $1, $5 }' "$1"; } # LOG

echo "=== every batch outcome writes its row and continues to the next guard ==="
for row in \
  'violations|todo-ban|1|violations' \
  'incomplete|secrets|2|incomplete'; do
  IFS='|' read -r name guard status outcome <<<"$row"
  fixture "$name"
  head="$(git -C "$R" rev-parse HEAD)"
  assert_eq "$name: the batch keeps the guard's verdict" "$status" \
    "$(run "$R" "COMMIT_GUARDS_CHECKS=$guard conflict-markers" "all --staged")"
  assert_eq "$name: each guard's outcome, batch scope and starting commit" \
    "$guard,staged,$outcome,$head;conflict-markers,staged,clean,$head" "$(rows "$(log_of "$R")")"
  assert_eq "$name: each guard carries the clock's elapsed time" "" "$(unmeasured "$(log_of "$R")")"
  assert_eq "$name: starts are whole epoch seconds and durations have three decimals" \
    '1700000000,0.125;1700000000,0.125' "$(times "$(log_of "$R")")"
done
assert_eq "the log stays out of the working tree: status shows only the staged marker" \
  "A  planted.rs" "$(git -C "$R" status --porcelain --untracked-files=all --ignored)"
assert_eq "a second run appends its own rows" 1 "$(run "$R" "$TWO" "all --staged")"
assert_eq "four rows after two runs" 4 "$(LC_ALL=C awk 'END { print NR }' "$(log_of "$R")")"

echo "=== a supported whole-second clock records fast guards in the same second ==="
fixture whole-second
CLOCK_BIN="$TMP/whole-clock"
assert_eq "the whole-second clock leaves the batch verdict intact" 1 "$(run "$R" "$TWO" "all --staged")"
assert_eq "both same-second durations are measured zero values" \
  '1700000000,0.000;1700000000,0.000' "$(times "$(log_of "$R")")"
CLOCK_BIN="$TMP/clock-bin"

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
gg_mutant CLEAN_GG commit-guards 'outcome=incomplete' 'outcome=clean'
fixture false-clean
head="$(git -C "$R" rev-parse HEAD)"
assert_eq "must-fail: falsifying an incomplete row leaves the batch dependency error" 2 \
  "$(run "$R" 'COMMIT_GUARDS_CHECKS=secrets conflict-markers' 'all --staged' "$CLEAN_GG")"
assert_eq "must-fail: the incomplete outcome assertion detects a false clean row" \
  "secrets,staged,clean,$head;conflict-markers,staged,clean,$head" "$(rows "$(log_of "$R")")"
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
