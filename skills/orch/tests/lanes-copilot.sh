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
TMP_ROOT="$(mktemp -d)" || { echo "lanes-copilot: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "lanes-copilot: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "lanes-copilot: scratch=resolve-failed" >&2; exit 1; }
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
  # CLAIM_ON names an account one live lane is claimed on for this run: its
  # tmux server is this suite's own process, so the claim counts.
  if [[ -n "${CLAIM_ON:-}" ]]; then
    mkdir -p "$run/store/claims"
    printf '%s\t%%5\t%s\tcop\t2026-09-28T00:00:00Z\n' "$$" "$CLAIM_ON" > "$run/store/claims/cop.claim"
  fi
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
  local extra='{}'
  [[ $# -lt 3 ]] || extra="$3"
  jq -nc --argjson e "$1" --argjson r "$2" --argjson x "$extra" \
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
mkdir -p "$H/.0copilot/session-state"
run_lanes list --harness copilot --local --json
while IFS='|' read -r label alias field want; do
  assert_eq "$(record "$alias" "$field")" "$want" "$label"
done <<'ROWS'
a pool with room binds the monthly bucket, used share from remaining over entitlement|1copilot|[.status, .monthly_pct, .headroom_pct, .binding_bucket, .binding_resets_at]|["ok",10,90,"monthly","2026-10-01T00:00:00Z"]
the plan is the endpoint's own|1copilot|.plan|"business"
a pool at zero is spent whatever overage it permits|2copilot|[.monthly_pct, .headroom_pct, .credits.overage_permitted]|[100,0,true]
one credit left rounds up to a spent share|3copilot|.monthly_pct|100
an explicit unlimited seat is a monthly pool at 0 percent used|4copilot|[.status, .unlimited, .monthly_pct, .headroom_pct, .binding_bucket, .credits.unit, .credits.unlimited]|["ok",true,0,100,"monthly","AIC",true]
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

run_lanes list --harness copilot --local
# The cell under MONTH on the 1copilot row, found by the header's own column.
month_cell() {
  awk '$1 == "LANE" { for (i = 1; i <= NF; i++) if ($i == "MONTH") c = i } $1 == "1copilot" && c { print $c }' <<<"$OUT"
}
assert_eq "$(month_cell)" "10%" "the table shows the monthly pool used in its MONTH column"
CTL_TABLE="$(mutant_scripts ctl-table lanes)" || exit 1
mutate_file "$CTL_TABLE/lanes" 'num(.model_pct), num(.monthly_pct),' 'num(.model_pct), num(.model_pct),'
LANES_BIN="$CTL_TABLE/lanes" run_lanes list --harness copilot --local
assert_eq "$(month_cell)" "-" "control: a table that fills MONTH from another field shows no pool"

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

echo "=== a live lane on a Copilot account is charged its burn over the month ==="
# 5 points of a 5-hour window an hour, held as 5 of the month's 720 hours: a
# weekly charge would read 21 in the pinned figure, not 5.
CLAIM_ON="$H/.1copilot" run_lanes pick --lane "$H/.1copilot" --harness copilot --json
assert_eq "$(jq -c '[.claims, .binding_bucket, (.burn_pct_per_lane_hour * 144 | round), (.projected_headroom_pct * 1000 | round)]' <<<"$OUT" 2>/dev/null || echo unparseable)" \
  '[1,"monthly",5,89965]' "one live claim is charged 5/720 of the default burn, so a pool with room is projected with room"

echo "=== a Pi pick never returns a Copilot CLI account the stated pool names ==="
# The stated pool names both a Pi root and a Copilot account; the Copilot one
# has more room, so a Pi pick that counted it would return it.
PI_POOL="ORCH_LANE_COPILOT_POOL=$H/.1copilot=5/100,$H/.pi1=10/100"
ROW_ENV=("$PI_POOL")
run_lanes pick --harness pi --model github-copilot/gpt-5 --json
ROW_ENV=()
assert_eq "rc=$RC dir=$(jq -r '.config_dir' <<<"$OUT" 2>/dev/null || echo unparseable)" "rc=0 dir=$H/.pi1" \
  "the Copilot account is left out of the Pi candidates, and the Pi root is picked"

echo "=== the stored login is read defensively, and the stated pool is its fallback ==="
# `label|config.json|want status|want reason`: `-` is no file. The reason is
# the one the record's detail names; nothing is fetched for any of these.
new_home login
while IFS='|' read -r label config want_status want_reason; do
  rm -rf -- "${H:?}/.1copilot"
  mkdir -p "$H/.1copilot/session-state"
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
two GitHub.com logins in one account are refused, never one of them guessed|{"copilot_tokens":{"https://github.com:a":"x","https://github.com:b":"y"}}|no_credentials|login unread: token-ambiguous
a login another host issued is never sent to GitHub.com|{"copilot_tokens":{"https://acme.ghe.com:a":"ghu_tenant"}}|no_credentials|login unread: token-foreign-host
the GitHub.com login is read beside another host's|{"copilot_tokens":{"https://acme.ghe.com:a":"ghu_tenant","https://github.com:b":"gho_b"}}|ok|none
an object holding only another type is no login|{"copilot_tokens":{"https://github.com:a":7}}|no_credentials|login unread: token-missing
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

echo "=== lanes asks the Copilot endpoint with the account's stored login ==="
# End to end, with no fetch stub: `lanes` reads the login copilot_account
# wrote, hands it to curl in its config on stdin, and parses what the shim
# answers. The shim records its argv and stdin and answers a 10 percent pool.
SHIM="$TMP_ROOT/curl-shim"
mkdir -p "$SHIM"
cat > "$SHIM/curl" <<'SHIMEOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$CURL_ARGV"
cat > "$CURL_STDIN"
printf 'HTTP/2 200\r\n\r\n%s\n200' "$CURL_BODY"
SHIMEOF
chmod +x "$SHIM/curl"
# curl_row NAME [LANES] — `lanes list` on the 1copilot account through the
# shim; OUT, RC.
curl_row() {
  new_home "curl-$1"
  copilot_account 1copilot "$(pool 1000 900)"
  ROW_ENV=(ORCH_LANES_FETCH_CMD= PATH="$SHIM:$PATH" CURL_ARGV="$TMP_ROOT/$1.argv" CURL_STDIN="$TMP_ROOT/$1.stdin"
    CURL_BODY="$(pool 1000 900)")
  LANES_BIN="${2:-}" run_lanes list --harness copilot --local --json
  ROW_ENV=()
}
curl_seen() { # NAME — what the shim was handed: stdin, then argv's two tests
  printf '%s|%s|%s' "$(cat "$TMP_ROOT/$1.stdin" 2>/dev/null)" \
    "$(grep -c 'api.github.com/copilot_internal/user' "$TMP_ROOT/$1.argv" 2>/dev/null || true)" \
    "$(grep -c gho_1copilot "$TMP_ROOT/$1.argv" 2>/dev/null || true)"
}
curl_row e2e
assert_eq "$(curl_seen e2e)|$(record 1copilot .monthly_pct)" \
  'header = "Authorization: token gho_1copilot"|1|0|10' \
  "the endpoint is asked with the stored login in curl's config, never in argv, and its answer is the pool"

echo "=== discovery finds a Copilot account by its marker, its variable or its setting ==="
new_home discover
copilot_account 1copilot "$(pool 100 50)"
mkdir -p "$H/.copilot-backup" "$TMP_ROOT/elsewhere" "$TMP_ROOT/named"
printf '{}\n' > "$TMP_ROOT/named/config.json"
names() { jq -r '[.[] | .alias] | sort | join(",")' <<<"$OUT" 2>/dev/null || echo unparseable; }
run_lanes list --harness copilot --local --json
assert_eq "$(names)" 1copilot "a directory with no marker is no account"
# A Pi root named for the Copilot pool it spends holds Pi's settings.json and
# auth.json and no Copilot marker: it is no Copilot account, and a Pi pick on
# the pool stated for it returns it.
mkdir -p "$H/.pi-copilot" "$H/.3copilot/session-state"
printf '{"compaction":{"enabled":false}}\n' > "$H/.pi-copilot/settings.json"
printf '{}\n' > "$H/.pi-copilot/auth.json"
run_lanes list --harness copilot --local --json
assert_eq "$(names)" 1copilot,3copilot "a Pi root named for the pool is not listed, and a session-state directory marks a Copilot account"
ROW_ENV=("ORCH_LANE_COPILOT_POOL=$H/.pi-copilot=10/100")
run_lanes pick --harness pi --model github-copilot/gpt-5 --json
ROW_ENV=()
assert_eq "rc=$RC dir=$(jq -r '.config_dir' <<<"$OUT" 2>/dev/null || echo unparseable)" "rc=0 dir=$H/.pi-copilot" \
  "a Pi pick returns the Pi root named for the pool it spends"
CTL_MARK="$(mutant_scripts ctl-mark lanes)" || exit 1
mutate_file "$CTL_MARK/lanes" '				copilot) markers=(config.json session-state) ;;' '				copilot) markers=(settings.json config.json) ;;'
LANES_BIN="$CTL_MARK/lanes" run_lanes list --harness copilot --local --json
assert_eq "$(names)" 1copilot,pi-copilot "control: with settings.json as a marker the Pi root reads as a Copilot account"
rm -rf -- "${H:?}/.3copilot"
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
lanes_control ctl-unlimited-zero lib/copilot-credits.sh '    | (if $unlimited then 0' '    | (if $unlimited then null'
copilot_account 4copilot '{"quota_snapshots":{"premium_interactions":{"unlimited":true}}}'
run_lanes pick --lane "$H/.4copilot" --harness copilot --model claude-opus-5
assert_eq "rc=$RC" rc=5 "control: an unlimited seat read with no share is unmeasured for a named model"
lanes_control ctl-month-burn lib/lane-model.sh '   elif .binding_bucket == "monthly" then $burn_default * 5 / 720' '   elif false then 0'
copilot_account 1copilot "$(pool 1000000 900000)"
CLAIM_ON="$H/.1copilot" run_lanes pick --lane "$H/.1copilot" --harness copilot --json
assert_eq "$(jq -c '(.burn_pct_per_lane_hour * 144 | round)' <<<"$OUT" 2>/dev/null || echo unparseable)" 21 \
  "control: without the monthly arm a Copilot pool is charged the weekly burn"
lanes_control ctl-pi-copilot lanes '			case "$copilot_ids" in *$'"'"'\n'"'"'"$id"$'"'"'\n'"'"'*) continue ;; esac' ':'
ROW_ENV=("ORCH_LANE_COPILOT_POOL=$H/.1copilot=5/100,$H/.pi1=10/100")
run_lanes pick --harness pi --model github-copilot/gpt-5 --json
ROW_ENV=()
assert_eq "$(jq -r '.config_dir' <<<"$OUT" 2>/dev/null || echo unparseable)" "$H/.1copilot" \
  "control: without the exclusion a Pi pick returns the Copilot account"
lanes_control ctl-discover lanes '				copilot) markers=(config.json session-state) ;;' ''
run_lanes list --harness copilot --local --json
assert_eq "$(jq 'length' <<<"$OUT" 2>/dev/null || echo unparseable)" 0 "control: without its markers no Copilot account is discovered"
lanes_control ctl-ambiguous lib/copilot-credits.sh '            elif ($v | length) > 1 then "token-ambiguous"' '            elif ($v | length) > 1 then "token\t" + $v[0]'
printf '{"copilot_tokens":{"https://github.com:a":"x","https://github.com:b":"y"}}\n' > "$H/.2copilot/config.json"
control_row 2copilot .status '"ok"' "control: without the ambiguity refusal one of two logins is guessed and measured"
lanes_control ctl-host lib/copilot-credits.sh 'select(.key | startswith("https://github.com:"))' 'select(true)'
printf '{"copilot_tokens":{"https://acme.ghe.com:a":"ghu_tenant"}}\n' > "$H/.2copilot/config.json"
control_row 2copilot .status '"ok"' "control: without the host test a tenant's token is sent to GitHub.com"
lanes_control ctl-comment lib/copilot-credits.sh "sed '/^[[:space:]]*\/\//d' \"\$config\"" "cat \"\$config\""
printf '// This file is managed automatically\n{"copilot_tokens":"gho_c"}\n' > "$H/.2copilot/config.json"
control_row 2copilot .status '"no_credentials"' "control: without the comment skip the CLI's own config.json is unreadable"
lanes_control ctl-fallback lanes '			measure_copilot_pool "$alias" copilot "$dir" "copilot login unread: $COPILOT_CREDITS_REASON in $dir/config.json"' '			emit_lane "$alias" copilot "$dir" no_credentials "" "" "{}"'
rm -f -- "${H:?}/.2copilot/config.json"
mkdir -p "$H/.2copilot/session-state"
ROW_ENV=(ORCH_LANE_COPILOT_POOL="$H/.2copilot=250/1000")
control_row 2copilot .measured_through '"local"' "control: without the fallback an account with no login ignores its stated reading"
ROW_ENV=()
# The two request rules, each cut from a private copy: the Copilot arm of the
# fetch, and the login taken whole rather than past its tag.
CTL_FETCH="$(mutant_scripts ctl-fetch lanes)" || exit 1
mutate_file "$CTL_FETCH/lanes" '	elif [[ "$harness" == "copilot" ]]; then' '	elif false; then'
curl_row ctl-fetch "$CTL_FETCH/lanes"
assert_eq "$(curl_seen ctl-fetch)" 'header = "Authorization: Bearer gho_1copilot"|0|0' \
  "control: without the Copilot arm the login goes to another endpoint as a Bearer token"
CTL_TOKEN="$(mutant_scripts ctl-token lib/copilot-credits.sh)" || exit 1
mutate_file "$CTL_TOKEN/lib/copilot-credits.sh" 'COPILOT_CREDITS_TOKEN="${answer#token	}"' 'COPILOT_CREDITS_TOKEN="$answer"'
curl_row ctl-token "$CTL_TOKEN/lanes"
assert_eq "$(curl_seen ctl-token | cut -d'|' -f1)" "$(printf 'header = "Authorization: token token\tgho_1copilot"')" \
  "control: without the tag stripped the login is sent with it"

echo "=== two spaced samples of a Copilot pool expose its rate ==="
# The same reset on both, the used share rising 20 points over ten minutes:
# the monthly bucket's prior is compared as the others' are, 2 points a minute.
new_home rate
RATE_STATE="$TMP_ROOT/rate-state"
copilot_account 1copilot "$(pool 1000 800)"
ROW_ENV=(OVERSEE_WATCH_STATE_DIR="$RATE_STATE")
run_lanes list --harness copilot --local --json --no-cache
for f in "$RATE_STATE"/usage/*.json; do
  jq --argjson at "$(( $(date +%s) - 600 ))" '.fetched_at = $at' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
done
printf '%s\n' "$(pool 1000 600)" > "$FIXTURE_DIR/.1copilot.json"
run_lanes list --harness copilot --local --json --no-cache
rate_row() { # [LANES] — the rate fields of the 1copilot record, read from the cache
  LANES_BIN="${1:-}" run_lanes list --harness copilot --local --json
  record 1copilot '[.binding_bucket, .usage_rate_state, (.usage_rate_pct_per_min | if . == null then null else round end)]'
}
assert_eq "$(rate_row)" '["monthly","measured",2]' "a Copilot pool measured twice ten minutes apart reads a two-point rate"
CTL_RATE="$(mutant_scripts ctl-rate lib/lane-model.sh)" || exit 1
mutate_file "$CTL_RATE/lib/lane-model.sh" '                  elif $binding.bucket == "monthly" then ._rate_prior.monthly_pct else null end),' '                  else null end),'
assert_eq "$(rate_row "$CTL_RATE/lanes")" '["monthly","one-sample",null]' \
  "control: without the monthly prior every Copilot pool reads one sample"
ROW_ENV=()
LANES_BIN=""

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
