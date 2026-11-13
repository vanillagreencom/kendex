#!/usr/bin/env bash
# Surface: mailbox without orch. Inputs: skills/mailbox/scripts/**.
set -euo pipefail
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE
ROOT="$(cd -- "${BASH_SOURCE[0]%/*}/../../.." && pwd -P)"
# shellcheck source=../../orch/tests/lib/assertions.sh
. "$ROOT/skills/orch/tests/lib/assertions.sh"
# shellcheck source=../../orch/tests/lib/growth-state.sh
. "$ROOT/skills/orch/tests/lib/growth-state.sh"
TMP_ROOT="$(mktemp -d)" || { echo 'mailbox-alone: scratch=mktemp-failed' >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo 'mailbox-alone: scratch=not-a-directory' >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo 'mailbox-alone: scratch=resolve-failed' >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
REPO="$TMP_ROOT/repo"
PEER="$TMP_ROOT/peer"
mkdir -p "$REPO/.agents/skills/mailbox" "$PEER" "$TMP_ROOT/home"
cp -R "${MAILBOX_UNDER_TEST:-$ROOT/skills/mailbox}/scripts" "$REPO/.agents/skills/mailbox/scripts"
for project in "$REPO" "$PEER"; do
  git -C "$project" init -q
  git -C "$project" config gc.auto 0
  git -C "$project" config maintenance.auto false
done
MAIL="$REPO/.agents/skills/mailbox/scripts/lane-mail"
printf 'Mailbox message.\n' > "$TMP_ROOT/message"
lm() {
  RC=0
  OUT="$(cd -- "$REPO" && env -i PATH="$PATH" HOME="$TMP_ROOT/home" \
    "$MAIL" "$@" 2>"$TMP_ROOT/err")" || RC=$?
  ERR="$(sed -n '1p' "$TMP_ROOT/err")"
}
unchanged() { # VERB ARGS...
  local before after
  before="$(git -C "$REPO" status --porcelain --untracked-files=all)"
  lm "$@"
  after="$(git -C "$REPO" status --porcelain --untracked-files=all)"
  assert_eq "$after" "$before" "$1 writes no file"
}
reader_refusal() { # SEND|PEER
  if [ "$1" = send ]; then
    unchanged send --item overseer --directive --file "$TMP_ROOT/message"
  else
    unchanged peer send --repo "$PEER" --file "$TMP_ROOT/message"
    assert_eq "$(git -C "$PEER" status --porcelain --untracked-files=all)" '' 'peer target stays unchanged'
  fi
  assert_eq "$RC" 2 "$1 refuses without a reader"
  assert_eq "${ERR%%=*}" 'lane-mail: overseer-absent' "$1 keeps the reader refusal key"
}
attach_refusal() {
  unchanged notice --item overseer --to owner --file "$TMP_ROOT/message" \
    --attach "$TMP_ROOT/message" --attach "$TMP_ROOT/second"
  assert_eq "$RC" 2 'notice refuses a repeated attachment'
  assert_eq "$ERR" 'lane-mail: attach-repeated=--attach' 'notice names the repeated attachment option'
}
owner_rows() {
  mkdir -p "$REPO/tmp"
  # Talk schema proof: Fleet e3df94d7a control-vm/neon-schema.sql:662,
  # talk_memories.text CHECK (octet_length(text) <= 256); migration 068 keeps it.
  # Fleet consumes purpose for approval cards and open as reply_events.open_url.
  OWNER_BOX="$REPO/tmp/lane-mail/overseer/to-overseer.jsonl"
  for row in plain-ask memory memory-ascii-boundary memory-utf8-boundary plain-notice open; do
    printf '%s\n' "$row" > "$REPO/tmp/owner-message"
    extra=()
    verb=ask
    case "$row" in
      memory*) extra=(--purpose memory) ;;
      plain-notice) verb=notice ;;
      open) verb=notice; extra=(--open 'https://example.com/a?b=c#d') ;;
    esac
    case "$row" in
      memory-ascii-boundary) python3 -c 'print("x" * 256)' > "$REPO/tmp/owner-message" ;;
      memory-utf8-boundary) python3 -c 'print("é" * 128)' > "$REPO/tmp/owner-message" ;;
    esac
    if [[ $verb == ask ]]; then extra+=(--options approve,deny --recommend deny); fi
    rc=0
    lm "$verb" --item overseer --to owner --file "$REPO/tmp/owner-message" ${extra[@]+"${extra[@]}"}
    rc=$RC
    assert_eq "$rc" 0 "$row accepted" "$TMP_ROOT/err"
    actual=missing
    if [[ $rc -eq 0 ]]; then
      actual="$(tail -n 1 "$OWNER_BOX" | jq -c '{purpose: (if has("purpose") then .purpose else "absent" end), open: (if has("open") then .open else "absent" end), bytes: (.text | utf8bytelength)}')"
    fi
    case "$row" in
      memory-ascii-boundary | memory-utf8-boundary) expected='{"purpose":"memory","open":"absent","bytes":256}' ;;
      memory) expected='{"purpose":"memory","open":"absent","bytes":6}' ;;
      plain-ask) expected='{"purpose":"absent","open":"absent","bytes":9}' ;;
      plain-notice) expected='{"purpose":"absent","open":"absent","bytes":12}' ;;
      open) expected='{"purpose":"absent","open":"https://example.com/a?b=c#d","bytes":4}' ;;
    esac
    assert_eq "$actual" "$expected" "$row optional envelope fields"
  done
  for row in purpose-unknown memory-ascii-over memory-utf8-over http multiple no-host newline bad-port notice-purpose ask-open lane-open peer-open; do
    printf '%s\n' "$row" > "$REPO/tmp/owner-message"
    args=(ask --item overseer --to owner --options approve,deny --recommend deny)
    key=purpose-invalid
    case "$row" in
      purpose-unknown) args+=(--purpose other) ;;
      memory-ascii-over | memory-utf8-over)
        args+=(--purpose memory); key=memory-too-long
        if [[ $row == memory-ascii-over ]]; then
          python3 -c 'print("x" * 257)' > "$REPO/tmp/owner-message"
        else
          python3 -c 'print("é" * 128 + "x")' > "$REPO/tmp/owner-message"
        fi ;;
      notice-purpose) args=(notice --item overseer --to owner --purpose memory); key=option-unknown ;;
      ask-open) args+=(--open https://example.com); key=option-unknown ;;
      lane-open) args=(notice --item TEST-1 --open https://example.com); key=option-unknown ;;
      peer-open) args=(peer ask --repo other --open https://example.com); key=option-unknown ;;
      *)
        key=open-invalid
        case "$row" in
          http) url='http://example.com' ;;
          multiple) url='https://example.com https://other.com' ;;
          no-host) url='https:///path' ;;
          newline) url=$'https://example.com\n' ;;
          bad-port) url='https://example.com:bad' ;;
        esac
        args=(notice --item overseer --to owner --open "$url") ;;
    esac
    before="$(cat "$OWNER_BOX" 2>/dev/null || true)"
    rc=0
    lm "${args[@]}" --file "$REPO/tmp/owner-message"
    rc=$RC
    assert_eq "$rc" 2 "$row refuses" "$TMP_ROOT/err"
    assert_file_contains "$TMP_ROOT/err" "lane-mail: $key=" "$row refusal category"
    assert_eq "$(cat "$OWNER_BOX" 2>/dev/null || true)" "$before" "$row writes no envelope"
  done
}
if [ "${1:-}" = --owner-rows ]; then
  owner_rows
  printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
  [[ "$FAIL" -eq 0 ]]
  exit
fi
if [ "${1:-}" = --attach-row ]; then
  attach_refusal
  printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
  [[ "$FAIL" -eq 0 ]]
  exit
fi
if [ "${1:-}" = --reader-row ]; then
  reader_refusal send
  printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
  [[ "$FAIL" -eq 0 ]]
  exit
fi

owner_rows
lm ask --item overseer --to owner --wait 0 --options proceed,hold --recommend hold --file "$TMP_ROOT/message"
assert_eq "$RC" 0 'owner ask works alone'
ASK="${OUT#id=}"
lm notice --item overseer --to owner --file "$TMP_ROOT/message"
assert_eq "$RC" 0 'notice works alone'
for verb in events pending inbox drain; do
  args=("$verb" --item overseer --root "$REPO")
  [ "$verb" != drain ] || args+=(--after 0)
  lm "${args[@]}"
  assert_eq "$RC" 0 "$verb works alone"
done
lm resolve --item overseer --id "$ASK" --default
assert_eq "$RC" 0 'resolve works alone'
lm wait --item overseer --id "$ASK" --timeout 0
assert_eq "$RC" 0 'wait reads the resolved ask alone'
# A watch wakes only for unread inbound mail. This fixture is the answer
# producer's existing envelope format, with no registered session needed.
printf '{"id":"watch-answer","kind":"answer","re":"%s","text":"Watch wake."}\n' "$ASK" >> "$REPO/tmp/lane-mail/overseer/to-lane.jsonl"
lm watch --item overseer --once
assert_eq "$RC" 0 'watch works alone'
reader_refusal send
reader_refusal peer
attach_refusal
while IFS='|' read -r verb item flag value; do
  args=("$verb" --item "$item" --root "$REPO")
  [ -z "$flag" ] || args+=("$flag")
  [ -z "$value" ] || args+=("$value")
  case "$verb" in send) args+=(--directive --file "$TMP_ROOT/message") ;; notice) args+=(--to owner --file "$TMP_ROOT/message") ;; esac
  unchanged "${args[@]}"
  assert_eq "$RC" 2 "$verb $flag refuses without orch"
  assert_eq "${ERR%%=*}" 'lane-mail: orch-missing' "$verb $flag names the missing package"
done <<ROWS
send|TEST-1||
events|overseer|--host|
send|overseer|--state-dir|$TMP_ROOT/state
compact|overseer||
notice|overseer|--attach|$TMP_ROOT/message
ROWS

if [ -z "${MAILBOX_UNDER_TEST:-}" ]; then
  for control in startup reader require attach; do
    mkdir -p "$TMP_ROOT/$control"
    cp -R "$ROOT/skills/mailbox/scripts" "$TMP_ROOT/$control/scripts"
    if [ "$control" = startup ]; then
      mutate_file "$TMP_ROOT/$control/scripts/lane-mail" '. "$SCRIPT_DIR/lib/common-root.sh"' \
        '. "$SCRIPT_DIR/lib/common-root.sh"; . "$ORCH_SCRIPTS/lib/lane-host-read.sh"'
      row=()
    elif [ "$control" = reader ]; then
      mutate_file "$TMP_ROOT/$control/scripts/lane-mail" 'if [ ! -f "$ORCH_SCRIPTS/workflow-state" ]; then' \
        'if [ ! -f "$ORCH_SCRIPTS/workflow-state" ]; then return 0;'
      row=(--reader-row)
    elif [ "$control" = attach ]; then
      mutate_file "$TMP_ROOT/$control/scripts/lane-mail" \
        '[ -z "$ATTACH" ] || refuse attach-repeated --attach' \
        ': # [ -z "$ATTACH" ] || refuse attach-repeated --attach'
      row=(--attach-row)
    else
      mutate_file "$TMP_ROOT/$control/scripts/lane-mail" 'lm_require_orch() { # FILE...' \
        'lm_require_orch() { return 0; # FILE...'
      row=()
    fi
    rc=0
    env MAILBOX_UNDER_TEST="$TMP_ROOT/$control" "$BASH" "$ROOT/skills/mailbox/tests/alone.sh" \
      ${row[@]+"${row[@]}"} >"$TMP_ROOT/$control.log" 2>&1 || rc=$?
    assert_eq "$rc" 1 "$control mutant fails the same assertions"
  done
  mkdir -p "$TMP_ROOT/purpose-control"
  cp -R "$ROOT/skills/mailbox/scripts" "$TMP_ROOT/purpose-control/scripts"
  mutate_file "$TMP_ROOT/purpose-control/scripts/lane-mail" '+ (if $purpose == "" then {} else {purpose: $purpose} end)' '+ {} # + (if $purpose == "" then {} else {purpose: $purpose} end)'
  rc=0
  env MAILBOX_UNDER_TEST="$TMP_ROOT/purpose-control" "$BASH" "$ROOT/skills/mailbox/tests/alone.sh" --owner-rows > "$TMP_ROOT/purpose-control.log" 2>&1 || rc=$?
  assert_eq "$rc" 1 'purpose control fails the same assertions'
  assert_file_contains "$TMP_ROOT/purpose-control.log" 'FAIL  memory optional envelope fields' 'purpose control detects missing approval marker'
fi
printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
