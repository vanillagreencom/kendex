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
cleanup() {
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
        LANE_HOST_STUB_LOG="$TMP_ROOT/host.log" ORCH_OVERSEER_PREFERENCE=claude::high \
        ORCH_OVERSEER_WALL_MINUTES=0 ORCH_OVERSEER_SUCCESSOR_ACCOUNTS=0 \
        ORCH_HANDOFF_AGENT_RESERVE_TOKENS=0 ORCH_HANDOFF_CONTEXT_PCT=50 \
        "$SUCCEED" "$@"
    )
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
  if [[ "$notice" == yes ]]; then
    assert_file_contains "$TMP_ROOT/err" "lanes: host-accounts-unreadable host=$host exit=$accounts_rc" \
      "$name: the account mark relays the provider fallback"
  fi
  rc=0
  out="$(run_seat --print-launch-line --harness claude --entry claude::high 2>"$TMP_ROOT/err")" || rc=$?
  assert_eq "$rc" "$pick_rc" "$name: the seat pick answers" "$TMP_ROOT/err"
  if [[ "$pick_rc" == 0 ]]; then
    # oversee-watch stores this shell command verbatim for death recovery.
    assert_contains "$out" "CLAUDE_CONFIG_DIR='$H/.claude'" "$name: the seat uses the measured folder" "$TMP_ROOT/err"
  else
    assert_contains "$(cat "$TMP_ROOT/err")" 'unmeasured=1' "$name: the seat pick keeps the folder unmeasured"
  fi
  if [[ "$notice" == yes ]]; then
    assert_file_contains "$TMP_ROOT/err" "lanes: host-accounts-unreadable host=$host exit=$accounts_rc" \
      "$name: the shared seat pick relays the provider fallback"
  fi
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
  if [[ "$name" == provider-failed && -z "${OVERSEE_SUCCEED_UNDER_TEST:-}" ]]; then
    CONTROL="$(mutant_scripts hidden-fallback lib/overseer-launch.sh)"
    mutate_file "$CONTROL/lib/overseer-launch.sh" '[[ ! -s "$DEP_ERR" ]] || cat -- "$DEP_ERR" >&2; : > "$DEP_ERR"' \
      '[[ 1 == 1 || ! -s "$DEP_ERR" ]] || cat -- "$DEP_ERR" >&2; : > "$DEP_ERR"'
    SUCCEED="$CONTROL/oversee-succeed"
    for mode in mark pick; do
      args=(--check-marks --harness claude --context 100:1000)
      [[ "$mode" != pick ]] || args=(--print-launch-line --harness claude --entry claude::high)
      rc=0
      out="$(SEAT_CACHE="control-$mode" run_seat "${args[@]}" 2>"$TMP_ROOT/err")" || rc=$?
      assert_eq "$rc" 0 "control: $mode still accepts the local fallback" "$TMP_ROOT/err"
      assert_file_not_contains "$TMP_ROOT/err" 'lanes: host-accounts-unreadable' "control: $mode loses the fallback notice"
    done
    SUCCEED="$TEST_DIR/../scripts/oversee-succeed"
  fi
  if [[ "$name" == provider-failed-unmeasured && -z "${OVERSEE_SUCCEED_UNDER_TEST:-}" ]]; then
    CONTROL="$(mutant_scripts hidden-refusal-fallback lib/overseer-launch.sh)"
    mutate_file "$CONTROL/lib/overseer-launch.sh" "awk '/^lanes: host-accounts-unreadable /'" \
      ": awk '/^lanes: host-accounts-unreadable /'"
    SUCCEED="$CONTROL/oversee-succeed"
    rc=0
    out="$(SEAT_CACHE=control-state run_seat --check-marks --harness claude --context 100:1000 2>"$TMP_ROOT/err")" || rc=$?
    assert_eq "$rc" 0 'control: the unmeasured account mark still answers' "$TMP_ROOT/err"
    assert_file_not_contains "$TMP_ROOT/err" 'lanes: host-accounts-unreadable' 'control: the unmeasured account mark loses the fallback notice'
    SUCCEED="$TEST_DIR/../scripts/oversee-succeed"
  fi
done <<'ROWS'
local-file|yes|no|provider|0||80|0|no
provider-token|no|yes|provider|0||90|0|no
unmeasured|no|no|provider|0||unknown|3|no
cloud-no-repo|yes|no|claude-cloud|0||80|0|no
cloud-repo|yes|no|claude-cloud|0|allowed|80|0|no
provider-failed|yes|no|provider|1||80|0|yes
provider-failed-unmeasured|no|no|provider|1||unknown|3|yes
ROWS
printf '\npass: %s   fail: %s\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
