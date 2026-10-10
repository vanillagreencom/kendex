#!/usr/bin/env bash
# Pick rejects an ended Claude refresh login even with a live access token.
# Inputs: scripts/lanes and the libraries it sources.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
LANES="$TEST_DIR/../scripts/lanes"
TMP_ROOT="$(mktemp -d)" || { echo "lanes-login: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "lanes-login: scratch=not-a-directory" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "lanes-login: scratch=resolve-failed" >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
source "$TEST_DIR/lib/assertions.sh"
source "$TEST_DIR/lib/lanes-fixture.sh"
source "$TEST_DIR/lib/growth-state.sh"
FETCHER="$TMP_ROOT/fetch"; make_fetcher "$FETCHER"
mkdir -p "$TMP_ROOT/repo" "$TMP_ROOT/bin"
git -C "$TMP_ROOT/repo" init -q -b main
git -C "$TMP_ROOT/repo" config gc.auto 0
git -C "$TMP_ROOT/repo" config maintenance.auto false
# Fixed noon UTC; the same-day row ends one hour later.
REAL_DATE="$(command -v date)"
cat > "$TMP_ROOT/bin/date" <<'CLOCK'
#!/usr/bin/env bash
if [[ "${1:-}" == +%s ]]; then printf '%s\n' 1791460800; else exec "$REAL_DATE" "$@"; fi
CLOCK
chmod +x "$TMP_ROOT/bin/date"
CONTROL="$(mutant_scripts auth-pick lanes)"
mutate_file "$CONTROL/lanes" 'if token_expired "$refresh_expiry" "$now_s"; then' 'if false && token_expired "$refresh_expiry" "$now_s"; then'
ROUNDING="$(mutant_scripts expiry-rounding lanes)"
mutate_file "$ROUNDING/lanes" '(( exp <= $2 * 1000 ))' '(( exp / 1000 <= $2 ))'
for row in 'expired|1791460799000|5|expired' 'at-end|1791460800000|5|expired' 'not-yet-ended|1791460800001|0|ok' 'same-day|1791464400000|0|ok' 'unstated|0|0|ok' 'missing|0|5|no_credentials'; do
  IFS='|' read -r name expiry expected_rc expected_status <<<"$row"
  new_home "$name"
  make_lane "$H" claude
  jq --argjson expiry "$expiry" '.claudeAiOauth.refreshTokenExpiresAt=$expiry' "$H/.claude/.credentials.json" > "$H/creds.tmp"
  mv -- "$H/creds.tmp" "$H/.claude/.credentials.json"
  [[ "$name" != missing ]] || rm -- "$H/.claude/.credentials.json"
  claude_usage 10 10 10 Opus > "$FIXTURE_DIR/.claude.json"
  for verb in named chooser; do
    args=(pick --harness claude --json)
    [[ "$verb" != named ]] || args+=(--lane "$H/.claude")
    rc=0
    (cd "$TMP_ROOT/repo" && env -i GIT_CEILING_DIRECTORIES="$GIT_CEILING_DIRECTORIES" PATH="$TMP_ROOT/bin:$PATH" HOME="$H" LANES_HOME="$H" REAL_DATE="$REAL_DATE" \
      FIXTURE_DIR="$FIXTURE_DIR" ORCH_LANES_FETCH_CMD="$FETCHER" ORCH_LANE_DIRS="$H/.claude" \
      OVERSEE_WATCH_STATE_DIR="$H/store" "$LANES" "${args[@]}") > "$H/out" 2> "$H/err" || rc=$?
    want_rc="$expected_rc"; [[ "$verb" != chooser || "$expected_rc" == 0 ]] || want_rc=3
    assert_eq "$rc" "$want_rc" "$name $verb pick exit" "$H/err"
    if [[ "$verb" == named ]]; then
      assert_eq "$(jq -r .status "$H/out")" "$expected_status" "$name named pick status" "$H/err"
    elif [[ "$expected_rc" != 0 ]]; then
      assert_eq "$(jq -r .qualifying_count "$H/out")" 0 "$name chooser seats no expired login" "$H/err"
      assert_contains "$(cat "$H/err")" "$expected_status" "$name refusal names the failed login status" "$H/err"
    fi
  done
  if [[ "$name" == expired ]]; then
    rc=0
    (cd "$TMP_ROOT/repo" && env -i GIT_CEILING_DIRECTORIES="$GIT_CEILING_DIRECTORIES" PATH="$TMP_ROOT/bin:$PATH" HOME="$H" LANES_HOME="$H" REAL_DATE="$REAL_DATE" \
      FIXTURE_DIR="$FIXTURE_DIR" ORCH_LANES_FETCH_CMD="$FETCHER" ORCH_LANE_DIRS="$H/.claude" \
      OVERSEE_WATCH_STATE_DIR="$H/control-store" "$CONTROL/lanes" pick --harness claude --json) > "$H/control-out" 2> "$H/control-err" || rc=$?
    assert_eq "$rc" 0 "must-fail: removing the refresh expiry check seats the expired account" "$H/control-err"
    assert_eq "$(jq -r .config_dir "$H/control-out")" "$H/.claude" "must-fail: the refused account itself is picked" "$H/control-err"
  elif [[ "$name" == not-yet-ended ]]; then
    rc=0
    (cd "$TMP_ROOT/repo" && env -i GIT_CEILING_DIRECTORIES="$GIT_CEILING_DIRECTORIES" PATH="$TMP_ROOT/bin:$PATH" HOME="$H" LANES_HOME="$H" REAL_DATE="$REAL_DATE" \
      FIXTURE_DIR="$FIXTURE_DIR" ORCH_LANES_FETCH_CMD="$FETCHER" ORCH_LANE_DIRS="$H/.claude" \
      OVERSEE_WATCH_STATE_DIR="$H/rounding-store" "$ROUNDING/lanes" pick --harness claude --json) > "$H/control-out" 2> "$H/control-err" || rc=$?
    assert_eq "$rc" 3 "must-fail: rounding expiry down rejects a login that has not ended" "$H/control-err"
    assert_eq "$(jq -r .qualifying_count "$H/control-out")" 0 "must-fail: early expiry removes the only candidate" "$H/control-err"
  fi
done
printf 'pass: %s   fail: %s\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
