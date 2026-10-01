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
FALLBACK="$LANES"; SCORE="$LANES"; BOUND="$LANES"
if [[ -z "${LANES_UNDER_TEST:-}" ]]; then
  CTRL="$(mutant_scripts mutant-missing-model lanes)"
  mutate_file "$CTRL/lanes" '[[ "$missing_model" != true ]] || trigger=true' '[[ "$missing_model" != true ]] || trigger=false'
  FALLBACK="$CTRL/lanes"
  CTRL="$(mutant_scripts mutant-reset-score lib/lane-model.sh)"
  mutate_file "$CTRL/lib/lane-model.sh" 'else 1 + 1 / (1 + $hours) end' 'else 1 end'
  SCORE="$CTRL/lanes"
  CTRL="$(mutant_scripts mutant-unbounded-score lib/lane-model.sh)"
  mutate_file "$CTRL/lib/lane-model.sh" 'else 1 + 1 / (1 + $hours) end' 'else 1 + 1000 / (1 + $hours) end'
  BOUND="$CTRL/lanes"
fi

# name|harness|host A room|A reset hours|B room|B reset hours|local A model use|A label|winner|score|script
for row in \
  "fresh-8claude|claude|null|75|11|67|0|Opus|8|unknown|$LANES" \
  "named-fresh-8claude|claude|null|75|11|67|0|Opus|8|named|$LANES" \
  "neither-measures-opus|claude|100|75|11|67|null|Sonnet|10|unknown|$LANES" \
  "host-missing-scope-with-shared-window|claude|100|75|11|67|20|Sonnet|8|local80|$LANES" \
  "equal-room-sooner-reset|claude|80|9|80|1|null|Opus|10|120|$LANES" \
  "room-and-reset-example|claude|80|1|90|9|null|Opus|8|120|$LANES" \
  "eleven-cannot-beat-hundred|claude|11|0|100|10000|null|Opus|10|unknown|$LANES" \
  "codex-equal-room|codex|80|9|80|1|null|Opus|10|120|$LANES" \
  "pi-equal-room|pi|80|9|80|1|null|Opus|10|120|$LANES" \
  "unknown-reset-no-bonus|claude|80|null|80|1|null|Opus|10|120|$LANES" \
  "past-reset-bonus-capped|claude|80|-1|90|9|null|Opus|8|160|$LANES" \
  "control-fallback|claude|null|75|11|67|0|Opus|8|unknown|$FALLBACK" \
  "control-reset|claude|80|9|80|1|null|Opus|10|120|$SCORE" \
  "control-bound|claude|11|0|100|10000|null|Opus|10|unknown|$BOUND"; do
  IFS='|' read -r name harness room hours b_room b_hours local_model label winner score script <<<"$row"
  new_home "$name"
  make_lane "$H" 8claude
  # A scoped window alone reproduces the host row that measures no Opus.
  jq -n --argjson p "$local_model" --argjson h "$hours" '{limits: (if $p == null then [] else [{kind: "weekly_scoped", percent: $p,
    resets_at: (if $h == null then null else (1790812800 + $h * 3600 | todate) end), scope: {model: {display_name: "Opus"}}}] end)}' > "$FIXTURE_DIR/.8claude.json"
  jq -nr --arg a "$H/.8claude" --arg b "$H/.10claude" --arg harness "$harness" --arg label "$label" \
    --argjson room "$room" --argjson hours "$hours" --argjson br "$b_room" --argjson bh "$b_hours" '
    def reset($h): if $h == null then "" else (1790812800 + $h * 3600 | todate) end;
    [[$a, $room, $hours, $label], [$b, $br, $bh, "Opus"]][]
    | "account=\(.[0])\tharness=\($harness)\tstatus=ok\t" +
      (if $harness == "pi" then "monthly" elif $harness == "codex" then "weekly" else "model" end) +
      "-pct=\(if .[1] == null then "" else 100 - .[1] end)\t" +
      (if $harness == "pi" then "monthly" elif $harness == "codex" then "weekly" else "model" end) +
      "-resets=\(reset(.[2]))\tmodel-label=\(.[3])"' > "$H/accounts"
  if [[ "$name" == host-missing-scope-with-shared-window ]]; then
    printf '\tweekly-pct=0\n' > "$H/shared"
    paste -d '' "$H/accounts" "$H/shared" > "$H/accounts.tmp"; mv "$H/accounts.tmp" "$H/accounts"
  fi
  args=(pick --harness "$harness" --model claude-opus-5-5 --json)
  [[ "$harness" != pi ]] || args=(pick --harness pi --model github-copilot/claude-opus-5-5 --json)
  [[ "$score" != named ]] || args+=(--lane "$H/.8claude")
  rc=0
  out="$(cd "$TMP_ROOT/repo" && env -i PATH="$TMP_ROOT/bin:$PATH" HOME="$H" REAL_DATE="$REAL_DATE" \
    LANES_HOME="$H" FIXTURE_DIR="$FIXTURE_DIR" ORCH_LANES_FETCH_CMD="$FETCHER" \
    ORCH_LANE_HOST="$TEST_DIR/fixtures/lane-host" LANE_HOST_STUB_ACCOUNTS="$H/accounts" LANE_HOST_STUB_LOG="$H/host.log" \
    OVERSEE_WATCH_STATE_DIR="$H/store" ORCH_STATE_DIR="$H/state" ORCH_LANE_DIRS="$H/.8claude:$H/.10claude" \
    "$script" "${args[@]}" 2>"$H/err")" || rc=$?
  printf 'case=%s rc=%s json=%s\n' "$name" "$rc" "$out"
  got="$(jq -r '.config_dir // "none"' <<<"$out")"
  want="$H/.${winner}claude"
  case "$score" in
    unknown|named) ;;
    local80) got+=" room=$(jq -r '.effective_headroom_pct' <<<"$out")"; want+=" room=80" ;;
    *) got+=" score=$(jq -r '.selection_score' <<<"$out")"; want+=" score=$score" ;;
  esac
  if [[ "$name" == control-* && -z "${LANES_UNDER_TEST:-}" ]]; then
    [[ "$rc" == 0 && "$got" != "$want" ]] && pass "$name turns its assertion red" || fail "$name did not reach the behavior"
  else
    assert_eq "rc=$rc $got" "rc=0 $want" "$name" "$H/err"
  fi
done
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
