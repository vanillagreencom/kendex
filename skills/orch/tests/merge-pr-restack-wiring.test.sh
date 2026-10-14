#!/usr/bin/env bash
# The restack cycle's validation wiring in merge-pr-restack.md: step 2's live
# commands read the base branch, resolve the mode, ask restack-skip and start
# the range run after the restack and before step 3's worktree-push, and
# executed as the document writes them against a real worktree they run the
# range command and worktree-push records both pre-push and post-push runs,
# with no second publication. The skip check skips the same validated head.
# restack_skip.sh holds the skip check's own rows.
# Step 3's head read comes after the push and before step 4, and prints the
# head= of the range run's record. The full-mode route is workflow prose no
# suite can make red; dev_validate_run.sh RESOLVE_ROWS holds --resolve-mode's
# full answer with no run started.
# A live command is a line whose first text is [MAIN_REPO_ROOT]/ or
# git -C [WT_PATH], which a commented or prose copy never is. Each pin has a
# control a moved, commented or altered decoy cannot satisfy. The runner
# itself is dev_validate_run.sh.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
RESTACK_DOC="$REPO_ROOT/skills/orch/workflows/merge-pr-restack.md"
# shellcheck source=lib/assertions.sh
source "$TEST_DIR/lib/assertions.sh"
source "$TEST_DIR/lib/growth-state.sh"
TMP_ROOT="$(mktemp -d)" || { echo "merge-pr-restack-wiring: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "merge-pr-restack-wiring: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "merge-pr-restack-wiring: scratch=resolve-failed" >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT

RESTACK='worktree create [ISSUE] --restack'
BASE_READ='resolve-base-branch [WT_PATH]'
RESOLVE='dev-validate-run --resolve-mode --worktree [WT_PATH]'
SKIP='restack-skip --worktree [WT_PATH] --base origin/[BASE_BRANCH]'
RANGE='dev-validate-run --worktree [WT_PATH] --validate-mode range --base origin/[BASE_BRANCH]'
RECORD='dev-validate-run --record --run-dir [RUN_DIR]'
PUSH='worktree-push --worktree [WT_PATH] --issue [ISSUE]'
POST_RECORD='worktree-push --record-restack-validation [RUN_DIR] --worktree [WT_PATH] --issue [ISSUE]'
HEAD_READ='git -C [WT_PATH] rev-parse HEAD'
LIVE='^[[:space:]]*(\\[MAIN_REPO_ROOT\\]/|git -C \\[WT_PATH\\] )'

# command_at DOC NEEDLE — `LINE<tab>COMMAND` for the first live command line
# holding NEEDLE, or nothing.
command_at() {
  awk -v needle="$2" -v live="$LIVE" '
    $0 ~ live && index($0, needle) > 0 {
      sub(/^[[:space:]]+/, ""); printf "%d\t%s\n", NR, $0; exit
    }
  ' "$1"
}

# wiring_of DOC — `ordered` when every step-2 command is live, each after the
# one before it in the order restack, base read, mode, skip check, range run, record read, and
# all of them before step 3's push; otherwise the first command missing or out
# of place.
wiring_of() {
  local needle at push prev=0
  push="$(command_at "$1" "$PUSH")"
  [[ -n "$push" ]] || { printf 'missing: %s\n' "$PUSH"; return 0; }
  for needle in "$RESTACK" "$BASE_READ" "$RESOLVE" "$SKIP" "$RANGE" "$RECORD"; do
    at="$(command_at "$1" "$needle")"
    [[ -n "$at" ]] || { printf 'missing: %s\n' "$needle"; return 0; }
    (( ${at%%$'\t'*} > prev && ${at%%$'\t'*} < ${push%%$'\t'*} )) || { printf 'out-of-order: %s\n' "$needle"; return 0; }
    prev="${at%%$'\t'*}"
  done
  echo ordered
}

echo "=== step 2's validation commands run after the restack and before step 3's push ==="
assert_eq "$(wiring_of "$RESTACK_DOC")" "ordered" \
  "merge-pr-restack.md reads the base, resolves the mode, asks the skip check and runs the range command before the push"

echo "=== controls: a moved or commented range command fails the pin ==="
MOVED="$TMP_ROOT/moved.md"
awk -v needle="$RANGE" -v push="$PUSH" '
  /^[[:space:]]*\[MAIN_REPO_ROOT\]\// && index($0, needle) > 0 { held = $0; next }
  { print }
  /^[[:space:]]*\[MAIN_REPO_ROOT\]\// && index($0, push) > 0 { print held }
' "$RESTACK_DOC" > "$MOVED"
COMMENTED="$TMP_ROOT/commented.md"
awk -v needle="$RANGE" '
  /^[[:space:]]*\[MAIN_REPO_ROOT\]\// && index($0, needle) > 0 { sub(/\[MAIN_REPO_ROOT\]/, "# [MAIN_REPO_ROOT]") }
  { print }
' "$RESTACK_DOC" > "$COMMENTED"
assert_eq "$(wiring_of "$MOVED")" "out-of-order: $RANGE" \
  "control: a range command moved after step 3's push fails the order pin"
assert_eq "$(wiring_of "$COMMENTED")" "missing: $RANGE" \
  "control: a commented range command is not a live command"

echo "=== step 3's head read comes after its push and before step 4 ==="
# head_read_of DOC — `placed` when step 3's head read is live after the push
# and before step 4 opens; otherwise what is missing or out of place.
head_read_of() {
  local push at step4
  push="$(command_at "$1" "$PUSH")"
  at="$(command_at "$1" "$HEAD_READ")"
  step4="$(awk '/^4\. / { print NR; exit }' "$1")"
  [[ -n "$push" && -n "$at" && -n "$step4" ]] || { echo missing; return 0; }
  (( ${at%%$'\t'*} > ${push%%$'\t'*} && ${at%%$'\t'*} < step4 )) || { echo out-of-order; return 0; }
  echo placed
}

READ_BEFORE_PUSH="$TMP_ROOT/read-before-push.md"
awk -v needle="$HEAD_READ" -v push="$PUSH" -v live="$LIVE" '
  $0 ~ live && index($0, push) > 0 { print "   " needle }
  $0 ~ live && index($0, needle) > 0 { next }
  { print }
' "$RESTACK_DOC" > "$READ_BEFORE_PUSH"
assert_eq "$(head_read_of "$RESTACK_DOC")" "placed" \
  "merge-pr-restack.md reads the pushed head between step 3's push and step 4"
assert_eq "$(head_read_of "$READ_BEFORE_PUSH")" "out-of-order" \
  "control: a head read moved before step 3's push fails the placement pin"

echo "=== the live commands execute: the range run passes and step 3's head read matches its record ==="
# A worktree whose base branch origin/main sits one commit behind HEAD, with a
# full battery and a range command that each write their own marker outside
# the worktree.
make_worktree() { # NAME
  local wt="$TMP_ROOT/$1"
  git init -q -b ken-1 "$wt"
  git -C "$wt" config gc.auto 0
  git -C "$wt" config maintenance.auto false
  git -C "$wt" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m base
  git -C "$wt" update-ref refs/remotes/origin/main HEAD
  git -C "$wt" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m branch
  {
    printf '[env]\n'
    printf 'DEV_VALIDATE_CMD = "touch %s"\n' "$TMP_ROOT/$1-full-ran"
    printf 'DEV_VALIDATE_TIMEOUT_SECS = "20"\n'
    printf 'DEV_VALIDATE_RANGE_CMD = "printf %%s $DEV_VALIDATE_BASE > %s"\n' "$TMP_ROOT/$1-range-ran"
  } > "$wt/kendex.settings.toml"
  printf 'kendex.settings.toml\ntmp/\n' >> "$(git -C "$wt" rev-parse --path-format=absolute --git-path info/exclude)"
  printf '%s\n' "$wt"
}

# live DOC NEEDLE WT BASE_BRANCH RUN_DIR [SCRIPTS] — run the document's command with its
# placeholders filled, under an environment carrying none of the caller's
# DEV_VALIDATE_* settings. The range run polls every second rather than the
# default, which changes when its wait notices the end and nothing it runs.
live() {
  local line
  line="$(command_at "$1" "$2")"
  [[ -n "$line" ]] || { printf 'live: no live command holds %s\n' "$2" >&2; return 1; }
  line="${line#*$'\t'}"
  if [[ "$2" == "$RESOLVE" ]]; then
    line="$(awk '/^[[:space:]]*RESTACK_MODE_ARGS=\(\)/ {take=1} take {print} take && /dev-validate-run --resolve-mode/ {exit}' "$1")"
  fi
  line="${line//\[MAIN_REPO_ROOT\]\/.agents\/skills\/orch\/scripts\//${6:-$REPO_ROOT/skills/orch/scripts}/}"
  line="${line//\[WT_PATH\]/$3}"
  line="${line//\[BASE_BRANCH\]/$4}"
  line="${line//\[RUN_DIR\]/$5}"
  line="${line//\[ISSUE\]/KEN-1}"
  [[ "$2" != "$RANGE" ]] || line="$line --poll 1"
  (cd "$3" && env -u DEV_VALIDATE_CMD -u DEV_VALIDATE_RANGE_CMD -u DEV_VALIDATE_TIMEOUT_SECS -u DEV_VALIDATE_BASE \
    -u DEV_VALIDATE_CLASS -u DEV_VALIDATE_DOCS_ONLY -u DEV_VALIDATE_PATHS -u WORKTREE_DEFAULT_BRANCH \
    -u ORCH_STATE_DIR -u ORCH_PR_ORDER ORCH_WORKTREE_BIN="$NETWORK_PUSH" "$BASH" -c "set -u; $line")
}

fixture_failed() { echo "merge-pr-restack-wiring: fixture=failed step=$1" >&2; exit 1; }

# Step 2's route over the fixture, each command as the document writes it.
WT="$(make_worktree range)" || fixture_failed worktree
NETWORK_PUSH="$TMP_ROOT/network-push"
printf '#!/bin/sh\nexit 0\n' > "$NETWORK_PUSH"
chmod +x "$NETWORK_PUSH"
BASE="$(live "$RESTACK_DOC" "$BASE_READ" "$WT" - -)" || fixture_failed base-read
MODE="$(live "$RESTACK_DOC" "$RESOLVE" "$WT" "$BASE" -)" || fixture_failed resolve-mode
OUT="$(live "$RESTACK_DOC" "$RANGE" "$WT" "$BASE" -)" || true
VERDICT="$(sed -n 's/^state=done .*\(validate=[A-Za-z-]*\).*$/\1/p' <<<"$OUT")"
RUN_DIR="$(sed -n 's/^state=started run-dir=\([^ ]*\) .*$/\1/p' <<<"$OUT")"
RECORD_LINE="$(live "$RESTACK_DOC" "$RECORD" "$WT" "$BASE" "$RUN_DIR")" || fixture_failed record
RECORDED_HEAD="$(sed -n 's/^.* head=\([^ ]*\) .*$/\1/p' <<<"$RECORD_LINE")"

assert_eq "mode=${MODE#validate-mode=} verdict=$VERDICT record=${RECORD_LINE%% *}" \
  "mode=range verdict=validate=pass record=validate-mode=range" \
  "with DEV_VALIDATE_RANGE_CMD set the restack resolves range, runs the range command to a pass and records range"
assert_eq "$(cat "$TMP_ROOT/range-range-ran" 2>/dev/null || echo absent)" \
  "$(git -C "$WT" rev-parse origin/main)" \
  "the range command ran against the commit origin/[BASE_BRANCH] names"
assert_eq "$([[ -e "$TMP_ROOT/range-full-ran" ]] && echo ran || echo absent)" "absent" \
  "and the full battery did not run in its place"

# Only the network push is substituted. The document calls the real
# worktree-push and state writer, with the pending map a restack produces.
STATE="$REPO_ROOT/skills/orch/scripts/workflow-state"
"$STATE" --state-dir "$WT/tmp" init KEN-1 --worktree "$WT" >/dev/null
MAP_FILE="$(git -C "$WT" rev-parse --git-path kendex-rebase-map)"
[[ "$MAP_FILE" == /* ]] || MAP_FILE="$WT/$MAP_FILE"
printf 'rebase-hop:\nrebase-map: %s %s\n' "$(git -C "$WT" rev-parse HEAD~1)" "$RECORDED_HEAD" > "$MAP_FILE"
live "$RESTACK_DOC" "$PUSH" "$WT" "$BASE" "$RUN_DIR" > "$TMP_ROOT/push.out" || fixture_failed push
assert_eq "$("$STATE" --state-dir "$WT/tmp" get KEN-1 '.stages | map({kind,reason,run_dir}) | tojson')" \
  "[{\"kind\":\"validate\",\"reason\":\"restack\",\"run_dir\":\"$RUN_DIR\"}]" \
  'the document push records its actual range run as the restack stage'
assert_eq "$("$STATE" --state-dir "$WT/tmp" get KEN-1 '.validate_rounds[0] | {kind,mode,seconds} | tojson')" \
  "{\"kind\":\"restack\",\"mode\":\"range\",\"seconds\":$(sed -n 's/.* seconds=\([0-9]*\).*/\1/p' <<<"$RECORD_LINE")}" \
  'the document push records the actual range validation minutes'
STAGE_TIMES="$("$STATE" --state-dir "$WT/tmp" get KEN-1 '.stages[0] | {start,end} | tojson')"
assert_eq "$STAGE_TIMES" \
  "$(jq -cn --arg start "$(sed -n 's/.* started-at=\([^ ]*\).*/\1/p' <<<"$RECORD_LINE")" --arg end "$(sed -n 's/.* ended-at=\([^ ]*\).*/\1/p' <<<"$RECORD_LINE")" '{start:($start|fromdateiso8601),end:($end|fromdateiso8601)}')" \
  'the document push records the run start and end'

MUTANT_SCRIPTS="$(mutant_scripts no-stage-writer worktree-push)" || fixture_failed mutant
mutate_file "$MUTANT_SCRIPTS/worktree-push" 'record_restack_validation() {' 'record_restack_validation() { return 0'
"$STATE" --state-dir "$WT/tmp" update KEN-1 '.stages=[] | .validate_rounds=[]'
printf 'rebase-hop:\nrebase-map: %s %s\n' "$(git -C "$WT" rev-parse HEAD~1)" "$RECORDED_HEAD" > "$MAP_FILE"
live "$RESTACK_DOC" "$PUSH" "$WT" "$BASE" "$RUN_DIR" "$MUTANT_SCRIPTS" > "$TMP_ROOT/control-push.out" || fixture_failed control-push
assert_eq "$("$STATE" --state-dir "$WT/tmp" get KEN-1 '.stages')" '[]' \
  'control: dropping the push writer fails the real recording assertion'

SKIP_LINE="$(live "$RESTACK_DOC" "$SKIP" "$WT" "$BASE" -)" || true
assert_eq "${SKIP_LINE%% *}" "restack=skip" \
  "the document's skip check, asked again of the head the range run passed, skips it"

# head_check DOC — `same` when DOC's step-3 head read, run in the fixture,
# prints the head= of the range run's record; `differs` otherwise.
head_check() {
  local now
  now="$(live "$1" "$HEAD_READ" "$WT" - -)" || fixture_failed head-read
  [[ -n "$RECORDED_HEAD" && "$now" == "$RECORDED_HEAD" ]] && echo same || echo differs
}

PARENT_READ="$TMP_ROOT/parent-read.md"
awk -v needle="$HEAD_READ" -v live="$LIVE" '
  $0 ~ live && index($0, needle) > 0 { sub(/rev-parse HEAD$/, "rev-parse HEAD~1") }
  { print }
' "$RESTACK_DOC" > "$PARENT_READ"

assert_eq "$(head_check "$RESTACK_DOC")" "same" \
  "step 3's head read prints the head= the range run recorded"
assert_eq "$(head_check "$PARENT_READ")" "differs" \
  "control: a head read of HEAD~1 keeps the matched text and fails the equality row"

echo '=== a push-time rewrite records both real range runs without another push ==='
cat > "$NETWORK_PUSH" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
wt="$2"
printf 'push\n' >> "$wt/tmp/network-pushes"
old="$(git -C "$wt" rev-parse HEAD)"
git -C "$wt" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m push-rewrite
new="$(git -C "$wt" rev-parse HEAD)"
map="$(git -C "$wt" rev-parse --git-path kendex-rebase-map)"
[[ "$map" == /* ]] || map="$wt/$map"
printf 'rebase-hop:\nrebase-map: %s %s\n' "$old" "$new" > "$map"
SH
"$STATE" --state-dir "$WT/tmp" update KEN-1 '.stages=[] | .validate_rounds=[]'
printf 'rebase-hop:\nrebase-map: %s %s\n' "$(git -C "$WT" rev-parse HEAD~1)" "$RECORDED_HEAD" > "$MAP_FILE"
live "$RESTACK_DOC" "$PUSH" "$WT" "$BASE" "$RUN_DIR" > "$TMP_ROOT/rewrite-push.out" || fixture_failed rewrite-push
assert_eq "$(head_check "$RESTACK_DOC")" differs 'the document head check detects the head rewritten during the push'
assert_eq "$("$STATE" --state-dir "$WT/tmp" get KEN-1 '.stages | map(.run_dir) | tojson')" \
  "[\"$RUN_DIR\"]" 'the first run is recorded against its pre-push head'
OUT="$(live "$RESTACK_DOC" "$RANGE" "$WT" "$BASE" -)" || true
assert_eq "$(sed -n 's/^state=done .*\(validate=[A-Za-z-]*\).*$/\1/p' <<<"$OUT")" validate=pass 'the rewritten head passes the real second range run'
POST_RUN_DIR="$(sed -n 's/^state=started run-dir=\([^ ]*\) .*$/\1/p' <<<"$OUT")"
POST_LINE="$(live "$RESTACK_DOC" "$RECORD" "$WT" "$BASE" "$POST_RUN_DIR")" || fixture_failed post-record-read
RECORDED_HEAD="$(sed -n 's/^.* head=\([^ ]*\) .*$/\1/p' <<<"$POST_LINE")"
assert_eq "$(head_check "$RESTACK_DOC")" same 'the second record read binds the current pushed head'
printf 'rebase-unmapped: %s\n' "$RECORDED_HEAD" > "$MAP_FILE"
for attempt in first recheck; do
  live "$RESTACK_DOC" "$POST_RECORD" "$WT" "$BASE" "$POST_RUN_DIR" > "$TMP_ROOT/post-$attempt.out" || fixture_failed post-record
done
assert_eq "$("$STATE" --state-dir "$WT/tmp" get KEN-1 '.stages | map(.run_dir) | tojson')" \
  "[\"$RUN_DIR\",\"$POST_RUN_DIR\"]" 'both routes share the writer and deduplicate the second run directory'
assert_eq "$("$STATE" --state-dir "$WT/tmp" get KEN-1 '.validate_rounds | map({kind,mode,seconds}) | tojson')" \
  "[{\"kind\":\"restack\",\"mode\":\"range\",\"seconds\":$(sed -n 's/.* seconds=\([0-9]*\).*/\1/p' <<<"$RECORD_LINE")},{\"kind\":\"restack\",\"mode\":\"range\",\"seconds\":$(sed -n 's/.* seconds=\([0-9]*\).*/\1/p' <<<"$POST_LINE")}]" \
  'the post-push route includes the second run time in validation minutes'
assert_eq "$(cat "$WT/tmp/network-pushes")" push 'recording the second run never publishes again'
assert_eq "$(cat "$MAP_FILE")" "rebase-unmapped: $RECORDED_HEAD" 'recording timing consumes no restack map'
rm -f "$MAP_FILE"
live "$RESTACK_DOC" "$POST_RECORD" "$WT" "$BASE" "$RUN_DIR" > "$TMP_ROOT/wrong-head.out" 2> "$TMP_ROOT/wrong-head.err" || fixture_failed wrong-head
assert_eq "$(cat "$TMP_ROOT/wrong-head.err")" 'worktree-push: stage-unrecorded issue=KEN-1' 'a run for the pre-push head reports unavailable on the post-push route'
assert_eq "$("$STATE" --state-dir "$WT/tmp" get KEN-1 '.stages | map(.run_dir) | tojson')" \
  "[\"$RUN_DIR\",\"$POST_RUN_DIR\"]" 'an unavailable timing record leaves both accepted runs unchanged'
"$STATE" --state-dir "$WT/tmp" update KEN-1 '.stages=[] | .validate_rounds=[]'
live "$RESTACK_DOC" "$POST_RECORD" "$WT" "$BASE" "$POST_RUN_DIR" "$MUTANT_SCRIPTS" > "$TMP_ROOT/control-post.out" || fixture_failed control-post
assert_eq "$("$STATE" --state-dir "$WT/tmp" get KEN-1 '.stages')" '[]' 'control: dropping the shared writer fails the post-push recording assertion'
MUTANT_SCRIPTS="$(mutant_scripts publishing-record-mode worktree-push)" || fixture_failed mutant-record-mode
mutate_file "$MUTANT_SCRIPTS/worktree-push" $'\texit 0\nfi\n\n# Every rewrite' $'\t:\nfi\n\n# Every rewrite'
live "$RESTACK_DOC" "$POST_RECORD" "$WT" "$BASE" "$POST_RUN_DIR" "$MUTANT_SCRIPTS" > "$TMP_ROOT/control-publication.out" || fixture_failed control-publication
assert_eq "$(cat "$WT/tmp/network-pushes")" $'push\npush' 'control: dropping the recording-only exit fails the no-second-publication assertion'

# The restack's real mode read and CI command use the same required-context
# owner. This branch changes shell source so the classifier covers it.
CI_WT="$(make_worktree ci-restack)" || fixture_failed ci-worktree
# A declared queue path lets the real classifier prove this shell change has
# no queue work. Undeclared queue paths cannot prove PR coverage.
printf 'HARNESS_CI_QUEUE_PATHS = "queued/**"\n' >> "$CI_WT/kendex.settings.toml"
git -C "$CI_WT" add -f kendex.settings.toml
git -C "$CI_WT" -c user.name=t -c user.email=t@example.com commit -q -m coverage
git -C "$CI_WT" update-ref refs/remotes/origin/main HEAD
# Policy variations exercise the workflow order without adding a settings
# change to the classifier's snapshot.
git -C "$CI_WT" update-index --skip-worktree kendex.settings.toml
printf '#!/bin/sh\nprintf changed\\n\n' > "$CI_WT/check.sh"
git -C "$CI_WT" add check.sh
git -C "$CI_WT" -c user.name=t -c user.email=t@example.com commit -q -m source
printf 'ORCH_PR_ORDER = "push-first"\nDEV_VALIDATE_CI_CONTEXT = "CI"\n' >> "$CI_WT/kendex.settings.toml"
mkdir -p "$TMP_ROOT/ci-bin"
cat > "$TMP_ROOT/ci-bin/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case "$2" in
  status) exit 0 ;;
  view) printf '{"state":"OPEN","baseRefName":"main"}\n' ;;
  'repos/{owner}/{repo}/rules/branches/main')
    context=CI
    case "${PROOF_CI_WORLD:-required}" in empty|unrequired) context=Lint ;; esac
    printf '[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"%s"}]}},{"type":"merge_queue"}]\n' "$context"
    [[ "${PROOF_CI_WORLD:-required}" != unreadable ]] || exit 1 ;;
  'repos/{owner}/{repo}/branches/main') : ;;
  *) exit 9 ;;
esac
SH
chmod +x "$TMP_ROOT/ci-bin/gh"
CI_COMMAND='dev-validate-run --worktree [WT_PATH] --validate-mode ci --base origin/[BASE_BRANCH]'
CI_RESOLVED="$(PATH="$TMP_ROOT/ci-bin:$PATH" live "$RESTACK_DOC" "$RESOLVE" "$CI_WT" main -)" || fixture_failed ci-resolve
assert_eq "$CI_RESOLVED" validate-mode=ci 'push-first restack resolves to pending CI'
CI_OUT="$(PATH="$TMP_ROOT/ci-bin:$PATH" live "$RESTACK_DOC" "$CI_COMMAND" "$CI_WT" main -)" || fixture_failed ci-start
CI_DIR="$(sed -n 's/^state=started run-dir=\([^ ]*\) .*$/\1/p' <<<"$CI_OUT")"
CI_RECORD="$(live "$RESTACK_DOC" "$RECORD" "$CI_WT" main "$CI_DIR")" || fixture_failed ci-record
assert_contains "$CI_RECORD" 'validate-mode=ci selection=unreported verdict=pending' 'restack records pending proof, not a local pass'
assert_contains "$CI_RECORD" "head=$(git -C "$CI_WT" rev-parse HEAD)" 'restack CI record binds the restacked head'
assert_eq "$([[ -e "$TMP_ROOT/ci-restack-range-ran" || -e "$TMP_ROOT/ci-restack-full-ran" ]] && echo ran || echo deferred)" deferred 'restack starts no local command'
MUTANT_SCRIPTS="$(mutant_scripts ci-restack-mode dev-validate-run)" || fixture_failed ci-mutant
mutate_file "$MUTANT_SCRIPTS/dev-validate-run" '"$validate_mode" == ci || "$pr_order" == push-first' '"$validate_mode" == ci || false'
CI_RESOLVED="$(PATH="$TMP_ROOT/ci-bin:$PATH" live "$RESTACK_DOC" "$RESOLVE" "$CI_WT" main - "$MUTANT_SCRIPTS")" || fixture_failed ci-control
assert_eq "$CI_RESOLVED" validate-mode=range 'control: dropping automatic CI breaks the push-first restack mode'

# Execute the workflow's mode block for every order under a covered subset.
for order in review-first open-first push-first; do
  sed '/^ORCH_PR_ORDER =/d; /^DEV_VALIDATE_SELECTION_CMD =/d' "$CI_WT/kendex.settings.toml" > "$CI_WT/settings.next"
  mv "$CI_WT/settings.next" "$CI_WT/kendex.settings.toml"
  printf 'ORCH_PR_ORDER = "%s"\nDEV_VALIDATE_SELECTION_CMD = "echo selection=subset"\n' "$order" >> "$CI_WT/kendex.settings.toml"
  want=range
  [[ "$order" != push-first ]] || want=ci
  CI_RESOLVED="$(PATH="$TMP_ROOT/ci-bin:$PATH" live "$RESTACK_DOC" "$RESOLVE" "$CI_WT" main -)" || fixture_failed order-resolve
  assert_eq "$CI_RESOLVED" "validate-mode=$want" "$order keeps its restack validation order with subset CI coverage"
done
cp "$RESTACK_DOC" "$TMP_ROOT/restack-order-mutant.md"
mutate_file "$TMP_ROOT/restack-order-mutant.md" '[[ "$PR_ORDER" != pr-order=push-first ]] ||' 'false ||'
sed '/^ORCH_PR_ORDER =/d' "$CI_WT/kendex.settings.toml" > "$CI_WT/settings.next"
mv "$CI_WT/settings.next" "$CI_WT/kendex.settings.toml"
printf 'ORCH_PR_ORDER = "review-first"\n' >> "$CI_WT/kendex.settings.toml"
CI_RESOLVED="$(PATH="$TMP_ROOT/ci-bin:$PATH" live "$TMP_ROOT/restack-order-mutant.md" "$RESOLVE" "$CI_WT" main -)" || fixture_failed order-control
assert_eq "$CI_RESOLVED" validate-mode=ci 'control: applying the opt-in base to every order breaks review-first restack validation'

cp "$RESTACK_DOC" "$TMP_ROOT/restack-array-mutant.md"
mutate_file "$TMP_ROOT/restack-array-mutant.md" '${RESTACK_MODE_ARGS[@]+"${RESTACK_MODE_ARGS[@]}"}' '"${RESTACK_MODE_ARGS[@]}"'
if (( BASH_VERSINFO[0] == 3 && BASH_VERSINFO[1] == 2 )); then
  array_rc=0
  LC_ALL=C PATH="$TMP_ROOT/ci-bin:$PATH" live "$TMP_ROOT/restack-array-mutant.md" "$RESOLVE" "$CI_WT" main - > "$TMP_ROOT/array-control.out" 2> "$TMP_ROOT/array-control.err" || array_rc=$?
  array_error="$(sed 's/^[^:]*: line [0-9][0-9]*: //' "$TMP_ROOT/array-control.err")"
  printf 'control: bare-array diagnostic=%s\n' "$array_error"
  assert_eq "$array_rc" 127 'control: bare empty-array expansion fails review-first under Bash 3.2 nounset' "$TMP_ROOT/array-control.err"
  assert_eq "$array_error" 'RESTACK_MODE_ARGS[@]: unbound variable' 'control: bare empty-array failure names the target array' "$TMP_ROOT/array-control.err"
else
  printf 'control: bare-array requires Bash 3.2; current=%s\n' "$BASH_VERSION"
fi

# Pending validation comes from an accepted receipt or a run submit starts.
# Execute the workflow's binding and no-CI check against the real run record.
submit_none_check() { # DOC SOURCE
  local block binding mode=ci
  block="$(awk '/^```bash/ {inside=1; block=""; next} /^```/ && inside {if (index(block, "submit-pr: ci-uncovered")) {printf "%s", block; exit} inside=0} inside {block=block $0 ORS}' "$1")"
  [[ -n "$block" ]] || return 2
  if [[ "$2" == run ]]; then
    binding="$(awk '/^```bash/ {inside=1; block=""; next} /^```/ && inside {if (index(block, "SUBMIT_VALIDATE_RECORD=")) {printf "%s", block; exit} inside=0} inside {block=block $0 ORS}' "$1")"
    [[ -n "$binding" ]] || return 2
    binding="${binding//.agents\/skills\/orch\/scripts\//$REPO_ROOT/skills/orch/scripts/}"
    binding="${binding//\[RUN_DIR\]/$CI_DIR}"
    block="$binding"$'\n'"$block"
    mode=
  fi
  env -i PATH="$PATH" SUBMIT_VALIDATE_MODE="$mode" "$BASH" -uc "$block"
}
SUBMIT_DOC="$REPO_ROOT/skills/orch/workflows/submit-pr.md"
for source in receipt run; do
  none_rc=0
  submit_none_check "$SUBMIT_DOC" "$source" > "$TMP_ROOT/submit-none-$source.out" 2> "$TMP_ROOT/submit-none-$source.err" || none_rc=$?
  # Submit's caller consumes this keyed refusal, not the runner's read errors.
  assert_eq "$none_rc $(sed -n 's/^submit-pr: ci-uncovered cause=//p' "$TMP_ROOT/submit-none-$source.err")" '1 no-required-ci' "a pending ci $source blocks submit when the live CI wait has verdict=none"
done
cp "$SUBMIT_DOC" "$TMP_ROOT/submit-none-mutant.md"
mutate_file "$TMP_ROOT/submit-none-mutant.md" '[[ "$SUBMIT_VALIDATE_MODE" == ci ]]' '[[ "$SUBMIT_VALIDATE_MODE" == full ]]'
none_rc=0
submit_none_check "$TMP_ROOT/submit-none-mutant.md" receipt > "$TMP_ROOT/submit-none-control.out" 2> "$TMP_ROOT/submit-none-control.err" || none_rc=$?
assert_eq "$none_rc" 0 'control: dropping the ci receipt check permits an uncovered submit'
cp "$SUBMIT_DOC" "$TMP_ROOT/submit-mode-mutant.md"
mutate_file "$TMP_ROOT/submit-mode-mutant.md" 'SUBMIT_VALIDATE_MODE="${SUBMIT_VALIDATE_MODE#validate-mode=}"' 'SUBMIT_VALIDATE_MODE="${SUBMIT_VALIDATE_MODE#validate-mode=}"; SUBMIT_VALIDATE_MODE=full'
none_rc=0
submit_none_check "$TMP_ROOT/submit-mode-mutant.md" run > "$TMP_ROOT/submit-mode-control.out" 2> "$TMP_ROOT/submit-mode-control.err" || none_rc=$?
assert_eq "$none_rc" 0 'control: discarding the pending run mode permits an uncovered submit'

# Exercise the merge block before a direct attempt or queue arm. The workflow
# reads real skip state and calls the shipped proof owner; only GitHub is stubbed.
MERGE_DOC="$REPO_ROOT/skills/orch/workflows/merge-pr.md"
merge_proof() { # WT [SCRIPTS]
  local block wt="$1" scripts="${2:-$REPO_ROOT/skills/orch/scripts}"
  block="$(awk '/^   ```bash/ {inside=1; block=""; next} /^   ```/ && inside {if (index(block, "RESTACK_SKIPS=")) {printf "%s", block; exit} inside=0} inside {block=block $0 ORS}' "$MERGE_DOC")"
  [[ -n "$block" ]] || return 2
  block="${block//.agents\/skills\/orch\/scripts\//$scripts/}"
  block="${block//\[STATE_KEY\]/KEN-1}"
  block="${block//\[PREPARED_HEAD\]/$(git -C "$wt" rev-parse HEAD)}"
  block="${block//\[PREPARED_BASE\]/$(git -C "$wt" rev-parse origin/main)}"
  block="${block//\[WORKTREE_PATH\]/$wt}"
  (cd "$wt" && env -u ORCH_STATE_DIR -u DEV_VALIDATE_CI_CONTEXT -u DEV_VALIDATE_SELECTION_CMD \
    -u ORCH_PR_ORDER PATH="$TMP_ROOT/ci-bin:$PATH" "$BASH" -euo pipefail -c "$block"$'\n''echo merge-admitted')
}
record_skip() { # WT LINE
  local head validated
  head="$(sed -n 's/.* head=\([^ ]*\).*/\1/p' <<<"$2")"
  validated="$(sed -n 's/.* validated-head=\([^ ]*\).*/\1/p' <<<"$2")"
  [[ -n "$head" && -n "$validated" ]] || fixture_failed proof-skip
  "$STATE" --state-dir "$1/tmp" update KEN-1 --arg head "$head" --arg validated "$validated" \
    '.restack_skips=[{head:$head,validated_head:$validated,condition:"no-conflict",paths:[]}]'
}
MUTANT_PROOF="$(mutant_scripts missing-proof-refusal dev-validate-run)" || fixture_failed proof-control
mutate_file "$MUTANT_PROOF/dev-validate-run" $'    exit 1\n  fi\n  # Read against an empty default' $'    : # exit 1\n    exit 0\n  fi\n  # Read against an empty default'
for cause in timeout host; do
  PROOF_WT="$(make_worktree "proof-$cause")" || fixture_failed proof-worktree
  printf 'HARNESS_CI_QUEUE_PATHS = "queued/**"\nDEV_VALIDATE_FINDING_PREFIX = "guard: "\n' >> "$PROOF_WT/kendex.settings.toml"
  # Keep settings out of the validation snapshot when each CI contract varies.
  git -C "$PROOF_WT" add -f kendex.settings.toml
  git -C "$PROOF_WT" -c user.name=t -c user.email=t@example.com commit -q -m settings
  git -C "$PROOF_WT" update-ref refs/remotes/origin/main HEAD
  git -C "$PROOF_WT" update-index --skip-worktree kendex.settings.toml
  printf '#!/bin/sh\nprintf changed\\n\n' > "$PROOF_WT/check.sh"
  git -C "$PROOF_WT" add check.sh
  git -C "$PROOF_WT" -c user.name=t -c user.email=t@example.com commit -q -m source
  sed '/^DEV_VALIDATE_CMD =/d; /^DEV_VALIDATE_TIMEOUT_SECS =/d' "$PROOF_WT/kendex.settings.toml" > "$PROOF_WT/settings.next"
  mv "$PROOF_WT/settings.next" "$PROOF_WT/kendex.settings.toml"
  printf 'ORCH_PR_ORDER = "review-first"\nDEV_VALIDATE_CMD = "if test x$PROOF_EXIT = x124; then sleep 2; else exit $PROOF_EXIT; fi"\nDEV_VALIDATE_TIMEOUT_SECS = "1"\n' >> "$PROOF_WT/kendex.settings.toml"
  PROOF_EXIT=3
  [[ "$cause" != timeout ]] || PROOF_EXIT=124
  export PROOF_EXIT
  proof_rc=0
  OUT="$(cd "$PROOF_WT" && env -u DEV_VALIDATE_CI_CONTEXT -u ORCH_PR_ORDER \
    "$REPO_ROOT/skills/orch/scripts/dev-validate-run" --worktree "$PROOF_WT" --poll 1)" || proof_rc=$?
  assert_eq "$proof_rc $(sed -n 's/^state=done .* validate=\([^ ]*\).*/\1/p' <<<"$OUT")" '1 no-verdict' "$cause produces a real no-verdict"
  # Move the base and rebase the no-verdict branch before the real skip check.
  git -C "$PROOF_WT" checkout -qb base-update origin/main
  printf 'base changed\n' > "$PROOF_WT/base.sh"
  git -C "$PROOF_WT" add base.sh
  git -C "$PROOF_WT" -c user.name=t -c user.email=t@example.com commit -q -m base-update
  git -C "$PROOF_WT" update-ref refs/remotes/origin/main HEAD
  git -C "$PROOF_WT" checkout -q ken-1
  git -C "$PROOF_WT" -c user.name=t -c user.email=t@example.com rebase -q origin/main
  "$STATE" --state-dir "$PROOF_WT/tmp" init KEN-1 --worktree "$PROOF_WT" >/dev/null
  SKIP_LINE="$(live "$RESTACK_DOC" "$SKIP" "$PROOF_WT" main -)" || fixture_failed proof-reuse
  record_skip "$PROOF_WT" "$SKIP_LINE"
  for row in 'empty|setting-empty' 'unrequired|context-unrequired' 'unreadable|rules-unread' 'required|ci'; do
    IFS='|' read -r PROOF_CI_WORLD want <<<"$row"
    export PROOF_CI_WORLD
    sed '/^DEV_VALIDATE_CI_CONTEXT =/d' "$PROOF_WT/kendex.settings.toml" > "$PROOF_WT/settings.next"
    mv "$PROOF_WT/settings.next" "$PROOF_WT/kendex.settings.toml"
    [[ "$PROOF_CI_WORLD" == empty ]] || printf 'DEV_VALIDATE_CI_CONTEXT = "CI"\n' >> "$PROOF_WT/kendex.settings.toml"
    proof_rc=0
    OUT="$(merge_proof "$PROOF_WT")" || proof_rc=$?
    if [[ "$want" == ci ]]; then
      assert_contains "$OUT" "validation-proof=ci verdict=pending head=$(git -C "$PROOF_WT" rev-parse HEAD)" "$cause admits required exact-head validation CI"
      assert_eq "$proof_rc ${OUT##*$'\n'}" '0 merge-admitted' "$cause admits the existing CI route"
    else
      assert_eq "$proof_rc ${OUT##*$'\n'}" "1 validation-proof=missing ci-fallback=$want" "$cause holds merge and queue for $PROOF_CI_WORLD CI"
      CONTROL_OUT="$(merge_proof "$PROOF_WT" "$MUTANT_PROOF")" || fixture_failed proof-control-run
      assert_eq "${CONTROL_OUT##*$'\n'}" merge-admitted 'control: removing refusal while retaining invocation permits uncovered merge'
    fi
  done
  # A changed pushed head reads its own skip and needs its own proof.
  git -C "$PROOF_WT" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m pushed-head
  SKIP_LINE="$(live "$RESTACK_DOC" "$SKIP" "$PROOF_WT" main -)" || fixture_failed rewritten-skip
  record_skip "$PROOF_WT" "$SKIP_LINE"
  sed '/^DEV_VALIDATE_CI_CONTEXT =/d' "$PROOF_WT/kendex.settings.toml" > "$PROOF_WT/settings.next"
  mv "$PROOF_WT/settings.next" "$PROOF_WT/kendex.settings.toml"
  OUT="$(live "$RESTACK_DOC" "$RANGE" "$PROOF_WT" main -)" || fixture_failed range-proof
  proof_rc=0
  OUT="$(merge_proof "$PROOF_WT")" || proof_rc=$?
  assert_eq "$proof_rc ${OUT##*$'\n'}" '1 validation-proof=missing ci-fallback=setting-empty' 'a pass from another recorded head and range command supplies no full proof'
  sed '/^DEV_VALIDATE_CI_CONTEXT =/d; /^DEV_VALIDATE_RANGE_CMD =/d' "$PROOF_WT/kendex.settings.toml" > "$PROOF_WT/settings.next"
  mv "$PROOF_WT/settings.next" "$PROOF_WT/kendex.settings.toml"
  proof_rc=0
  OUT="$(merge_proof "$PROOF_WT")" || proof_rc=$?
  assert_eq "$proof_rc ${OUT##*$'\n'}" '1 validation-proof=missing ci-fallback=setting-empty' "$cause full fallback on the pushed head keeps missing proof"
  PROOF_EXIT=0
  export PROOF_EXIT
  OUT="$(cd "$PROOF_WT" && env -u DEV_VALIDATE_CI_CONTEXT -u ORCH_PR_ORDER \
    "$REPO_ROOT/skills/orch/scripts/dev-validate-run" --worktree "$PROOF_WT" --poll 1 --fresh)" || fixture_failed local-proof
  LOCAL_DIR="$(sed -n 's/^state=started run-dir=\([^ ]*\) .*/\1/p' <<<"$OUT")"
  # These record fields come from scoped selection and full fix-round runs.
  # A current-tree pass still needs whole-branch coverage at this boundary.
  cp "$LOCAL_DIR/start" "$TMP_ROOT/proof-start"
  cp "$LOCAL_DIR/log" "$TMP_ROOT/proof-log"
  for coverage in scoped range battery; do
    cp "$TMP_ROOT/proof-start" "$LOCAL_DIR/start"
    cp "$TMP_ROOT/proof-log" "$LOCAL_DIR/log"
    case "$coverage" in
      scoped) printf 'scoped=true\n' >> "$LOCAL_DIR/start" ;;
      range|battery) printf 'class-base=%s\n' "$(git -C "$PROOF_WT" rev-parse origin/main)" >> "$LOCAL_DIR/start" ;;
    esac
    [[ "$coverage" != battery ]] || printf 'validate: lanes=orch selection=battery\n' >> "$LOCAL_DIR/log"
    proof_rc=0
    OUT="$(merge_proof "$PROOF_WT")" || proof_rc=$?
    if [[ "$coverage" == battery ]]; then
      assert_eq "$proof_rc ${OUT##*$'\n'}" '0 merge-admitted' 'a full fix-round run with stated battery coverage proves the branch'
    else
      assert_eq "$proof_rc ${OUT##*$'\n'}" '1 validation-proof=missing ci-fallback=setting-empty' "$coverage local record alone does not prove the branch"
    fi
  done
  cp "$TMP_ROOT/proof-start" "$LOCAL_DIR/start"
  cp "$TMP_ROOT/proof-log" "$LOCAL_DIR/log"
  OUT="$(merge_proof "$PROOF_WT")" || fixture_failed local-proof-read
  assert_contains "$OUT" "validation-proof=local-pass run-dir=$LOCAL_DIR" "$cause accepts the genuine current-tree full local pass"
  assert_eq "${OUT##*$'\n'}" merge-admitted 'the local proof reaches the merge route'
  SKIP_LINE="$(live "$RESTACK_DOC" "$SKIP" "$PROOF_WT" main -)" || fixture_failed pass-skip
  record_skip "$PROOF_WT" "$SKIP_LINE"
  OUT="$(merge_proof "$PROOF_WT")" || fixture_failed pass-proof-read
  assert_contains "$OUT" "validation-proof=tree-pass run-dir=$LOCAL_DIR" 'a genuine-pass-backed skip retains accepted equivalence reuse'
done
unset PROOF_EXIT PROOF_CI_WORLD

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
