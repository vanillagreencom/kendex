#!/usr/bin/env bash
# oversee-watch's directive receipts: what a lane's to-lane.cursor makes the
# watch say about the directives the overseer sent it. The cursor is the
# receipt, whichever of the lane's read paths moved it. The real `lane-mail`
# writes and reads each mailbox; the rest of the sandbox is
# lib/oversee-watch-harness.sh.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"

# shellcheck source=lib/oversee-watch-harness.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/oversee-watch-harness.sh"

LANE_MAIL="$REPO_ROOT/skills/orch/scripts/lane-mail"
HEARTBEAT='EVENT heartbeat loops=1 interval=0s since=none'

echo "=== oversee-watch directive receipts ==="

mail_reset() { # ITEM
  rm -rf -- "${CASE_REPO_ROOT:?}/tmp/lane-mail"
  mkdir -p -- "$CASE_REPO_ROOT/tmp/lane-mail/$1"
}
# The overseer's directive to ITEM; prints its id.
direct() { # ITEM TEXT
  printf '%s\n' "$2" > "$TMP_ROOT/directive.txt"
  (cd "$CASE_REPO_ROOT" && "$LANE_MAIL" send --item "$1" --root "$CASE_REPO_ROOT" --directive \
    --file "$TMP_ROOT/directive.txt") | sed -n 's/^lane-mail: sent item=[^ ]* id=\([^ ]*\) .*/\1/p'
}
# The lane's own read at a wait point, which moves its cursor.
lane_reads() { # ITEM
  (cd "$CASE_REPO_ROOT" && "$LANE_MAIL" inbox --item "$1" >/dev/null)
}
# One run's receipt lines for ITEM, their event words joined, or the first
# line when there are none.
receipts() { # ITEM [WATCH_BIN] [ENV...]
  local item="$1" bin="${2:-}" out
  shift
  [[ $# -eq 0 ]] || shift
  out="$(WATCH_BIN="$bin" run_watch "$@" -- --max-loops 1 --item "$item" 2>"$STUB_DIR/receipts.err")"
  RECEIPTS="$(grep -E "^EVENT directive-(read|unread) $item " <<<"$out" | sed -E 's/ age=[0-9]+$/ age=N/' | paste -sd '|' -)" \
    || RECEIPTS="$(head -1 <<<"$out")"
}

read_sequence() { # [WATCH_BIN]
  local bin="${1:-}"
  mail_reset KEN-80
  receipts KEN-80 "$bin"
  READ_FIRST="$RECEIPTS"
  READ_ID="$(direct KEN-80 'Rebase onto main.')"
  receipts KEN-80 "$bin" ORCH_DIRECTIVE_UNREAD_SECS=3600
  READ_YOUNG="$RECEIPTS"
  lane_reads KEN-80
  receipts KEN-80 "$bin"
  READ_AFTER="$RECEIPTS"
  receipts KEN-80 "$bin"
  READ_AGAIN="$RECEIPTS"
}
new_case receipts_read
read_sequence
assert_eq "$READ_FIRST|$READ_YOUNG" "$HEARTBEAT|$HEARTBEAT" \
  "a lane with nothing sent and one with a directive younger than the age say nothing" "$STUB_DIR/receipts.err"
assert_eq "$READ_AFTER" "EVENT directive-read KEN-80 $READ_ID" \
  "the lane's cursor passing the directive is its receipt, reported as directive-read" "$STUB_DIR/receipts.err"
assert_eq "$READ_AGAIN" "$HEARTBEAT" "and reported once" "$STUB_DIR/receipts.err"

unread_sequence() { # [WATCH_BIN]
  local bin="${1:-}"
  mail_reset KEN-81
  receipts KEN-81 "$bin"
  UNREAD_ID="$(direct KEN-81 'Stop and rebase.')"
  receipts KEN-81 "$bin" ORCH_DIRECTIVE_UNREAD_SECS=0
  UNREAD_FIRST="$RECEIPTS"
  receipts KEN-81 "$bin" ORCH_DIRECTIVE_UNREAD_SECS=0
  UNREAD_AGAIN="$RECEIPTS"
  lane_reads KEN-81
  receipts KEN-81 "$bin" ORCH_DIRECTIVE_UNREAD_SECS=0
  UNREAD_READ="$RECEIPTS"
}
new_case receipts_unread
unread_sequence
assert_eq "$UNREAD_FIRST|$UNREAD_AGAIN|$UNREAD_READ" \
  "EVENT directive-unread KEN-81 $UNREAD_ID age=N|$HEARTBEAT|EVENT directive-read KEN-81 $UNREAD_ID" \
  "a directive past the age the cursor has not passed is directive-unread once, then directive-read when read" \
  "$STUB_DIR/receipts.err"

# A lane first watched after it read its mail: the watch starts from its
# cursor, so no directive it read before is replayed as news.
new_case receipts_first_watch
mail_reset KEN-82
direct KEN-82 'Old news.' >/dev/null
lane_reads KEN-82
receipts KEN-82
assert_eq "$RECEIPTS" "$HEARTBEAT" "a lane first watched is taken as having read up to its cursor" "$STUB_DIR/receipts.err"

# Must-fail inverses: the cursor not read, so no directive is ever read; and
# the unread line not remembered, so it comes back on every run.
MUTANT_DIR="$TMP_ROOT/mutant"
mkdir -p "$MUTANT_DIR/orch"
cp -R "$REPO_ROOT/skills/orch/scripts" "$MUTANT_DIR/orch/scripts"
ln -s "$REPO_ROOT/skills/github" "$MUTANT_DIR/github"
receipts_mutant() { # NAME OLD NEW
  python3 - "$REPO_ROOT/skills/orch/scripts/oversee-watch" "$MUTANT_DIR/orch/scripts/oversee-watch-$1" "$2" "$3" <<'PY'
import sys
src, out, old, new = sys.argv[1:]
s = open(src).read()
assert s.count(old) == 1, "receipts mutant pattern: " + old
open(out, "w").write(s.replace(old, new))
PY
  chmod +x "$MUTANT_DIR/orch/scripts/oversee-watch-$1"
}
receipts_mutant cursorless '    lane_read="${BASH_REMATCH[1]}"' '    lane_read=0'
receipts_mutant forgetful '        unread_at="$line"' '        :'
new_case receipts_read_mutant
read_sequence "$MUTANT_DIR/orch/scripts/oversee-watch-cursorless"
assert_eq "$READ_AFTER" "$HEARTBEAT" "control: with the cursor unread, a directive the lane read is never reported" \
  "$STUB_DIR/receipts.err"
new_case receipts_unread_mutant
unread_sequence "$MUTANT_DIR/orch/scripts/oversee-watch-forgetful"
assert_eq "$UNREAD_AGAIN" "EVENT directive-unread KEN-81 $UNREAD_ID age=N" \
  "control: with the reported line forgotten, the unread directive is reported on every run" "$STUB_DIR/receipts.err"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
