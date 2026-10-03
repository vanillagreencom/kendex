#!/usr/bin/env bash
# Tests for the expires-first tier key of `lanes pick` on a claude-cloud host
# kind: a Claude cloud credit above ORCH_LANE_CLOUD_CREDIT_FLOOR ranks before
# every refilling window, the earliest expiry first, and a cloud-session pick
# keeps only the accounts ORCH_LANE_CLOUD_REPOS gives this checkout's
# repository. The kind's line is the real lane-host's; the network layer is the
# fetch stub lib/lanes-fixture.sh writes, so every row runs offline.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
unset ORCH_LANE_DIRS ORCH_LANE_ALIASES ORCH_LANE_EXCLUDE ORCH_LANE_RETIRE ORCH_LANES_USAGE_TTL CODEX_HOME
unset ORCH_LANE_MAX_PCT ORCH_LANE_BURN_PCT_PER_HOUR ORCH_LANE_CLOUD_CREDIT_FLOOR ORCH_LANE_CLOUD_REPOS ORCH_LANE_HOST ORCH_STATE_DIR
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LANES="$(cd "$TEST_DIR/.." && pwd)/scripts/lanes"

TMP_ROOT="$(mktemp -d)" || { echo "lanes-cloud-credit: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "lanes-cloud-credit: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "lanes-cloud-credit: scratch=resolve-failed" >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT

# shellcheck source=lib/assertions.sh
source "$TEST_DIR/lib/assertions.sh"
# shellcheck source=lib/lanes-fixture.sh
source "$TEST_DIR/lib/lanes-fixture.sh"
# shellcheck source=lib/growth-state.sh
source "$TEST_DIR/lib/growth-state.sh"

FETCHER="$TMP_ROOT/fetch"
make_fetcher "$FETCHER"

# A checkout carrying no settings, whose origin is the github.com repository
# the cloud-session rows give or withhold.
NOSETTINGS="$TMP_ROOT/nosettings"; mkdir -p "$NOSETTINGS"
git -C "$NOSETTINGS" init -q -b main
git -C "$NOSETTINGS" config gc.auto 0
git -C "$NOSETTINGS" config maintenance.auto false
git -C "$NOSETTINGS" remote add origin git@github.com:Owner/Repo.git

# cloud_body WEEKLY [CREDIT] — a Claude usage body, its 5-hour window at 10
# and its weekly window at WEEKLY, carrying the cloud credit CREDIT as
# `remaining:limit:resets_at[:locked_reason]`, or none where CREDIT is absent.
cloud_body() {
  local remaining="" limit="" resets="" locked=""
  [[ -z "${2:-}" ]] || IFS=':' read -r remaining limit resets locked <<<"$2"
  jq -n --argjson w "$1" --arg rem "$remaining" --arg lim "$limit" --arg at "$resets" --arg locked "$locked" '{
    five_hour: {utilization: 10, resets_at: "2026-07-27T06:00:00Z"},
    seven_day: {utilization: $w, resets_at: "2026-08-01T06:00:00Z"}}
    + if $rem == "" then {} else {iguana_necktie: {limit_dollars: ($lim | tonumber), remaining_dollars: ($rem | tonumber),
        used_dollars: (($lim | tonumber) - ($rem | tonumber)), resets_at: ($at | sub("_"; ":"; "g")),
        locked_reason: (if $locked == "" then null else $locked end)}} end'
}

# Accounts, `name|weekly|credit`. aclaude holds plan room and no credit;
# bclaude a spent week and a credit; cclaude and dclaude credits expiring in
# 2099-03 and 2099-06; fclaude a credit of 5 dollars; lclaude a locked credit;
# uclaude a spent week and no credit reading at all.
new_home cloud
for spec in "aclaude|10|" "bclaude|100|241:250:2099-06-01T07_59_00Z" "cclaude|100|200:250:2099-03-01T00_00_00Z" \
  "dclaude|100|200:250:2099-06-01T00_00_00Z" "fclaude|100|5:250:2099-06-01T00_00_00Z" \
  "lclaude|100|241:250:2099-06-01T00_00_00Z:overage" "uclaude|100|"; do
  IFS='|' read -r name week credit <<<"$spec"
  make_lane "$H" "$name" 3600
  cloud_body "$week" "$credit" > "$FIXTURE_DIR/.$name.json"
done
dirs() { local d out=""; for d in "$@"; do out="$out:$H/.$d"; done; printf 'ORCH_LANE_DIRS=%s' "${out#:}"; }
repos() { local d out=""; for d in "$@"; do out="$out,$d=owner/repo"; done; printf 'ORCH_LANE_CLOUD_REPOS=%s' "${out#,}"; }

# table ROW... — `label|env|expect`: env is `;`-separated `env` arguments.
# expect is `name=value` tokens: rc, a field of the picked JSON record, or
# line.KEY, the fields of the first `lanes: KEY` line on stderr, comma-joined,
# or none.
RUN_SEQ=0
table() {
  local row label env expect env_args got token name value
  for row in "$@"; do
    IFS='|' read -r label env expect <<<"$row"
    [[ -n "$expect" ]] || { printf 'table: a row with no expect asserts nothing: %s\n' "$row" >&2; exit 1; }
    RUN="$TMP_ROOT/runs/$((++RUN_SEQ))"; mkdir -p "$RUN"
    env_args=()
    [[ -z "$env" ]] || IFS=';' read -ra env_args <<<"$env"
    OUT=$(cd "$NOSETTINGS" && env GIT_CEILING_DIRECTORIES="$TMP_ROOT" LANES_HOME="$H" \
      ORCH_LANES_FETCH_CMD="$FETCHER" OVERSEE_WATCH_STATE_DIR="$RUN/store" ORCH_STATE_DIR="$RUN/fleet" \
      ${env_args[@]+"${env_args[@]}"} "${LANES_UNDER_TEST:-$LANES}" pick --harness claude --json 2>"$RUN/err")
    RC=$?
    got=""
    for token in $expect; do
      name="${token%%=*}"
      case "$name" in
        rc) value="$RC" ;;
        line.*)
          value="$(awk -v k="${name#line.}" '$1 == "lanes:" && $2 == k { $1 = ""; $2 = ""; sub(/^ +/, ""); gsub(/ +/, ","); print; exit }' "$RUN/err")"
          value="${value:-none}"
          ;;
        *) value="$(jq -r ".$name" <<<"$OUT" 2>/dev/null || echo UNPARSEABLE)" ;;
      esac
      got="$got $name=$value"
    done
    assert_eq "${got# }" "$expect" "$label" "$RUN/err"
  done
}

CLOUD="ORCH_LANE_HOST=claude-cloud"

echo "=== tier 0 spends the expiring credit first ==="
table \
  "on claude-cloud a credit outranks plan room, whatever its spent week reads|$CLOUD;$(dirs aclaude bclaude);$(repos aclaude bclaude)|rc=0 config_dir=$H/.bclaude credits.remaining_dollars=241" \
  "on a local kind the same pair is judged on plan windows alone|$(dirs aclaude bclaude)|rc=0 config_dir=$H/.aclaude" \
  "between two credits the earlier expiry is spent first|$CLOUD;$(dirs cclaude dclaude);$(repos cclaude dclaude)|rc=0 config_dir=$H/.cclaude" \
  "an ORCH_LANE_RETIRE date before the credit reset is the account's expiry|$CLOUD;$(dirs cclaude dclaude);$(repos cclaude dclaude);ORCH_LANE_RETIRE=dclaude=2099-01-01|rc=0 config_dir=$H/.dclaude"

echo "=== the floor, the lock and an unread credit ==="
table \
  "a credit at the floor takes its walled plan verdict|$CLOUD;$(dirs fclaude);$(repos fclaude);ORCH_LANE_CLOUD_CREDIT_FLOOR=5|rc=3 walled=1" \
  "a credit above the floor is tier 0|$CLOUD;$(dirs fclaude);$(repos fclaude);ORCH_LANE_CLOUD_CREDIT_FLOOR=4|rc=0 config_dir=$H/.fclaude" \
  "a locked credit takes its walled plan verdict|$CLOUD;$(dirs lclaude);$(repos lclaude)|rc=3 walled=1" \
  "a body without the credit is named and judged on its plan windows|$CLOUD;$(dirs uclaude aclaude);$(repos uclaude aclaude)|rc=0 config_dir=$H/.aclaude line.cloud-credit-unread=account=uclaude" \
  "a floor nobody can read refuses the pick|$CLOUD;$(dirs bclaude);$(repos bclaude);ORCH_LANE_CLOUD_CREDIT_FLOOR=five|rc=1 line.invalid-lane-cloud-credit-floor=value=five"

echo "=== a cloud session reaches only a repository its account was given ==="
table \
  "an account with no entry for this checkout's repository is passed over|$CLOUD;$(dirs aclaude bclaude);$(repos aclaude)|rc=0 config_dir=$H/.aclaude" \
  "with no account given the repository the pick names each one|$CLOUD;$(dirs bclaude);ORCH_LANE_CLOUD_REPOS=bclaude=owner/other|rc=3 line.cloud-repo-unset=account=$H/.bclaude,repo=Owner/Repo" \
  "an entry nobody can read refuses the pick|$CLOUD;$(dirs bclaude);ORCH_LANE_CLOUD_REPOS=bclaude=owner|rc=1 line.invalid-cloud-repos=entry=bclaude=owner"

echo "=== controls ==="
# cloud_mutant NAME SCRIPT — mutant_scripts' copy with the github skill beside
# it, which a cloud-session pick reads the checkout's repository through.
cloud_mutant() {
  local dir
  dir="$(mutant_scripts "$1/orch" "$2")" || return 1
  ln -s "$(cd "$TEST_DIR/../.." && pwd)/github" "$TMP_ROOT/$1/github" || return 1
  printf '%s\n' "$dir"
}
# The tier key replaced by the score alone, the order before it: the plan
# account's score outranks the credit.
CTRL="$(cloud_mutant mutant-tier-key lib/lane-model.sh)" || exit 1
mutate_file "$CTRL/lib/lane-model.sh" 'sort_by([._tier, ._expires, (._score | neg), .claims,' 'sort_by([(.selection_score | neg), .claims,'
LANES_UNDER_TEST="$CTRL/lanes" table \
  "control: without the tier key plan room outranks the credit|$CLOUD;$(dirs aclaude bclaude);$(repos aclaude bclaude)|rc=0 config_dir=$H/.aclaude"
# shellcheck disable=SC2016  # the script's own text, never expanded here.
CTRL="$(cloud_mutant mutant-cloud-floor lib/lane-model.sh)" || exit 1
mutate_file "$CTRL/lib/lane-model.sh" 'and $c.remaining_dollars > $cloud_floor and' 'and'
LANES_UNDER_TEST="$CTRL/lanes" table \
  "control: without the floor comparison a credit at the floor is picked|$CLOUD;$(dirs fclaude);$(repos fclaude);ORCH_LANE_CLOUD_CREDIT_FLOOR=5|rc=0 config_dir=$H/.fclaude"
CTRL="$(cloud_mutant mutant-cloud-repo lib/lane-model.sh)" || exit 1
mutate_file "$CTRL/lib/lane-model.sh" 'else . + {verdict: "cloud-repo-unset"} end ]' 'else . end ]'
LANES_UNDER_TEST="$CTRL/lanes" table \
  "control: without cloud-repo-unset an account with no entry is picked|$CLOUD;$(dirs aclaude bclaude);$(repos aclaude)|rc=0 config_dir=$H/.bclaude"
CTRL="$(cloud_mutant mutant-cloud-unread lib/lane-model.sh)" || exit 1
# shellcheck disable=SC2016
mutate_file "$CTRL/lib/lane-model.sh" 'message cloud-credit-unread "$name" >&2' ':'
LANES_UNDER_TEST="$CTRL/lanes" table \
  "control: without its note a body with no credit drops it silently|$CLOUD;$(dirs uclaude aclaude);$(repos uclaude aclaude)|rc=0 config_dir=$H/.aclaude line.cloud-credit-unread=none"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
