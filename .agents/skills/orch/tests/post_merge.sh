#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
# shellcheck source=lib/assertions.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/assertions.sh"
DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../scripts" && pwd)"
SCRATCH="$(mktemp -d)"; trap 'rm -rf -- "$SCRATCH"' EXIT
git init -q "$SCRATCH/seed"; git -C "$SCRATCH/seed" config gc.auto 0; git -C "$SCRATCH/seed" config maintenance.auto false; git -C "$SCRATCH/seed" config user.email test@example.com; git -C "$SCRATCH/seed" config user.name test
git -C "$SCRATCH/seed" commit -qm initial --allow-empty; git -C "$SCRATCH/seed" branch -M main
mkdir "$SCRATCH/bin"; printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" "$*"' '[[ "$1" != "$FAIL_STEP" ]]' > "$SCRATCH/bin/kendex"; chmod +x "$SCRATCH/bin/kendex"
export PATH="$SCRATCH/bin:$PATH"; unset ORCH_POST_MERGE_CMD WORKTREE_DEFAULT_BRANCH
# Each row runs the real sync and command; kendex is the external boundary.
while IFS='|' read -r FAIL_STEP expected_rc expected; do
  git clone -q -c gc.auto=0 -c maintenance.auto=false "$SCRATCH/seed" "$SCRATCH/$FAIL_STEP"; before="$(git -C "$SCRATCH/$FAIL_STEP" rev-parse HEAD)"; export before FAIL_STEP
  git -C "$SCRATCH/seed" commit -qm advance --allow-empty; after="$(git -C "$SCRATCH/seed" rev-parse HEAD)"; export after
  touch "$SCRATCH/$FAIL_STEP/kendex.toml"
  export ORCH_POST_MERGE_CMD='[ "$ORCH_POST_MERGE_BEFORE" = "$before" ] && [ "$ORCH_POST_MERGE_AFTER" = "$after" ] && [ "$(git rev-parse HEAD)" = "$after" ] && [ "$FAIL_STEP" != command ]'
  case "$FAIL_STEP" in sync-base) git -C "$SCRATCH/$FAIL_STEP" remote set-url origin "$SCRATCH/absent" ;; success) "$DIR/sync-base" "$SCRATCH/success" >/dev/null ;; empty) ORCH_POST_MERGE_CMD='' ;; absent) rm -- "$SCRATCH/$FAIL_STEP/kendex.toml" ;;
    adopt) mkdir -p "$SCRATCH/adopt/.agents/skills/review-gate/scripts"; printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" "$*"; exit 2' > "$SCRATCH/adopt/.agents/skills/review-gate/scripts/validate-workflow.sh"; chmod +x "$SCRATCH/adopt/.agents/skills/review-gate/scripts/validate-workflow.sh" ;; esac
  rc=0; out="$(bash "${POST_MERGE_UNDER_TEST:-$DIR/post-merge}" "$SCRATCH/$FAIL_STEP" 2>"$SCRATCH/error")" || rc=$?
  out="$(printf '%s\n' "$out" | sed '/^main$/d' | tr '\n' ',')"
  assert_eq "$rc:$out" "$expected_rc:$expected" "$FAIL_STEP" "$SCRATCH/error"
  case "$FAIL_STEP" in command) FAIL_STEP=retry; bash "${POST_MERGE_UNDER_TEST:-$DIR/post-merge}" "$SCRATCH/command" >/dev/null ;; success) before=$after; bash "${POST_MERGE_UNDER_TEST:-$DIR/post-merge}" "$SCRATCH/success" >/dev/null ;; esac
done <<'ROWS'
sync-base|1|post-merge: sync-base=1,
command|1|post-merge: sync-base=0,post-merge: command=1,
refresh|1|post-merge: sync-base=0,post-merge: command=0,refresh --scope project --yes --leave,post-merge: refresh=1,
verify|1|post-merge: sync-base=0,post-merge: command=0,refresh --scope project --yes --leave,post-merge: refresh=0,adopt-writer: review-gate=absent,post-merge: adopt=0,verify --scope project,post-merge: verify=1,
success|0|post-merge: sync-base=0,post-merge: command=0,refresh --scope project --yes --leave,post-merge: refresh=0,adopt-writer: review-gate=absent,post-merge: adopt=0,verify --scope project,post-merge: verify=0,
empty|0|post-merge: sync-base=0,post-merge: command=skipped,refresh --scope project --yes --leave,post-merge: refresh=0,adopt-writer: review-gate=absent,post-merge: adopt=0,verify --scope project,post-merge: verify=0,
adopt|1|post-merge: sync-base=0,post-merge: command=0,refresh --scope project --yes --leave,post-merge: refresh=0,--adopt,adopt-writer: adopt=2,post-merge: adopt=1,
absent|0|post-merge: sync-base=0,post-merge: command=0,post-merge: refresh=skipped,post-merge: adopt=skipped,post-merge: verify=skipped,
ROWS

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
