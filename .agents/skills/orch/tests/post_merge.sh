#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
# shellcheck source=lib/assertions.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/assertions.sh"
DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../scripts" && pwd)"
SCRATCH="$(mktemp -d)"; trap 'rm -rf -- "$SCRATCH"' EXIT
git init -q "$SCRATCH/seed"; git -C "$SCRATCH/seed" config user.email test@example.com; git -C "$SCRATCH/seed" config user.name test
printf '{}\n' > "$SCRATCH/seed/.kendex-lock.json"; git -C "$SCRATCH/seed" add -A; git -C "$SCRATCH/seed" commit -qm initial; git -C "$SCRATCH/seed" branch -M main
# The stub's refresh re-records the committed record, as a refresh on a main
# whose record its rolling pull request has not landed yet does, and writes
# a render no branch landed, as one for a package a merge only declared.
mkdir "$SCRATCH/bin"; printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" "$*"' '[[ "$1" != refresh ]] || { printf stale > .kendex-lock.json; mkdir -p .agents/new; printf x > .agents/new/render; }' '[[ "$1" != "$FAIL_STEP" ]]' > "$SCRATCH/bin/kendex"; chmod +x "$SCRATCH/bin/kendex"
export PATH="$SCRATCH/bin:$PATH"; unset ORCH_POST_MERGE_CMD WORKTREE_DEFAULT_BRANCH
# Each row runs the real sync and command; kendex is the external boundary.
# The refresh-only row is the hosted merged step: the flag alone, so the
# clone stays at the head it had and neither sync-base nor verify runs.
while IFS='|' read -r FAIL_STEP expected_rc expected; do
  flag=""; [[ "$FAIL_STEP" != refresh-only ]] || flag=--refresh-only
  git clone -q "$SCRATCH/seed" "$SCRATCH/$FAIL_STEP"; before="$(git -C "$SCRATCH/$FAIL_STEP" rev-parse HEAD)"; export before FAIL_STEP
  git -C "$SCRATCH/seed" commit -qm advance --allow-empty; after="$(git -C "$SCRATCH/seed" rev-parse HEAD)"; export after
  touch "$SCRATCH/$FAIL_STEP/kendex.toml"
  export ORCH_POST_MERGE_CMD='[ "$ORCH_POST_MERGE_BEFORE" = "$before" ] && [ "$ORCH_POST_MERGE_AFTER" = "$after" ] && [ "$(git rev-parse HEAD)" = "$after" ] && [ "$FAIL_STEP" != command ]'
  case "$FAIL_STEP" in sync-base) git -C "$SCRATCH/$FAIL_STEP" remote set-url origin "$SCRATCH/absent" ;; success) "$DIR/sync-base" "$SCRATCH/success" >/dev/null ;; empty) ORCH_POST_MERGE_CMD='' ;; absent) rm -- "$SCRATCH/$FAIL_STEP/kendex.toml" ;; esac
  rc=0; out="$(bash "${POST_MERGE_UNDER_TEST:-$DIR/post-merge}" $flag "$SCRATCH/$FAIL_STEP" 2>"$SCRATCH/error")" || rc=$?
  out="$(printf '%s\n' "$out" | sed '/^main$/d' | tr '\n' ',')"
  assert_eq "$rc:$out" "$expected_rc:$expected" "$FAIL_STEP" "$SCRATCH/error"
  # Every run leaves the checkout as it found it, whatever the refresh and
  # the verify returned: the record the refresh re-wrote restored, the
  # render it created removed, and the untracked manifest the row made kept.
  [[ "$FAIL_STEP" == absent ]] && want="" || want="?? kendex.toml"
  left="$(git -C "$SCRATCH/$FAIL_STEP" status --porcelain --untracked-files=all)"
  assert_eq "$left" "$want" "$FAIL_STEP: the run left the checkout as it found it"
  case "$FAIL_STEP" in
    command) FAIL_STEP=retry; bash "${POST_MERGE_UNDER_TEST:-$DIR/post-merge}" "$SCRATCH/command" >/dev/null ;;
    success) before=$after; bash "${POST_MERGE_UNDER_TEST:-$DIR/post-merge}" "$SCRATCH/success" >/dev/null || fail "success: the second run refused" ;;
    refresh-only) assert_eq "$(git -C "$SCRATCH/refresh-only" rev-parse HEAD)" "$before" "refresh-only: the run left the base unsynced" ;;
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

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
