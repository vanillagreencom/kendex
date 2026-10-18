#!/usr/bin/env bash
# Surface: overseer Claude seat accounts, through the real succession judge.
# Inputs: scripts/*, scripts/lib/*, ../mailbox/scripts/*, ../github/scripts/*,
# tests/lib/{assertions,git-env,growth-state,lanes-fixture,tier-model-path}.sh, fixtures/lane-host.
set -euo pipefail
case "${OSTYPE:-}" in msys*|mingw*) export MSYS=winsymlinks:nativestrict ;; esac
source "${BASH_SOURCE[0]%/*}/lib/git-env.sh"
TEST_DIR="$(cd -- "${BASH_SOURCE[0]%/*}" && pwd -P)"
source "$TEST_DIR/lib/assertions.sh"
source "$TEST_DIR/lib/lanes-fixture.sh"
source "$TEST_DIR/lib/growth-state.sh"
SUCCEED="${OVERSEE_SUCCEED_UNDER_TEST:-$TEST_DIR/../scripts/oversee-succeed}"
TMP_ROOT="$(mktemp -d)" || { echo 'oversee-seat-accounts: scratch=mktemp-failed' >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo 'oversee-seat-accounts: scratch=not-a-directory' >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo 'oversee-seat-accounts: scratch=resolve-failed' >&2; exit 1; }
SOCK="oversee-seat-accounts-$$"
HOLDER=""
cleanup() {
  if [[ -n "$HOLDER" ]]; then
    printf '\n' >&6
    wait "$HOLDER" || true
    exec 6>&-
  fi
  tmux -L "$SOCK" kill-server 2>/dev/null || true
  rm -rf -- "${TMP_ROOT:?}"
}
trap cleanup EXIT
new_home fleet
mkdir -p "$TMP_ROOT/work" "$TMP_ROOT/bin"
git -C "$TMP_ROOT/work" init -q -b main
git -C "$TMP_ROOT/work" config gc.auto 0
git -C "$TMP_ROOT/work" config maintenance.auto false
git -C "$TMP_ROOT/work" remote add origin https://github.com/fixture/seat.git
make_fetcher "$TMP_ROOT/fetch"
cp "$(command -v sleep)" "$TMP_ROOT/bin/claude"
tmux -L "$SOCK" -f /dev/null new-session -d -s fleet -c "$TMP_ROOT/work" "exec '$TMP_ROOT/bin/claude' 100000"
PANE="$(tmux -L "$SOCK" display-message -p '#{pane_id}')"
TMUX_ADDR="$(tmux -L "$SOCK" display-message -p '#{socket_path},#{pid},0')"
printf 'fixture-next: arbitrary-notice version=unrecognized\n\topaque=provider-detail\n' > "$TMP_ROOT/future-notice"
FUTURE_NOTICE_BYTES="$(wc -c < "$TMP_ROOT/future-notice")"
cp "$TEST_DIR/fixtures/lane-host" "$TMP_ROOT/future-provider"
mutate_file "$TMP_ROOT/future-provider" "printf 'lane-host-fixture: accounts-failed\\n'" \
  'cat -- "$FUTURE_NOTICE"'
cp "$TEST_DIR/fixtures/lane-host" "$TMP_ROOT/held-provider"
mutate_file "$TMP_ROOT/held-provider" 'sleep "$LANE_HOST_STUB_ACCOUNTS_DELAY"' \
  'IFS= read -r -t "$LANE_HOST_STUB_ACCOUNTS_DELAY" < "$ACCOUNTS_RELEASE"'

# The provider stub emits only usage metadata. The host owns the stored token.
# A different home and cache for each row prevents a prior reading admitting it.
while IFS='|' read -r name credentials provider host accounts_rc cloud_repos headroom pick_rc notice; do
  new_home "$name"
  mkdir -p "$H/.claude"
  if [[ "$credentials" == yes ]]; then
    make_lane "$H" claude
    claude_usage 20 20 20 Fable > "$FIXTURE_DIR/.claude.json"
  fi
  : > "$TMP_ROOT/accounts.tsv"
  if [[ "$provider" == yes ]]; then
    printf 'account=%s\tharness=claude\tsession-5h-pct=10\tweekly-pct=10\n' "$H/.claude" > "$TMP_ROOT/accounts.tsv"
  fi
  [[ "$host" != provider ]] || host="$TEST_DIR/fixtures/lane-host"
  [[ "$notice" != future ]] || host="$TMP_ROOT/future-provider"
  [[ "$cloud_repos" != allowed ]] || cloud_repos="claude=fixture/seat"
  run_seat() {
    rm -f -- "$TMP_ROOT/work/tmp/lane-mail/overseer"/account-mark-*.memo
    (
      cd "$TMP_ROOT/work"
      exec env -i GIT_CEILING_DIRECTORIES="$GIT_CEILING_DIRECTORIES" HOME="$H" PATH="$TMP_ROOT/bin:$PATH" \
        TMUX="$TMUX_ADDR" TMUX_PANE="$PANE" CLAUDE_CONFIG_DIR="$H/.claude" \
        LANES_HOME="$H" FIXTURE_DIR="$FIXTURE_DIR" ORCH_LANES_FETCH_CMD="$TMP_ROOT/fetch" \
        ORCH_LANE_DIRS="$H/.claude" OVERSEE_WATCH_STATE_DIR="$H/${SEAT_CACHE:-state}" \
        ORCH_LANE_HOST="$host" LANE_HOST_STUB_ACCOUNTS="$TMP_ROOT/accounts.tsv" \
        LANE_HOST_STUB_ACCOUNTS_STATUS="$accounts_rc" ORCH_LANE_CLOUD_REPOS="$cloud_repos" \
        FUTURE_NOTICE="$TMP_ROOT/future-notice" \
        ORCH_LANE_HOST_SHORT_MAX_CALLS=1 ORCH_LANE_HOST_SHORT_BUSY_WAIT_SECS=0 \
        LANE_HOST_STUB_LOG="$TMP_ROOT/host.log" ORCH_OVERSEER_PREFERENCE=claude::high \
        ORCH_OVERSEER_WALL_MINUTES=0 ORCH_OVERSEER_SUCCESSOR_ACCOUNTS=0 \
        ORCH_HANDOFF_AGENT_RESERVE_TOKENS=0 ORCH_HANDOFF_CONTEXT_PCT=50 \
        "$SUCCEED" "$@"
    )
  }
  if [[ "$notice" == busy ]]; then
    mkfifo "$TMP_ROOT/accounts-release"
    exec 6<>"$TMP_ROOT/accounts-release"
    env -i HOME="$H" PATH="$PATH" ORCH_LANE_HOST="$TMP_ROOT/held-provider" \
      LANE_HOST_STUB_LOG="$TMP_ROOT/holder.log" LANE_HOST_STUB_ACCOUNTS_DELAY=60 \
      ACCOUNTS_RELEASE="$TMP_ROOT/accounts-release" ORCH_LANE_HOST_SHORT_MAX_CALLS=1 \
      "$TEST_DIR/../scripts/lane-host" accounts >"$TMP_ROOT/holder.out" 2>"$TMP_ROOT/holder.err" &
    HOLDER=$!
    await_marker "$TMP_ROOT/holder.log"
    assert_file_contains "$TMP_ROOT/holder.log" accounts 'the owned accounts child entered the provider after taking its slot'
  fi
  assert_notice() {
    case "$notice" in
      failed|future)
        assert_file_contains "$TMP_ROOT/err" "lanes: host-accounts-unreadable host=$host exit=$accounts_rc" \
          "$name: $1 relays the provider fallback" ;;
      busy)
        assert_file_contains "$TMP_ROOT/err" 'lane-host: lane-host-busy count=1 cap=1 verb=accounts item=-' \
          "$name: $1 relays the dispatcher's capacity failure"
        assert_file_contains "$TMP_ROOT/err" 'lanes: lane-host-busy step=accounts item=-' \
          "$name: $1 relays the reader's capacity fallback" ;;
    esac
    if [[ "$notice" == future ]]; then
      if head -c "$FUTURE_NOTICE_BYTES" "$TMP_ROOT/err" > "$TMP_ROOT/notice-prefix" \
        && cmp -s "$TMP_ROOT/future-notice" "$TMP_ROOT/notice-prefix"; then
        pass "$name: $1 preserves unknown provider notice bytes"
      else
        fail "$name: $1 preserves unknown provider notice bytes" "$(cat "$TMP_ROOT/err")"
      fi
    fi
  }
  rc=0
  out="$(run_seat --check-marks --harness claude --context 100:1000 2>"$TMP_ROOT/err")" || rc=$?
  assert_eq "$rc" 0 "$name: the account mark answers" "$TMP_ROOT/err"
  if [[ "$headroom" == unknown ]]; then
    assert_contains "$out" 'mark-unmeasured kind=headroom' "$name: no reader means no measurement" "$TMP_ROOT/err"
  else
    assert_contains "$out" "context-below-mark tokens=100 window=1000 mark=50 headroom=$headroom" \
      "$name: the account mark uses the measured room" "$TMP_ROOT/err"
  fi
  assert_notice 'the account mark'
  rc=0
  out="$(run_seat --print-launch-line --harness claude --entry claude::high 2>"$TMP_ROOT/err")" || rc=$?
  assert_eq "$rc" "$pick_rc" "$name: the seat pick answers" "$TMP_ROOT/err"
  if [[ "$pick_rc" == 0 ]]; then
    # oversee-watch stores this shell command verbatim for death recovery.
    assert_contains "$out" "CLAUDE_CONFIG_DIR='$H/.claude'" "$name: the seat uses the measured folder" "$TMP_ROOT/err"
  else
    assert_contains "$(cat "$TMP_ROOT/err")" 'unmeasured=1' "$name: the seat pick keeps the folder unmeasured"
  fi
  assert_notice 'the seat pick'
  if [[ "$name" == provider-token && -z "${OVERSEE_SUCCEED_UNDER_TEST:-}" ]]; then
    CONTROL="$(mutant_scripts local-reader lib/overseer-launch.sh)"
    mutate_file "$CONTROL/lib/overseer-launch.sh" '[[ "$harness" == claude ]]' '[[ "$harness" == claude && 0 == 1 ]]'
    SUCCEED="$CONTROL/oversee-succeed"
    rc=0
    out="$(SEAT_CACHE=control-state run_seat --check-marks --harness claude --context 100:1000 2>"$TMP_ROOT/err")" || rc=$?
    assert_eq "$rc" 0 'control: the old reader still answers' "$TMP_ROOT/err"
    assert_contains "$out" 'mark-unmeasured kind=headroom' 'control: the old reader cannot measure the token-only folder' "$TMP_ROOT/err"
    rc=0
    out="$(SEAT_CACHE=control-state run_seat --print-launch-line --harness claude --entry claude::high 2>"$TMP_ROOT/err")" || rc=$?
    assert_eq "$rc" 3 'control: the old reader cannot pick the token-only seat' "$TMP_ROOT/err"
    assert_contains "$(cat "$TMP_ROOT/err")" 'unmeasured=1' 'control: the old reader reports its unmeasured folder'
    SUCCEED="$TEST_DIR/../scripts/oversee-succeed"
  fi
  if [[ "$name" == cloud-no-repo && -z "${OVERSEE_SUCCEED_UNDER_TEST:-}" ]]; then
    CONTROL="$(mutant_scripts cloud-policy lib/overseer-launch.sh)"
    mutate_file "$CONTROL/lib/overseer-launch.sh" '[[ "$launch:$pool" != ssh:plan ]]' '[[ "$launch:$pool" != ssh:plan && "$launch:$pool" != cloud-session:cloud-credit ]]'
    SUCCEED="$CONTROL/oversee-succeed"
    rc=0
    out="$(SEAT_CACHE=control-state run_seat --print-launch-line --harness claude --entry claude::high 2>"$TMP_ROOT/err")" || rc=$?
    assert_eq "$rc" 3 'control: cloud launch policy rejects the local plan seat' "$TMP_ROOT/err"
    SUCCEED="$TEST_DIR/../scripts/oversee-succeed"
  fi
  if [[ "$notice" == busy && -z "${OVERSEE_SUCCEED_UNDER_TEST:-}" ]]; then
    CONTROL="$(mutant_scripts hidden-provider-channel lib/overseer-launch.sh)"
    mutate_file "$CONTROL/lib/overseer-launch.sh" '"$@" --provider-notices-fd3' \
      '"$@" ${CONTROL_ENABLE_PROVIDER_CHANNEL:+"--provider-notices-fd3"}'
    SUCCEED="$CONTROL/oversee-succeed"
    rc=0
    out="$(SEAT_CACHE=control-state run_seat --check-marks --harness claude --context 100:1000 2>"$TMP_ROOT/err")" || rc=$?
    assert_eq "$rc" 0 'control: the unmeasured account mark still answers' "$TMP_ROOT/err"
    assert_file_not_contains "$TMP_ROOT/err" 'lanes: lane-host-busy' 'control: the unmeasured account mark loses the capacity fallback'
    SUCCEED="$TEST_DIR/../scripts/oversee-succeed"
  fi
  if [[ "$notice" == busy ]]; then
    if [[ -f "$H/.cache/orch/lane-host-slots/short/slot.$HOLDER" ]]; then
      pass 'the same accounts child still holds the slot after every capacity read'
    else
      fail 'the same accounts child still holds the slot after every capacity read' 'the accounts slot was released'
    fi
    printf '\n' >&6
    wait "$HOLDER"
    HOLDER=""
    exec 6>&-
  fi
done <<'ROWS'
local-file|yes|no|provider|0||80|0|no
provider-token|no|yes|provider|0||90|0|no
unmeasured|no|no|provider|0||unknown|3|no
cloud-no-repo|yes|no|claude-cloud|0||80|0|no
cloud-repo|yes|no|claude-cloud|0|allowed|80|0|no
provider-failed|yes|no|provider|1||80|0|failed
provider-failed-unmeasured|no|no|provider|1||unknown|3|failed
provider-busy-unmeasured|no|no|provider|0||unknown|3|busy
provider-future-unmeasured|no|no|provider|1||unknown|3|future
ROWS
printf '\npass: %s   fail: %s\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
