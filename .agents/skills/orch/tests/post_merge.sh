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
table() { # SCRIPT TAG JUDGE — every row against SCRIPT, each judged by JUDGE GOT WANT ROW STDERR;
  # returns 1 at the first row JUDGE refuses
  local rc out expected_rc expected W
  while IFS='|' read -r FAIL_STEP expected_rc expected; do
    W="$SCRATCH/$2-$FAIL_STEP"
    git clone -q -c gc.auto=0 -c maintenance.auto=false "$SCRATCH/seed" "$W"; before="$(git -C "$W" rev-parse HEAD)"; export before FAIL_STEP
    git -C "$SCRATCH/seed" commit -qm advance --allow-empty; after="$(git -C "$SCRATCH/seed" rev-parse HEAD)"; export after
    touch "$W/kendex.toml"
    export ORCH_POST_MERGE_CMD='[ "$ORCH_POST_MERGE_BEFORE" = "$before" ] && [ "$ORCH_POST_MERGE_AFTER" = "$after" ] && [ "$(git rev-parse HEAD)" = "$after" ] && [ "$FAIL_STEP" != command ]'
    case "$FAIL_STEP" in sync-base) git -C "$W" remote set-url origin "$SCRATCH/absent" ;; success) "$DIR/sync-base" "$W" >/dev/null ;; empty) ORCH_POST_MERGE_CMD='' ;; absent) rm -- "$W/kendex.toml" ;;
      adopt) mkdir -p "$W/.agents/skills/review-gate/scripts"; printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" "$*"; exit 2' > "$W/.agents/skills/review-gate/scripts/validate-workflow.sh"; chmod +x "$W/.agents/skills/review-gate/scripts/validate-workflow.sh" ;; esac
    rc=0; out="$(bash "$1" "$W" 2>"$SCRATCH/error")" || rc=$?
    out="$(printf '%s\n' "$out" | sed '/^main$/d' | tr '\n' ',')"
    "$3" "$rc:$out" "$expected_rc:$expected" "$FAIL_STEP" "$SCRATCH/error" || return 1
    case "$FAIL_STEP" in command) FAIL_STEP=retry; bash "$1" "$W" >/dev/null ;; success) before=$after; bash "$1" "$W" >/dev/null ;; esac
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
}
table "$DIR/post-merge" real assert_eq
# Must-fail control: a copy with no adopt step fails the verify row. Its judge
# counts nothing, so the misses it expects stay out of the suite's tally. It
# runs from a copy of the skill tree, since sync-base finds the github skill
# beside orch.
miss() { [[ "$1" == "$2" ]] || { printf 'miss %s rc=%s\n' "$3" "${1%%:*}"; return 1; }; }
step='  step adopt "$SCRIPT_DIR/adopt-writer" . || exit $?'
assert_eq "$(grep -cxF -- "$step" "$DIR/post-merge" || true)" 1 "control finds the adopt step as one line to strip"
mkdir "$SCRATCH/mutant"; cp -R "$DIR/.." "$SCRATCH/mutant/orch"; ln -s "$(cd "$DIR/../../github" && pwd)" "$SCRATCH/mutant/github"
step="$step" awk '$0 == ENVIRON["step"] { print "  :"; next } { print }' "$DIR/post-merge" >"$SCRATCH/mutant/orch/scripts/post-merge"
rc=0; out="$(table "$SCRATCH/mutant/orch/scripts/post-merge" mutant miss 2>"$SCRATCH/control-error")" || rc=$?
assert_eq "$rc:$out" "1:miss verify rc=1" "control: a copy with no adopt step fails the verify row" "$SCRATCH/control-error"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
