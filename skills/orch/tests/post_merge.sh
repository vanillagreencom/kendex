#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
# shellcheck source=lib/assertions.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/assertions.sh"
DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../scripts" && pwd)"
SCRATCH="$(mktemp -d)"; trap 'rm -rf -- "$SCRATCH"' EXIT
TMP_ROOT="$SCRATCH"
# shellcheck source=lib/growth-state.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/growth-state.sh"
git init -q "$SCRATCH/seed"; git -C "$SCRATCH/seed" config gc.auto 0; git -C "$SCRATCH/seed" config maintenance.auto false; git -C "$SCRATCH/seed" config user.email test@example.com; git -C "$SCRATCH/seed" config user.name test
printf '{}\n' > "$SCRATCH/seed/.kendex-lock.json"; git -C "$SCRATCH/seed" add -A; git -C "$SCRATCH/seed" commit -qm initial; git -C "$SCRATCH/seed" branch -M main
# The stub's refresh re-records the committed record, as a refresh on a main
# whose record its rolling pull request has not landed yet does, and writes
# a render no branch landed, as one for a package a merge only declared.
mkdir "$SCRATCH/bin"; printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" "$*"' '[[ "$1" != refresh ]] || { printf stale > .kendex-lock.json; mkdir -p .agents/new; printf x > .agents/new/render; }' '[[ "$1" != "$FAIL_STEP" ]]' > "$SCRATCH/bin/kendex"; chmod +x "$SCRATCH/bin/kendex"
export PATH="$SCRATCH/bin:$PATH"; unset ORCH_POST_MERGE_CMD WORKTREE_DEFAULT_BRANCH
# Each row runs the real sync and command; kendex is the external boundary.
# The refresh-only row is the hosted merged step: the flag alone, so the
# clone stays at the head it had and neither sync-base nor verify runs.
table() { # SCRIPT TAG JUDGE — every row against SCRIPT, each judged by JUDGE GOT WANT ROW STDERR;
  # returns 1 at the first row JUDGE refuses
  local rc out expected_rc expected W flag left want
  while IFS='|' read -r FAIL_STEP expected_rc expected; do
    W="$SCRATCH/$2-$FAIL_STEP"; flag=""; [[ "$FAIL_STEP" != refresh-only ]] || flag=--refresh-only
    git clone -q -c gc.auto=0 -c maintenance.auto=false "$SCRATCH/seed" "$W"; before="$(git -C "$W" rev-parse HEAD)"; export before FAIL_STEP
    git -C "$SCRATCH/seed" commit -qm advance --allow-empty; after="$(git -C "$SCRATCH/seed" rev-parse HEAD)"; export after
    touch "$W/kendex.toml"
    export ORCH_POST_MERGE_CMD='[ "$ORCH_POST_MERGE_BEFORE" = "$before" ] && [ "$ORCH_POST_MERGE_AFTER" = "$after" ] && [ "$(git rev-parse HEAD)" = "$after" ] && [ "$FAIL_STEP" != command ]'
    case "$FAIL_STEP" in sync-base) git -C "$W" remote set-url origin "$SCRATCH/absent" ;; success) "$DIR/sync-base" "$W" >/dev/null ;; empty) ORCH_POST_MERGE_CMD='' ;; absent) rm -- "$W/kendex.toml" ;;
      esac
    rc=0; out="$(bash "$1" $flag "$W" 2>"$SCRATCH/error")" || rc=$?
    out="$(printf '%s\n' "$out" | sed '/^main$/d' | tr '\n' ',')"
    "$3" "$rc:$out" "$expected_rc:$expected" "$FAIL_STEP" "$SCRATCH/error" || return 1
    # Every run leaves the checkout as it found it, whatever the refresh, the
    # verify returned: the record the refresh re-wrote
    # restored, the render it created removed, and the untracked files the
    # row made kept.
    case "$FAIL_STEP" in absent) want="" ;; *) want="?? kendex.toml" ;; esac
    left="$(git -C "$W" status --porcelain --untracked-files=all)"
    "$3" "$left" "$want" "$FAIL_STEP: the run left the checkout as it found it" || return 1
    case "$FAIL_STEP" in
      command) FAIL_STEP=retry; bash "$1" "$W" >/dev/null ;;
      success) before=$after; rc=0; bash "$1" "$W" >/dev/null || rc=$?; "$3" "$rc" 0 "success: the second run" || return 1 ;;
      refresh-only) "$3" "$(git -C "$W" rev-parse HEAD)" "$before" "refresh-only: the run left the base unsynced" || return 1 ;;
    esac
  done <<'ROWS'
sync-base|1|post-merge: sync-base=1,
command|1|post-merge: sync-base=0,post-merge: command=1,
refresh|1|post-merge: sync-base=0,post-merge: command=0,refresh --scope project --yes --leave,post-merge: refresh=1,post-merge: restore=0,
verify|1|post-merge: sync-base=0,post-merge: command=0,refresh --scope project --yes --leave,post-merge: refresh=0,verify --scope project,post-merge: verify=1,post-merge: restore=0,
success|0|post-merge: sync-base=0,post-merge: command=0,refresh --scope project --yes --leave,post-merge: refresh=0,verify --scope project,post-merge: verify=0,post-merge: restore=0,
empty|0|post-merge: sync-base=0,post-merge: command=skipped,refresh --scope project --yes --leave,post-merge: refresh=0,verify --scope project,post-merge: verify=0,post-merge: restore=0,
absent|0|post-merge: sync-base=0,post-merge: command=0,post-merge: refresh=skipped,post-merge: verify=skipped,
refresh-only|0|refresh --scope project --yes --leave,post-merge: refresh=0,post-merge: restore=0,
ROWS
}
table "$DIR/post-merge" real assert_eq
# Must-fail control: a copy with no verify step fails the verify row. Its judge
# counts nothing, so the misses it expects stay out of the suite's tally. The
# mutant tree is named orch, with the github skill linked beside it, since
# sync-base finds its auth helper there.
miss() { [[ "$1" == "$2" ]] || { printf 'miss %s rc=%s\n' "$3" "${1%%:*}"; return 1; }; }
mutant="$(mutant_scripts orch post-merge)/post-merge" || exit 1
ln -s "$(cd "$DIR/../../github" && pwd)" "$SCRATCH/github"
mutate_file "$mutant" '[[ $rc -ne 0 || "$mode" != full ]] || step verify kendex verify --scope project || rc=$?' ':'
rc=0; out="$(table "$mutant" mutant miss 2>"$SCRATCH/control-error")" || rc=$?
assert_eq "$rc:$out" "1:miss verify rc=0" "control: a copy with no verify step fails the verify row" "$SCRATCH/control-error"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
