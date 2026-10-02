#!/usr/bin/env bash
# Provider accounts and Claude usage responses exercise the chooser offline.
# The date command is the clock boundary; every pick reads the same instant.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LANES="${LANES_UNDER_TEST:-$(cd "$TEST_DIR/.." && pwd)/scripts/lanes}"
TMP_ROOT="$(mktemp -d)" || { echo "lanes-pick-reset: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "lanes-pick-reset: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "lanes-pick-reset: scratch=resolve-failed" >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
source "$TEST_DIR/lib/assertions.sh"
source "$TEST_DIR/lib/lanes-fixture.sh"
source "$TEST_DIR/lib/growth-state.sh"
FETCHER="$TMP_ROOT/fetch"; make_fetcher "$FETCHER"
mkdir -p "$TMP_ROOT/bin" "$TMP_ROOT/repo"
git -C "$TMP_ROOT/repo" init -q -b main
git -C "$TMP_ROOT/repo" config gc.auto 0
git -C "$TMP_ROOT/repo" config maintenance.auto false
REAL_DATE="$(command -v date)"
cat > "$TMP_ROOT/bin/date" <<'CLOCK'
#!/usr/bin/env bash
if [[ "${1:-}" == +%s ]]; then printf '%s\n' 1790812800; else exec "$REAL_DATE" "$@"; fi
CLOCK
chmod +x "$TMP_ROOT/bin/date"

# Controls remove one behavior without deleting the matching code. Use the
# same expectations as the fixed chooser and require that each turns red.
FALLBACK="$LANES"; SCORE="$LANES"; BOUND="$LANES"; LOCAL="$LANES"; NOMATCH="$LANES"; UNKNOWN="$LANES"; RESTORE="$LANES"; COLLECT="$LANES"
# measure_lane is the helper dependency. This private copy makes its command
# fail, rather than returning the unreachable record the usage endpoint emits.
CTRL="$(mutant_scripts failed-local-reader lib/lane-model.sh)"
mutate_file "$CTRL/lib/lane-model.sh" 'measure_lane "$1" "$2" >&7' '{ echo "local-reader: failed" >&2; false; }'
FAILED="$CTRL/lanes"
if [[ -z "${LANES_UNDER_TEST:-}" ]]; then
  CTRL="$(mutant_scripts mutant-missing-model lib/lane-model.sh)"
  mutate_file "$CTRL/lib/lane-model.sh" 'elif $h == "claude" and $model != "" and (lane_measured or .status == "no_usage_data")' 'elif false and $h == "claude" and $model != "" and (lane_measured or .status == "no_usage_data")'
  FALLBACK="$CTRL/lanes"
  CTRL="$(mutant_scripts mutant-reset-score lib/lane-model.sh)"
  mutate_file "$CTRL/lib/lane-model.sh" 'else 1 + 1 / (1 + $hours) end' 'else 1 end'
  SCORE="$CTRL/lanes"
  CTRL="$(mutant_scripts mutant-unbounded-score lib/lane-model.sh)"
  mutate_file "$CTRL/lib/lane-model.sh" 'else 1 + 1 / (1 + $hours) end' 'else 1 + 1000 / (1 + $hours) end'
  BOUND="$CTRL/lanes"
  CTRL="$(mutant_scripts mutant-local-scope lib/lane-model.sh)"
  mutate_file "$CTRL/lib/lane-model.sh" 'elif $h == "claude" and $model != "" and ((.model_buckets // []) | length) == 0 then empty' 'elif false and $h == "claude" and $model != "" and ((.model_buckets // []) | length) == 0 then empty'
  LOCAL="$CTRL/lanes"
  # Restores the refusal of a reading whose buckets name no window for the
  # model, so the shared-window rows must turn red.
  CTRL="$(mutant_scripts mutant-no-match lib/lane-model.sh)"
  mutate_file "$CTRL/lib/lane-model.sh" '((.model_buckets // []) | length) == 0 then empty' '(model_bindings($model) | length) == 0 then empty'
  NOMATCH="$CTRL/lanes"
  CTRL="$(mutant_scripts mutant-unknown-bonus lib/lane-model.sh)"
  mutate_file "$CTRL/lib/lane-model.sh" 'if $hours == null then 1 else' 'if $hours == null then 1.1 else'
  UNKNOWN="$CTRL/lanes"
  CTRL="$(mutant_scripts mutant-restore-shared lib/lane-model.sh)"
  mutate_file "$CTRL/lib/lane-model.sh" 'elif [[ "$trigger" == model ]]; then' 'elif false; then'
  RESTORE="$CTRL/lanes"
  CTRL="$(mutant_scripts mutant-helper-row lib/lane-model.sh)"
  mutate_file "$CTRL/lib/lane-model.sh" 'measure_lane "$1" "$2" >&7' '{ echo "local-reader: failed" >&2; false; }'
  rm -- "$CTRL/lanes" && cp -p -- "$LANES" "$CTRL/lanes" || exit 1
  mutate_file "$CTRL/lanes" '. + {status: "error", headroom_pct: null, detail: "local-reading failed"}' '.'
  COLLECT="$CTRL/lanes"
fi

pick_run() { # SCRIPT FETCHER ARGS... — one pick in H's world, its stderr in H/err
  local script="$1" fetcher="$2"
  shift 2
  (cd "$TMP_ROOT/repo" && env -i PATH="$TMP_ROOT/bin:$PATH" HOME="$H" REAL_DATE="$REAL_DATE" \
    LANES_HOME="$H" FIXTURE_DIR="$FIXTURE_DIR" ORCH_LANES_FETCH_CMD="$fetcher" \
    ORCH_LANE_HOST="$TEST_DIR/fixtures/lane-host" LANE_HOST_STUB_ACCOUNTS="$H/accounts" LANE_HOST_STUB_LOG="$H/host.log" \
    OVERSEE_WATCH_STATE_DIR="$H/store" ORCH_STATE_DIR="$H/state" ORCH_LANE_DIRS="$H/.8claude:$H/.10claude" \
    "$script" "$@" 2>"$H/err")
}

# name|harness|host A room|A reset hours|B room|B reset hours|local A model use|A label|winner|score|script|local scope|fetch|host status
# Local shared room without Opus comes from normal usage endpoint windows.
for row in \
  "fresh-8claude|claude|null|75|11|67|0|Opus|8|unknown|$LANES" \
  "named-fresh-8claude|claude|null|75|11|67|0|Opus|8|named|$LANES" \
  "neither-measures-opus|claude|100|75|11|67|0|Sonnet|8|unknown|$LANES|Sonnet" \
  "named-neither-measures-opus|claude|100|75|11|67|0|Sonnet|8|named|$LANES|Sonnet" \
  "unreachable-wrong-model|claude|100|75|11|67|0|Sonnet|8|unknown|$LANES|Sonnet|ok|unreachable" \
  "named-unreachable-wrong-model|claude|100|75|11|67|0|Sonnet|8|named|$LANES|Sonnet|ok|unreachable" \
  "unreachable-matching-model|claude|100|75|11|67|0|Sonnet|8|unknown|$LANES|Opus|ok|unreachable" \
  "named-unreachable-matching-model|claude|100|75|11|67|0|Sonnet|8|named|$LANES|Opus|ok|unreachable" \
  "local-http-failed|claude|100|75|11|67|0|Sonnet|10|reject|$LANES|Opus|503" \
  "named-local-http-failed|claude|100|75|11|67|0|Sonnet|8|refuse|$LANES|Opus|503" \
  "local-transport-failed|claude|100|75|11|67|0|Sonnet|10|reject|$LANES|Opus|transport" \
  "named-local-transport-failed|claude|100|75|11|67|0|Sonnet|8|refuse|$LANES|Opus|transport" \
  "local-empty|claude|100|75|11|67|null|Sonnet|10|reject|$LANES" \
  "named-local-empty|claude|100|75|11|67|null|Sonnet|8|refuse|$LANES" \
  "local-helper-failed|claude|100|75|11|67|0|Sonnet|10|reject|$FAILED|Opus|helper" \
  "named-local-helper-failed|claude|100|75|11|67|0|Sonnet|none|failed|$FAILED|Opus|helper" \
  "host-refusal-is-authoritative|claude|100|75|11|67|0|Sonnet|8|host-refused|$LANES|Opus|ok|refused" \
  "host-missing-scope-with-shared-window|claude|100|75|11|67|20|Sonnet|8|local80|$LANES" \
  "equal-room-sooner-reset|claude|80|9|80|1|null|Opus|10|120|$LANES" \
  "room-and-reset-example|claude|80|1|90|9|null|Opus|8|120|$LANES" \
  "eleven-cannot-beat-hundred|claude|11|0|100|10000|null|Opus|10|unknown|$LANES" \
  "codex-equal-room|codex|80|9|80|1|null|Opus|10|120|$LANES" \
  "pi-equal-room|pi|80|9|80|1|null|Opus|10|120|$LANES" \
  "unknown-reset-no-bonus|claude|80|null|40|1|null|Opus|8|80|$LANES" \
  "past-reset-bonus-capped|claude|80|-1|90|9|null|Opus|8|160|$LANES" \
  "control-fallback|claude|null|75|11|67|0|Opus|8|unknown|$FALLBACK" \
  "control-reset|claude|80|9|80|1|null|Opus|10|120|$SCORE" \
  "control-bound|claude|11|0|100|10000|null|Opus|10|unknown|$BOUND" \
  "control-local-scope|claude|100|75|11|67|0|Sonnet|8|unknown|$NOMATCH|Sonnet" \
  "control-named-local-scope|claude|100|75|11|67|0|Sonnet|8|named|$NOMATCH|Sonnet" \
  "control-unreachable-local-scope|claude|100|75|11|67|0|Sonnet|8|unknown|$NOMATCH|Sonnet|ok|unreachable" \
  "control-named-unreachable-local-scope|claude|100|75|11|67|0|Sonnet|8|named|$NOMATCH|Sonnet|ok|unreachable" \
  "control-unknown-reset|claude|80|null|40|1|null|Opus|8|80|$UNKNOWN" \
  "control-local-http|claude|100|75|11|67|0|Sonnet|10|reject|$RESTORE|Opus|503" \
  "control-named-local-http|claude|100|75|11|67|0|Sonnet|8|refuse|$RESTORE|Opus|503" \
  "control-helper-row|claude|100|75|11|67|0|Sonnet|10|reject|$COLLECT|Opus|helper"; do
  IFS='|' read -r name harness room hours b_room b_hours local_model label winner score script local_scope fetch host_status <<<"$row"
  local_scope="${local_scope:-Opus}"; fetch="${fetch:-ok}"; host_status="${host_status:-ok}"
  new_home "$name"
  make_lane "$H" 8claude
  # A scoped window alone reproduces the host row that measures no Opus.
  jq -n --argjson p "$local_model" --argjson h "$hours" --arg scope "$local_scope" '{limits: (if $p == null then [] else [{kind: "weekly_scoped", percent: $p,
    resets_at: (if $h == null then null else (1790812800 + $h * 3600 | todate) end), scope: {model: {display_name: $scope}}}] end)}
    | if $scope == "Sonnet" then . + {five_hour: {utilization: 0}, seven_day: {utilization: 0}} else . end' > "$FIXTURE_DIR/.8claude.json"
  fetcher="$FETCHER"; detail="no fresh local model window for claude-opus-5-5"; status=no_usage_data
  [[ "$local_model" != null ]] || detail="authenticated, but the usage response carried no session/weekly/monthly window"
  case "$fetch" in
    ok) ;;
    503) printf '503\n' > "$FIXTURE_DIR/.8claude.status"; status=unreachable; detail="usage query refused with HTTP 503" ;;
    transport) fetcher=false; status=unreachable; detail="usage query could not be run" ;;
    helper) detail="local-reader: failed" ;;
    *) echo "unknown fetch fixture: $fetch" >&2; exit 1 ;;
  esac
  jq -nr --arg a "$H/.8claude" --arg b "$H/.10claude" --arg harness "$harness" --arg label "$label" \
    --arg status "$host_status" --argjson room "$room" --argjson hours "$hours" --argjson br "$b_room" --argjson bh "$b_hours" '
    def reset($h): if $h == null then "" else (1790812800 + $h * 3600 | todate) end;
    [[$a, $room, $hours, $label], [$b, $br, $bh, "Opus"]][]
    | "account=\(.[0])\tharness=\($harness)\tstatus=\(if .[0] == $a then $status else "ok" end)\t" +
      (if $harness == "pi" then "monthly" elif $harness == "codex" then "weekly" else "model" end) +
      "-pct=\(if .[1] == null then "" else 100 - .[1] end)\t" +
      (if $harness == "pi" then "monthly" elif $harness == "codex" then "weekly" else "model" end) +
      "-resets=\(reset(.[2]))\tmodel-label=\(.[3])"' > "$H/accounts"
  if [[ "$label" == Sonnet ]]; then
    printf '\tweekly-pct=0\n' > "$H/shared"
    paste -d '\0' "$H/accounts" "$H/shared" > "$H/accounts.tmp"; mv "$H/accounts.tmp" "$H/accounts"
  fi
  args=(pick --harness "$harness" --model claude-opus-5-5 --json)
  [[ "$harness" != pi ]] || args=(pick --harness pi --model github-copilot/claude-opus-5-5 --json)
  want_rc=0
  case "$score" in
    named) args+=(--lane "$H/.8claude" --projected) ;;
    refuse|host-refused) args+=(--lane "$H/.8claude" --projected); want_rc=5 ;;
    failed) args+=(--lane "$H/.8claude" --projected); want_rc=1 ;;
  esac
  rc=0
  out="$(pick_run "$script" "$fetcher" "${args[@]}")" || rc=$?
  printf 'case=%s rc=%s json=%s\n' "$name" "$rc" "$out"
  got="$(jq -r '.config_dir // "none"' <<<"$out")"
  got="${got:-none}"
  want="$H/.${winner}claude"
  case "$score" in
    unknown|named) ;;
    reject|dropped) got+=" qualifying=$(jq -r '.qualifying_count' <<<"$out")"; want+=" qualifying=1" ;;
    refuse)
      got+=" status=$(jq -r '.status' <<<"$out") detail=$(jq -r '.detail' <<<"$out")"
      want+=" status=$status detail=$detail"
      ;;
    host-refused) got+=" status=$(jq -r '.status' <<<"$out")"; want+=" status=$host_status" ;;
    failed) want=none ;;
    local80) got+=" room=$(jq -r '.effective_headroom_pct' <<<"$out")"; want+=" room=80" ;;
    *) got+=" score=$(jq -r '.selection_score' <<<"$out") room=$(jq -r '.projected_headroom_pct' <<<"$out")"; want+=" score=$score room=$room" ;;
  esac
  if [[ "$score" == reject || "$score" == refuse || "$score" == failed ]]; then
    reported=no; grep -F -- "$detail" "$H/err" >/dev/null && reported=yes
    got+=" cause=$reported"; want+=" cause=yes"
  fi
  if [[ "$name" == control-* && -z "${LANES_UNDER_TEST:-}" ]]; then
    [[ ( "$rc" == 0 || "$rc" == 5 ) && "rc=$rc $got" != "rc=$want_rc $want" ]] && pass "$name turns its assertion red" || fail "$name did not reach the behavior"
  else
    assert_eq "rc=$rc $got" "rc=$want_rc $want" "$name" "$H/err"
  fi
done

# A plan whose one scoped window is Fable's, at 5H 0 and WEEK 66. The host row's
# model label is Fable for an Opus launch and Sonnet for a Fable launch, so it
# names no window for the launched model and every row consults the local
# reading. An Opus launch is judged on the shared windows and a Fable launch on
# the local Fable window; a reading with no model window stays unmeasured.
# `through` is the credential the record names and `line` the keyed stderr line
# that consultation printed. `named` is the call the open-terminal launch gate
# makes.
# name|local scoped window|host label|model|form|script|expected
NO_MODEL="detail=no fresh local model window for claude-opus-5-5 line=pick-local-model-unmeasured"
for row in \
  "shared-binds-opus|Fable|Fable|claude-opus-5-5|pick|$LANES|rc=0 lane=8claude through=local status=ok bucket=weekly room=34 detail=null line=pick-local-model-reading" \
  "named-shared-binds-opus|Fable|Fable|claude-opus-5-5|named|$LANES|rc=0 lane=8claude through=local status=ok bucket=weekly room=34 detail=null line=pick-local-model-reading" \
  "fable-window-binds-fable|Fable|Sonnet|fable|named|$LANES|rc=3 lane=8claude through=local status=ok bucket=model room=0 detail=null line=pick-local-model-reading" \
  "no-model-window-unmeasured|none|Fable|claude-opus-5-5|named|$LANES|rc=5 lane=8claude through=local status=no_usage_data bucket=null room=null $NO_MODEL" \
  "control-shared-binds-opus|Fable|Fable|claude-opus-5-5|named|$NOMATCH|rc=0 lane=8claude through=local status=ok bucket=weekly room=34 detail=null line=pick-local-model-reading" \
  "control-no-model-window|none|Fable|claude-opus-5-5|named|$LOCAL|rc=5 lane=8claude through=local status=no_usage_data bucket=null room=null $NO_MODEL"; do
  IFS='|' read -r name scope host_label model form script want <<<"$row"
  new_home "$name"
  make_lane "$H" 8claude
  jq -n --arg scope "$scope" '{five_hour: {utilization: 0}, seven_day: {utilization: 66},
    limits: (if $scope == "none" then [] else [{kind: "weekly_scoped", percent: 100, scope: {model: {display_name: $scope}}}] end)}' \
    > "$FIXTURE_DIR/.8claude.json"
  printf 'account=%s\tharness=claude\tstatus=ok\tsession-5h-pct=0\tweekly-pct=66\tmodel-pct=100\tmodel-label=%s\n' "$H/.8claude" "$host_label" > "$H/accounts"
  args=(pick --harness claude --model "$model" --json)
  [[ "$form" == pick ]] || args+=(--lane "$H/.8claude" --projected)
  rc=0
  out="$(pick_run "$script" "$FETCHER" "${args[@]}")" || rc=$?
  line="$(sed -nE 's/^lanes: (pick-local-model-(reading|unmeasured)) .*/\1/p' "$H/err")"
  got="rc=$rc $(jq -r '"lane=\(.config_dir // "none" | sub(".*/\\."; "")) through=\(.measured_through) status=\(.status) bucket=\(.binding_bucket) room=\(.projected_headroom_pct) detail=\(.detail)"' <<<"$out") line=${line:-none}"
  if [[ "$name" == control-* && -z "${LANES_UNDER_TEST:-}" ]]; then
    [[ ( "$rc" == 0 || "$rc" == 5 ) && "$got" != "$want" ]] && pass "$name turns its assertion red" || fail "$name did not reach the behavior"
  else
    assert_eq "$got" "$want" "$name" "$H/err"
  fi
done
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
