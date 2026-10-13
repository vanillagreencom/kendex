#!/usr/bin/env bash
# Surface: lane_run_detached, portable recovery process-group separation.
# Inputs: skills/orch/scripts/lib/** skills/github/scripts/lib/group-leader.sh skills/orch/tests/lib/assertions.sh skills/orch/tests/lib/git-env.sh
set -euo pipefail
TEST_DIR="$(cd -- "${BASH_SOURCE[0]%/*}" && pwd -P)"
. "$TEST_DIR/lib/git-env.sh"
. "$TEST_DIR/lib/assertions.sh"
SCRIPTS="$(cd -- "$TEST_DIR/../scripts" && pwd -P)"
LIB="${LIB_UNDER_TEST:-$SCRIPTS/lib/lane-launch.sh}"
TMP_ROOT="$(mktemp -d)" || { echo 'lane_run_detached: scratch=mktemp-failed' >&2; exit 1; }
[[ -d "$TMP_ROOT" && ! -L "$TMP_ROOT" ]] || { echo 'lane_run_detached: scratch=not-a-directory' >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo 'lane_run_detached: scratch=resolve-failed' >&2; exit 1; }
OWNED_CHILD=""
cleanup() {
  if [[ -n "$OWNED_CHILD" ]]; then kill "$OWNED_CHILD" 2>/dev/null || :; wait "$OWNED_CHILD" 2>/dev/null || :; fi
  rm -rf -- "${TMP_ROOT:?}"
}
trap cleanup EXIT
. "$LIB"
PERL="$(command -v perl)"
NOHUP="$(command -v nohup)"
PARENT_GROUP="$(ps -o pgid= -p "$$")"
PARENT_GROUP=${PARENT_GROUP//[[:space:]]/}
mkdir -p "$TMP_ROOT/bin"
ln -s "$PERL" "$TMP_ROOT/bin/perl"
ln -s "$NOHUP" "$TMP_ROOT/bin/nohup"
# Only the launch runs without setsid. The child acknowledges its group and
# PID before the parent judges it. The deadline bounds a missing launch.
cat > "$TMP_ROOT/child.pl" <<'CHILD'
open my $ready, '>', $ARGV[0] or die "ready: $!";
print $ready join("|", $$, getpgrp(0), ($SIG{INT} // ''), ($SIG{QUIT} // '')), "\n";
close $ready or die "ready-close: $!";
sleep 90;
CHILD
saved_path=$PATH
PATH="$TMP_ROOT/bin"
lane_run_detached "$TMP_ROOT/out" "$TMP_ROOT/err" "$PERL" "$TMP_ROOT/child.pl" "$TMP_ROOT/ready"
OWNED_CHILD=$!
PATH=$saved_path
deadline=$((SECONDS + 5))
while [[ ! -f "$TMP_ROOT/ready" && "$SECONDS" -lt "$deadline" ]]; do sleep 0.05; done
if [[ -f "$TMP_ROOT/ready" ]]; then
  IFS='|' read -r child group interrupt quit < "$TMP_ROOT/ready"
  assert_eq "$child" "$OWNED_CHILD" 'the launch retains the PID used by wake records'
  assert_eq "$group" "$child" 'portable recovery leads its own process group'
  if [[ "$group" != "$PARENT_GROUP" ]]; then pass 'predecessor group termination cannot reach recovery'; else fail 'predecessor group termination cannot reach recovery'; fi
  assert_eq "$interrupt|$quit" '|' 'portable recovery restores interrupt and quit'
else
  fail 'portable recovery acknowledges a started process'
  dump_stderr "$TMP_ROOT/err"
fi
kill "$OWNED_CHILD" 2>/dev/null || :
wait "$OWNED_CHILD" 2>/dev/null || :
OWNED_CHILD=""
dependency_lib="$TMP_ROOT/dependencies/orch/scripts/lib"
dependency_shared="$TMP_ROOT/dependencies/github/scripts/lib"
mkdir -p "$dependency_lib" "$dependency_shared" "$TMP_ROOT/no-perl"
cp -R -- "${LIB%/*}/." "$dependency_lib/"
ln -s "$NOHUP" "$TMP_ROOT/no-perl/nohup"
for dependency in library perl; do
  if [[ "$dependency" == library ]]; then
    missing_path="$TMP_ROOT/bin"
    expected=group-leader-missing
  else
    cp -- "$SCRIPTS/../../github/scripts/lib/group-leader.sh" "$dependency_shared/"
    missing_path="$TMP_ROOT/no-perl"
    expected=missing-command
  fi
  answer=$("$BASH" -euo pipefail -c '
    . "$1"
    export PATH="$2"
    rc=0
    lane_run_detached "$3" "$4" "$5" "$6" "$7" || rc=$?
    printf "%s\n" "$rc"
  ' _ "$dependency_lib/lane-launch.sh" "$missing_path" "$TMP_ROOT/dependency.out" \
    "$TMP_ROOT/dependency.err" "$PERL" "$TMP_ROOT/child.pl" "$TMP_ROOT/dependency.ready" \
    2> "$TMP_ROOT/dependency.err")
  assert_eq "$answer" 2 "missing $dependency refuses the portable launch"
  assert_eq "$(sed -n 's/^lane-launch: detached=\([^ ]*\).*$/\1/p' "$TMP_ROOT/dependency.err")" "$expected" \
    "missing $dependency reports the failed dependency"
  if [[ ! -e "$TMP_ROOT/dependency.ready" ]]; then pass "missing $dependency starts no recovery command"; else fail "missing $dependency starts no recovery command"; fi
done
if [[ -z "${DETACHED_CONTROL:-}" ]]; then
  control="$TMP_ROOT/control/orch/scripts/lib"
  mkdir -p "$control" "$TMP_ROOT/control/github/scripts/lib"
  cp -R -- "$SCRIPTS/lib/." "$control/"
  cp -- "$SCRIPTS/../../github/scripts/lib/group-leader.sh" "$TMP_ROOT/control/github/scripts/lib/"
  python3 - "$control/lane-launch.sh" <<'CONTROL'
from pathlib import Path
import sys
p=Path(sys.argv[1])
text=p.read_text()
old='nohup "${KENDEX_GROUP_LEADER[@]}" "$@"'
assert text.count(old)==1
changed=text.replace(old, 'nohup "$@"')
assert changed != text
p.write_text(changed)
CONTROL
  status=0
  DETACHED_CONTROL=1 LIB_UNDER_TEST="$control/lane-launch.sh" "$BASH" "${BASH_SOURCE[0]}" > "$TMP_ROOT/control.log" 2>&1 || status=$?
  if [[ "$status" != 0 ]] && rg -q '^  FAIL ' "$TMP_ROOT/control.log"; then pass 'omitted group separation control fails'; else fail 'omitted group separation control fails'; fi
  for dependency in library perl; do
    control="$TMP_ROOT/control-$dependency/orch/scripts/lib"
    mkdir -p "$control" "$TMP_ROOT/control-$dependency/github/scripts/lib"
    cp -R -- "$SCRIPTS/lib/." "$control/"
    cp -- "$SCRIPTS/../../github/scripts/lib/group-leader.sh" "$TMP_ROOT/control-$dependency/github/scripts/lib/"
    python3 - "$control/lane-launch.sh" "$dependency" <<'CONTROL'
from pathlib import Path
import sys
p=Path(sys.argv[1])
text=p.read_text()
key='group-leader-missing path=%s' if sys.argv[2]=='library' else 'missing-command commands=perl'
needle="printf 'lane-launch: detached="+key
assert text.count(needle)==1
start=text.index(needle)
end=text.index('return 2',start)
assert text[start:end].count('return')==0
changed=text[:end]+text[end:].replace('return 2','return 0',1)
assert changed != text
p.write_text(changed)
CONTROL
    status=0
    DETACHED_CONTROL=1 LIB_UNDER_TEST="$control/lane-launch.sh" "$BASH" "${BASH_SOURCE[0]}" > "$TMP_ROOT/control-$dependency.log" 2>&1 || status=$?
    if [[ "$status" != 0 ]] && rg -q '^  FAIL ' "$TMP_ROOT/control-$dependency.log"; then pass "$dependency failure reported as success control fails"; else fail "$dependency failure reported as success control fails"; fi
  done
fi
printf '\nResults: %s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
