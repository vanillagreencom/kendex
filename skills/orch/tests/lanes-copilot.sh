#!/usr/bin/env bash
# Tests for the Copilot accounts `lanes` measures: discovery of a Copilot
# account directory, the stored login lib/copilot-credits.sh reads the usage
# endpoint with, the monthly credit pool it parses from the endpoint's answer,
# the stated fallback, and the judgement `pick` takes of it through
# lib/lane-model.sh. The endpoint is injected through ORCH_LANES_FETCH_CMD
# answering fixed bodies in the shape its `quota_snapshots.premium_interactions`
# object carries, and curl through a shim on PATH for the request's own row,
# so every row runs offline; lanes.sh holds every other harness's rows.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
# Every account this suite measures lives under LANES_HOME; an inherited
# setting would point discovery at the operator's real accounts.
unset ORCH_LANE_DIRS ORCH_LANE_ALIASES ORCH_LANE_EXCLUDE ORCH_LANE_RETIRE ORCH_LANE_COPILOT_POOL \
  ORCH_LANES_USAGE_TTL ORCH_LANE_MAX_PCT ORCH_HANDOFF_HEADROOM_PCT CODEX_HOME COPILOT_HOME

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TEST_DIR/.." && pwd)/scripts"
TMP_ROOT="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT

# shellcheck source=lib/assertions.sh
source "$TEST_DIR/lib/assertions.sh"
# shellcheck source=lib/lanes-fixture.sh
source "$TEST_DIR/lib/lanes-fixture.sh"
# shellcheck source=lib/growth-state.sh
source "$TEST_DIR/lib/growth-state.sh"

FETCHER="$TMP_ROOT/fetch"
make_fetcher "$FETCHER"
# Runs are made from a repository carrying no settings, so the checkout's
# kendex.settings.toml supplies no threshold.
NOSETTINGS="$TMP_ROOT/nosettings"
mkdir -p "$NOSETTINGS"
git -C "$NOSETTINGS" init -q -b main

# run_lanes ARGS... — `lanes` under the current home and a fresh state; OUT, RC.
RUN_SEQ=0
run_lanes() {
  local run="$TMP_ROOT/runs/$((++RUN_SEQ))"
  mkdir -p "$run/store"
  RC=0
  OUT="$(cd "$NOSETTINGS" && env GIT_CEILING_DIRECTORIES="$TMP_ROOT" LANES_HOME="$H" \
    ORCH_LANES_FETCH_CMD="$FETCHER" FETCH_LOG="$run/fetch.log" OVERSEE_WATCH_STATE_DIR="$run/store" \
    ${ROW_ENV[@]+"${ROW_ENV[@]}"} "${LANES_BIN:-$SCRIPTS_DIR/lanes}" "$@" 2>"$run/stderr")" || RC=$?
  ERR="$(cat "$run/stderr")"
}
ROW_ENV=()

# copilot_account NAME BODY — a Copilot account under H holding a stored login
# in the layout lib/copilot-credits.sh assumes, and the usage endpoint's
# answer for it.
copilot_account() {
  mkdir -p "$H/.$1"
  printf '{"copilot_tokens":{"https://github.com:user":"gho_%s"}}\n' "$1" > "$H/.$1/config.json"
  printf '%s\n' "$2" > "$FIXTURE_DIR/.$1.json"
}
# pool ENTITLEMENT REMAINING [EXTRA_JSON] — a premium_interactions answer.
pool() {
  jq -nc --argjson e "$1" --argjson r "$2" --argjson x "${3:-{\}}" \
    '{copilot_plan: "business", quota_reset_date_utc: "2026-10-01",
      quota_snapshots: {premium_interactions: ({entitlement: $e, remaining: $r, credits_used: ($e - $r),
        overage_permitted: true, overage_count: 0, unlimited: false, token_based_billing: true,
        percent_remaining: 99} + $x)}}'
}
record() { # ALIAS JQ — one field of that account's listed record
  jq -c --arg a "$1" ".[] | select(.alias == \$a) | $2" <<<"$OUT" 2>/dev/null || echo unparseable
}

echo "=== the monthly pool is read from the endpoint's counts ==="
new_home pool
copilot_account 1copilot "$(pool 1000000 900000)"
copilot_account 2copilot "$(pool 1000000 0)"
copilot_account 3copilot "$(pool 1000000 1)"
copilot_account 4copilot '{"quota_snapshots":{"premium_interactions":{"unlimited":true}}}'
copilot_account 5copilot '{"quota_snapshots":{"premium_interactions":{"unlimited":"true","percent_remaining":100}}}'
copilot_account 6copilot "$(pool 0 0)"
copilot_account 7copilot '{"quota_snapshots":{"premium_interactions":{"entitlement":"1000000","remaining":900000}}}'
copilot_account 8copilot '{"quota_snapshots":{}}'
copilot_account 9copilot "$(pool 1000 -500)"
copilot_account 10copilot "$(pool 1000 1200)"
mkdir -p "$H/.0copilot"
printf '{}\n' > "$H/.0copilot/settings.json"
run_lanes list --harness copilot --local --json
while IFS='|' read -r label alias field want; do
  assert_eq "$(record "$alias" "$field")" "$want" "$label"
done <<'ROWS'
a pool with room binds the monthly bucket, used share from remaining over entitlement|1copilot|[.status, .monthly_pct, .headroom_pct, .binding_bucket, .binding_resets_at]|["ok",10,90,"monthly","2026-10-01T00:00:00Z"]
the plan is the endpoint's own|1copilot|.plan|"business"
a pool at zero is spent whatever overage it permits|2copilot|[.monthly_pct, .headroom_pct, .credits.overage_permitted]|[100,0,true]
one credit left rounds up to a spent share|3copilot|.monthly_pct|100
an explicit unlimited seat is room with no bucket|4copilot|[.status, .unlimited, .headroom_pct, .binding_bucket, .credits.unit, .credits.unlimited]|["ok",true,100,null,"AIC",true]
an unlimited that is not the boolean true measures nothing|5copilot|[.status, .unlimited, .headroom_pct]|["no_usage_data",false,null]
an entitlement of zero measures nothing|6copilot|[.status, .headroom_pct, .credits]|["no_usage_data",null,null]
an entitlement of another type measures nothing|7copilot|[.status, .headroom_pct]|["no_usage_data",null]
an answer with no pool measures nothing|8copilot|[.status, .headroom_pct]|["no_usage_data",null]
a pool used past its grant reads 100, never a negative headroom|9copilot|[.monthly_pct, .headroom_pct]|[100,0]
more remaining than granted reads as no use, never a negative share|10copilot|[.monthly_pct, .headroom_pct]|[0,100]
ROWS
assert_eq "$(record 1copilot 'del(.credits.measured_at) | .credits')" \
  '{"unit":"AIC","unlimited":false,"used":100000,"granted":1000000,"remaining":900000,"over":0,"overage_permitted":true,"token_based_billing":true}' \
  "the credit counts ride beside the share"
assert_eq "$(record 1copilot '.credits.measured_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$")')" true \
  "the counts carry the time they were measured"
assert_eq "$(record 0copilot .status)" '"no_credentials"' "an account holding no login reads no_credentials"

echo "=== pick judges a Copilot account on its pool ==="
while IFS='|' read -r label args want; do
  eval "set -- $args"
  run_lanes "$@"
  assert_eq "rc=$RC out=$(head -n 1 <<<"$OUT")" "$want" "$label"
done <<ROWS
the unlimited seat is picked over one with less room, handed back under COPILOT_HOME|pick --harness copilot --exclude-lane $H/.10copilot|rc=0 out=COPILOT_HOME=$H/.4copilot
a named account at zero is walled even under a bound of 100|pick --lane $H/.2copilot --harness copilot --max-pct 100|rc=3 out=
a named unlimited seat is room for any model|pick --lane $H/.4copilot --harness copilot --model claude-opus-5 --binding-floor|rc=0 out=COPILOT_HOME=$H/.4copilot
a named account with room clears the default bound|pick --lane $H/.1copilot --harness copilot --model claude-opus-5|rc=0 out=COPILOT_HOME=$H/.1copilot
a named account whose answer measured nothing is unmeasured|pick --lane $H/.5copilot --harness copilot|rc=5 out=
ROWS

echo "=== the stored login is read defensively, and the stated pool is its fallback ==="
# `label|config.json|want status|want reason`: `-` is no file. The reason is
# the one the record's detail names; nothing is fetched for any of these.
new_home login
while IFS='|' read -r label config want_status want_reason; do
  rm -rf -- "${H:?}/.1copilot"
  mkdir -p "$H/.1copilot"
  printf '{}\n' > "$H/.1copilot/settings.json"
  [[ "$config" == - ]] || printf '%s\n' "$config" > "$H/.1copilot/config.json"
  printf '%s\n' "$(pool 1000 900)" > "$FIXTURE_DIR/.1copilot.json"
  run_lanes list --harness copilot --local --json
  reason="$(record 1copilot .detail | grep -o 'login unread: [a-z-]*' || echo none)"
  assert_eq "$(record 1copilot .status)|$reason" "\"$want_status\"|$want_reason" "$label"
done <<'ROWS'
a login as a bare string reads|{"copilot_tokens":"gho_bare"}|ok|none
no config.json is no login|-|no_credentials|login unread: config-missing
a config.json that is not JSON is unreadable|{"copilot_tokens":|no_credentials|login unread: config-unreadable
no copilot_tokens key is no login|{"logged_in_users":[]}|no_credentials|login unread: token-missing
an object holding no string is no login|{"copilot_tokens":{"a":1}}|no_credentials|login unread: token-missing
two logins in one account are refused, never one of them guessed|{"copilot_tokens":{"a":"x","b":"y"}}|no_credentials|login unread: token-ambiguous
ROWS
printf '// This file is managed automatically\n{"copilot_tokens":{"https://github.com:user":"gho_c"}}\n' > "$H/.1copilot/config.json"
run_lanes list --harness copilot --local --json
assert_eq "$(record 1copilot .status)" '"ok"' "the comment line the CLI writes ahead of the JSON is skipped"
rm -f -- "${H:?}/.1copilot/config.json"
ROW_ENV=(ORCH_LANE_COPILOT_POOL="$H/.1copilot=250/1000")
run_lanes pick --lane "$H/.1copilot" --harness copilot --json
ROW_ENV=()
assert_eq "$(jq -c '[.status, .measured_through, .monthly_pct, (.credits | del(.measured_at))]' <<<"$OUT" 2>/dev/null || echo unparseable)" \
  '["ok","stated",25,{"unit":"AIC","unlimited":false,"used":250,"granted":1000,"remaining":750}]' \
  "an account whose login does not read takes its stated reading as the fallback"

echo "=== the request hands the login to curl on stdin, never in argv ==="
SHIM="$TMP_ROOT/curl-shim"
mkdir -p "$SHIM"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" > "$CURL_ARGV"\ncat > "$CURL_STDIN"\nprintf "HTTP/2 200\\r\\n\\r\\n{}\\n200"\n' > "$SHIM/curl"
chmod +x "$SHIM/curl"
( . "$SCRIPTS_DIR/lib/copilot-credits.sh"
  CURL_ARGV="$TMP_ROOT/argv" CURL_STDIN="$TMP_ROOT/stdin" PATH="$SHIM:$PATH" copilot_credits_request gho_secret_login >/dev/null )
assert_eq "$(grep -c gho_secret_login "$TMP_ROOT/argv")|$(grep -c 'api.github.com/copilot_internal/user' "$TMP_ROOT/argv")|$(cat "$TMP_ROOT/stdin")" \
  '0|1|header = "Authorization: token gho_secret_login"' \
  "the endpoint is asked with the login in curl's config on stdin, and the login is nowhere in argv"
run_lanes list --harness copilot --local
assert_eq "$(head -n 1 <<<"$OUT" | tr -s ' ')" "LANE HARNESS THROUGH STATUS PLAN 5H WEEK MODEL MONTH HEADROOM CLAIMS AGE DETAIL" \
  "the table shows the monthly pool in a column of its own"

echo "=== discovery finds a Copilot account by its marker, its variable or its setting ==="
new_home discover
copilot_account 1copilot "$(pool 100 50)"
mkdir -p "$H/.copilot-backup" "$TMP_ROOT/elsewhere" "$TMP_ROOT/named"
printf '{}\n' > "$TMP_ROOT/named/config.json"
names() { jq -r '[.[] | .alias] | sort | join(",")' <<<"$OUT" 2>/dev/null || echo unparseable; }
run_lanes list --harness copilot --local --json
assert_eq "$(names)" 1copilot "a directory with no marker is no account"
ROW_ENV=(COPILOT_HOME="$TMP_ROOT/elsewhere")
run_lanes list --harness copilot --local --json
assert_eq "$(names)" 1copilot,elsewhere "COPILOT_HOME joins the inventory, marker or none"
ROW_ENV=(ORCH_LANE_DIRS="$TMP_ROOT/named")
run_lanes list --harness copilot --local --json
assert_eq "$(names)" named "an ORCH_LANE_DIRS entry holding config.json is a Copilot account and replaces discovery"
ROW_ENV=()
run_lanes list --json
assert_eq "$(jq -r '[.[] | select(.harness == "copilot") | .alias] | join(",")' <<<"$OUT")" 1copilot \
  "list names Copilot accounts among all harnesses"

echo "=== a provider row reports a Copilot account's monthly pool ==="
printf 'account=%s\tharness=copilot\tmonthly-pct=97\tmonthly-resets=2026-10-01T00:00:00Z\n' "$TMP_ROOT/hosted" \
  > "$TMP_ROOT/accounts.tsv"
ROW_ENV=(ORCH_LANE_HOST="$TEST_DIR/fixtures/lane-host" LANE_HOST_STUB_LOG="$TMP_ROOT/accounts.log" \
  LANE_HOST_STUB_ACCOUNTS="$TMP_ROOT/accounts.tsv")
run_lanes host-accounts --harness copilot --json
ROW_ENV=()
assert_eq "$(jq -c '.[0] | [.harness, .monthly_pct, .binding_bucket, .measured_through]' <<<"$OUT" 2>/dev/null || echo unparseable)" \
  '["copilot",97,"monthly","host"]' "a provider's copilot row carries its monthly share and reset"

echo "=== must-fail controls ==="
# One per rule, each in a private copy of the scripts.
lanes_control() { # NAME FILE OLD NEW
  local dir
  dir="$(mutant_scripts "$1" "$2")" || exit 1
  mutate_file "$dir/$2" "$3" "$4"
  LANES_BIN="$dir/lanes"
}
new_home control
copilot_account 2copilot "$(pool 1000000 0)"
copilot_account 3copilot "$(pool 1000000 1)"
copilot_account 5copilot '{"quota_snapshots":{"premium_interactions":{"unlimited":"true","percent_remaining":100}}}'
copilot_account 6copilot "$(pool 0 0)"
copilot_account 9copilot "$(pool 1000 -500)"
copilot_account 10copilot "$(pool 1000 1200)"
control_row() { # ALIAS FIELD WANT LABEL
  run_lanes list --harness copilot --local --json
  assert_eq "$(record "$1" "$2")" "$3" "$4"
}
lanes_control ctl-zero lib/copilot-credits.sh '       elif $remaining <= 0 then 100' '       elif false then 100'
control_row 9copilot .monthly_pct 150 "control: without the zero arm a pool past its grant reads past 100"
lanes_control ctl-clamp lib/copilot-credits.sh '| ceil | if . < 0 then 0 else . end)' '| ceil)'
control_row 10copilot .monthly_pct -20 "control: without the clamp more remaining than granted reads a negative share"
lanes_control ctl-ceil lib/copilot-credits.sh '* 100 / $granted) | ceil |' '* 100 / $granted) | floor |'
control_row 3copilot .monthly_pct 99 "control: rounded down, one credit left reads as room"
lanes_control ctl-unlimited lib/copilot-credits.sh '| ($q.unlimited == true) as $unlimited' '| ($q.unlimited | . == true or . == "true") as $unlimited'
control_row 5copilot .headroom_pct 100 "control: an unlimited read loosely takes a string for a measured unlimited seat"
lanes_control ctl-limit lib/copilot-credits.sh '($remaining != null and $granted != null and $granted > 0) as $counted' '($remaining != null and $granted != null) as $counted'
control_row 6copilot '[.status, .monthly_pct]' '["ok",100]' "control: without the entitlement bound a zero grant reads as a measured pool"
lanes_control ctl-bind lanes '[{k: "monthly", p: $b.monthly_pct}, ' '['
control_row 2copilot .binding_bucket null "control: without the monthly bucket in the binding a Copilot pool binds nothing"
lanes_control ctl-model lib/lane-model.sh '  elif .unlimited == true then unlimited_wall' '  elif false then unlimited_wall'
copilot_account 4copilot '{"quota_snapshots":{"premium_interactions":{"unlimited":true}}}'
run_lanes pick --lane "$H/.4copilot" --harness copilot --model claude-opus-5
assert_eq "rc=$RC" rc=5 "control: without the unlimited arm a named model on an unlimited seat is unmeasured"
lanes_control ctl-discover lanes '				copilot) markers=(settings.json config.json) ;;' ''
run_lanes list --harness copilot --local --json
assert_eq "$(jq 'length' <<<"$OUT" 2>/dev/null || echo unparseable)" 0 "control: without its markers no Copilot account is discovered"
lanes_control ctl-ambiguous lib/copilot-credits.sh '            else "token-ambiguous" end' '            else "token\t" + $v[0] end'
printf '{"copilot_tokens":{"a":"x","b":"y"}}\n' > "$H/.2copilot/config.json"
control_row 2copilot .status '"ok"' "control: without the ambiguity refusal one of two logins is guessed and measured"
lanes_control ctl-comment lib/copilot-credits.sh "sed '/^[[:space:]]*\/\//d' \"\$config\"" "cat \"\$config\""
printf '// This file is managed automatically\n{"copilot_tokens":"gho_c"}\n' > "$H/.2copilot/config.json"
control_row 2copilot .status '"no_credentials"' "control: without the comment skip the CLI's own config.json is unreadable"
lanes_control ctl-fallback lanes '			measure_copilot_pool "$alias" copilot "$dir" "copilot login unread: $COPILOT_CREDITS_REASON in $dir/config.json"' '			emit_lane "$alias" copilot "$dir" no_credentials "" "" "{}"'
rm -f -- "${H:?}/.2copilot/config.json"
printf '{}\n' > "$H/.2copilot/settings.json"
ROW_ENV=(ORCH_LANE_COPILOT_POOL="$H/.2copilot=250/1000")
control_row 2copilot .measured_through '"local"' "control: without the fallback an account with no login ignores its stated reading"
ROW_ENV=()
LANES_BIN=""

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
