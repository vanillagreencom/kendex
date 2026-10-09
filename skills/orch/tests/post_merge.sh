#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
# shellcheck source=lib/assertions.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/assertions.sh"
DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../scripts" && pwd)"
TMP_ROOT="$(mktemp -d)" || { echo "post-merge-test: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "post-merge-test: scratch=not-a-directory" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "post-merge-test: scratch=resolve-failed" >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
SCRATCH="$TMP_ROOT"
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
# Refresh-only belongs to an authorized refresh owner outside the control
# host. It leaves the clone unsynced and runs neither command nor verify.
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
    out="$(printf '%s\n' "$out" | sed -n '/^post-merge: /p; /^refresh /p; /^verify /p' | tr '\n' ',')"
    "$3" "$rc:$out" "$expected_rc:$expected" "$FAIL_STEP" "$SCRATCH/error" || return 1
    case "$FAIL_STEP" in
      absent) want="" ;;
      sync-base|command) want="?? kendex.toml" ;;
      *) want=$' M .kendex-lock.json\n?? .agents/new/render\n?? kendex.toml' ;;
    esac
    left="$(git -C "$W" status --porcelain --untracked-files=all)"
    "$3" "$left" "$want" "$FAIL_STEP: checkout changes retained" || return 1
    case "$FAIL_STEP" in
      command) FAIL_STEP=retry; bash "$1" "$W" >/dev/null ;;
      success) before=$after; rc=0; bash "$1" "$W" >/dev/null || rc=$?; "$3" "$rc" 1 "success: retained changes stop the second sync" || return 1 ;;
      refresh-only) "$3" "$(git -C "$W" rev-parse HEAD)" "$before" "refresh-only: the run left the base unsynced" || return 1 ;;
    esac
  done <<'ROWS'
sync-base|1|post-merge: sync-base=1,
command|1|post-merge: sync-base=0,post-merge: command=1,
refresh|1|post-merge: sync-base=0,post-merge: command=0,refresh --scope project --yes --leave,post-merge: refresh=1,post-merge: changes=kept,
verify|1|post-merge: sync-base=0,post-merge: command=0,refresh --scope project --yes --leave,post-merge: refresh=0,verify --scope project,post-merge: verify=1,post-merge: changes=kept,
success|0|post-merge: sync-base=0,post-merge: command=0,refresh --scope project --yes --leave,post-merge: refresh=0,verify --scope project,post-merge: verify=0,post-merge: changes=kept,
empty|0|post-merge: sync-base=0,post-merge: command=skipped,refresh --scope project --yes --leave,post-merge: refresh=0,verify --scope project,post-merge: verify=0,post-merge: changes=kept,
absent|0|post-merge: sync-base=0,post-merge: command=0,post-merge: refresh=skipped,post-merge: verify=skipped,
refresh-only|0|refresh --scope project --yes --leave,post-merge: refresh=0,post-merge: changes=kept,
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

# The rolling record workflow can still be pending across successive merges.
# Local commands must process each merge without creating refresh dirt.
workflow_owner() { # SCRIPT TAG JUDGE
  local script="$1" tag="$2" judge="$3" W seed before after fail rc out expected calls=''
  W="$SCRATCH/workflow-$tag"
  seed="$SCRATCH/workflow-seed-$tag"
  git clone -q -c gc.auto=0 -c maintenance.auto=false "$SCRATCH/seed" "$seed"
  git -C "$seed" config user.name test
  git -C "$seed" config user.email test@example.com
  # A tracked manifest reaches refresh if command-only ever falls through.
  touch "$seed/kendex.toml"
  git -C "$seed" add kendex.toml
  git -C "$seed" commit -qm manifest
  git clone -q -c gc.auto=0 -c maintenance.auto=false "$seed" "$W"
  before="$(git -C "$W" rev-parse HEAD)"
  export COMMAND_LOG="$SCRATCH/commands-$tag" FAIL_STEP=success
  export ORCH_POST_MERGE_CMD='printf "%s:%s\n" "$ORCH_POST_MERGE_BEFORE" "$ORCH_POST_MERGE_AFTER" >> "$COMMAND_LOG"; exit "$COMMAND_EXIT"'
  # A failure on the second merge keeps the first successful checkpoint.
  while IFS='|' read -r fail expected; do
    if [[ "$fail" != retry ]]; then
      git -C "$seed" commit -qm merge --allow-empty
    fi
    after="$(git -C "$seed" rev-parse HEAD)"
    COMMAND_EXIT="$expected"; export COMMAND_EXIT
    rc=0; out="$(bash "$script" --command-only "$W" 2>"$SCRATCH/error")" || rc=$?
    "$judge" "$rc" "$expected" "$fail: command-only exit" "$SCRATCH/error" || return 1
    "$judge" "$(git -C "$W" rev-parse HEAD)" "$after" "$fail: synchronized merge" || return 1
    calls="${calls}${before}:${after}"$'\n'
    "$judge" "$(cat "$COMMAND_LOG")" "${calls%$'\n'}" "$fail: command range" || return 1
    [[ "$expected" != 0 ]] || before="$after"
    "$judge" "$(git -C "$W" rev-parse refs/kendex/post-merge-base)" "$before" "$fail: successful checkpoint" || return 1
    "$judge" "$out" $'main\npost-merge: sync-base=0\npost-merge: command='"$expected" "$fail: no refresh or verify" || return 1
    "$judge" "$(git -C "$W" status --porcelain --untracked-files=all)" '' "$fail: no refresh dirt" || return 1
  done <<'ROWS'
first|0
second|23
retry|0
ROWS
}
workflow_owner "$DIR/post-merge" real assert_eq
mutant="$(mutant_scripts orch post-merge)/post-merge" || exit 1
mutate_file "$mutant" '[[ "$mode" != command-only ]] || exit 0' ':'
rc=0; out="$(workflow_owner "$mutant" refresh-fallthrough miss 2>"$SCRATCH/control-error")" || rc=$?
assert_contains "$rc:$out" '1:miss first: no refresh or verify' 'control: local refresh during workflow ownership is rejected'

# A user can stage one version and leave a different worktree version.
# Full mode permits its configured command to create this work after sync.
REAL_GIT="$(command -v git)"
export REAL_GIT
printf 'original\n' > "$SCRATCH/seed/user file"
printf 'original\n' > "$SCRATCH/seed/line"$'\n'"break"
printf 'ignored-*\n' > "$SCRATCH/seed/.gitignore"
git -C "$SCRATCH/seed" add .
git -C "$SCRATCH/seed" commit -qm preservation
cat > "$SCRATCH/write-user-work" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf staged > 'user file'
git add 'user file'
printf unstaged > 'user file'
printf newline > "line"$'\n'"break"
printf untracked > 'user new'
printf untracked-newline > "new"$'\n'"line"
printf ignored > ignored-user
SH
preservation() { # SCRIPT TAG MODE JUDGE
  local script="$1" tag="$2" mode="$3" judge="$4" W rc=0 out flag=""
  W="$SCRATCH/preserve-$tag"
  git clone -q -c gc.auto=0 -c maintenance.auto=false "$SCRATCH/seed" "$W"
  touch "$W/kendex.toml"
  export FAIL_STEP=success
  if [[ "$mode" == refresh-only ]]; then
    (cd -- "$W" && bash "$SCRATCH/write-user-work")
    flag=--refresh-only
    export ORCH_POST_MERGE_CMD='exit 98'
  else
    export ORCH_POST_MERGE_CMD="bash '$SCRATCH/write-user-work'"
  fi
  out="$(bash "$script" $flag "$W" 2>"$SCRATCH/error")" || rc=$?
  "$judge" "$rc" 0 "$tag: exit" "$SCRATCH/error" || return 1
  "$judge" "$(cat "$W/user file")" unstaged "$tag: tracked preserved" || return 1
  "$judge" "$(git -C "$W" show ':user file')" staged "$tag: index preserved" || return 1
  "$judge" "$(cat "$W/line"$'\n'"break")" newline "$tag: newline path preserved" || return 1
  "$judge" "$(cat "$W/user new" 2>/dev/null || :)" untracked "$tag: untracked preserved" || return 1
  "$judge" "$(cat "$W/new"$'\n'"line" 2>/dev/null || :)" untracked-newline "$tag: untracked newline preserved" || return 1
  "$judge" "$(cat "$W/ignored-user")" ignored "$tag: ignored preserved" || return 1
  "$judge" "$(cat "$W/.kendex-lock.json")" stale "$tag: refresh output retained" || return 1
  "$judge" "$(cat "$W/.agents/new/render" 2>/dev/null || :)" x "$tag: new output retained" || return 1
  [[ "$mode" != refresh-only ]] || {
    rc=0
    bash "$script" "$W" > "$SCRATCH/dirty-out" 2>"$SCRATCH/error" || rc=$?
    "$judge" "$rc" 1 "$tag: full mode refuses existing tracked changes" || return 1
    "$judge" "$(cat "$W/user file");$(git -C "$W" show ':user file')" 'unstaged;staged' "$tag: refused sync preserves both versions" || return 1
  }
}
preservation "$DIR/post-merge" refresh-only refresh-only assert_eq
preservation "$DIR/post-merge" full full assert_eq

# Separate defects prove tracked restoration and new-untracked cleanup fail.
for defect in tracked untracked; do
  mutant="$(mutant_scripts orch post-merge)/post-merge" || exit 1
  case "$defect" in
    tracked) cleanup='git checkout -q -- .'; expected='1:miss tracked: tracked preserved rc=staged' ;;
    untracked) cleanup='git clean -fdq'; expected='1:miss untracked: untracked preserved rc=' ;;
  esac
  mutate_file "$mutant" '  if changes=' "  $cleanup"$'\n''  if changes='
  rc=0; out="$(preservation "$mutant" "$defect" full miss)" || rc=$?
  assert_eq "$rc:$out" "$expected" "$defect cleanup control rejects data loss"
done

# Git status may fail after refresh (for example, an index read error).
# Fail that external boundary only after kendex has run, so sync is exercised.
cat > "$SCRATCH/bin/git" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${STATUS_FAIL:-0}" == 1 && "$1" == status && -f "$REFRESH_CALLED" ]]; then
  exit 19
fi
exec "$REAL_GIT" "$@"
SH
cat > "$SCRATCH/bin/kendex" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == refresh ]]; then
  : > "$REFRESH_CALLED"
fi
case "$1:$FAIL_STEP" in
  refresh:refresh) exit 23 ;;
  verify:verify) exit 24 ;;
esac
SH
chmod +x "$SCRATCH/bin/git" "$SCRATCH/bin/kendex"
while IFS='|' read -r FAIL_STEP STATUS_FAIL expected_rc changes; do
  W="$SCRATCH/status-$FAIL_STEP-$STATUS_FAIL"
  git clone -q -c gc.auto=0 -c maintenance.auto=false "$SCRATCH/seed" "$W"
  touch "$W/kendex.toml"
  git -C "$W" add kendex.toml
  git -C "$W" -c user.name=test -c user.email=test@example.com commit -qm manifest
  # Refresh-only permits this clean fixture without synchronizing its local commit.
  REFRESH_CALLED="$SCRATCH/called-$FAIL_STEP-$STATUS_FAIL"
  export REFRESH_CALLED FAIL_STEP STATUS_FAIL
  rc=0; out="$(bash "$DIR/post-merge" --refresh-only "$W")" || rc=$?
  assert_eq "$rc" "$expected_rc" "$FAIL_STEP/$STATUS_FAIL: first failure retained"
  assert_contains "$out" "post-merge: changes=$changes" "$FAIL_STEP/$STATUS_FAIL: checkout status"
done <<'ROWS'
success|0|0|none
success|1|1|unreadable
refresh|1|23|unreadable
ROWS
unset STATUS_FAIL
# Full mode verification failure also survives a later status failure.
W="$SCRATCH/status-verify"
git clone -q -c gc.auto=0 -c maintenance.auto=false "$SCRATCH/seed" "$W"
touch "$W/kendex.toml"
export ORCH_POST_MERGE_CMD='' FAIL_STEP=verify STATUS_FAIL=1
REFRESH_CALLED="$SCRATCH/called-verify"; export REFRESH_CALLED
rc=0; out="$(bash "$DIR/post-merge" "$W")" || rc=$?
assert_eq "$rc" 24 "verification failure survives a status read failure"
assert_contains "$out" 'post-merge: changes=unreadable' "failed verification reports unreadable status"
unset STATUS_FAIL

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
