#!/usr/bin/env bash
# The restack cycle's wiring in merge-pr-restack.md, executed as the document
# writes it against a real worktree: step 2 asks record-push for a fix round in
# flight, reads the base, resolves the mode, asks restack-skip and starts the
# range run before step 3's record-push; the push records that run as the
# item's restack stage, a second run recorded after a push-time rewrite takes
# no second publication, and step 3's proof block prints the reader's reply,
# hands back on a refusal and holds the merge on a missing answer. restack_skip.sh holds the skip check's
# own rows, tests/rust/push.rs the push's and tests/rust/validate.rs the
# runner's.
# A live command is a line whose first text is [MAIN_REPO_ROOT]/ or
# git -C [WT_PATH], which a commented or prose copy never is. A request is the
# JSON the document's sentence writes to the file its fence names. Each pin has
# a control a moved, commented or altered decoy cannot satisfy. Only the
# worktree skill's push and gh are stood in.
# Inputs: skills/agent-runtime/, skills/agent-runtime/scripts/, skills/change-scope/references/,
# skills/change-scope/scripts/, skills/communication/references/reports.md, skills/mailbox/scripts/,
# skills/orch/runtime/, skills/orch/scripts/, skills/orch/tests/,
# skills/orch/workflows/merge-pr-restack.md, skills/orch/workflows/submit-pr.md.
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

RUNTIME="$REPO_ROOT/skills/orch/scripts/orch-runtime"
INSTALL=(CHANGE_SCOPE_PATHS_CLI="$REPO_ROOT/skills/change-scope/scripts/harness-only")
LIVE_ROUND='orch-runtime op --item [ISSUE] --request [WT_PATH]/tmp/restack-live-round-[ISSUE].json'
RESTACK='worktree create [ISSUE] --restack'
BASE_READ='resolve-base-branch [WT_PATH]'
RESOLVE='dev-validate-run --resolve-mode --worktree [WT_PATH]'
SKIP='restack-skip --worktree [WT_PATH] --base origin/[BASE_BRANCH]'
RANGE='dev-validate-run --worktree [WT_PATH] --validate-mode range --base origin/[BASE_BRANCH]'
RECORD='dev-validate-run --record --run-dir [RUN_DIR]'
PUSH='orch-runtime op --item [ISSUE] --request [WT_PATH]/tmp/restack-push-[ISSUE].json'
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
# one before it in the order live-round check, restack, base read, mode, skip
# check, range run, record read, and all of them before step 3's push;
# otherwise the first command missing or out of place.
wiring_of() {
  local needle at push prev=0
  push="$(command_at "$1" "$PUSH")"
  [[ -n "$push" ]] || { printf 'missing: %s\n' "$PUSH"; return 0; }
  for needle in "$LIVE_ROUND" "$RESTACK" "$BASE_READ" "$RESOLVE" "$SKIP" "$RANGE" "$RECORD"; do
    at="$(command_at "$1" "$needle")"
    [[ -n "$at" ]] || { printf 'missing: %s\n' "$needle"; return 0; }
    (( ${at%%$'\t'*} > prev && ${at%%$'\t'*} < ${push%%$'\t'*} )) || { printf 'out-of-order: %s\n' "$needle"; return 0; }
    prev="${at%%$'\t'*}"
  done
  echo ordered
}

echo "=== step 2's commands run after the live-round check and before step 3's push ==="
assert_eq "$(wiring_of "$RESTACK_DOC")" "ordered" \
  "merge-pr-restack.md asks for a live round, reads the base, resolves the mode, asks the skip check and runs the range command before the push"

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
# install_skills WT — link the skills the runtime's validation reads from the
# project's install (`.agents/skills/<name>`) to this checkout's own, kept out
# of git's view of the worktree.
install_skills() {
  local name
  mkdir -p "$1/.agents/skills"
  for name in orch github change-scope harness-ci; do
    [[ ! -d "$REPO_ROOT/skills/$name" ]] || ln -s "$REPO_ROOT/skills/$name" "$1/.agents/skills/$name"
  done
  printf '.agents/\n' >> "$(git -C "$1" rev-parse --path-format=absolute --git-path info/exclude)"
}

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
  install_skills "$wt"
  printf '%s\n' "$wt"
}

# live DOC NEEDLE WT BASE_BRANCH RUN_DIR — run the document's command with its
# placeholders filled, under an environment carrying none of the caller's
# DEV_VALIDATE_* settings, the worktree skill's push stood in by
# $NETWORK_PUSH. The fixture repository links this checkout's skills where an
# install puts them, and the program an install's settings name is named
# here from this checkout. The range run polls every second rather than the
# default, which changes when its wait notices the end and nothing it runs.
live() {
  local line
  line="$(command_at "$1" "$2")"
  [[ -n "$line" ]] || { printf 'live: no live command holds %s\n' "$2" >&2; return 1; }
  line="${line#*$'\t'}"
  if [[ "$2" == "$RESOLVE" ]]; then
    line="$(awk '/^[[:space:]]*RESTACK_MODE_ARGS=\(\)/ {take=1} take {print} take && /dev-validate-run --resolve-mode/ {exit}' "$1")"
  fi
  line="${line//\[MAIN_REPO_ROOT\]\/.agents\/skills\/orch\/scripts\//$REPO_ROOT/skills/orch/scripts/}"
  line="${line//\[WT_PATH\]/$3}"
  line="${line//\[BASE_BRANCH\]/$4}"
  line="${line//\[RUN_DIR\]/$5}"
  line="${line//\[ISSUE\]/KEN-1}"
  [[ "$2" != "$RANGE" ]] || line="$line --poll 1"
  (cd "$3" && env -u DEV_VALIDATE_CMD -u DEV_VALIDATE_RANGE_CMD -u DEV_VALIDATE_TIMEOUT_SECS -u DEV_VALIDATE_BASE \
    -u DEV_VALIDATE_CLASS -u DEV_VALIDATE_DOCS_ONLY -u DEV_VALIDATE_PATHS -u WORKTREE_DEFAULT_BRANCH \
    -u ORCH_STATE_DIR -u ORCH_PR_ORDER "${INSTALL[@]}" WORKTREE_CLI="$NETWORK_PUSH" "$BASH" -c "set -u; $line")
}

# request_of DOC FILE — the JSON the document's sentence writes to FILE with
# the harness file tool, or nothing.
request_of() {
  awk -v file="$2" '
    BEGIN { lead = "`" file "` with the harness file tool as `" }
    { at = index($0, lead) }
    at > 0 { rest = substr($0, at + length(lead)); print substr(rest, 1, index(rest, "`") - 1); exit }
  ' "$1"
}

# op_live DOC NAME WT RUN_DIR — write the request the document names for
# [WT_PATH]/tmp/NAME-[ISSUE].json, then run the fence that sends it.
op_live() {
  local request
  request="$(request_of "$1" "[WT_PATH]/tmp/$2-[ISSUE].json")"
  [[ -n "$request" ]] || { printf 'op_live: no request for %s\n' "$2" >&2; return 1; }
  request="${request//\[WT_PATH\]/$3}"
  request="${request//\[ISSUE\]/KEN-1}"
  request="${request//\[RUN_DIR\]/$4}"
  mkdir -p "$3/tmp"
  printf '%s\n' "$request" > "$3/tmp/$2-KEN-1.json"
  live "$1" "orch-runtime op --item [ISSUE] --request [WT_PATH]/tmp/$2-[ISSUE].json" "$3" - "$4"
}

# state_read WT POINTER JQ — the item record's value at POINTER under WT/tmp,
# filtered by JQ.
state_read() {
  "$RUNTIME" --state-dir "$1/tmp" state get --item KEN-1 "$2" | jq -c "$3"
}

fixture_failed() { echo "merge-pr-restack-wiring: fixture=failed step=$1" >&2; exit 1; }

NETWORK_PUSH="$TMP_ROOT/network-push"
printf '#!/bin/sh\nexit 0\n' > "$NETWORK_PUSH"
chmod +x "$NETWORK_PUSH"

# Step 2's live-round request over a fix round whose record stands with no
# receipt beside it, the record the runtime's round stamp writes.
ROUND_WT="$(make_worktree live-round)" || fixture_failed live-round-worktree
"$RUNTIME" --state-dir "$ROUND_WT/tmp" state init --item KEN-1 --worktree "$ROUND_WT" >/dev/null || fixture_failed live-round-state
"$RUNTIME" --state-dir "$ROUND_WT/tmp" state set --item KEN-1 /dev_round_id r1 >/dev/null || fixture_failed live-round-id
"$RUNTIME" round --text stamp --worktree "$ROUND_WT" --issue KEN-1 --round-id r1 --item 1 'fix the parser' 'the parser suite' >/dev/null || fixture_failed live-round-stamp
round_rc=0
ROUND_OUT="$(op_live "$RESTACK_DOC" restack-live-round "$ROUND_WT" -)" || round_rc=$?
assert_eq "$round_rc $(jq -r '.result.live_round' <<<"$ROUND_OUT")" '3 r1' \
  "step 2's live-round request answers exit 3 naming the fix round in flight"
cp "$RESTACK_DOC" "$TMP_ROOT/live-round-mutant.md"
mutate_file "$TMP_ROOT/live-round-mutant.md" '"mode": "check-live-round"' '"mode": "record-restack-validation", "run_dir": "[WT_PATH]"'
round_rc=0
op_live "$TMP_ROOT/live-round-mutant.md" restack-live-round "$ROUND_WT" - > /dev/null 2>&1 || round_rc=$?
assert_eq "$round_rc" 1 'control: a request asking another question refuses where the live round stands, never answering exit 3'

# Step 2's route over the fixture, each command as the document writes it.
WT="$(make_worktree range)" || fixture_failed worktree
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

# The document's push over the rebase map a restack leaves, with the real
# record-push and only the worktree skill's push stood in.
"$RUNTIME" --state-dir "$WT/tmp" state init --item KEN-1 --worktree "$WT" >/dev/null || fixture_failed state
MAP_FILE="$(git -C "$WT" rev-parse --git-path kendex-rebase-map)"
[[ "$MAP_FILE" == /* ]] || MAP_FILE="$WT/$MAP_FILE"
printf 'rebase-hop:\nrebase-map: %s %s\n' "$(git -C "$WT" rev-parse HEAD~1)" "$RECORDED_HEAD" > "$MAP_FILE"
op_live "$RESTACK_DOC" restack-push "$WT" "$RUN_DIR" > "$TMP_ROOT/push.out" || fixture_failed push
assert_eq "$(state_read "$WT" /stages '.result.value | map({kind,reason,run_dir})')" \
  "[{\"kind\":\"validate\",\"reason\":\"restack\",\"run_dir\":\"$RUN_DIR\"}]" \
  'the document push records its actual range run as the restack stage'
assert_eq "$(state_read "$WT" /validate_rounds '.result.value[0] | {kind,mode,seconds}')" \
  "{\"kind\":\"restack\",\"mode\":\"range\",\"seconds\":$(sed -n 's/.* seconds=\([0-9]*\).*/\1/p' <<<"$RECORD_LINE")}" \
  'the document push records the actual range validation seconds'
assert_eq "$(state_read "$WT" /stages '.result.value[0] | {start,end}')" \
  "$(jq -cn --arg start "$(sed -n 's/.* started-at=\([^ ]*\).*/\1/p' <<<"$RECORD_LINE")" --arg end "$(sed -n 's/.* ended-at=\([^ ]*\).*/\1/p' <<<"$RECORD_LINE")" '{start:($start|fromdateiso8601),end:($end|fromdateiso8601)}')" \
  'the document push records the run start and end'
assert_eq "$(jq -r '.result.stage' "$TMP_ROOT/push.out")" "$RUN_DIR" 'the push reply names the run directory it recorded'

"$RUNTIME" --state-dir "$WT/tmp" state set --item KEN-1 /stages '[]' /validate_rounds '[]' >/dev/null
printf 'rebase-hop:\nrebase-map: %s %s\n' "$(git -C "$WT" rev-parse HEAD~1)" "$RECORDED_HEAD" > "$MAP_FILE"
cp "$RESTACK_DOC" "$TMP_ROOT/push-mode-mutant.md"
mutate_file "$TMP_ROOT/push-mode-mutant.md" '{"op": "record-push", "mode": "branch", "worktree": "[WT_PATH]"}' '{"op": "record-push", "mode": "check-live-round", "worktree": "[WT_PATH]"}'
op_live "$TMP_ROOT/push-mode-mutant.md" restack-push "$WT" "$RUN_DIR" > "$TMP_ROOT/control-push.out" || fixture_failed control-push
assert_eq "$(state_read "$WT" /stages '.result.value')" '[]' \
  'control: a push request that asks only for a live round records no restack stage'

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
"$RUNTIME" --state-dir "$WT/tmp" state set --item KEN-1 /stages '[]' /validate_rounds '[]' >/dev/null
printf 'rebase-hop:\nrebase-map: %s %s\n' "$(git -C "$WT" rev-parse HEAD~1)" "$RECORDED_HEAD" > "$MAP_FILE"
op_live "$RESTACK_DOC" restack-push "$WT" "$RUN_DIR" > "$TMP_ROOT/rewrite-push.out" || fixture_failed rewrite-push
assert_eq "$(head_check "$RESTACK_DOC")" differs 'the document head check detects the head rewritten during the push'
assert_eq "$(state_read "$WT" /stages '.result.value | map(.run_dir)')" \
  "[\"$RUN_DIR\"]" 'the first run is recorded against its pre-push head'
OUT="$(live "$RESTACK_DOC" "$RANGE" "$WT" "$BASE" -)" || true
assert_eq "$(sed -n 's/^state=done .*\(validate=[A-Za-z-]*\).*$/\1/p' <<<"$OUT")" validate=pass 'the rewritten head passes the real second range run'
POST_RUN_DIR="$(sed -n 's/^state=started run-dir=\([^ ]*\) .*$/\1/p' <<<"$OUT")"
POST_LINE="$(live "$RESTACK_DOC" "$RECORD" "$WT" "$BASE" "$POST_RUN_DIR")" || fixture_failed post-record-read
RECORDED_HEAD="$(sed -n 's/^.* head=\([^ ]*\) .*$/\1/p' <<<"$POST_LINE")"
assert_eq "$(head_check "$RESTACK_DOC")" same 'the second record read binds the current pushed head'
printf 'rebase-unmapped: %s\n' "$RECORDED_HEAD" > "$MAP_FILE"
for attempt in first recheck; do
  op_live "$RESTACK_DOC" restack-stage "$WT" "$POST_RUN_DIR" > "$TMP_ROOT/post-$attempt.out" || fixture_failed post-record
done
assert_eq "$(state_read "$WT" /stages '.result.value | map(.run_dir)')" \
  "[\"$RUN_DIR\",\"$POST_RUN_DIR\"]" 'both routes share the writer and deduplicate the second run directory'
assert_eq "$(state_read "$WT" /validate_rounds '.result.value | map({kind,mode,seconds})')" \
  "[{\"kind\":\"restack\",\"mode\":\"range\",\"seconds\":$(sed -n 's/.* seconds=\([0-9]*\).*/\1/p' <<<"$RECORD_LINE")},{\"kind\":\"restack\",\"mode\":\"range\",\"seconds\":$(sed -n 's/.* seconds=\([0-9]*\).*/\1/p' <<<"$POST_LINE")}]" \
  'the stage request adds the second run time to the validation seconds'
assert_eq "$(cat "$WT/tmp/network-pushes")" push 'recording the second run never publishes again'
assert_eq "$(cat "$MAP_FILE")" "rebase-unmapped: $RECORDED_HEAD" 'recording the stage consumes no restack map'
rm -f "$MAP_FILE"
op_live "$RESTACK_DOC" restack-stage "$WT" "$RUN_DIR" > "$TMP_ROOT/wrong-head.out" || fixture_failed wrong-head
assert_eq "$(jq -r '.result.stage' "$TMP_ROOT/wrong-head.out")" 'unrecorded cause=no-run' 'a run for the pre-push head reports unrecorded on the stage request'
assert_eq "$(state_read "$WT" /stages '.result.value | map(.run_dir)')" \
  "[\"$RUN_DIR\",\"$POST_RUN_DIR\"]" 'an unrecorded stage leaves both accepted runs unchanged'
cp "$RESTACK_DOC" "$TMP_ROOT/stage-push-mutant.md"
mutate_file "$TMP_ROOT/stage-push-mutant.md" '{"op": "record-push", "mode": "record-restack-validation", "worktree": "[WT_PATH]", "run_dir": "[RUN_DIR]"}' '{"op": "record-push", "mode": "branch", "worktree": "[WT_PATH]"}'
op_live "$TMP_ROOT/stage-push-mutant.md" restack-stage "$WT" "$POST_RUN_DIR" > "$TMP_ROOT/control-publication.out" || fixture_failed control-publication
assert_eq "$(cat "$WT/tmp/network-pushes")" $'push\npush' 'control: a stage request that pushes publishes a second time'

# The restack's real mode read and CI command use the same required-context
# owner. This branch changes shell source so the classifier covers it.
CI_WT="$(make_worktree ci-restack)" || fixture_failed ci-worktree
# A declared queue path lets the real classifier prove this shell change has
# no queue work. Undeclared queue paths cannot prove PR coverage, and the
# queue list is read only under the per-push opt-back's reason.
printf 'HARNESS_CI_PER_PUSH_REASON = "restack suite"\nHARNESS_CI_QUEUE_PATHS = "queued/**"\n' >> "$CI_WT/kendex.settings.toml"
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
case "$1:$2" in
  repo:view) printf 'o/r\n'; exit 0 ;;
esac
case "$2" in
  status) exit 0 ;;
  user) printf '{"login":"fixture"}\n' ;;
  view) printf '{"state":"OPEN","baseRefName":"main"}\n' ;;
  'repos/o/r/rules/branches/main?per_page=100&page=1')
    printf '[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"CI"}]}},{"type":"merge_queue"}]\n' ;;
  'repos/o/r/branches/main') printf '{"name":"main","commit":{"sha":"0000000000000000000000000000000000000000","commit":{"committer":{"date":"2026-01-01T00:00:00Z"}}},"protected":true,"protection":{"enabled":true,"required_status_checks":{"enforcement_level":"off","contexts":[],"checks":[]}}}\n' ;;
  *) exit 9 ;;
esac
SH
chmod +x "$TMP_ROOT/ci-bin/gh"
CI_COMMAND='dev-validate-run --worktree [WT_PATH] --validate-mode ci --base origin/[BASE_BRANCH] --restack'
# A selector that admits the change and marks any scoped run: a restack is no
# round, so its ci call runs none.
printf 'DEV_VALIDATE_SELECTION_CMD = "echo selection=all; test $DEV_VALIDATE_SCOPED = false || touch %s"\n' \
  "$TMP_ROOT/ci-restack-scoped-ran" >> "$CI_WT/kendex.settings.toml"
CI_RESOLVED="$(PATH="$TMP_ROOT/ci-bin:$PATH" live "$RESTACK_DOC" "$RESOLVE" "$CI_WT" main -)" || fixture_failed ci-resolve
assert_eq "$CI_RESOLVED" validate-mode=ci 'push-first restack resolves to pending CI'
CI_OUT="$(PATH="$TMP_ROOT/ci-bin:$PATH" live "$RESTACK_DOC" "$CI_COMMAND" "$CI_WT" main -)" || fixture_failed ci-start
CI_DIR="$(sed -n 's/^state=started run-dir=\([^ ]*\) .*$/\1/p' <<<"$CI_OUT")"
CI_RECORD="$(live "$RESTACK_DOC" "$RECORD" "$CI_WT" main "$CI_DIR")" || fixture_failed ci-record
assert_contains "$CI_RECORD" 'validate-mode=ci selection=unreported verdict=pending' 'restack records pending proof, not a local pass'
assert_contains "$CI_RECORD" "head=$(git -C "$CI_WT" rev-parse HEAD)" 'restack CI record binds the restacked head'
assert_eq "$([[ -e "$TMP_ROOT/ci-restack-range-ran" || -e "$TMP_ROOT/ci-restack-full-ran" || -e "$TMP_ROOT/ci-restack-scoped-ran" ]] && echo ran || echo deferred)" deferred 'restack starts no local command'
assert_eq "$(grep -c '^class-base=' "$CI_DIR/start" || :)" 0 'restack CI record names no class base'
# The restack rule these rows hold lives in the runtime's validation start,
# where its must-fail control mutates it.

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
  # The record read runs the built runtime from its cache, which
  # AGENT_RUNTIME_CACHE names, else XDG_CACHE_HOME, else HOME's ~/.cache; an
  # empty value falls through to the next.
  env -i PATH="$PATH" HOME="$HOME" AGENT_RUNTIME_CACHE="${AGENT_RUNTIME_CACHE-}" XDG_CACHE_HOME="${XDG_CACHE_HOME-}" \
    SUBMIT_VALIDATE_MODE="$mode" "$BASH" -uc "$block"
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

echo '=== step 3 proof: the block prints the reader reply and holds a missing answer ==='
# merge_proof DOC WT [merge|submit] — run DOC's restack proof block for the
# pushed HEAD of WT, reached by the merge caller (steps 1-4) or by
# submission's steps the submit workflow names, which push first; prints the
# block's output, then merge-admitted where it exits 0.
merge_proof() {
  local block doc="$1" wt="$2" first=0 last=9 range
  if [[ "${3:-merge}" == submit ]]; then
    range="$(sed -n '/worktree-push-base-conflict/ {s/.*steps \([0-9]\)-\([0-9]\).*/\1 \2/p;}' "$SUBMIT_DOC" | head -n 1)"
    [[ "$range" =~ ^[0-9]\ [0-9]$ ]] || return 2
    read -r first last <<<"$range"
    op_live "$doc" restack-push "$wt" - > /dev/null || return $?
  fi
  block="$(awk -v first="$first" -v last="$last" '
    /^[0-9]+\. / {step=$1+0}
    /^   ```bash/ {inside=1; block=""; next}
    /^   ```/ && inside {if (step >= first && step <= last && index(block, "RESTACK_SKIPS=")) {printf "%s", block; exit} inside=0}
    inside {block=block $0 ORS}
  ' "$doc")"
  [[ -n "$block" ]] || return 2
  block="${block//.agents\/skills\/orch\/scripts\//$REPO_ROOT/skills/orch/scripts/}"
  block="${block//\[STATE_KEY\]/KEN-1}"
  block="${block//\[PREPARED_HEAD\]/$(git -C "$wt" rev-parse HEAD)}"
  block="${block//\[WORKTREE_PATH\]/$wt}"
  block="${block//\[BASE_BRANCH\]/main}"
  (cd "$wt" && env -u ORCH_STATE_DIR -u DEV_VALIDATE_CI_CONTEXT -u DEV_VALIDATE_SELECTION_CMD \
    -u ORCH_PR_ORDER "${INSTALL[@]}" WORKTREE_CLI="$NETWORK_PUSH" "$BASH" -euo pipefail -c "$block"$'\n''echo merge-admitted')
}
# record_skip WT LINE — the skip a restack-skip line names, recorded on the
# item through the runtime's restack-skip step.
record_skip() {
  local head condition validated paths entry request
  head="$(sed -n 's/.* head=\([^ ]*\).*/\1/p' <<<"$2")"
  condition="$(sed -n 's/.* condition=\([^ ]*\).*/\1/p' <<<"$2")"
  validated="$(sed -n 's/.* validated-head=\([^ ]*\).*/\1/p' <<<"$2")"
  paths="$(sed -n 's/.* paths=\([^ ]*\).*/\1/p' <<<"$2")"
  [[ -n "$head" && -n "$validated" ]] || fixture_failed proof-skip
  entry="$1/tmp/restack-skip-KEN-1.json"
  jq -n --arg head "$head" --arg condition "$condition" --arg validated "$validated" --arg paths "$paths" \
    '{head: $head, condition: $condition, validated_head: $validated, paths: (if $paths == "none" then [] else ($paths | split(",")) end)}' \
    > "$entry" || fixture_failed proof-skip-entry
  request="$(jq -cn --arg file "$entry" '{op: "record-pr-progress", step: "restack-skip", file: $file}')" ||
    fixture_failed proof-skip-request
  "$RUNTIME" --state-dir "$1/tmp" op --item KEN-1 --request-json "$request" >/dev/null || fixture_failed proof-skip-write
}
printf '#!/bin/sh\nexit 0\n' > "$NETWORK_PUSH"
PROOF_WT="$TMP_ROOT/proof"
git init -q -b ken-1 "$PROOF_WT"
git -C "$PROOF_WT" config gc.auto 0
git -C "$PROOF_WT" config maintenance.auto false
printf 'base\n' > "$PROOF_WT/base.txt"
git -C "$PROOF_WT" add base.txt
git -C "$PROOF_WT" -c user.name=t -c user.email=t@example.com commit -q -m base
git -C "$PROOF_WT" update-ref refs/remotes/origin/main HEAD
printf 'branch\n' > "$PROOF_WT/branch.txt"
git -C "$PROOF_WT" add branch.txt
git -C "$PROOF_WT" -c user.name=t -c user.email=t@example.com commit -q -m branch
# A full battery that fails while the marker stands, so one declaration
# records both a pass and a later failure.
printf '[env]\nDEV_VALIDATE_CMD = "test ! -e %s"\nDEV_VALIDATE_TIMEOUT_SECS = "20"\n' "$TMP_ROOT/proof-fail" > "$PROOF_WT/kendex.settings.toml"
printf 'kendex.settings.toml\ntmp/\n' >> "$(git -C "$PROOF_WT" rev-parse --path-format=absolute --git-path info/exclude)"
install_skills "$PROOF_WT"
"$RUNTIME" --state-dir "$PROOF_WT/tmp" state init --item KEN-1 --worktree "$PROOF_WT" >/dev/null || fixture_failed proof-state
OUT="$(cd "$PROOF_WT" && env -u DEV_VALIDATE_CI_CONTEXT -u ORCH_PR_ORDER "${INSTALL[@]}" "$RUNTIME" validate entry --worktree "$PROOF_WT" --poll 1)" || fixture_failed proof-pass
VALIDATED_DIR="$(sed -n 's/^state=started run-dir=\([^ ]*\).*/\1/p' <<<"$OUT")"
op_live "$RESTACK_DOC" restack-stage "$PROOF_WT" "$VALIDATED_DIR" > "$TMP_ROOT/proof-stage.out" || fixture_failed proof-stage
[[ "$(jq -r '.result.stage' "$TMP_ROOT/proof-stage.out")" == "$VALIDATED_DIR" ]] || fixture_failed proof-stage-recorded
# Move the base and restack the branch onto it, then record the skip the
# real check prints for the restacked head.
git -C "$PROOF_WT" checkout -qb base-update origin/main
printf 'base changed\n' > "$PROOF_WT/base-next.txt"
git -C "$PROOF_WT" add base-next.txt
git -C "$PROOF_WT" -c user.name=t -c user.email=t@example.com commit -q -m base-update
git -C "$PROOF_WT" update-ref refs/remotes/origin/main HEAD
git -C "$PROOF_WT" checkout -q ken-1
git -C "$PROOF_WT" -c user.name=t -c user.email=t@example.com rebase -q origin/main
SKIP_LINE="$(live "$RESTACK_DOC" "$SKIP" "$PROOF_WT" main -)" || fixture_failed proof-skip-check
record_skip "$PROOF_WT" "$SKIP_LINE"
for route in merge submit; do
  proof_rc=0
  OUT="$(merge_proof "$RESTACK_DOC" "$PROOF_WT" "$route")" || proof_rc=$?
  assert_eq "$proof_rc ${OUT##*$'\n'} $(head -n 1 <<<"$OUT" | jq -r '.result.proof, .result.skip.head' | paste -sd ' ' -)" \
    "0 merge-admitted complete $(git -C "$PROOF_WT" rev-parse HEAD)" \
    "the $route route prints a complete reply through the restacked head's skip and admits the merge"
done
cp "$RESTACK_DOC" "$TMP_ROOT/proof-print-mutant.md"
mutate_file "$TMP_ROOT/proof-print-mutant.md" $'     printf \'%s\\n\' "$RESTACK_PROOF"\n' ''
proof_rc=0
OUT="$(merge_proof "$TMP_ROOT/proof-print-mutant.md" "$PROOF_WT")" || proof_rc=$?
assert_eq "$proof_rc $OUT" '0 merge-admitted' "control: a block that drops the print keeps no reader reply"
# A later run at the restacked tree that did not pass, recorded by the same
# stage request, voids the skip's proof.
touch "$TMP_ROOT/proof-fail"
OUT="$(cd "$PROOF_WT" && env -u DEV_VALIDATE_CI_CONTEXT -u ORCH_PR_ORDER "${INSTALL[@]}" "$RUNTIME" validate entry --worktree "$PROOF_WT" --poll 1)" || true
FAILED_DIR="$(sed -n 's/^state=started run-dir=\([^ ]*\).*/\1/p' <<<"$OUT")"
op_live "$RESTACK_DOC" restack-stage "$PROOF_WT" "$FAILED_DIR" > "$TMP_ROOT/proof-failed-stage.out" || fixture_failed proof-failed-stage
[[ "$(jq -r '.result.stage' "$TMP_ROOT/proof-failed-stage.out")" == "$FAILED_DIR" ]] || fixture_failed proof-failed-recorded
proof_rc=0
OUT="$(merge_proof "$RESTACK_DOC" "$PROOF_WT")" || proof_rc=$?
assert_eq "$proof_rc $(jq -r '.result.proof, .result.lacks.tree' <<<"$OUT" | paste -sd ' ' -)" \
  "1 missing $(git -C "$PROOF_WT" rev-parse 'HEAD^{tree}')" \
  'a later failure at the restacked tree voids the skip: the block prints the missing reply and holds the merge'
cp "$RESTACK_DOC" "$TMP_ROOT/proof-missing-mutant.md"
mutate_file "$TMP_ROOT/proof-missing-mutant.md" '!= missing ]]' '!= absent ]]'
proof_rc=0
OUT="$(merge_proof "$TMP_ROOT/proof-missing-mutant.md" "$PROOF_WT")" || proof_rc=$?
assert_eq "$proof_rc ${OUT##*$'\n'}" '0 merge-admitted' 'control: a block that never reads missing admits the voided merge'
# The skip alone, with no recorded run behind its validated head.
"$RUNTIME" --state-dir "$PROOF_WT/tmp" state set --item KEN-1 /stages '[]' >/dev/null
rm -f "$TMP_ROOT/proof-fail"
proof_rc=0
OUT="$(merge_proof "$RESTACK_DOC" "$PROOF_WT")" || proof_rc=$?
assert_eq "$proof_rc $(jq -r '.result.proof' <<<"$OUT")" '1 missing' 'a recorded skip with no recorded pass behind it proves nothing'
# A record the reader cannot decode: the reader refuses with its reply on
# stdout, which the block prints before it hands back with the status.
"$RUNTIME" --state-dir "$PROOF_WT/tmp" state set --item KEN-1 /stages '"unreadable"' >/dev/null || fixture_failed proof-unreadable
proof_rc=0
OUT="$(merge_proof "$RESTACK_DOC" "$PROOF_WT")" || proof_rc=$?
assert_eq "$proof_rc $(jq -r '.ok' <<<"$OUT")" '1 false' 'a refused proof read prints its reply and hands back with its status'
cp "$RESTACK_DOC" "$TMP_ROOT/proof-refusal-mutant.md"
mutate_file "$TMP_ROOT/proof-refusal-mutant.md" '|| PROOF_STATUS=$?' '|| exit $?'
proof_rc=0
OUT="$(merge_proof "$TMP_ROOT/proof-refusal-mutant.md" "$PROOF_WT")" || proof_rc=$?
assert_eq "$proof_rc [$OUT]" '1 []' 'control: a block that exits before the print hides the refusal'

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
