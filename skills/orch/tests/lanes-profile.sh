#!/usr/bin/env bash
# Surface: lanes' Claude usage-refusal profile check.
# Inputs: scripts/lanes, its sourced libraries and lib/lanes-fixture.sh.
# The curl boundary returns Claude Code's account/organization profile shape.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LANES="$(cd "$TEST_DIR/.." && pwd)/scripts/lanes"
TMP_ROOT="$(mktemp -d)" || { echo "lanes-profile: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "lanes-profile: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "lanes-profile: scratch=resolve-failed" >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
source "$TEST_DIR/lib/assertions.sh"
source "$TEST_DIR/lib/lanes-fixture.sh"
source "$TEST_DIR/lib/growth-state.sh"
mkdir -p "$TMP_ROOT/bin" "$TMP_ROOT/repo"
git -C "$TMP_ROOT/repo" init -q -b main
git -C "$TMP_ROOT/repo" config gc.auto 0
git -C "$TMP_ROOT/repo" config maintenance.auto false
cat > "$TMP_ROOT/bin/curl" <<'CURL'
#!/usr/bin/env bash
set -euo pipefail
config="$(cat)"
endpoint="" beta=""
for arg in "$@"; do
  case "$arg" in
    */usage) endpoint=usage ;;
    */profile) endpoint=profile ;;
    'anthropic-beta: '*) beta="$arg" ;;
  esac
done
printf '%s\t%s\t%s\n' "$endpoint" "$config" "$beta" >> "$CURL_LOG"
case "$endpoint" in
  usage) code="$USAGE_CODE"; body='{}' ;;
  profile)
    [[ "$PROFILE_CODE" != transport ]] || exit 7
    code="$PROFILE_CODE"; body="$(cat "$PROFILE_BODY")"
    ;;
  *) exit 6 ;;
esac
printf 'HTTP/1.1 %s Fixture\r\nContent-Type: application/json\r\nRetry-After: 901\r\n\r\n%s\n%s' "$code" "$body" "$code"
CURL
chmod +x "$TMP_ROOT/bin/curl"
LAPSED='{"account":{"has_claude_max":false},"organization":{"organization_type":"claude_free","subscription_status":"canceled"}}'
ACTIVE='{"account":{"has_claude_max":true},"organization":{"organization_type":"claude_max","subscription_status":"active"}}'
SHIPPED="$LANES"
CLASSIFY="$(mutant_scripts profile-classify lanes)"
mutate_file "$CLASSIFY/lanes" 'detail="$profile_detail"' ': "$profile_detail"'
ACTIVE_CONTROL="$(mutant_scripts profile-active lanes)"
mutate_file "$ACTIVE_CONTROL/lanes" '$org.organization_type == "claude_free"' '$org.organization_type != null'
mutate_file "$ACTIVE_CONTROL/lanes" '$org.subscription_status == "canceled"' '$org.subscription_status != null'
mutate_file "$ACTIVE_CONTROL/lanes" '.account.has_claude_max == false' '.account.has_claude_max != null'
HTTP_CONTROL="$(mutant_scripts profile-http-gate lanes)"
mutate_file "$HTTP_CONTROL/lanes" '( "$HTTP_CODE" == 401 || "$HTTP_CODE" == 403 )' 'true'
HARNESS_CONTROL="$(mutant_scripts profile-harness-gate lanes)"
mutate_file "$HARNESS_CONTROL/lanes" '"$harness" == claude && ( "$HTTP_CODE" == 401' '( "$HTTP_CODE" == 401'
ANSWER_CONTROL="$(mutant_scripts profile-answer-gate lanes)"
mutate_file "$ANSWER_CONTROL/lanes" '[[ "$HTTP_CODE" == 2?? ]] || return 1' '[[ "$HTTP_CODE" == ??? ]] || return 1'
FIELDS_CONTROL="$(mutant_scripts profile-fields-gate lanes)"
mutate_file "$FIELDS_CONTROL/lanes" '.account.has_claude_max == false' '(.account.has_claude_max // false) == false'

profile_run() { # SCRIPT USAGE_CODE PROFILE_CODE ARGS...
  local script="$1" usage="$2" profile="$3"
  shift 3
  (cd "$TMP_ROOT/repo" && env -i PATH="$TMP_ROOT/bin:$PATH" HOME="$H" LANES_HOME="$H" \
    GIT_CEILING_DIRECTORIES="$GIT_CEILING_DIRECTORIES" ORCH_LANE_HOST=local \
    ORCH_LANE_DIRS="$ACCOUNT" ORCH_LANES_CLAUDE_USAGE_URL=https://lanes-test.invalid/api/oauth/usage \
    ORCH_LANES_CODEX_USAGE_URL=https://lanes-test.invalid/codex/usage \
    OVERSEE_WATCH_STATE_DIR="$H/store" ORCH_STATE_DIR="$H/state" \
    CURL_LOG="$H/curl.log" USAGE_CODE="$usage" PROFILE_CODE="$profile" PROFILE_BODY="$H/profile.json" \
    "$script" "$@" 2>"$H/err")
}

# name|usage code|profile code|profile body|harness|local plan|cause|profile calls|script
# An active profile must not become an ended plan even with stale free credentials.
for row in \
  "fallback-401|401|transport|{}|claude|max|baseline|1|$SHIPPED" \
  "fallback-403|403|transport|{}|claude|max|baseline|1|$SHIPPED" \
  "lapsed-401|401|200|$LAPSED|claude|max|ended|1|$SHIPPED" \
  "lapsed-403|403|200|$LAPSED|claude|max|ended|1|$SHIPPED" \
  "active-profile|403|200|$ACTIVE|claude|free|same|1|$SHIPPED" \
  "failed-profile|403|503|$LAPSED|claude|max|same|1|$SHIPPED" \
  "missing-plan|403|200|{}|claude|free|same|1|$SHIPPED" \
  "missing-status|403|200|{\"account\":{\"has_claude_max\":false},\"organization\":{\"organization_type\":\"claude_free\"}}|claude|max|same|1|$SHIPPED" \
  "missing-max|403|200|{\"organization\":{\"organization_type\":\"claude_free\",\"subscription_status\":\"canceled\"}}|claude|max|same|1|$SHIPPED" \
  "bad-json|403|200|not-json|claude|max|same|1|$SHIPPED" \
  "paid-canceled|403|200|{\"account\":{\"has_claude_max\":true},\"organization\":{\"organization_type\":\"claude_max\",\"subscription_status\":\"canceled\"}}|claude|max|same|1|$SHIPPED" \
  "rate-limited|429|200|$LAPSED|claude|max|baseline|0|$SHIPPED" \
  "unreachable|503|200|$LAPSED|claude|max|baseline|0|$SHIPPED" \
  "codex-refused|403|200|$LAPSED|codex|max|same|0|$SHIPPED" \
  "control-classify|403|200|$LAPSED|claude|max|ended|1|$CLASSIFY/lanes" \
  "control-active|403|200|$ACTIVE|claude|free|same|1|$ACTIVE_CONTROL/lanes" \
  "control-http|429|200|$LAPSED|claude|max|baseline|0|$HTTP_CONTROL/lanes" \
  "control-harness|403|200|$LAPSED|codex|max|same|0|$HARNESS_CONTROL/lanes" \
  "control-answer|403|503|$LAPSED|claude|max|same|1|$ANSWER_CONTROL/lanes" \
  "control-fields|403|200|{\"organization\":{\"organization_type\":\"claude_free\",\"subscription_status\":\"canceled\"}}|claude|max|same|1|$FIELDS_CONTROL/lanes"; do
  IFS='|' read -r name code profile body harness plan cause calls script <<<"$row"
  new_home "$name"
  ACCOUNT="$H/.$harness"
  if [[ "$harness" == claude ]]; then make_lane "$H" claude 3600 "$plan"
  else make_codex_token_lane "$ACCOUNT" 3600; fi
  printf '%s\n' "$body" > "$H/profile.json"
  out="$(profile_run "$script" "$code" "$profile" list --harness "$harness" --json)"
  detail="$(jq -r '.[0].detail' <<<"$out")"
  if [[ "$name" == fallback-* ]]; then
    if [[ "$code" == 401 ]]; then DETAIL_401="$detail"; else DETAIL_403="$detail"; fi
  fi
  status=refused
  [[ "$code" != 429 ]] || status=rate_limited
  [[ "$code" != 503 ]] || status=unreachable
  got="$(jq -r '.[0].status' <<<"$out") calls=$(awk '$1 == "profile" { n++ } END { print n+0 }' "$H/curl.log")"
  want="$status calls=$calls"
  if [[ "$cause" == ended ]]; then
    # Assert the response's plan values, not human sentence wording.
    old="$DETAIL_403"; [[ "$code" != 401 ]] || old="$DETAIL_401"
    got+=" cause=$(jq -r --arg old "$old" '.[0].detail | . != $old and contains("claude_free") and contains("canceled")' <<<"$out")"
    want+=" cause=true"
  elif [[ "$cause" == same ]]; then
    got+=" cause=$([[ "$detail" == "$DETAIL_403" ]] && echo same || echo changed)"
    want+=" cause=same"
  fi
  if [[ "$name" == control-* ]]; then
    [[ "$got" != "$want" ]] && pass "$name turns the unchanged assertion red" || fail "$name did not reject the planted defect"
  else
    assert_eq "$got" "$want" "$name" "$H/err"
    record="$(cat "$H/store/usage"/*.json)"
    assert_eq "$(jq -r --arg detail "$detail" --arg code "$code" '.refusal.detail == $detail and .refusal.code == $code' <<<"$record")" true "$name records the same detail and usage code"
    if [[ "$calls" == 1 ]]; then
      assert_eq "$(awk -F '\t' 'NR == 1 { auth=$2; beta=$3 } $1 == "profile" { print ($2 == auth && $3 == beta && beta == "anthropic-beta: oauth-2025-04-20") }' "$H/curl.log")" 1 "$name uses the same token and beta header"
    fi
    if [[ "$cause" == ended ]]; then
      cached="$(profile_run "$script" "$code" transport list --harness "$harness" --json --cache-only)"
      assert_eq "$(jq -r '.[0].detail' <<<"$cached")" "$detail" "$name keeps the recorded cause on the cached refusal"
      assert_eq "$(awk 'END { print NR }' "$H/curl.log")" 2 "$name posts no request for a cached refusal"
    fi
  fi
done
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
