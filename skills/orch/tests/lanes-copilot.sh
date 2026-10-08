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
    '{copilot_plan: "business", quota_reset_date_utc: "2099-10-01",
      quota_snapshots: {premium_interactions: ({entitlement: $e, remaining: $r, credits_used: ($e - $r),
        overage_permitted: true, overage_count: 0, unlimited: false, token_based_billing: true,
        percent_remaining: 99} + $x)}}'
}
record() { # ALIAS JQ — one field of that account's listed record
  jq -c --arg a "$1" ".[] | select(.alias == \$a) | $2" <<<"$OUT" 2>/dev/null || echo unparseable
}

echo "=== the monthly pool is read from the endpoint's counts ==="
new_home pool
# The endpoint's own credits_used differs from the pool github.com shows.
copilot_account 1copilot "$(pool 1000000 900000 '{"credits_used":318085}')"
copilot_account 2copilot "$(pool 1000000 0)"
copilot_account 3copilot "$(pool 1000000 1)"
# Equal resets keep the chooser row focused on unlimited room, not its bonus.
copilot_account 4copilot '{"quota_reset_date_utc":"2099-10-01","quota_snapshots":{"premium_interactions":{"unlimited":true}}}'
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
a pool with room binds the monthly bucket, used share from remaining over entitlement|1copilot|[.status, .monthly_pct, .headroom_pct, .binding_bucket, .binding_resets_at]|["ok",10,90,"monthly","2099-10-01T00:00:00Z"]
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
# key is the first keyed stderr line, its fields comma-joined, or none.
pick_key() {
  local key
  key="$(awk '$1 == "lanes:" { $1 = ""; sub(/^ +/, ""); gsub(/ +/, ","); print; exit }' <<<"$ERR")"
  printf '%s\n' "${key:-none}"
}
while IFS='|' read -r label args want; do
  eval "set -- $args"
  run_lanes "$@"
  assert_eq "rc=$RC out=$(head -n 1 <<<"$OUT") key=$(pick_key)" "$want" "$label"
done <<ROWS
the unlimited seat is picked over one with less room, handed back under COPILOT_HOME|pick --harness copilot --exclude-lane $H/.10copilot|rc=0 out=COPILOT_HOME=$H/.4copilot key=none
a named account at zero is walled even under a bound of 100, its line naming no Codex credits|pick --lane $H/.2copilot --harness copilot --max-pct 100|rc=3 out= key=pick-lane-walled,lane=$H/.2copilot,wall=100,bucket=monthly,max-pct=100,projected-headroom=0
a named unlimited seat is room for any model|pick --lane $H/.4copilot --harness copilot --model claude-opus-5 --binding-floor|rc=0 out=COPILOT_HOME=$H/.4copilot key=none
a named account with room clears the default bound|pick --lane $H/.1copilot --harness copilot --model claude-opus-5|rc=0 out=COPILOT_HOME=$H/.1copilot key=none
a named account whose answer measured nothing is unmeasured|pick --lane $H/.5copilot --harness copilot|rc=5 out= key=pick-lane-unmeasured,lane=$H/.5copilot,model=none
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
  if [[ "$want_status" == no_credentials ]]; then
    run_lanes pick --lane "$H/.1copilot" --harness copilot --json
    assert_eq "rc=$RC $(grep -o 'status=[^ ]*' <<<"$ERR") reason=$(grep -o 'login unread: [a-z-]*' <<<"$ERR" | sort -u)" \
      "rc=5 status=no_credentials reason=$want_reason" "the named refusal carries the login record's status and detail"
    assert_eq "$(grep -c '^fix=.*ORCH_LANE_COPILOT_POOL=<dir>=<used>/<granted>.*harness=copilot.*monthly-pct' <<<"$ERR")" 1 \
      "the Copilot CLI refusal names both pool-reading repairs"
  fi
done <<'ROWS'
a login as a bare string reads|{"copilot_tokens":"gho_bare"}|ok|none
the login under the key Copilot CLI 1.0.90 writes reads|{"copilotTokens":{"https://github.com:user":"gho_cur"}}|ok|none
the current key is read ahead of the 1.0.88 one|{"copilotTokens":{"https://github.com:a":"x","https://github.com:b":"y"},"copilot_tokens":"gho_old"}|no_credentials|login unread: token-ambiguous
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
# An account a Copilot CLI 1.0.90 session runs on, its login as that CLI writes
# it, is measured by `list` and named by `pick --lane`; with the reader held to
# the 1.0.88 key it reads no_credentials and the pick refuses it unmeasured.
printf '// This file is managed automatically\n{"copilotTokens":{"https://github.com:user":"gho_cur"}}\n' > "$H/.1copilot/config.json"
CTL_KEY="$(mutant_scripts ctl-login-key lib/copilot-credits.sh)" || exit 1
mutate_file "$CTL_KEY/lib/copilot-credits.sh" '(.copilotTokens // .copilot_tokens) as $t' '.copilot_tokens as $t'
for bin in "" "$CTL_KEY/lanes"; do
  LANES_BIN="$bin" run_lanes list --harness copilot --local --json
  listed="$(record 1copilot '[.status, .monthly_pct]')"
  LANES_BIN="$bin" run_lanes pick --lane "$H/.1copilot" --harness copilot --json
  if [[ -z "$bin" ]]; then
    assert_eq "$listed|rc=$RC" '["ok",10]|rc=0' "the running session's account under the current login key is measured"
  else
    assert_eq "$listed|rc=$RC" '["no_credentials",null]|rc=5' "control: a reader of the 1.0.88 key alone leaves that account unmeasured"
  fi
done
rm -f -- "${H:?}/.1copilot/config.json"
ROW_ENV=(ORCH_LANE_COPILOT_POOL="$H/.1copilot=250/1000")
run_lanes pick --lane "$H/.1copilot" --harness copilot --json
ROW_ENV=()
assert_eq "$(jq -c '[.status, .measured_through, .monthly_pct, (.credits | del(.measured_at))]' <<<"$OUT" 2>/dev/null || echo unparseable)" \
  '["ok","stated",25,{"unit":"AIC","unlimited":false,"used":250,"granted":1000,"remaining":750}]' \
  "an account whose login does not read takes its stated reading as the fallback"
# measure_copilot_pool refuses an override entry nothing can read, the named
# Copilot form's one guard for it; its control reads the entry as no reading.
ROW_ENV=(ORCH_LANE_COPILOT_POOL="$H/.1copilot=12.5/300")
run_lanes pick --lane "$H/.1copilot" --harness copilot
assert_eq "rc=$RC key=$(sed -n 1p <<<"$ERR" | cut -d' ' -f2)" "rc=1 key=invalid-copilot-pool" \
  "a named account whose login does not read refuses an override entry nothing can read"
CTL_MEASURE="$(mutant_scripts ctl-pool-measure lanes)" || exit 1
mutate_file "$CTL_MEASURE/lanes" '	entries="$(copilot_pool_entries)" || return 1' '	entries="$(copilot_pool_entries)"'
LANES_BIN="$CTL_MEASURE/lanes" run_lanes pick --lane "$H/.1copilot" --harness copilot
assert_eq "rc=$RC" "rc=5" "control: the named form ignoring the refusal reads an unreadable entry as no reading"
ROW_ENV=()

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

echo "=== a login config.json names and the Secret Service holds is read as Copilot CLI reads it ==="
# Copilot CLI 1.0.91 keeps a keyring login's token in the Secret Service item
# service=copilot-cli username=<host>:<login>:github, or the older
# <host>:<login>, and config.json then names the login in lastLoggedInUser.
# The stub secret-tool answers `search` in the layout libsecret's
# tool/secret-tool.c prints, per KR_MODE, with the error lines it and
# gnome-keyring print, and records its argv and any line it could read on
# stdin; the token rides through the curl shim to the endpoint. The timeout
# wrapper records the bound it was handed, then runs the real timeout.
KR_BIN="$TMP_ROOT/keyring-bin" KR_TBIN="$TMP_ROOT/keyring-timeout"
REAL_TIMEOUT="$(command -v timeout)" || { echo "lanes-copilot: timeout=not-on-path" >&2; exit 1; }
mkdir -p "$KR_BIN" "$KR_TBIN"
cat > "$KR_BIN/secret-tool" <<'KREOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$KR_LOG"
if IFS= read -r line; then printf 'stdin=%s\n' "$line" >> "$KR_LOG"; fi
item() { # USER [SECRET] — one search match; no SECRET is a withheld secret
  printf '[/org/freedesktop/secrets/collection/login/7]\nlabel = keyring:%s@copilot-cli\n' "$1"
  [[ $# -lt 2 ]] || printf 'secret = %s\n' "$2"
  printf 'created = 2026-10-01 00:00:00\nmodified = 2026-10-01 00:00:00\nschema = org.freedesktop.Secret.Generic\n'
  printf 'attribute.service = copilot-cli\nattribute.username = %s\n' "$1" >&2
}
case "$KR_MODE:$5" in
  github:*:github | legacy:https://github.com:probe) item "$5" "$KR_TOKEN" ;;
  locked:*:github) printf 'secret-tool: Cannot get secret of a locked object\n' >&2; item "$5" ;;
  refused:*:github) printf "secret-tool: Couldn't get item secret\n" >&2; item "$5" ;;
  blank:*:github) item "$5" "" ;;
  unreachable:*) printf 'secret-tool: Cannot autolaunch D-Bus without X11 $DISPLAY\n' >&2; exit 1 ;;
  hang:*) exec sleep 30 ;;
esac
exit 0
KREOF
cat > "$KR_TBIN/timeout" <<'KREOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$KR_LOG.bound"
# The hang row waits out a 1 second bound in place of the one lanes passes.
bound="$1"
[[ $KR_MODE != hang ]] || bound=1
exec "$REAL_TIMEOUT" "$bound" "${@:2}"
KREOF
chmod +x "$KR_BIN/secret-tool" "$KR_TBIN/timeout"
NOKR="$TMP_ROOT/no-secret-tool" NOTIMEOUT="$TMP_ROOT/no-timeout"
path_without "$NOKR" secret-tool
path_without "$NOTIMEOUT" timeout
assert_eq "$(env PATH="$NOKR" bash -c 'command -v secret-tool || echo none')|$(env PATH="$NOTIMEOUT" bash -c 'command -v timeout || echo none')" \
  "none|none" "the keyring-absent PATHs resolve no secret-tool and no timeout"
KR_PATH="$KR_BIN:$KR_TBIN:$SHIM:$PATH"
KR_TOKEN=gho_keyring_secret
KR_CONFIG='{"lastLoggedInUser":{"host":"https://github.com","login":"probe"},"loggedInUsers":[{"host":"https://github.com","login":"probe"}]}'
KR_USER=https://github.com:probe:github
KR_ASKED_GITHUB="search service copilot-cli username $KR_USER"
KR_ASKED_BOTH="$KR_ASKED_GITHUB,search service copilot-cli username https://github.com:probe"
KR_UNREAD="copilot login unread:"
# keyring_row NAME MODE CONFIG PATH [LANES] — `lanes list` on 1copilot with
# CONFIG as its config.json and the stub answering MODE; OUT, ERR, RC. The
# lane list collect_lanes reads is the stdin a search would inherit, so the
# 2copilot account after 1copilot is the line a search not reading /dev/null
# would take.
keyring_row() {
  new_home "kr-$1"
  mkdir -p "$H/.1copilot/session-state" "$H/.2copilot/session-state"
  printf '%s\n' "$3" > "$H/.1copilot/config.json"
  : > "$TMP_ROOT/kr-$1.log"
  ROW_ENV=(ORCH_LANES_FETCH_CMD= PATH="$4" KR_MODE="$2" KR_TOKEN="$KR_TOKEN" KR_LOG="$TMP_ROOT/kr-$1.log"
    REAL_TIMEOUT="$REAL_TIMEOUT" CURL_ARGV="$TMP_ROOT/kr-$1.argv" CURL_STDIN="$TMP_ROOT/kr-$1.stdin"
    CURL_BODY="$(pool 1000 900)")
  LANES_BIN="${5:-}" run_lanes list --harness copilot --local --json
  ROW_ENV=()
}
# `label|name|mode|config|PATH|want [status, pct]|want detail|want secret-tool argv|want curl stdin`;
# each search is wanted under the 5 second bound.
while IFS='|' read -r label name mode config path want detail asked header; do
  keyring_row "$name" "$mode" "$config" "$path"
  # The login's detail, less the clause measure_copilot_pool adds for no stated pool.
  got_detail="$(jq -r '.[] | select(.alias == "1copilot") | .detail // "none"' <<<"$OUT" 2>/dev/null || echo unparseable)"
  got_detail="${got_detail%%, and ORCH_LANE_COPILOT_POOL *}"
  got_asked="$(paste -sd, "$TMP_ROOT/kr-$name.log")"
  got_bound="$(paste -sd, "$TMP_ROOT/kr-$name.log.bound" 2>/dev/null)"
  want_bound=none
  [[ $asked == none ]] || want_bound="5 secret-tool ${asked//,/,5 secret-tool }"
  assert_eq "$(record 1copilot '[.status, .monthly_pct]')|${got_detail//"$H"/HOME}|${got_asked:-none}|${got_bound:-none}|$(cat "$TMP_ROOT/kr-$name.stdin" 2>/dev/null || echo none)" \
    "$want|$detail|$asked|$want_bound|$header" "$label"
  seen="$(cat "$TMP_ROOT/kr-$name.log" "$TMP_ROOT/kr-$name.log.bound" "$TMP_ROOT/kr-$name.argv" 2>/dev/null; printf '%s\n%s\n' "$OUT" "$ERR")"
  assert_eq "$(grep -c -F -- "$KR_TOKEN" <<<"$seen" || true)" 0 "$label: the keyring token reaches no argv and no lanes output"
done <<ROWS
the token under the :github username is the login|github|github|$KR_CONFIG|$KR_PATH|["ok",10]|none|$KR_ASKED_GITHUB|header = "Authorization: token $KR_TOKEN"
the older username is read where the :github one holds nothing|legacy|legacy|$KR_CONFIG|$KR_PATH|["ok",10]|none|$KR_ASKED_BOTH|header = "Authorization: token $KR_TOKEN"
no secret-tool on PATH is an absent Secret Service|absent|github|$KR_CONFIG|$NOKR|["no_credentials",null]|$KR_UNREAD keyring-absent in the Secret Service: no secret-tool on PATH|none|none
no timeout on PATH is an absent Secret Service, never an unbounded search|notimeout|github|$KR_CONFIG|$KR_BIN:$SHIM:$NOTIMEOUT|["no_credentials",null]|$KR_UNREAD keyring-absent in the Secret Service: no timeout on PATH|none|none
a Secret Service secret-tool cannot reach is absent, under secret-tool's error|unreachable|unreachable|$KR_CONFIG|$KR_PATH|["no_credentials",null]|$KR_UNREAD keyring-absent in the Secret Service: secret-tool search exited 1 for username=$KR_USER: secret-tool: Cannot autolaunch D-Bus without X11 \$DISPLAY|$KR_ASKED_GITHUB|none
a search that outlasts its bound names the bound|hang|hang|$KR_CONFIG|$KR_PATH|["no_credentials",null]|$KR_UNREAD keyring-absent in the Secret Service: secret-tool search outlasted 5s for username=$KR_USER|$KR_ASKED_GITHUB|none
a locked item is refused, never unlocked|locked|locked|$KR_CONFIG|$KR_PATH|["no_credentials",null]|$KR_UNREAD keyring-locked in the Secret Service item service=copilot-cli username=$KR_USER|$KR_ASKED_GITHUB|none
a secret withheld for another cause is refused under secret-tool's error, never locked|refused|refused|$KR_CONFIG|$KR_PATH|["no_credentials",null]|$KR_UNREAD keyring-refused in the Secret Service item service=copilot-cli username=$KR_USER: secret-tool: Couldn't get item secret|$KR_ASKED_GITHUB|none
no item under either username is an empty keyring|empty|none|$KR_CONFIG|$KR_PATH|["no_credentials",null]|$KR_UNREAD keyring-empty in the Secret Service items service=copilot-cli username=$KR_USER and https://github.com:probe|$KR_ASKED_BOTH|none
an item with an empty secret is no login|blank|blank|$KR_CONFIG|$KR_PATH|["no_credentials",null]|$KR_UNREAD keyring-empty in the Secret Service items service=copilot-cli username=$KR_USER and https://github.com:probe|$KR_ASKED_BOTH|none
a token in config.json is read and the keyring is not asked|config|github|{"copilotTokens":{"https://github.com:probe":"gho_cfg"},"lastLoggedInUser":{"host":"https://github.com","login":"probe"}}|$KR_PATH|["ok",10]|none|none|header = "Authorization: token gho_cfg"
a last login another host issued is never looked up for GitHub.com|tenant|github|{"lastLoggedInUser":{"host":"https://acme.ghe.com","login":"probe"}}|$KR_PATH|["no_credentials",null]|$KR_UNREAD token-missing in HOME/.1copilot/config.json|none|none
ROWS
CTL_KEYRING="$(mutant_scripts ctl-keyring lib/copilot-credits.sh)" || exit 1
mutate_file "$CTL_KEYRING/lib/copilot-credits.sh" '    "login	"?*) copilot_credits_keyring "${answer#login	}" ;;' \
  '    "login	"?*) COPILOT_CREDITS_REASON=token-missing; return 1 ;;'
keyring_row ctl-keyring github "$KR_CONFIG" "$KR_PATH" "$CTL_KEYRING/lanes"
assert_eq "$(record 1copilot '[.status, .monthly_pct]')" '["no_credentials",null]' \
  "control: without the keyring read a keyring login is never measured"

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
printf 'account=%s\tharness=copilot\tmonthly-pct=97\tmonthly-resets=2099-10-01T00:00:00Z\n' "$TMP_ROOT/hosted" \
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
copilot_account 1copilot "$(pool 1000000 900000 '{"credits_used":318085}')"
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
lanes_control ctl-used lib/copilot-credits.sh 'used: ($granted - $remaining),' 'used: (($q.credits_used | numbers) // null),'
control_row 1copilot .credits.used 318085 "control: used read from the endpoint's credits_used is not the pool the share is judged from"
lanes_control ctl-bind lanes '[{k: "monthly", p: $b.monthly_pct}, ' '['
control_row 2copilot .binding_bucket null "control: without the monthly bucket in the binding a Copilot pool binds nothing"
lanes_control ctl-walled-harness lanes 'if .harness == "codex" and .credits != null then' 'if .credits != null then'
run_lanes pick --lane "$H/.2copilot" --harness copilot --max-pct 100
assert_eq "rc=$RC key=$(pick_key)" "rc=3 key=pick-lane-walled,lane=$H/.2copilot,wall=100,bucket=monthly,max-pct=100,projected-headroom=0,credits=none,credit-floor=5000" \
  "control: without the harness test a walled Copilot account names a Codex balance of none"
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
lanes_control ctl-fallback lanes '			measure_copilot_pool "$alias" copilot "$dir" "copilot login unread: $COPILOT_CREDITS_REASON in $COPILOT_CREDITS_WHERE"' '			emit_lane "$alias" copilot "$dir" no_credentials "" "" "{}"'
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

echo "=== a Pi pick reads the Copilot pool from the provider's harness=pi row ==="
# The provider's accounts verb, the fixture lane host answering a file, carries
# a Pi root's pool as a harness=pi row. The row with a reading replaces the
# ORCH_LANE_COPILOT_POOL override for its root; one with none leaves the
# override standing; with neither the pick refuses with a fix= line naming the
# read that failed. `pi_row NAME PCT [STATUS]` writes one row for $H/.pi1.
new_home pihost
mkdir -p "$H/.pi1"
PI_MODEL=(--harness pi --model github-copilot/gpt-5)
pi_row() { # NAME PCT [STATUS]
  if [[ -n "$2" ]]; then
    printf 'account=%s\tharness=pi\tmonthly-pct=%s\tmonthly-resets=2099-10-07T00:00:00Z\n' "$H/.pi1" "$2"
  else
    printf 'account=%s\tharness=pi\tstatus=%s\tdetail=http-403-forbidden\n' "$H/.pi1" "$3"
  fi > "$TMP_ROOT/pi-$1.tsv"
}
pi_row room 40
pi_row walled 97
pi_row refused "" refused
: > "$TMP_ROOT/pi-none.tsv"
PI_HOST="ORCH_LANE_HOST=$TEST_DIR/fixtures/lane-host"
# pi_run ROWS SETTING ARGS... — `lanes` under the fixture host answering
# ROWS (`-` for no provider) and SETTING as ORCH_LANE_COPILOT_POOL (`-` for
# none, `cli=READING` to state it for the Copilot CLI home $H/.clicopilot
# alone), PI_STUB one more setting where set; OUT, RC, ERR.
PI_STUB=""
pi_run() {
  local rows="$1" setting="$2"
  shift 2
  ROW_ENV=()
  [[ "$rows" == - ]] || ROW_ENV+=("$PI_HOST" "LANE_HOST_STUB_LOG=$TMP_ROOT/pi-host.log" "LANE_HOST_STUB_ACCOUNTS=$TMP_ROOT/pi-$rows.tsv")
  [[ -z "$PI_STUB" ]] || ROW_ENV+=("$PI_STUB")
  case "$setting" in
    -) ;;
    cli=*) ROW_ENV+=("ORCH_LANE_COPILOT_POOL=$H/.clicopilot=${setting#cli=}") ;;
    *) ROW_ENV+=("ORCH_LANE_COPILOT_POOL=$H/.pi1=$setting") ;;
  esac
  run_lanes "$@"
  ROW_ENV=()
}
pi_fields() { # JQ — one compact reading of the printed record
  jq -c "$1" <<<"$OUT" 2>/dev/null || echo unparseable
}
fix_line() { # the fix= line on stderr, the host path shortened
  local line
  line="$(grep '^fix=' <<<"$ERR" | sed -n 1p)"
  printf '%s' "${line//$TEST_DIR\/fixtures\/lane-host/HOST}"
}
# pi_verdict — the exit, the key of the last keyed lanes: line, and the read
# the fix= line names: local, absent, answered, or row:STATUS:DETAIL for a
# provider row that read no pool, or none.
pi_verdict() {
  local key fix
  key="$(grep '^lanes: ' <<<"$ERR" | tail -n 1 | cut -d' ' -f2)"
  fix="$(sed -nE -e 's/^fix=[^:]*: ORCH_LANE_HOST=local asks no lane host,.*/local/p' \
    -e 's/^fix=[^:]*: lane host .* implements no accounts verb,.*/absent/p' \
    -e 's/^fix=[^:]*: the accounts verb of lane host .* carried no harness=pi row .*/answered/p' \
    -e 's/^fix=[^:]*: the accounts row of lane host .* read no pool, status=([^ ]*) detail=([^,]*),.*/row:\1:\2/p' <<<"$ERR" | paste -sd, -)"
  printf 'rc=%s key=%s fix=%s' "$RC" "${key:-none}" "${fix:-none}"
}
PI_READ='[.config_dir, .measured_through, .monthly_pct, .binding_bucket, .binding_resets_at]'
pi_run room - pick "${PI_MODEL[@]}" --json
assert_eq "rc=$RC $(pi_fields "$PI_READ")" "rc=0 [\"$H/.pi1\",\"host\",40,\"monthly\",\"2099-10-07T00:00:00Z\"]" \
  "a provider row alone is a candidate, with no hand-set number, its reset as binding_resets_at"
pi_run room 99/100 pick "${PI_MODEL[@]}" --json
assert_eq "rc=$RC $(pi_fields '[.measured_through, .monthly_pct]')" 'rc=0 ["host",40]' \
  "the provider's reading replaces a walled override for the same root"
pi_run walled 1/100 pick --lane "$H/.pi1" "${PI_MODEL[@]}" --json
assert_eq "rc=$RC $(pi_fields '[.measured_through, .wall, .binding_resets_at]')" 'rc=3 ["host",97,"2099-10-07T00:00:00Z"]' \
  "a walled provider row refuses the named form even where the override has room, dated by its reset"
pi_run refused 10/100 pick --lane "$H/.pi1" "${PI_MODEL[@]}" --json
assert_eq "rc=$RC $(pi_fields '[.measured_through, .monthly_pct]') local=$(grep -c '^lanes: pick-local-reading' <<<"$ERR")" 'rc=0 ["stated",10] local=0' \
  "a provider row with no reading leaves the override standing, never reported as a local reading"
pi_run refused - pick --lane "$H/.pi1" "${PI_MODEL[@]}" --json
assert_eq "rc=$RC $(pi_fields '[.status, .detail]')" 'rc=5 ["refused","http-403-forbidden"]' \
  "with no override the provider's refused row stands, carrying its detail"
pi_run none - pick "${PI_MODEL[@]}"
assert_eq "rc=$RC key=$(sed -n 1p <<<"$ERR" | cut -d' ' -f2)" "rc=5 key=copilot-pool-unstated" \
  "a provider naming no Pi root and no override is unstated"
assert_eq "$(fix_line)" "fix=no Copilot pool reading for any Pi root: the accounts verb of lane host HOST carried no harness=pi row with monthly-pct for it that ORCH_LANE_EXCLUDE and ORCH_LANE_RETIRE leave in, and ORCH_LANE_COPILOT_POOL states none; store the Copilot seat on that provider so its accounts row reads the pool (lanes host-accounts --harness pi --no-cache prints what it answers), take the root out of those two settings, or state the override ORCH_LANE_COPILOT_POOL=<Pi root>=<credits used>/<credits granted>" \
  "the unstated refusal under a provider names the accounts read and its repair"
pi_run - - pick "${PI_MODEL[@]}"
assert_eq "rc=$RC $(fix_line | cut -d: -f2 | cut -d, -f1)" "rc=5  ORCH_LANE_HOST=local asks no lane host" \
  "the unstated refusal with no provider names the host setting as the read that was not made"
# How the provider's accounts read ended, one row each: FORM is `auto` or
# `named`, STUB one LANE_HOST_STUB_ setting or `-`. A row that reads no pool
# and an absent verb are unstated, each fix= line naming that read; a failed or
# busy read is lanes failing, which a retry can answer, unless the override
# states the pool. An override naming only a Copilot CLI home states no Pi
# root, and a root ORCH_LANE_EXCLUDE drops is named as dropped.
copilot_account clicopilot '{"quota_snapshots":{}}'
while IFS='|' read -r label rows setting stub form want; do
  PI_STUB="${stub#-}"
  args=(pick "${PI_MODEL[@]}")
  [[ "$form" == auto ]] || args=(pick --lane "$H/.pi1" "${PI_MODEL[@]}")
  pi_run "$rows" "$setting" "${args[@]}"
  assert_eq "$(pi_verdict)" "$want" "$label"
done <<'ROWS'
a refused row with no override refuses auto as unstated, naming its status and detail|refused|-|-|auto|rc=5 key=copilot-pool-unstated fix=row:refused:http-403-forbidden
a refused row with no override refuses a named root, naming its status and detail|refused|-|-|named|rc=5 key=pick-lane-unmeasured fix=row:refused:http-403-forbidden
a failed accounts read with no override is lanes failing, never unstated|room|-|LANE_HOST_STUB_ACCOUNTS_STATUS=1|auto|rc=1 key=copilot-pool-unread fix=none
a failed accounts read fails a named root the same way|room|-|LANE_HOST_STUB_ACCOUNTS_STATUS=1|named|rc=1 key=copilot-pool-unread fix=none
a busy lane host is a failed read a retry can answer|room|-|LANE_HOST_STUB_ACCOUNTS_STATUS=69|auto|rc=1 key=copilot-pool-unread fix=none
a failed accounts read leaves a stated override to judge|room|10/100|LANE_HOST_STUB_ACCOUNTS_STATUS=1|auto|rc=0 key=host-accounts-unreadable fix=none
a provider with no accounts verb is unstated, the fix naming the absent verb|room|-|LANE_HOST_STUB_NO_ACCOUNTS=1|auto|rc=5 key=copilot-pool-unstated fix=absent
a named root on a provider with no accounts verb names the absent verb|room|-|LANE_HOST_STUB_NO_ACCOUNTS=1|named|rc=5 key=pick-lane-unmeasured fix=absent
a named root the provider has no row for names the accounts read|none|-|-|named|rc=5 key=pick-lane-unmeasured fix=answered
a named root with no provider names the host setting|-|-|-|named|rc=5 key=pick-lane-unmeasured fix=local
a malformed override refuses a named root even where the provider row reads the pool|room|garbage|-|named|rc=1 key=invalid-copilot-pool fix=none
a failed read beside an override naming only a Copilot CLI home is lanes failing|room|cli=10/100|LANE_HOST_STUB_ACCOUNTS_STATUS=1|auto|rc=1 key=copilot-pool-unread fix=none
no Pi row beside an override naming only a Copilot CLI home is unstated|none|cli=10/100|-|auto|rc=5 key=copilot-pool-unstated fix=answered
an absent verb beside an override naming only a Copilot CLI home is unstated|room|cli=10/100|LANE_HOST_STUB_NO_ACCOUNTS=1|auto|rc=5 key=copilot-pool-unstated fix=absent
a stated Pi root the exclusion drops is a pick with no candidate, never unstated|-|10/100|ORCH_LANE_EXCLUDE=pi1|auto|rc=3 key=no-candidate fix=none
ROWS
PI_STUB=""
# A Copilot CLI account gets its own pool repair, not the Pi root repair.
copilot_account nopoolcopilot '{"quota_snapshots":{}}'
run_lanes pick --lane "$H/.nopoolcopilot" --harness copilot
assert_eq "$(pi_verdict) $(grep -o 'status=[^ ]*' <<<"$ERR")" "rc=5 key=pick-lane-unmeasured fix=none status=no_usage_data" \
  "an unread Copilot endpoint prints the CLI account's current status"
pi_run room - list --json
assert_eq "$(pi_fields '[.[] | select(.harness == "pi")] | length')" 0 "list shows no Pi row"
pi_run room - host-accounts --json
assert_eq "$(pi_fields 'length')" 0 "host-accounts under all leaves the Pi row out"
pi_run room - host-accounts --harness pi --json
assert_eq "$(pi_fields '[.[] | [.harness, .monthly_pct]]')" '[["pi",40]]' "host-accounts --harness pi prints the Pi row"

echo "=== must-fail controls: the Pi pool read ==="
lanes_control ctl-pi-rows lanes '[[ "$harness" =~ ^(claude|codex|copilot|pi)$ ]]' '[[ "$harness" =~ ^(claude|codex|copilot)$ ]]'
pi_run room - pick "${PI_MODEL[@]}" --json
assert_eq "rc=$RC" rc=5 "control: without harness=pi admitted the provider row is dropped and the pick is unstated"
lanes_control ctl-pi-unstated lanes '[[ "$harness" == pi && -z "$pool_roots" && "$hosted" == "[]" ]]' '[[ "$harness" == pi && -z "$pool_roots" ]]'
pi_run room - pick "${PI_MODEL[@]}" --json
assert_eq "rc=$RC" rc=5 "control: an unstated check that skips the provider rows refuses a pool the provider read"
lanes_control ctl-pi-replace lib/lane-model.sh 'if $h == "pi" then (if .headroom_pct == null then "local" else "host" end)' 'if $h == "pi" then "local"'
pi_run room 99/100 pick "${PI_MODEL[@]}" --json
assert_eq "rc=$RC walled=$(pi_fields .walled)" 'rc=3 walled=1' \
  "control: an override that outranks the provider row walls a pool the provider read with room"
lanes_control ctl-pi-override lib/lane-model.sh 'if $h == "pi" then (if .headroom_pct == null then "local" else "host" end)' 'if $h == "pi" then (if .status == "unreachable" then "local" else "host" end)'
pi_run refused 10/100 pick --lane "$H/.pi1" "${PI_MODEL[@]}" --json
assert_eq "rc=$RC $(pi_fields '.measured_through')" 'rc=5 "host"' \
  "control: under the unreachable rule a refused Pi row hides the override"
lanes_control ctl-pi-all lanes '		[[ "$want:$harness" != all:pi || "$mode" == cache || "$mode" == buckets ]] || continue' ''
pi_run room - list --json
assert_eq "$(pi_fields '[.[] | select(.harness == "pi")] | length')" 1 "control: without the all filter list shows the Pi row"
lanes_control ctl-pi-fix lanes 'lane_copilot_pool_fix "${ORCH_LANE_HOST:-local}" "$HOSTED_READ"; } >&2' ':; } >&2'
pi_run none - pick "${PI_MODEL[@]}"
assert_eq "rc=$RC fix=$(fix_line)" "rc=5 fix=" "control: without the fix call the unstated refusal names no repair"
lanes_control ctl-pi-stated lib/lane-model.sh 'if [[ "$age" == stated ]]; then' 'if false; then'
pi_run refused 10/100 pick --lane "$H/.pi1" "${PI_MODEL[@]}" --json
assert_eq "rc=$RC local=$(grep -c '^lanes: pick-local-reading' <<<"$ERR")" "rc=0 local=1" \
  "control: without the stated arm a stated override is reported as a local reading the provider never made"
lanes_control ctl-pi-unread-rows lanes 'if [[ "$harness" == pi && "${walled:-0}" -eq 0 && "${unmeasured:-0}" -gt 0 ]]; then' 'if false; then'
pi_run refused - pick "${PI_MODEL[@]}"
assert_eq "$(pi_verdict)" "rc=3 key=no-candidate-unmeasured fix=none" \
  "control: without the unread-rows arm a refused row is a pick with no candidate and no repair"
lanes_control ctl-pi-row-fix lanes 'elif [[ "$through" == host ]]; then' 'elif false; then'
pi_run refused - pick --lane "$H/.pi1" "${PI_MODEL[@]}"
assert_eq "$(pi_verdict)" "rc=5 key=pick-lane-unmeasured fix=answered" \
  "control: without the row arm a refused row is reported as no row at all"
lanes_control ctl-pi-named-fix lanes '[[ "$harness" != pi && "$harness" != copilot ]] || copilot_pool_records_fix "[$record]" >&2 || return 1' ':'
pi_run none - pick --lane "$H/.pi1" "${PI_MODEL[@]}"
assert_eq "$(pi_verdict)" "rc=5 key=pick-lane-unmeasured fix=none" "control: without the named fix call a named root names no repair"
lanes_control ctl-cli-fix lib/lane-launch.sh '"$root" "${4:-none}" "${5:-none}" ;;' '"$root" none none ;;'
run_lanes pick --lane "$H/.nopoolcopilot" --harness copilot
assert_eq "rc=$RC $(grep -o 'status=[^ ]*' <<<"$ERR")" "rc=5 status=none" \
  "control: dropping the record fields loses the Copilot CLI refusal's status"
lanes_control ctl-pi-unread lanes 'if [[ "$harness" == pi && -z "$pool_roots" && "$HOSTED_READ" == failed ]]; then' 'if false; then'
PI_STUB=LANE_HOST_STUB_ACCOUNTS_STATUS=69 pi_run room - pick "${PI_MODEL[@]}"
assert_eq "rc=$RC" "rc=5" "control: without the failed-read arm a busy host is refused as unstated"
lanes_control ctl-pi-unread-named lanes 'if [[ "$harness" == pi && "$HOSTED_READ" == failed ]]; then' 'if false; then'
PI_STUB=LANE_HOST_STUB_ACCOUNTS_STATUS=1 pi_run room - pick --lane "$H/.pi1" "${PI_MODEL[@]}"
assert_eq "$(pi_verdict)" "rc=1 key=pick-lane-unmeasured fix=none" "control: without the named failed-read arm a failed read is refused as an unmeasured root"
lanes_control ctl-pi-absent lanes '		2) HOSTED_READ=absent; return 0 ;;' '		2) HOSTED_READ=answered; return 0 ;;'
PI_STUB=LANE_HOST_STUB_NO_ACCOUNTS=1 pi_run room - pick "${PI_MODEL[@]}"
assert_eq "$(pi_verdict)" "rc=5 key=copilot-pool-unstated fix=answered" "control: an absent verb read as an answer sends the operator to a row no verb can carry"
lanes_control ctl-pi-named-pool lanes '	if [[ "$harness" == pi ]]; then copilot_pool_entries >/dev/null || return 1; fi' ''
pi_run room garbage pick --lane "$H/.pi1" "${PI_MODEL[@]}"
assert_eq "rc=$RC" "rc=0" "control: without the named override check a malformed override is judged past on the provider row"
lanes_control ctl-pi-roots lanes '		pool_roots="$(lane_dirs pi all)"' '		pool_roots="$(copilot_pool_entries)"'
PI_STUB=LANE_HOST_STUB_ACCOUNTS_STATUS=1 pi_run room cli=10/100 pick "${PI_MODEL[@]}"
assert_eq "$(pi_verdict)" "rc=3 key=no-candidate fix=none" \
  "control: a guard counting every override entry reads a Copilot CLI home as a Pi root and refuses as no candidate"
# The Pi branch's own line, at its three-tab depth: the other harnesses' filter
# takes `all` too.
lanes_control ctl-pi-roots-all lanes $'\t\t\t[[ "${2:-}" != all ]] && lane_excluded "$d" || printf' $'\t\t\tlane_excluded "$d" || printf'
PI_STUB=ORCH_LANE_EXCLUDE=pi1 pi_run - 10/100 pick "${PI_MODEL[@]}"
assert_eq "$(pi_verdict)" "rc=5 key=copilot-pool-unstated fix=local" \
  "control: roots counted after the exclusion read an excluded stated root as no override"
PI_STUB=""
LANES_BIN=""

echo
# A signed-out Copilot home can still have a stated pool reading. Recovery
# keeps the failed home excluded instead of treating that reading as a login.
new_home login-recovery
mkdir -p "$H/.failedcopilot/session-state" "$H/.othercopilot/session-state" "$H/.pi/agent"
export ORCH_LANE_COPILOT_POOL="$H/.failedcopilot=0/100,$H/.othercopilot=10/100,$H/.pi/agent=20/100"
for scenario in same-harness other-harness no-successor; do
  args=(pick --harness copilot --model gpt-5-mini --exclude-lane "$H/.failedcopilot" --json)
  want="0|$H/.othercopilot"
  case "$scenario" in
    other-harness) args=(pick --harness pi --model copilot/gpt-5-mini --exclude-lane "$H/.failedcopilot" --json); want="0|$H/.pi/agent" ;;
    no-successor) ORCH_LANE_COPILOT_POOL="$H/.failedcopilot=0/100"; want='3|none' ;;
  esac
  run_lanes "${args[@]}"
  picked="$(jq -r '.config_dir // "none"' <<<"$OUT")"
  assert_eq "$RC|$picked" "$want" "$scenario login recovery excludes the failed home despite usage room"
done
unset ORCH_LANE_COPILOT_POOL

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
