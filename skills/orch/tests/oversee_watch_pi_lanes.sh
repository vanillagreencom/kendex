#!/usr/bin/env bash
# oversee-watch's reading of a Pi lane: idle, working or walled from the rows
# its own lane-mail-check hook writes in its mailbox under the pi-hooks
# carrier (lib/session-rows.sh), never from its pane. Every case stages a pane
# that would answer something else, so an event that follows the rows proves
# the pane was not what judged it. The writer's rows are pinned in
# hooks/tests/lane-mail-check.test.sh and the judge's in lane-state.sh.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
# shellcheck source=lib/oversee-watch-harness.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/oversee-watch-harness.sh"
# mutant_scripts and mutate_file, the two halves of the control below.
# shellcheck source=lib/growth-state.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/growth-state.sh"

FIXTURE_HOST="$REPO_ROOT/skills/orch/tests/fixtures/lane-host"
COMPOSER='\xe2\x9d\xaf\xc2\xa0'
# The screens: a Claude Code idle composer, which the pane rungs read idle,
# and a streaming counter, which they read working.
IDLE_SCREEN="$(printf '%b\n' '⏺ Done: the PR is merged.' "$COMPOSER")"
WORKING_SCREEN="$(printf '%b\n' '✶ Germinating… (29m 16s · ↓ 58.7k tokens)' "$COMPOSER")"

# pi_lane ROOT [HOST] — the fleet state: gh-2 is a Pi lane on ROOT, its
# mailbox there, and gh-1 is not in the fleet.
pi_lane() {
  printf 'gh-2\n' > "$STUB_DIR/windows.txt"
  jq -cn --arg root "$1" --arg host "${2:-}" \
    '{issue_id: "oversee", triaged: [], lanes: [{item: "gh-2", window: "gh-2", harness: "pi",
      host: (if $host == "" then null else $host end), mail_root: $root, status: "running"}]}' \
    > "$STUB_DIR/state.json"
  mkdir -p "$1/tmp/lane-mail/gh-2"
  printf 'step: dev round 1\n' > "$1/tmp/lane-status-gh-2.md"
}
# rows ROOT SHAPE — the lane's last row, or no rows file for `none`.
rows() {
  local file="$1/tmp/lane-mail/gh-2/session-rows.jsonl"
  rm -f -- "${file:?}"
  case "$2" in
    none) ;;
    ended) printf '%s\n' '{"at":1,"event":"Stop","harness":"pi","stop_reason":"stop"}' > "$file" ;;
    reopened) printf '%s\n' '{"at":1,"event":"Stop","harness":"pi","stop_reason":"stop"}' \
      '{"at":2,"event":"PreToolUse","harness":"pi"}' > "$file" ;;
    limit) printf '%s\n' '{"at":1,"event":"Stop","harness":"pi","stop_reason":"error","message":"429 Usage limit reached for this model"}' > "$file" ;;
    # the Claude Code SDK's own words, which pi-claude-bridge ends the turn on
    weekly|session) printf '{"at":1,"event":"Stop","harness":"pi","stop_reason":"error","message":"You'"'"'ve hit your %s limit \u00b7 resets Oct 4, 6pm (UTC)"}\n' "$2" > "$file" ;;
  esac
}
# watch [ENV=VAL...] — one run of two passes; OUT holds its stdout.
watch() {
  OUT="$(run_watch "$@" -- --state "$STUB_DIR/state.json" 2>"$STUB_DIR/err" </dev/null || true)"
}
events() { grep '^EVENT ' <<<"$OUT" | grep -v '^EVENT heartbeat' | paste -sd '|' - || true; }

echo "=== a Pi lane is judged from its rows, never its pane ==="
# SHAPE|SCREEN|WANT
while IFS='|' read -r shape screen want; do
  [[ -n "$shape" ]] || continue
  new_case "pi_$shape"
  ROOT="$STUB_DIR/wt"
  pi_lane "$ROOT"
  rows "$ROOT" "$shape"
  if [[ "$screen" == idle ]]; then printf '%s\n' "$IDLE_SCREEN" > "$STUB_DIR/pane-gh-2.txt"
  else printf '%s\n' "$WORKING_SCREEN" > "$STUB_DIR/pane-gh-2.txt"; fi
  watch
  assert_eq "events=$(events)" "events=$want" "a Pi lane whose rows are $shape over a $screen pane reports '${want:-nothing}'" "$STUB_DIR/err"
done <<'ROWS'
ended|working|EVENT idle-after-return gh-2
reopened|idle|
none|idle|
limit|idle|EVENT usage-limit gh-2
ROWS
# The wall's block is the error the turn ended on, the banner the judge read.
assert_contains "$OUT" "429 Usage limit reached for this model" "the usage-limit block carries Pi's own error message" "$STUB_DIR/err"

echo "=== a new turn end is news once more ==="
new_case pi_next_turn
ROOT="$STUB_DIR/wt"
pi_lane "$ROOT"
rows "$ROOT" ended
printf '%s\n' "$IDLE_SCREEN" > "$STUB_DIR/pane-gh-2.txt"
watch
watch
assert_eq "events=$(events)" "events=" "the same turn end is reported once across runs" "$STUB_DIR/err"
printf '%s\n' '{"at":3,"event":"PreToolUse","harness":"pi"}' '{"at":4,"event":"Stop","harness":"pi","stop_reason":"stop"}' \
  >> "$ROOT/tmp/lane-mail/gh-2/session-rows.jsonl"
watch
assert_eq "events=$(events)" "events=EVENT idle-after-return gh-2" "a later turn end on the same pane is reported again" "$STUB_DIR/err"

echo "=== a hosted Pi lane's rows are read through lane-host ==="
new_case pi_hosted
REMOTE_DISK="$STUB_DIR/remote"
pi_lane "$REMOTE_DISK/srv/lane/gh-2"
printf 'gitdir: /srv/clone/.git/worktrees/gh-2\n' > "$REMOTE_DISK/srv/lane/gh-2/.git"
jq '.lanes[0].host = $h | .lanes[0].mail_root = "/srv/lane/gh-2"' --arg h "$FIXTURE_HOST" "$STUB_DIR/state.json" \
  > "$STUB_DIR/state.next" && mv "$STUB_DIR/state.next" "$STUB_DIR/state.json"
rows "$REMOTE_DISK/srv/lane/gh-2" ended
printf '%s\n' "$WORKING_SCREEN" > "$STUB_DIR/pane-gh-2.txt"
HOSTED_ENV=(ORCH_LANE_HOST="$FIXTURE_HOST" LANE_HOST_STUB_LOG="$STUB_DIR/host.log" LANE_HOST_STUB_DIR="$REMOTE_DISK")
watch "${HOSTED_ENV[@]}"
assert_eq "events=$(events)" "events=EVENT idle-after-return gh-2" "a hosted Pi lane's rows judge it idle over a working pane" "$STUB_DIR/err"
new_case pi_hosted_unread
pi_lane "$REMOTE_DISK/srv/lane/gh-2"
jq '.lanes[0].host = $h | .lanes[0].mail_root = "/srv/lane/gh-2"' --arg h "$FIXTURE_HOST" "$STUB_DIR/state.json" \
  > "$STUB_DIR/state.next" && mv "$STUB_DIR/state.next" "$STUB_DIR/state.json"
printf '%s\n' "$IDLE_SCREEN" > "$STUB_DIR/pane-gh-2.txt"
watch "${HOSTED_ENV[@]}" LANE_HOST_STUB_CAT_STATUS=5 \
  LANE_HOST_STUB_CAT_PATH=/srv/lane/gh-2/tmp/lane-mail/gh-2/session-rows.jsonl
assert_eq "events=$(events) unread=$(grep -c '^oversee-watch: lane-rows-unread lane=gh-2 item=gh-2 exit=2$' "$STUB_DIR/err" || true)" \
  "events= unread=2" "a failed rows read is noted each pass and the lane is unjudged, never read at its pane" "$STUB_DIR/err"

echo "=== a Pi lane's weekly wall is kept for its account ==="
# A Pi lane on a Claude model ends its turn on the error its harness reported,
# carried in its session row and never drawn in a pane, so the weekly phrase
# alone records the wall for the claimed account (lib/account-wall.sh); a
# session limit records nothing. Controls: the row read as a pane, through
# the drawn-prefix test, records nothing; the row's weekly test widened to any
# limit records the session wall.
# LABEL|SHAPE|SCRIPTS|WANT, SCRIPTS `-` for the shipped watch or a mutant's name
WALL_SCRIPTS=()
pi_wall_mutant() { # NAME FILE OLD NEW
  local scripts
  scripts="$(mutant_scripts "$1/orch" "$2")" || exit 1
  ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/$1/github"
  mutate_file "$scripts/$2" "$3" "$4"
  WALL_SCRIPTS+=("$1=$scripts/oversee-watch")
}
pi_wall_mutant pi-wall-as-pane oversee-watch '"$banner" "${LANE_ROWS[$i]:+row}"' '"$banner" ""'
pi_wall_mutant pi-wall-any-limit lib/account-wall.sh '*You*"ve hit your weekly limit"*' '*You*"ve hit your "*'
while IFS='|' read -r label shape bin want; do
  [[ -n "$label" ]] || continue
  new_case "pi_wall_$shape"
  ROOT="$STUB_DIR/wt"
  pi_lane "$ROOT"
  rows "$ROOT" "$shape"
  printf '%s\n' "$IDLE_SCREEN" > "$STUB_DIR/pane-gh-2.txt"
  printf '900 %%3\n' > "$STUB_DIR/panes.txt"
  printf '900 %%3\n' > "$STUB_DIR/pane-key-gh-2.txt"
  mkdir -p "$STATE_DIR/claims"
  printf '900\t%%3\t/home/me/.eclaude\tgh-2\t2026-08-16T00:00:00Z\n' > "$STATE_DIR/claims/c.claim"
  printf '1788364800' > "$STUB_DIR/now.epoch"
  watch_bin=""
  for entry in "${WALL_SCRIPTS[@]}"; do [[ "${entry%%=*}" != "$bin" ]] || watch_bin="${entry#*=}"; done
  [[ "$bin" == - || -n "$watch_bin" ]] || { echo "pi wall: unknown scripts $bin" >&2; exit 1; }
  WATCH_BIN="$watch_bin" watch TZ=UTC
  wall="$(find "$STATE_DIR/walls" -name '*.json' -exec cat {} + 2>/dev/null | jq -r '"\(.config_dir)@\(.resets_at)"' | paste -sd, - || true)"
  assert_eq "events=$(events) wall=${wall:-none}" "$want" "$label" "$STUB_DIR/err"
done <<'ROWS'
a claimed Pi lane whose turn ended on the weekly-limit error records its account's wall|weekly|-|events=EVENT usage-limit gh-2 /home/me/.eclaude resets=2026-10-04T18:00:00Z wall=/home/me/.eclaude@1791136800
a claimed Pi lane whose turn ended on a session limit records no wall|session|-|events=EVENT usage-limit gh-2 /home/me/.eclaude resets=2026-10-04T18:00:00Z wall=none
control: a Pi lane's row read through the drawn-prefix test records no wall|weekly|pi-wall-as-pane|events=EVENT usage-limit gh-2 /home/me/.eclaude resets=2026-10-04T18:00:00Z wall=none
control: a row test widened to any limit records the session wall|session|pi-wall-any-limit|events=EVENT usage-limit gh-2 /home/me/.eclaude resets=2026-10-04T18:00:00Z wall=/home/me/.eclaude@1791136800
ROWS

echo "=== must-fail control ==="
# Rows read and never handed to the judge: a rowless Pi lane's idle-looking
# pane is read idle, the pane scrape the rows exist to end.
MUTANT_DIR="$TMP_ROOT/pi-lanes-mutant"
MUTANT_WATCH="$(mutant_scripts pi-lanes-mutant/orch oversee-watch)/oversee-watch" || exit 1
ln -s "$REPO_ROOT/skills/github" "$MUTANT_DIR/github"
mutate_file "$MUTANT_WATCH" '"$pane" "" "" "${LANE_ROWS[$i]:-}"' '"$pane" "" "" ""'
new_case pi_mutant
ROOT="$STUB_DIR/wt"
pi_lane "$ROOT"
rows "$ROOT" none
printf '%s\n' "$IDLE_SCREEN" > "$STUB_DIR/pane-gh-2.txt"
WATCH_BIN="$MUTANT_WATCH" watch
assert_eq "events=$(events)" "events=EVENT idle-after-return gh-2" \
  "control: a watch that drops the rows reads a rowless Pi lane idle off its pane" "$STUB_DIR/err"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
