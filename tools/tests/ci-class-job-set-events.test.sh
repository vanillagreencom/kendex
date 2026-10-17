#!/usr/bin/env bash
# Tests for CI event selection and platform parity.
set -euo pipefail

# A suite running from inside a git hook inherits GIT_DIR, GIT_COMMON_DIR,
# GIT_WORK_TREE and GIT_INDEX_FILE, which would resolve ROOT to the hook's
# repository instead of this one.
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/ci-job-set-world.sh
. "$TEST_DIR/lib/ci-job-set-world.sh"

# An event the workflow does not classify on is refused, with the parity
# call or without: the main push and the nightly run (its schedule and its
# manual dispatch) run their fixed jobs with no selection, and a selection
# asked for one would stand lanes down on no diff.
# ARGUMENT|EVENT|EXPECTED
refused_rows=0
while IFS='|' read -r arg event expected; do
  refused_rows=$((refused_rows + 1))
  check "the ${event:-unset} event is refused, called with ${arg:-no argument}" "$expected" \
    "$(SELECT_ARG="$arg" SELECT_EVENT="$event" selection micro false skills/orch/SKILL.md)"
done <<ROWS
|push|exit=2 unsupported-event event=push
|schedule|exit=2 unsupported-event event=schedule
|workflow_dispatch|exit=2 unsupported-event event=workflow_dispatch
--event-parity|schedule|exit=2 unsupported-event event=schedule
||exit=2 unsupported-event event=
ROWS
[ "$refused_rows" -eq 5 ] || { echo "the refused-event table read $refused_rows rows" >&2; exit 1; }
# The macOS legs run wherever a shard and a platform lane run, on the pull
# request as in the merge group.
# EVENT|PATHS|LEGS
leg_rows=0
while IFS='|' read -r event paths expected; do
  leg_rows=$((leg_rows + 1))
  check "the $event legs over '$paths'" "$expected" \
    "$(SELECT_EVENT="$event" selection micro false "$(printf '%s\n' $paths)" | sed 's/.* shell_os=\(\[[^]]*\]\).*/\1/')"
done <<ROWS
pull_request|skills/orch/scripts/lanes|$BOTH
merge_group|skills/orch/scripts/lanes|$BOTH
pull_request|skills/orch/SKILL.md|$LINUX
merge_group|skills/orch/SKILL.md|$LINUX
pull_request|.github/AGENTS.md skills/orch/scripts/lanes|$BOTH
merge_group|.github/AGENTS.md skills/orch/scripts/lanes|$BOTH
pull_request|crates/core/src/lib.rs|$BOTH
merge_group|crates/core/src/lib.rs|$BOTH
ROWS
[ "$leg_rows" -eq 8 ] || { echo "the legs table read $leg_rows rows" >&2; exit 1; }
# Event parity: a copy that plants the macOS legs on the merge group alone is
# refused by the --event-parity call on either event. A call without the flag
# derives its one event alone, so the same copy answers it.
# ARGUMENT|EVENT|EXPECTED; an argument other than --event-parity is refused.
mkdir -p "$TMP/parity/tools"
cp -R "$ROOT/tools/lib" "$TMP/parity/tools/lib"
cp "$ROOT/tools/macos-test-contracts" "$ROOT/tools/macos-test-contracts.json" "$TMP/parity/tools/"
cp "$ROOT/tools/rust-reads" "$TMP/parity/tools/rust-reads"
sed 's/^      macos_shard "\$shards" || macos=false$/&; [ "$event" = merge_group ] || macos=false/' \
  "$JOB_SET" >"$TMP/parity/tools/ci-job-set"
chmod +x "$TMP/parity/tools/ci-job-set"
[ "$(grep -c 'macos=false; \[ "\$event" = merge_group \] || macos=false$' "$TMP/parity/tools/ci-job-set")" -eq 1 ] ||
  { echo "the event gate was not planted in the ci-job-set copy" >&2; exit 1; }
parity_rows=0
while IFS='|' read -r arg event expected; do
  parity_rows=$((parity_rows + 1))
  check "a macOS leg the merge group alone selects, called with ${arg:-no argument} on $event" "$expected" \
    "$(SELECT_WITH="$TMP/parity/tools/ci-job-set" SELECT_ARG="$arg" SELECT_EVENT="$event" selection micro false skills/orch/scripts/lanes | sed 's/.* shell_os=\(\[[^]]*\]\).*/\1/')"
done <<ROWS
--event-parity|pull_request|exit=2 event-parity event=merge_group
--event-parity|merge_group|exit=2 event-parity event=pull_request
|pull_request|$LINUX
|merge_group|$BOTH
--parity|pull_request|exit=2 unknown-argument value=--parity
ROWS
[ "$parity_rows" -eq 5 ] || { echo "the parity table read $parity_rows rows" >&2; exit 1; }
check "this tree's selection passes the --event-parity call unchanged" \
  "$(selection micro false skills/orch/scripts/lanes)" \
  "$(SELECT_ARG=--event-parity selection micro false skills/orch/scripts/lanes)"

# An Ubuntu lane that differs by event is refused too.
sed 's/^  row="\$class"$/  row="$class"; linux_integration=true; [ "$event" != merge_group ] || linux_integration=false/; s/cargo_linux=true/cargo_linux=$linux_integration/g' "$JOB_SET" >"$TMP/parity/tools/ci-job-set"
! cmp -s "$JOB_SET" "$TMP/parity/tools/ci-job-set" || exit 1
for event in pull_request merge_group; do
  other=merge_group
  [ "$event" != merge_group ] || other=pull_request
  check "Ubuntu event parity on $event" "exit=2 event-parity event=$other" \
    "$(SELECT_WITH="$TMP/parity/tools/ci-job-set" SELECT_ARG=--event-parity SELECT_EVENT="$event" selection micro false skills/orch/scripts/lanes)"
done

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
