#!/usr/bin/env bash
# Prompt cache efficiency test for pi-claude-bridge.
# Runs a multi-turn conversation and verifies Anthropic prompt caching is working.
# Expects: cacheRead stays nonzero after the first cached turn and cache hit
#   rate stays high. Claude Code may report smaller cacheRead on short tool
#   sub-turns even when the session is reused correctly.
#
# Also checks session sync correctness: consecutive same-provider turns must
# resume the session (Case 3), not rebuild it (Case 4). A rebuild would reset
# prompt caching. This catches the off-by-one cursor bug where pi's post-return
# assistant message append caused syncSharedSession to see 1 "missed" message.

source "$(dirname "$0")/lib/bash-setup.sh"

test_notice test cache-test

setup_test_env "cache-test" ".ndjson"

LOGFILE="$LOGDIR/cache-test.ndjson"

trap cleanup_test_command EXIT

TMPFILE="$LOGDIR/cache-test-scratch.txt"
rm -f "$TMPFILE" "$CLAUDE_BRIDGE_DEBUG_PATH"

test_notice phase conversation "Run the conversation with text and tool use."
run_test_command 180 pi --no-session -ne -e "$DIR" \
  --model "pi-claude/claude-haiku-4-5" \
  --mode json \
  -p "The secret number is 42. Acknowledge briefly." \
     "Write the secret number to $TMPFILE. Just the number, nothing else." \
     "What is 42 * 2? Just the number." \
     "Read $TMPFILE and tell me what's in it." \
     "What was the secret number, what did you write, what did you read, and what was 42*2? One per line." \
  > "$LOGFILE" 2>"$LOGFILE.err" || PI_EXIT=$?
PI_EXIT=${PI_EXIT:-0}

rm -f "$TMPFILE"

if [ -s "$LOGFILE.err" ]; then
  echo ""
  test_notice stderr_log "$LOGFILE.err"
  cat "$LOGFILE.err"
  echo ""
fi

if [ "$PI_EXIT" -ne 0 ]; then
  test_notice command_exit "$PI_EXIT"
  exit 1
fi

echo ""
test_notice phase cache_metrics
echo "---"
printf "%-6s  %8s  %8s  %8s  %8s  %s\n" "Turn" "Input" "CacheRd" "CacheWr" "Output" "CacheHit%"

# Thresholds
MIN_CACHE_HIT_PCT=90
MIN_EXPECTED_TURNS=7    # 5 prompts + 2 tool sub-turns (write + read)
MIN_CASE3_RESUMES=2
EXPECTED_CASE1=1

TURN=0
FAIL=0
AGG_INPUT=0
AGG_CACHE_READ=0
AGG_CACHE_WRITE=0
while IFS= read -r line; do
  TURN=$((TURN + 1))
  INPUT=$(echo "$line" | jq -r '.input')
  CACHE_READ=$(echo "$line" | jq -r '.cacheRead')
  CACHE_WRITE=$(echo "$line" | jq -r '.cacheWrite')
  OUTPUT=$(echo "$line" | jq -r '.output')
  TOTAL_INPUT=$((INPUT + CACHE_READ + CACHE_WRITE))

  if [ "$TOTAL_INPUT" -gt 0 ]; then
    HIT_PCT=$((CACHE_READ * 100 / TOTAL_INPUT))
  else
    HIT_PCT=0
  fi

  printf "%-6s  %8s  %8s  %8s  %8s  %s%%\n" "$TURN" "$INPUT" "$CACHE_READ" "$CACHE_WRITE" "$OUTPUT" "$HIT_PCT"

  # Assertions
  if [ "$TURN" -ge 3 ]; then
    # Turn 3+: cached prompt tokens should be present. Do not require monotonic
    # cacheRead: Claude Code usage accounting can report smaller cached context
    # on short tool sub-turns while preserving the same session and high cache
    # hit rate.
    if [ "$CACHE_READ" -le 0 ]; then
      test_notice cache_read "$CACHE_READ" "Turn $TURN did not report cached tokens."
      FAIL=$((FAIL + 1))
    fi
    # Hit rate is asserted on the AGGREGATE across turns 3+, not per turn: the
    # Claude Code CLI re-serializes a tail segment of the prompt at one tool
    # sub-turn boundary (observed on both SDK 0.3.215 and 0.3.220 at the same
    # ~32k prefix point), so that single turn's rate tracks the CLI's prompt
    # size, not bridge correctness — 0.3.220's ~6k larger prompt dropped it
    # from 92% to 78% with identical session reuse. A real caching break still
    # fails the aggregate hard (cacheRead collapses toward 0%), and the
    # per-turn cacheRead>0 and session-sync assertions below stay strict.
    AGG_INPUT=$((AGG_INPUT + INPUT))
    AGG_CACHE_READ=$((AGG_CACHE_READ + CACHE_READ))
    AGG_CACHE_WRITE=$((AGG_CACHE_WRITE + CACHE_WRITE))
  fi
done < <(jq -c 'select(.type == "turn_end") | .message.usage | {input, cacheRead, cacheWrite, output}' "$LOGFILE")

echo "---"

AGG_TOTAL=$((AGG_INPUT + AGG_CACHE_READ + AGG_CACHE_WRITE))
if [ "$AGG_TOTAL" -gt 0 ]; then
  AGG_HIT_PCT=$((AGG_CACHE_READ * 100 / AGG_TOTAL))
else
  AGG_HIT_PCT=0
fi
test_notice cache_hit_pct "$AGG_HIT_PCT"
if [ "$AGG_HIT_PCT" -lt $MIN_CACHE_HIT_PCT ]; then
  test_notice cache_hit_pct "$AGG_HIT_PCT" "Expected at least $MIN_CACHE_HIT_PCT percent."
  FAIL=$((FAIL + 1))
fi

if [ "$TURN" -lt $MIN_EXPECTED_TURNS ]; then
  test_notice turns "$TURN" "Expected at least $MIN_EXPECTED_TURNS turns."
  FAIL=$((FAIL + 1))
fi

# --- Assert session resume (no spurious rebuilds) ---
# With the off-by-one cursor bug, every follow-up turn triggered a rebuild
# instead of a resume, because pi appends the final assistant message after
# streamSimple returns, making the cursor lag by 1.
#
# Parses the "syncResult: path=<reuse|rebuild|clean-start> sessionId=<uuid>"
# marker emitted by syncSharedSession at the end of each call. Gives us both
# the distribution and sessionId stability in one pass.

echo ""
test_notice phase session_sync

CLEAN_START_COUNT=0
REUSE_COUNT=0
REBUILD_COUNT=0
declare -a SESSION_IDS=()

while IFS= read -r line; do
  path=$(echo "$line" | sed -nE 's/.*syncResult: path=([a-z-]+).*/\1/p')
  sid=$(echo "$line" | sed -nE 's/.*sessionId=([a-f0-9-]+).*/\1/p')
  case "$path" in
    clean-start) CLEAN_START_COUNT=$((CLEAN_START_COUNT + 1));;
    reuse)       REUSE_COUNT=$((REUSE_COUNT + 1));;
    rebuild)     REBUILD_COUNT=$((REBUILD_COUNT + 1));;
  esac
  if [ -n "$sid" ]; then
    SESSION_IDS+=("$sid")
  fi
done < <(grep "syncResult:" "$CLAUDE_BRIDGE_DEBUG_PATH" 2>/dev/null || true)

UNIQUE_SIDS=$(printf "%s\n" "${SESSION_IDS[@]}" | sort -u | grep -c . || true)
UNIQUE_SIDS=${UNIQUE_SIDS:-0}

test_notice clean_starts "$CLEAN_START_COUNT"
test_notice reuses "$REUSE_COUNT"
test_notice rebuilds "$REBUILD_COUNT"
test_notice session_ids "$UNIQUE_SIDS"

if [ "$CLEAN_START_COUNT" -ne $EXPECTED_CASE1 ]; then
  test_notice clean_starts "$CLEAN_START_COUNT" "Expected $EXPECTED_CASE1 clean start."
  FAIL=$((FAIL + 1))
fi

if [ "$REBUILD_COUNT" -gt 0 ]; then
  test_notice rebuilds "$REBUILD_COUNT" "Consecutive provider turns must reuse the session."
  echo "    Likely cause: off-by-one cursor — trailing assistant message misidentified as missed"
  FAIL=$((FAIL + 1))
fi

if [ "$REUSE_COUNT" -lt $MIN_CASE3_RESUMES ]; then
  test_notice reuses "$REUSE_COUNT" "Expected at least $MIN_CASE3_RESUMES reuses."
  FAIL=$((FAIL + 1))
fi

# Same-provider flow should never produce more than 1 distinct sessionId:
# one created on first turn (or none for clean-start), reused thereafter.
# A failure that churns UUIDs per turn would surface here even if the
# distribution checks above still passed.
if [ "$UNIQUE_SIDS" -gt 1 ]; then
  test_notice session_ids "$UNIQUE_SIDS" "Expected at most one session ID."
  FAIL=$((FAIL + 1))
fi

# --- Summary ---

echo ""
if [ "$FAIL" -eq 0 ]; then
  test_notice test_exit 0
else
  test_notice failed "$FAIL"
  test_notice log "$LOGFILE"
  test_notice debug_log "$CLAUDE_BRIDGE_DEBUG_PATH"
  exit 1
fi
