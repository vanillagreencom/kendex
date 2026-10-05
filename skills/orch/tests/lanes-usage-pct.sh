#!/usr/bin/env bash
# Tests for the percentage reading of lib/lane-usage.sh: a usage window whose
# percentage does not read leaves the lane unmeasured, never an empty window.
# Read as 0, an unreadable window would leave the account measured with full
# headroom, and pick would launch onto it. Each lane carries one unreadable
# window beside readable ones: the readable ones must not bind the lane while
# the unreadable one may be exhausted. A window the body omits is no reading,
# and the windows beside it stay measured. The network layer is the fetch stub
# lib/lanes-fixture.sh writes, so every row runs offline.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
unset ORCH_LANE_DIRS ORCH_LANE_ALIASES ORCH_LANE_EXCLUDE ORCH_LANE_RETIRE ORCH_LANES_USAGE_TTL CODEX_HOME
unset ORCH_LANE_MAX_PCT ORCH_LANE_HOST ORCH_STATE_DIR
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LANES="$(cd "$TEST_DIR/.." && pwd)/scripts/lanes"

TMP_ROOT="$(mktemp -d)" || { echo "lanes-usage-pct: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "lanes-usage-pct: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "lanes-usage-pct: scratch=resolve-failed" >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT

# shellcheck source=lib/assertions.sh
source "$TEST_DIR/lib/assertions.sh"
# shellcheck source=lib/lanes-fixture.sh
source "$TEST_DIR/lib/lanes-fixture.sh"
# mutant_scripts and mutate_file, the two halves of the must-fail controls below.
# shellcheck source=lib/growth-state.sh
source "$TEST_DIR/lib/growth-state.sh"

FETCHER="$TMP_ROOT/fetch"
make_fetcher "$FETCHER"

# Runs start in a repository carrying no settings, so neither the checkout's
# kendex.settings.toml nor its fleet state reaches a row.
NOSETTINGS="$TMP_ROOT/nosettings"; mkdir -p "$NOSETTINGS"
git -C "$NOSETTINGS" init -q -b main
git -C "$NOSETTINGS" config gc.auto 0
git -C "$NOSETTINGS" config maintenance.auto false

# list HARNESS [SCRIPT] — the JSON listing of HARNESS in OUT.
RUN_SEQ=0
list() {
  RUN="$TMP_ROOT/runs/$((++RUN_SEQ))"; mkdir -p "$RUN"
  OUT=$(cd "$NOSETTINGS" && env GIT_CEILING_DIRECTORIES="$TMP_ROOT" LANES_HOME="$H" \
    ORCH_LANES_FETCH_CMD="$FETCHER" OVERSEE_WATCH_STATE_DIR="$RUN/store" ORCH_STATE_DIR="$RUN/fleet" \
    "${2:-$LANES}" list --harness "$1" --json 2>"$RUN/err")
}

# observe EXPECT — every `lane.field` token of EXPECT as the listing reads it.
# `lane.buckets` is every scoped window of the lane as `label:pct`,
# comma-joined, or none: a reading the parser abandoned carries no window.
observe() {
  local got="" token name lane field value
  for token in $1; do
    name="${token%%=*}"; lane="${name%%.*}"; field="${name#*.}"
    case "$field" in
      buckets) value="$(jq -r --arg a "$lane" '.[] | select(.alias == $a) | [.model_buckets[] | "\(.label):\(.pct)"] | join(",")' <<<"$OUT" 2>/dev/null || echo UNPARSEABLE)"; value="${value:-none}" ;;
      *) value="$(jq -r --arg a "$lane" ".[] | select(.alias == \$a) | .$field" <<<"$OUT" 2>/dev/null || echo UNPARSEABLE)" ;;
    esac
    got="$got $name=$value"
  done
  printf '%s' "${got# }"
}

# table ROW... — `label|harness|expect`, one listing and one assertion a row.
table() {
  local row label harness expect
  for row in "$@"; do
    IFS='|' read -r label harness expect <<<"$row"
    [[ -n "$expect" ]] || { printf 'table: a row with no expect asserts nothing: %s\n' "$row" >&2; exit 1; }
    list "$harness"
    assert_eq "$(observe "$expect")" "$expect" "$label" "$RUN/err"
  done
}

new_home invalid-pct
for lane in sclaude mclaude nclaude oclaude lclaude aclaude; do make_lane "$H" "$lane" 3600; done
for lane in scodex mcodex ncodex ocodex; do make_codex_lane "$H/.$lane"; done
claude_body() { # LANE FILTER
  jq -n '{five_hour: {utilization: 10, resets_at: "2026-07-27T06:00:00Z"},
          seven_day: {utilization: 20, resets_at: "2026-08-01T06:00:00Z"},
          limits: [{kind: "weekly_scoped", percent: 30, scope: {model: {display_name: "Opus"}}},
                   {kind: "weekly_scoped", percent: 40, scope: {model: {display_name: "Fable"}}}]} | '"$2" \
    > "$FIXTURE_DIR/.$1.json" || exit 1
}
claude_body sclaude '.five_hour.utilization = "12"'
claude_body mclaude 'del(.seven_day.utilization)'
claude_body nclaude '.limits[0].percent = -0.1'
claude_body oclaude '.limits[1].percent = 1e13'
claude_body lclaude 'del(.limits) | .seven_day_sonnet = {utilization: 5} | .seven_day_opus = {utilization: "7"}'
claude_body aclaude '.five_hour = null | del(.limits)'
# Each window carries a reset, which the parser alone renders: a row pinning
# the resets beside the null percentages fails on a parse that produced
# nothing, which lists the same nulls.
codex_body() { # LANE FILTER
  jq -n '{rate_limit: {primary_window: {used_percent: 30, reset_at: 1785000000, limit_window_seconds: 18000},
                       secondary_window: {used_percent: 20, reset_at: 1785600000, limit_window_seconds: 604800}}} | '"$2" \
    > "$FIXTURE_DIR/.$1.json" || exit 1
}
codex_body scodex '.rate_limit.primary_window.used_percent = "30"'
codex_body mcodex 'del(.rate_limit.secondary_window.used_percent)'
codex_body ncodex '.rate_limit.secondary_window.used_percent = -1'
codex_body ocodex '.rate_limit.primary_window.used_percent = 1e13'
unmeasured() { printf '%s.status=no_usage_data %s.verdict=unmeasured %s.session_5h_pct=null %s.weekly_pct=null' "$1" "$1" "$1" "$1"; }
# A Claude row pins the scoped windows the body names, each unread, and the
# label of the largest; a Codex row pins both windows' resets.
CLAUDE_SCOPED='model_pct=null model_label=Fable buckets=Opus:null,Fable:null'
CODEX_RESETS='resets.session=2026-07-25T17:20:00Z resets.weekly=2026-08-01T16:00:00Z'
claude_unmeasured() { printf '%s %s.%s' "$(unmeasured "$1")" "$1" "${CLAUDE_SCOPED// / $1.}"; }
codex_unmeasured() { printf '%s %s.%s' "$(unmeasured "$1")" "$1" "${CODEX_RESETS// / $1.}"; }

echo "=== a percentage that does not read is unmeasured, never an empty window ==="
table \
  "a string Claude session beside a readable weekly leaves the lane unmeasured|claude|$(claude_unmeasured sclaude)" \
  "a missing Claude weekly percentage leaves the lane unmeasured|claude|$(claude_unmeasured mclaude)" \
  "a negative scoped Claude window leaves the lane unmeasured|claude|$(claude_unmeasured nclaude)" \
  "an oversized scoped Claude window leaves the lane unmeasured|claude|$(claude_unmeasured oclaude)" \
  "an unreadable legacy Claude model window leaves the lane unmeasured|claude|$(unmeasured lclaude) lclaude.model_pct=null lclaude.model_label=Opus lclaude.buckets=Sonnet:null,Opus:null" \
  "an absent Claude session window leaves the weekly measured|claude|aclaude.status=ok aclaude.session_5h_pct=null aclaude.weekly_pct=20 aclaude.headroom_pct=80" \
  "a string Codex primary beside a readable secondary leaves the lane unmeasured|codex|$(codex_unmeasured scodex)" \
  "a missing Codex secondary percentage leaves the lane unmeasured|codex|$(codex_unmeasured mcodex)" \
  "a negative Codex secondary leaves the lane unmeasured|codex|$(codex_unmeasured ncodex)" \
  "an oversized Codex primary leaves the lane unmeasured|codex|$(codex_unmeasured ocodex)"
# One control per rule and harness: the type test, the range test, and the
# rule that one unreadable window unmeasures the rest. The Claude order control
# judges the range after `round`, which reads -0.1 as -0 and passes it.
range='and . >= 0 and . <= 1e12'
for spec in claude:sclaude:type:round claude:nclaude:range:round codex:scodex:type:floor codex:ncodex:range:floor \
  claude:nclaude:order:round claude:sclaude:whole: codex:scodex:whole:; do
  IFS=':' read -r harness lane rule op <<<"$spec"
  dir="$(mutant_scripts "mutant-pct-$harness-$rule" lib/lane-usage.sh)" || exit 1
  case "$harness:$rule" in
    *:type) mutate_file "$dir/lib/lane-usage.sh" "then $op else null end;" "then $op else 0 end;" ;;
    *:range) mutate_file "$dir/lib/lane-usage.sh" "$range then $op" "then $op" ;;
    claude:order) mutate_file "$dir/lib/lane-usage.sh" "$range then $op else null end;" \
      "then $op | (if (. > 1e12 or . < 0) then null else . end) else null end;" ;;
    claude:whole) mutate_file "$dir/lib/lane-usage.sh" 'if $unread then null' 'if false then null' ;;
    codex:whole) mutate_file "$dir/lib/lane-usage.sh" '(if any(.[]; .pct == null) then' '(if false then' ;;
  esac
  list "$harness" "$dir/lanes"
  assert_eq "$(observe "$lane.status")" "$lane.status=ok" "control $harness $rule: an unreadable percentage leaves the lane measured"
done

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
