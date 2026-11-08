#!/usr/bin/env bash
# Audit request transport, not proof that a model read its inputs. The stub
# consumes only stdin and read-accessible diff bytes; it runs no Git commands.
. "$(dirname "${BASH_SOURCE[0]}")/lib/stub-cli-world.bash"
. "$(dirname "${BASH_SOURCE[0]}")/lib/install.bash"

PROJ="$TMP_ROOT/proj"
mkdir -p "$PROJ/skills"
second_opinion_install "$SKILL_DIR" "$PROJ/skills"
HERMETIC="$PROJ/skills/second-opinion/scripts/second-opinion"
PACKET=$'CALLER-PACKET\nRun exactly one simple command per tool call.\nRead required.txt completely.\nEND-CALLER-PACKET'
AUDIT_RANGE="" EXPECT_ENDPOINT="" EXPECT_DIFF="" EXPECT_PAGED=""

suite_reset() {
  W_SCRIPT="$HERMETIC"
  # A control may replace only the production entry point in this owned copy.
  if [[ -n "${SECOND_OPINION_AUDIT_CONTROL:-}" ]]; then
    cp "$SECOND_OPINION_AUDIT_CONTROL" "$HERMETIC"
  fi
  AUDIT_RANGE="" EXPECT_ENDPOINT="" EXPECT_DIFF="-" EXPECT_PAGED="-"
  git -C "$WORK" config gc.auto 0
  git -C "$WORK" config maintenance.auto false
}

suite_word() {
  case "$1" in
    linked)
      git -C "$WORK" worktree add -q -b audit-linked "$ROW/linked" HEAD
      WORK="$ROW/linked"
      ;;
    historical)
      printf 'removed-input\n' >"$WORK/retired.txt"
      git -C "$WORK" add retired.txt
      git -C "$WORK" -c commit.gpgsign=false commit -q -m old
      rm "$WORK/retired.txt"
      printf 'pinned-input\n' >"$WORK/pinned.txt"
      git -C "$WORK" add -A
      git -C "$WORK" -c commit.gpgsign=false commit -q -m pinned
      EXPECT_ENDPOINT="$(git -C "$WORK" rev-parse HEAD)" || return 1
      printf 'not-in-range\n' >"$WORK/later.txt"
      git -C "$WORK" add later.txt
      git -C "$WORK" -c commit.gpgsign=false commit -q -m later
      HEAD_SHA="$(git -C "$WORK" rev-parse HEAD)" || return 1
      AUDIT_RANGE='HEAD~2...HEAD~1'
      EXPECT_DIFF='+pinned-input,-removed-input'
      ;;
    large)
      printf 'omitted-input\n' >"$WORK/zretired.txt"
      git -C "$WORK" add zretired.txt
      git -C "$WORK" -c commit.gpgsign=false commit -q -m old
      rm "$WORK/zretired.txt"
      { printf 'first-input\n'; head -c 140000 /dev/zero | tr '\0' x; printf '\nlast-input\n'; } >"$WORK/big.txt"
      git -C "$WORK" add -A
      git -C "$WORK" -c commit.gpgsign=false commit -q -m large
      HEAD_SHA="$(git -C "$WORK" rev-parse HEAD)" || return 1
      EXPECT_ENDPOINT="$HEAD_SHA"
      AUDIT_RANGE='HEAD~1...HEAD'
      EXPECT_DIFF='+first-input'
      EXPECT_PAGED='-omitted-input'
      ;;
    empty-range) AUDIT_RANGE='HEAD...HEAD'; EXPECT_ENDPOINT="$HEAD_SHA" ;;
    *) echo "UNKNOWN-WORD: $1" >&2; exit 2 ;;
  esac
}

argv_for() {
  local exclude
  exclude="$(git -C "$WORK" rev-parse --git-path info/exclude)" || return 1
  printf '%s\n' "$PACKET" >"$WORK/packet.md"
  printf 'required-source\n' >"$WORK/required.txt"
  # Ignore the two caller packet files in the starting binding; they are inputs,
  # not part of the tested diff. file.txt remains the fixture's dirty path.
  printf 'packet.md\nrequired.txt\n' >>"$exclude"
  printf '%s\n' audit --prompt "$WORK/packet.md" --cwd "$WORK" --output "$OUT"
  [[ -z "$AUDIT_RANGE" ]] || printf '%s\n' --range "$AUDIT_RANGE"
}

audit_state() {
  local prompt="$ROW/prompts/prompt-1.txt" binding diff packet endpoint p second continuity=ok
  binding="$(sed -n '/^--- begin audit binding ---$/,/^--- end audit binding ---$/{//d;p;}' "$prompt")" || return 1
  if jq -e --arg cwd "$WORK" --arg head "$HEAD_SHA" --argjson dirty '["file.txt"]' \
    '.cwd == $cwd and .head == $head and .dirty_paths == $dirty' <<<"$binding" >/dev/null 2>&1; then
    binding=ok
  else
    binding=invalid
  fi
  packet="$(head -n 4 "$prompt")" || return 1
  if [[ "$packet" == "$PACKET" ]]; then packet=ok; else packet=invalid; fi
  endpoint="$(jq -r '.qa_metadata.reviewed_head // ""' "$OUT")" || return 1
  if [[ "$endpoint" == "$EXPECT_ENDPOINT" ]]; then endpoint=ok; else endpoint=invalid; fi
  diff="$(sed -n '/^--- begin diff ---$/,/^--- end diff ---$/{/^[+-][^+-]/p;}' "$prompt" | paste -s -d ',' -)" || return 1
  if [[ "${diff:--}" == "$EXPECT_DIFF" ]]; then diff=ok; else diff=invalid; fi
  p="$ROW/prompts/paged-1.txt"
  if [[ "$EXPECT_PAGED" == '-' ]]; then
    [[ -f "$p" ]] && p=unexpected || p=ok
  elif [[ -f "$p" ]]; then
    if [[ "$(sed -n '/^-[^-]/p' "$p")" == "$EXPECT_PAGED" && "$(cat "$ROW/prompts/paged-1.mode")" == '-rw-------' ]]; then
      p=ok
    else
      p=invalid
    fi
  else
    p=missing
  fi
  second="$ROW/prompts/prompt-2.txt"
  if [[ -f "$second" ]]; then
    if [[ -n "$W_STDOUT2" ]]; then
      sed -n '/^--- Original request ---$/,/^--- End of original request ---$/{//d;p;}' "$second" >"$ROW/retried-request"
      cmp -s "$prompt" "$ROW/retried-request" || continuity=invalid
    else
      cmp -s "$prompt" "$second" || continuity=invalid
    fi
  elif [[ -n "$W_STDOUT2" || -n "$W_RC2" ]]; then
    continuity=missing
  fi
  printf 'binding=%s packet=%s endpoint=%s diff=%s paged=%s continuity=%s' "$binding" "$packet" "$endpoint" "$diff" "$p" "$continuity"
}

ROWS='linked historical range supplies binding and deleted bytes without reviewer Git|linked historical
existing-code audit supplies binding without inferring a diff|linked
explicit empty audit range still permits existing-code examination|linked empty-range
oversized audit range retains owner-only omitted deleted bytes for read tools|linked large
format retry carries the complete bound request|linked historical stdout:prose:delivered stdout2:good
replacement target receives the same caller-bound request|linked historical models:claude+lane_a target:- lane:lane_a env:SECOND_OPINION_LANE_A_MODEL=codex rc:7 rc2:0'
# The must-fail control scopes its run to the linked historical transport row.
if [[ "${1:-}" == linked ]]; then ROWS="${ROWS%%$'\n'*}"; fi
n=0
while IFS='|' read -r label world; do
  n=$((n + 1))
  # shellcheck disable=SC2086
  build "row-$n" capture env:SECOND_OPINION_CLAUDE_INLINE_DIFF=0 $world
  rendered="$(run audit)" || exit 1
  rc="${rendered%% *}"
  assert_eq "$rc $(audit_state)" 'rc=0 binding=ok packet=ok endpoint=ok diff=ok paged=ok continuity=ok' "$label"
done <<<"$ROWS"
finish
