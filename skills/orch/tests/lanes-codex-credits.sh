#!/usr/bin/env bash
# Tests for the credit tiers of the expires-first key. The Codex credit room
# rule: a Codex account at or past its plan windows stays pickable while its
# credit balance sits above ORCH_LANE_CODEX_CREDIT_FLOOR, ranked after every
# account with plan room, and the chooser, `pick --lane` and `list` give it one
# verdict. The Claude cloud credit on a claude-cloud host kind: above
# ORCH_LANE_CLOUD_CREDIT_FLOOR it ranks before every refilling window, the
# earliest expiry first, and a cloud-session pick keeps only the accounts
# ORCH_LANE_CLOUD_REPOS gives this checkout's repository. The kind's line is
# the real lane-host's; the network layer is the fetch stub
# lib/lanes-fixture.sh writes, so every row runs offline.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
unset ORCH_LANE_DIRS ORCH_LANE_ALIASES ORCH_LANE_EXCLUDE ORCH_LANE_RETIRE ORCH_LANES_USAGE_TTL CODEX_HOME
unset ORCH_LANE_MAX_PCT ORCH_LANE_BURN_PCT_PER_HOUR ORCH_LANE_CODEX_CREDIT_FLOOR ORCH_LANE_CLOUD_CREDIT_FLOOR ORCH_LANE_CLOUD_REPOS
unset ORCH_LANE_HOST ORCH_STATE_DIR
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LANES="$(cd "$TEST_DIR/.." && pwd)/scripts/lanes"

TMP_ROOT="$(mktemp -d)" || { echo "lanes-codex-credits: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "lanes-codex-credits: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "lanes-codex-credits: scratch=resolve-failed" >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT

# shellcheck source=lib/assertions.sh
source "$TEST_DIR/lib/assertions.sh"
# shellcheck source=lib/lanes-fixture.sh
source "$TEST_DIR/lib/lanes-fixture.sh"
# shellcheck source=lib/growth-state.sh
source "$TEST_DIR/lib/growth-state.sh"

FETCHER="$TMP_ROOT/fetch"
make_fetcher "$FETCHER"

# Runs start in a repository carrying no settings, so neither the checkout's
# kendex.settings.toml nor its fleet state reaches a row. Its origin is the
# github.com repository the cloud-session rows give or withhold.
NOSETTINGS="$TMP_ROOT/nosettings"; mkdir -p "$NOSETTINGS"
git -C "$NOSETTINGS" init -q -b main
git -C "$NOSETTINGS" config gc.auto 0
git -C "$NOSETTINGS" config maintenance.auto false
git -C "$NOSETTINGS" remote add origin git@github.com:Owner/Repo.git

# codex_body WEEKLY BALANCE HAS_CREDITS OVERAGE SPEND [RESET] — a Codex usage
# body, its 5-hour window at 20 and its weekly window at WEEKLY, resetting at
# epoch RESET (already past by default), carrying the credit reading the
# endpoint writes, the balance a string, or no credits object at all where
# BALANCE is `absent`, and its spend_control reading SPEND, or no
# spend_control at all where SPEND is `absent`.
codex_body() {
  jq -n --argjson w "$1" --arg b "$2" --argjson has "$3" --argjson over "$4" --arg spend "$5" \
    --argjson reset "${6:-1785400000}" '{
    rate_limit: {allowed: false,
      primary_window: {used_percent: 20, reset_at: 1785000000, limit_window_seconds: 18000},
      secondary_window: {used_percent: $w, reset_at: $reset, limit_window_seconds: 604800}}}
    + if $b == "absent" then {} else {credits: {has_credits: $has, unlimited: false,
        overage_limit_reached: $over, balance: $b,
        approx_local_messages: [10, 40], approx_cloud_messages: [2, 8]}} end
    + if $spend == "absent" then {} else {spend_control: {reached: ($spend | fromjson), individual_limit: null}} end'
}

# Accounts, `name:weekly:balance:has_credits:overage_limit_reached:spend[:reset]`.
# codex, 2codex and the floor pair are spent weekly windows on credits;
# 1codex and 8codex hold plan room, 8codex the more; scodex has reached its
# spend control and ncodex carries none; ucodex is spent and carries no credit
# reading. hcodex sits at --max-pct on credits with its reset past, so its
# score outranks pcodex, which holds plan room at 94 with its reset in 2100.
new_home credits
for spec in codex:100:62300:true:false:false 1codex:40:0:false:false:false 2codex:100:80000:true:false:false \
  3codex:100:5000:true:false:false 4codex:100:4999:true:false:false 5codex:100:90000:false:false:false \
  6codex:100:90000:true:true:false 7codex:100:lots:true:false:false 8codex:30:0:false:false:false \
  scodex:100:90000:true:false:true ncodex:100:90000:true:false:absent ucodex:100:absent:true:false:false \
  hcodex:95:62300:true:false:false pcodex:94:0:false:false:false:4102444800; do
  IFS=':' read -r name week balance has over spend reset <<<"$spec"
  make_codex_lane "$H/.$name"
  codex_body "$week" "$balance" "$has" "$over" "$spend" "$reset" > "$FIXTURE_DIR/.$name.json"
done

# cloud_body WEEKLY [CREDIT] — a Claude usage body, its 5-hour window at 10
# and its weekly window at WEEKLY, carrying the cloud credit CREDIT as
# `remaining:limit:resets_at[:locked_reason]`, or none where CREDIT is absent.
cloud_body() {
  local remaining="" limit="" resets="" locked=""
  [[ -z "${2:-}" ]] || IFS=':' read -r remaining limit resets locked <<<"$2"
  jq -n --argjson w "$1" --arg rem "$remaining" --arg lim "$limit" --arg at "$resets" --arg locked "$locked" '{
    five_hour: {utilization: 10, resets_at: "2099-07-27T06:00:00Z"},
    seven_day: {utilization: $w, resets_at: "2099-08-01T06:00:00Z"}}
    + if $rem == "" then {} else {iguana_necktie: {limit_dollars: ($lim | tonumber), remaining_dollars: ($rem | tonumber),
        used_dollars: (($lim | tonumber) - ($rem | tonumber)), resets_at: ($at | sub("_"; ":"; "g")),
        locked_reason: (if $locked == "" then null else $locked end)}} end'
}
# Claude accounts, `name|weekly|credit`. aclaude holds plan room and no
# credit; bclaude a spent week and a credit; cclaude and dclaude credits
# expiring in 2099-03 and 2099-06; eclaude a credit that expired in 2020;
# fclaude a credit of 5 dollars; lclaude a locked credit; uclaude a spent week
# and no credit reading at all, and mclaude one whose credit names no
# remaining_dollars.
for spec in "aclaude|10|" "gclaude|10|1:250:2099-09-01T00_00_00Z" "bclaude|100|241:250:2099-06-01T07_59_00Z" "cclaude|100|200:250:2099-03-01T00_00_00Z" \
  "dclaude|100|200:250:2099-06-01T00_00_00Z" "eclaude|10|241:250:2020-01-01T00_00_00Z" "fclaude|10|5:250:2099-06-01T00_00_00Z" \
  "lclaude|10|241:250:2099-06-01T00_00_00Z:overage" "uclaude|100|" "mclaude|100|241:250:2099-06-01T00_00_00Z"; do
  IFS='|' read -r name week credit <<<"$spec"
  make_lane "$H" "$name" 3600
  cloud_body "$week" "$credit" > "$FIXTURE_DIR/.$name.json"
done
jq 'del(.iguana_necktie.remaining_dollars)' "$FIXTURE_DIR/.mclaude.json" > "$FIXTURE_DIR/.mclaude.next"
mv -- "$FIXTURE_DIR/.mclaude.next" "$FIXTURE_DIR/.mclaude.json"
dirs() { local d out=""; for d in "$@"; do out="$out:$H/.$d"; done; printf 'ORCH_LANE_DIRS=%s' "${out#:}"; }
repos() { local d out=""; for d in "$@"; do out="$out,$d=owner/repo"; done; printf 'ORCH_LANE_CLOUD_REPOS=%s' "${out#,}"; }

# table ROW... — `label|env|args|expect`: env is `;`-separated `env`
# arguments. expect is `name=value` tokens: rc, key (the first keyed stderr
# line as `key,field=value,...`, or none), line.KEY (the fields of the first
# `lanes: KEY` line, comma-joined, or none), cr.LANE (the credit balance the
# table prints as LANE's headroom, or none), or a field of the JSON record.
RUN_SEQ=0
table() {
  local row label env args expect env_args got token name value
  for row in "$@"; do
    IFS='|' read -r label env args expect <<<"$row"
    [[ -n "$expect" ]] || { printf 'table: a row with no expect asserts nothing: %s\n' "$row" >&2; exit 1; }
    RUN="$TMP_ROOT/runs/$((++RUN_SEQ))"; mkdir -p "$RUN"
    env_args=()
    [[ -z "$env" ]] || IFS=';' read -ra env_args <<<"$env"
    # shellcheck disable=SC2086
    OUT=$(cd "$NOSETTINGS" && env GIT_CEILING_DIRECTORIES="$TMP_ROOT" LANES_HOME="$H" \
      ORCH_LANES_FETCH_CMD="$FETCHER" OVERSEE_WATCH_STATE_DIR="$RUN/store" ORCH_STATE_DIR="$RUN/fleet" \
      ${env_args[@]+"${env_args[@]}"} "${LANES_UNDER_TEST:-$LANES}" $args 2>"$RUN/err")
    RC=$?
    got=""
    for token in $expect; do
      name="${token%%=*}"
      case "$name" in
        rc) value="$RC" ;;
        key)
          value="$(awk '$1 == "lanes:" { $1 = ""; sub(/^ +/, ""); gsub(/ +/, ","); print; exit }' "$RUN/err")"
          value="${value:-none}"
          ;;
        line.*)
          value="$(awk -v k="${name#line.}" '$1 == "lanes:" && $2 == k { $1 = ""; $2 = ""; sub(/^ +/, ""); gsub(/ +/, ","); print; exit }' "$RUN/err")"
          value="${value:-none}"
          ;;
        cr.*)
          value="$(awk -v l="${name#cr.}" '$1 == l' <<<"$OUT" | grep -oE '[0-9.]+k? cr' | tr ' ' '_')"
          value="${value:-none}"
          ;;
        *) value="$(jq -r ".$name" <<<"$OUT" 2>/dev/null || echo UNPARSEABLE)" ;;
      esac
      got="$got $name=$value"
    done
    assert_eq "${got# }" "$expect" "$label" "$RUN/err"
  done
}

PICK='pick --harness codex --json'

echo "=== the chooser ranks credits after plan room ==="
table \
  "a credit-backed account ranks after an account with plan room, whatever their scores|$(dirs hcodex pcodex)|$PICK|rc=0 config_dir=$H/.pcodex binding_bucket=weekly" \
  "with no plan room anywhere, the credit-backed account is picked on its credits|$(dirs codex)|$PICK|rc=0 config_dir=$H/.codex binding_bucket=credits credits.balance=62300" \
  "among credit-backed accounts the larger balance is picked|$(dirs codex 2codex)|$PICK|rc=0 config_dir=$H/.2codex binding_bucket=credits" \
  "the plan-room order among accounts with plan room is unchanged|$(dirs codex 1codex 8codex)|$PICK|rc=0 config_dir=$H/.8codex binding_bucket=weekly"

# One live claim on hcodex, whose score still outranks codex at 100: its
# server is this suite's own process, which no tmux server enumerates, so the
# claim lives while the suite runs.
CLAIM_STORE="$TMP_ROOT/claim-store"; mkdir -p "$CLAIM_STORE/claims"
printf '%s\t%%1\t%s\tken-1\t2026-09-28T00:00:00Z\t\n' "$$" "$H/.hcodex" > "$CLAIM_STORE/claims/1.claim"
table \
  "among credit-backed accounts of one balance fewer claims are picked over a higher score|$(dirs codex hcodex);OVERSEE_WATCH_STATE_DIR=$CLAIM_STORE|$PICK|rc=0 config_dir=$H/.codex binding_bucket=credits claims=0"

echo "=== the floor and the reading's own flags ==="
table \
  "a balance at the floor is refused|$(dirs 3codex)|$PICK|rc=3 walled=1 unmeasured=0" \
  "a balance under the floor is refused|$(dirs 4codex)|$PICK|rc=3 walled=1 unmeasured=0" \
  "a spent account whose reading says it has no credits is refused|$(dirs 5codex)|$PICK|rc=3 walled=1" \
  "a spent account at its overage limit is refused|$(dirs 6codex)|$PICK|rc=3 walled=1" \
  "a balance that does not parse is no reading and is refused|$(dirs 7codex)|$PICK|rc=3 walled=1" \
  "a spent account whose spend control is reached is refused|$(dirs scodex)|$PICK|rc=3 walled=1" \
  "a spent account whose reading carries no spend control is refused|$(dirs ncodex)|$PICK|rc=3 walled=1" \
  "the floor setting is read: above the balance it refuses the account|$(dirs codex);ORCH_LANE_CODEX_CREDIT_FLOOR=70000|$PICK|rc=3 walled=1"

echo "=== pick --lane and list give the chooser's verdict ==="
table \
  "a named credit-backed account has room on its credits|$(dirs codex)|pick --lane $H/.codex --harness codex --json|rc=0 binding_bucket=credits credits.balance=62300 key=none" \
  "under --projected the named account is judged on the chooser's rule|$(dirs codex)|pick --lane $H/.codex --harness codex --projected --json|rc=0 binding_bucket=credits" \
  "a named account at the floor is refused, its line naming the balance and the floor|$(dirs 3codex)|pick --lane $H/.3codex --harness codex --json|rc=3 binding_bucket=weekly key=pick-lane-walled,lane=$H/.3codex,wall=100,bucket=weekly,max-pct=95,projected-headroom=0,credits=5000,credit-floor=5000" \
  "a named account whose balance did not parse names none|$(dirs 7codex)|pick --lane $H/.7codex --harness codex --json|rc=3 key=pick-lane-walled,lane=$H/.7codex,wall=100,bucket=weekly,max-pct=95,projected-headroom=0,credits=none,credit-floor=5000" \
  "a named account with no credit reading names no credit fields|$(dirs ucodex)|pick --lane $H/.ucodex --harness codex --json|rc=3 key=pick-lane-walled,lane=$H/.ucodex,wall=100,bucket=weekly,max-pct=95,projected-headroom=0" \
  "the listing record carries the credits bucket and the room verdict|$(dirs codex 3codex)|list --harness codex --json|rc=0 [0].alias=codex [0].verdict=room [0].binding_bucket=credits [0].credits.balance=62300 [0].headroom_pct=0 [1].alias=3codex [1].verdict=walled [1].binding_bucket=weekly" \
  "the listing gives the chooser's verdict and prints the balance as the account's room|$(dirs codex 1codex)|list --harness codex|rc=0 cr.codex=62.3k_cr cr.1codex=none"

echo "=== an account on its credits carries no plan-window wall forecast ==="
# Two readings a quarter-hour apart, at 99 and then 100 percent of the weekly
# window, measure a rate whose wall is now. oversee-succeed reads
# usage_rate_state and projected_wall_minutes off this record for its rate
# mark, so an account on its credits carries neither.
RATE_STORE="$TMP_ROOT/rate-store"
RATE_RESET="$(( $(date +%s) + 86400 ))"
rate_samples() { # LANES_SCRIPT
  rm -rf -- "${RATE_STORE:?}"
  local w
  for w in 99 100; do
    codex_body "$w" 62300 true false false "$RATE_RESET" \
      | jq --argjson reset "$RATE_RESET" '.rate_limit.primary_window.reset_at = $reset' > "$FIXTURE_DIR/.codex.json" || return 1
    (cd "$NOSETTINGS" && env GIT_CEILING_DIRECTORIES="$TMP_ROOT" LANES_HOME="$H" ORCH_LANES_FETCH_CMD="$FETCHER" \
      OVERSEE_WATCH_STATE_DIR="$RATE_STORE" ORCH_STATE_DIR="$TMP_ROOT/rate-fleet" "$(dirs codex)" \
      "$1" list --harness codex --json --no-cache >/dev/null) || return 1
    [[ "$w" == 100 ]] || age_usage_record "$RATE_STORE" "$H/.codex" 900
  done
  codex_body 100 62300 true false false "$RATE_RESET" \
    | jq --argjson reset "$RATE_RESET" '.rate_limit.primary_window.reset_at = $reset' > "$FIXTURE_DIR/.codex.json" || return 1
}
rate_samples "$LANES" || { echo "lanes-codex-credits: rate-samples=failed" >&2; exit 1; }
table \
  "a named account on its credits after 99 then 100 percent carries no rate and no wall minutes|$(dirs codex);OVERSEE_WATCH_STATE_DIR=$RATE_STORE|pick --lane $H/.codex --harness codex --json|rc=0 binding_bucket=credits usage_rate_state=credits projected_wall_minutes=null usage_rate_pct_per_min=null"

CLOUD="ORCH_LANE_HOST=claude-cloud"
CPICK='pick --harness claude --json'

echo "=== tier 0 spends the expiring Claude cloud credit first ==="
table \
  "on claude-cloud a credit outranks plan room, whatever its spent week reads|$CLOUD;$(dirs gclaude bclaude);$(repos gclaude bclaude)|$CPICK|rc=0 config_dir=$H/.bclaude credits.remaining_dollars=241" \
  "a named cloud credit has room despite its spent week|$CLOUD;$(dirs bclaude);$(repos bclaude)|pick --lane $H/.bclaude --harness claude --json|rc=0 credits.remaining_dollars=241" \
  "a named cloud credit has room under the launch projection|$CLOUD;$(dirs bclaude);$(repos bclaude)|pick --lane $H/.bclaude --harness claude --projected --json|rc=0 credits.remaining_dollars=241" \
  "a named credit on a local host keeps its walled plan verdict|$(dirs bclaude)|pick --lane $H/.bclaude --harness claude --json|rc=3" \
  "on a local kind the same pair is judged on plan windows alone|$(dirs gclaude bclaude)|$CPICK|rc=0 config_dir=$H/.gclaude" \
  "between two credits the earlier expiry is spent first|$CLOUD;$(dirs cclaude dclaude);$(repos cclaude dclaude)|$CPICK|rc=0 config_dir=$H/.cclaude" \
  "an ORCH_LANE_RETIRE date before the credit reset is the account's expiry|$CLOUD;$(dirs cclaude dclaude);$(repos cclaude dclaude);ORCH_LANE_RETIRE=dclaude=2099-01-01|$CPICK|rc=0 config_dir=$H/.dclaude"

echo "=== the floor, the lock, the expiry and an unread credit ==="
table \
  "a credit at the floor takes its walled plan verdict|$CLOUD;$(dirs fclaude);$(repos fclaude);ORCH_LANE_CLOUD_CREDIT_FLOOR=5|$CPICK|rc=3 walled=1" \
  "a named credit at the floor stays walled|$CLOUD;$(dirs fclaude);$(repos fclaude);ORCH_LANE_CLOUD_CREDIT_FLOOR=5|pick --lane $H/.fclaude --harness claude --json|rc=3" \
  "a named locked credit stays walled|$CLOUD;$(dirs lclaude);$(repos lclaude)|pick --lane $H/.lclaude --harness claude --json|rc=3" \
  "a named expired credit stays walled|$CLOUD;$(dirs eclaude);$(repos eclaude)|pick --lane $H/.eclaude --harness claude --json|rc=3" \
  "a credit above the floor is tier 0|$CLOUD;$(dirs fclaude);$(repos fclaude);ORCH_LANE_CLOUD_CREDIT_FLOOR=4|$CPICK|rc=0 config_dir=$H/.fclaude" \
  "a locked credit takes its walled plan verdict|$CLOUD;$(dirs lclaude);$(repos lclaude)|$CPICK|rc=3 walled=1" \
  "a credit past its expiry takes its walled plan verdict, named as no unread one|$CLOUD;$(dirs eclaude);$(repos eclaude)|$CPICK|rc=3 walled=1 line.cloud-credit-unread=none" \
  "a body without the credit is named and passed over|$CLOUD;$(dirs uclaude gclaude);$(repos uclaude gclaude)|$CPICK|rc=0 config_dir=$H/.gclaude line.cloud-credit-unread=account=uclaude" \
  "a credit with no remaining_dollars is named as unread|$CLOUD;$(dirs mclaude gclaude);$(repos mclaude gclaude)|$CPICK|rc=0 config_dir=$H/.gclaude line.cloud-credit-unread=account=mclaude" \
  "a floor nobody can read refuses the pick|$CLOUD;$(dirs bclaude);$(repos bclaude);ORCH_LANE_CLOUD_CREDIT_FLOOR=five|$CPICK|rc=1 line.invalid-lane-cloud-credit-floor=value=five"

echo "=== a cloud session reaches only a repository its account was given ==="
table \
  "an account with no entry for this checkout's repository is passed over|$CLOUD;$(dirs gclaude bclaude);$(repos gclaude)|$CPICK|rc=0 config_dir=$H/.gclaude" \
  "with no account given the repository the pick names each one|$CLOUD;$(dirs bclaude);ORCH_LANE_CLOUD_REPOS=bclaude=owner/other|$CPICK|rc=3 line.cloud-repo-unset=account=$H/.bclaude,repo=Owner/Repo" \
  "a named cloud account with no repository entry is refused|$CLOUD;$(dirs bclaude)|pick --lane $H/.bclaude --harness claude --json|rc=7 key=cloud-repo-unset,account=$H/.bclaude,repo=Owner/Repo" \
  "a named projected cloud account with an entry for another repository is refused|$CLOUD;$(dirs bclaude);ORCH_LANE_CLOUD_REPOS=bclaude=owner/other|pick --lane $H/.bclaude --harness claude --projected --json|rc=7 key=cloud-repo-unset,account=$H/.bclaude,repo=Owner/Repo" \
  "a named cloud account on plan room also needs repository access|$CLOUD;$(dirs gclaude)|pick --lane $H/.gclaude --harness claude --json|rc=7 key=cloud-repo-unset,account=$H/.gclaude,repo=Owner/Repo" \
  "a named listed cloud account with credit and plan room passes|$CLOUD;$(dirs gclaude);$(repos gclaude)|pick --lane $H/.gclaude --harness claude --json|rc=0 config_dir=$H/.gclaude" \
  "a named local account needs no cloud repository entry|$(dirs aclaude)|pick --lane $H/.aclaude --harness claude --json|rc=0 config_dir=$H/.aclaude" \
  "an entry nobody can read refuses the pick|$CLOUD;$(dirs bclaude);ORCH_LANE_CLOUD_REPOS=bclaude=owner|$CPICK|rc=1 line.invalid-cloud-repos=entry=bclaude=owner"

echo "=== controls ==="
# Without the tier the score alone orders the pair, and the credit-backed
# account's is the higher.
CTRL="$(mutant_scripts mutant-credit-rank lib/lane-model.sh)" || exit 1
mutate_file "$CTRL/lib/lane-model.sh" 'sort_by([._tier, ._expires, (._score | neg), .claims,' 'sort_by([(.selection_score | neg), .claims,'
LANES_UNDER_TEST="$CTRL/lanes" table \
  "control: without the tier the credit-backed account is picked over plan room|$(dirs hcodex pcodex)|$PICK|rc=0 config_dir=$H/.hcodex binding_bucket=credits"

# Without its claims key, the tier key hands a balance tie to projected room.
CTRL="$(mutant_scripts mutant-credit-claims lib/lane-model.sh)" || exit 1
mutate_file "$CTRL/lib/lane-model.sh" '(._score | neg), .claims, (.projected_headroom_pct | neg)' '(._score | neg), (.projected_headroom_pct | neg)'
LANES_UNDER_TEST="$CTRL/lanes" table \
  "control: without the claims key the claimed account's room wins the tie|$(dirs codex hcodex);OVERSEE_WATCH_STATE_DIR=$CLAIM_STORE|$PICK|rc=0 config_dir=$H/.hcodex claims=1"

# One control per rule credit_room holds.
CTRL="$(mutant_scripts mutant-credit-floor lib/lane-model.sh)" || exit 1
# shellcheck disable=SC2016  # the script's own text, never expanded here.
mutate_file "$CTRL/lib/lane-model.sh" '.credits.balance > $credit_floor' '.credits.balance >= $credit_floor'
LANES_UNDER_TEST="$CTRL/lanes" table "control: a floor met rather than passed admits the account|$(dirs 3codex)|$PICK|rc=0 binding_bucket=credits"
CTRL="$(mutant_scripts mutant-credit-has lib/lane-model.sh)" || exit 1
mutate_file "$CTRL/lib/lane-model.sh" '.credits.has_credits == true' 'true'
LANES_UNDER_TEST="$CTRL/lanes" table "control: unread has_credits admits the account|$(dirs 5codex)|$PICK|rc=0 binding_bucket=credits"
CTRL="$(mutant_scripts mutant-credit-overage lib/lane-model.sh)" || exit 1
mutate_file "$CTRL/lib/lane-model.sh" '.credits.overage_limit_reached == false' 'true'
LANES_UNDER_TEST="$CTRL/lanes" table "control: unread overage_limit_reached admits the account|$(dirs 6codex)|$PICK|rc=0 binding_bucket=credits"
CTRL="$(mutant_scripts mutant-credit-spend lib/lane-model.sh)" || exit 1
mutate_file "$CTRL/lib/lane-model.sh" '.credits.spend_control_reached == false' 'true'
LANES_UNDER_TEST="$CTRL/lanes" table "control: unread spend control admits the account|$(dirs scodex)|$PICK|rc=0 binding_bucket=credits"

# The credits verdict drops the spent window's forecast only through its own
# fields.
CTRL="$(mutant_scripts mutant-credit-forecast lib/lane-model.sh)" || exit 1
mutate_file "$CTRL/lib/lane-model.sh" 'binding_bucket: "credits", usage_rate_state: "credits",' 'binding_bucket: "credits",'
mutate_file "$CTRL/lib/lane-model.sh" 'usage_rate_pct_per_min: null, projected_wall_minutes: null}' '}'
LANES_UNDER_TEST="$CTRL/lanes" table \
  "control: a credits verdict that keeps the forecast hands oversee-succeed a measured rate walling now|$(dirs codex);OVERSEE_WATCH_STATE_DIR=$RATE_STORE|pick --lane $H/.codex --harness codex --json|rc=0 binding_bucket=credits usage_rate_state=measured projected_wall_minutes=0"

# The record's credits come from parse_codex_usage alone, spend control
# included.
CTRL="$(mutant_scripts mutant-credit-spend-parse lib/lane-usage.sh)" || exit 1
# shellcheck disable=SC2016  # the script's own text, never expanded here.
mutate_file "$CTRL/lib/lane-usage.sh" '. + {spend_control_reached: $spent}' '. + {spend_control_reached: false}'
LANES_UNDER_TEST="$CTRL/lanes" table "control: a spend control read as never reached admits the account|$(dirs scodex)|$PICK|rc=0 binding_bucket=credits"
CTRL="$(mutant_scripts mutant-credit-parse lib/lane-usage.sh)" || exit 1
# shellcheck disable=SC2016  # the script's own text, never expanded here.
mutate_file "$CTRL/lib/lane-usage.sh" 'credits:        $credits,' 'credits:        null,'
LANES_UNDER_TEST="$CTRL/lanes" table "control: a reading carrying no credits walls the lone account|$(dirs codex)|$PICK|rc=3 walled=1"

# The setting is read, not a constant.
CTRL="$(mutant_scripts mutant-credit-setting lanes)" || exit 1
# shellcheck disable=SC2016
mutate_file "$CTRL/lanes" 'CREDIT_FLOOR="${ORCH_LANE_CODEX_CREDIT_FLOOR:-5000}"' 'CREDIT_FLOOR=5000'
LANES_UNDER_TEST="$CTRL/lanes" table "control: a floor read from no setting admits the account the setting refuses|$(dirs codex);ORCH_LANE_CODEX_CREDIT_FLOOR=70000|$PICK|rc=0"

# The setting refusal rows in lanes-settings-refusal.sh, reached through the
# validation they hold.
CTRL="$(mutant_scripts mutant-credit-setting-shape lanes)" || exit 1
# shellcheck disable=SC2016
mutate_file "$CTRL/lanes" 'die invalid-lane-codex-credit-floor "$CREDIT_FLOOR"' 'CREDIT_FLOOR=0'
LANES_UNDER_TEST="$CTRL/lanes" table "control: a floor nobody can read falls back to a number and the pick goes ahead|$(dirs codex);ORCH_LANE_CODEX_CREDIT_FLOOR=many|$PICK|rc=0"

# The named refusal names a balance only for a Codex reading that carries one.
CTRL="$(mutant_scripts mutant-credit-walled-reading lanes)" || exit 1
mutate_file "$CTRL/lanes" 'if .harness == "codex" and .credits != null then' 'if .harness == "codex" then'
LANES_UNDER_TEST="$CTRL/lanes" table "control: without the reading test a lane with no credits names a balance of none|$(dirs ucodex)|pick --lane $H/.ucodex --harness codex --json|rc=3 key=pick-lane-walled,lane=$H/.ucodex,wall=100,bucket=weekly,max-pct=95,projected-headroom=0,credits=none,credit-floor=5000"

# The named refusal names the balance only through its own message arm.
CTRL="$(mutant_scripts mutant-credit-walled-line lanes)" || exit 1
# shellcheck disable=SC2016
mutate_file "$CTRL/lanes" '[[ -z "${6:-}" ]] || printf' '[[ -n "${6:-}" ]] || printf'
LANES_UNDER_TEST="$CTRL/lanes" table "control: without its credit fields the refusal names no balance|$(dirs 3codex)|pick --lane $H/.3codex --harness codex --json|rc=3 key=pick-lane-walled,lane=$H/.3codex,wall=100,bucket=weekly,max-pct=95,projected-headroom=0"

# The table prints the balance only through its credits arm.
CTRL="$(mutant_scripts mutant-credit-table lib/lane-context.sh)" || exit 1
mutate_file "$CTRL/lib/lane-context.sh" 'if .binding_bucket == "credits"' 'if false'
LANES_UNDER_TEST="$CTRL/lanes" table "control: without the credits arm the table prints no balance|$(dirs codex 1codex)|list --harness codex|rc=0 cr.codex=none cr.1codex=none"

# The Claude cloud credit's rules, one control each. A cloud-session pick
# reads the checkout's repository through the github skill, so its mutants
# carry that skill beside them.
cloud_mutant() { # NAME SCRIPT
  local dir
  dir="$(mutant_scripts "$1/orch" "$2")" || return 1
  ln -s "$(cd "$TEST_DIR/../.." && pwd)/github" "$TMP_ROOT/$1/github" || return 1
  printf '%s\n' "$dir"
}
# cloud_control NAME SCRIPT OLD NEW ROW — ROW's table run under the mutant.
cloud_control() {
  CTRL="$(cloud_mutant "$1" "$2")" || exit 1
  mutate_file "$CTRL/$2" "$3" "$4"
  LANES_UNDER_TEST="$CTRL/lanes" table "$5"
}
cloud_control mutant-tier-key lib/lane-model.sh 'sort_by([._tier, ._expires, (._score | neg), .claims,' 'sort_by([(.selection_score | neg), .claims,' \
  "control: without the tier key plan room outranks the credit|$CLOUD;$(dirs gclaude bclaude);$(repos gclaude bclaude)|$CPICK|rc=0 config_dir=$H/.gclaude"
# shellcheck disable=SC2016  # Keep the tier call as a jq comment in the mutant.
cloud_control mutant-named-cloud-tier lib/lane-model.sh '      | with_lane_tier($pool; $cloud_floor; $retire; $now)' '      # | with_lane_tier($pool; $cloud_floor; $retire; $now)' \
  "control: without the named tier call its cloud credit stays walled|$CLOUD;$(dirs bclaude);$(repos bclaude)|pick --lane $H/.bclaude --harness claude --json|rc=3 credits.remaining_dollars=241"
# shellcheck disable=SC2016  # the script's own text, never expanded here.
cloud_control mutant-cloud-floor lib/lane-model.sh 'and $c.remaining_dollars > $cloud_floor and' 'and' \
  "control: without the floor comparison a credit at the floor is picked|$CLOUD;$(dirs fclaude);$(repos fclaude);ORCH_LANE_CLOUD_CREDIT_FLOOR=5|$CPICK|rc=0 config_dir=$H/.fclaude"
# shellcheck disable=SC2016
cloud_control mutant-cloud-lock lib/lane-model.sh ' and $c.locked_reason == null' '' \
  "control: without the lock test a locked credit is picked|$CLOUD;$(dirs lclaude);$(repos lclaude)|$CPICK|rc=0 config_dir=$H/.lclaude"
# shellcheck disable=SC2016
cloud_control mutant-cloud-expiry lib/lane-model.sh ' and $e > $now' '' \
  "control: without the expiry test an expired credit is picked|$CLOUD;$(dirs eclaude);$(repos eclaude)|$CPICK|rc=0 config_dir=$H/.eclaude"
# shellcheck disable=SC2016
cloud_control mutant-cloud-pool lib/lane-model.sh 'if $pool == "cloud-credit" and $read' 'if $read' \
  "control: without the pool test a local kind spends the credit first|$(dirs gclaude bclaude)|$CPICK|rc=0 config_dir=$H/.bclaude"
cloud_control mutant-cloud-repo lib/lane-model.sh 'else . + {verdict: "cloud-repo-unset"} end;' 'else . end;' \
  "control: without cloud-repo-unset an account with no entry is picked|$CLOUD;$(dirs gclaude bclaude);$(repos gclaude)|$CPICK|rc=0 config_dir=$H/.bclaude"
# shellcheck disable=SC2016  # Keep the named eligibility call as a jq comment.
cloud_control mutant-named-cloud-repo lib/lane-model.sh '      | with_lane_cloud_repo($cloud_repo)' '      # | with_lane_cloud_repo($cloud_repo)' \
  "control: without the named repository check an unlisted cloud account passes|$CLOUD;$(dirs bclaude)|pick --lane $H/.bclaude --harness claude --json|rc=0 config_dir=$H/.bclaude"
cloud_control mutant-named-cloud-repo-status lanes 'return 7' 'return 1' \
  "control: a repository refusal with the wrong status looks like a failed judge|$CLOUD;$(dirs bclaude)|pick --lane $H/.bclaude --harness claude --json|rc=1 key=cloud-repo-unset,account=$H/.bclaude,repo=Owner/Repo"
# shellcheck disable=SC2016
cloud_control mutant-cloud-unread lanes 'message cloud-credit-unread "$dir" >&2' ':' \
  "control: without its note a body with no credit drops it silently|$CLOUD;$(dirs uclaude gclaude);$(repos uclaude gclaude)|$CPICK|rc=0 config_dir=$H/.gclaude line.cloud-credit-unread=none"
# shellcheck disable=SC2016
cloud_control mutant-cloud-partial lib/lane-model.sh '($read | not)' '(.credits == null)' \
  "control: read as unread only when absent, a credit with no remaining_dollars is passed over and gclaude named first|$CLOUD;$(dirs mclaude gclaude);$(repos mclaude gclaude)|$CPICK|rc=0 config_dir=$H/.gclaude line.cloud-credit-unread=none"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
