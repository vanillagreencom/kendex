#!/usr/bin/env bash
# Surface: mailbox store snapshots. Inputs: skills/mailbox/scripts/**,
# skills/slack/scripts/lib/**, skills/slack/tests/lib/** and
# skills/slack/tests/fixtures/mailbox-pre-read-events/**.
# The unchanged CLI is the output oracle, including complete rows, tracker
# confirmation, logical numbering after compaction and appended tails.
set -uo pipefail
. "$(dirname "$0")/lib/harness.sh"

for format in current historical bound-reader; do
ROOT="$(sk_new_root "store-reader-$format")"
[ "$format" = current ] || sk_historical_mailbox "$ROOT"
if [ "$format" = bound-reader ]; then
  sk_mutant bound-reader mailbox.py 'path = MAILBOX_READ_FILES\[0\]' \
    'path = self.root / LANE_MAIL.parent / "lib/lane-mail-store.py"'
fi
PROBE_RC=0
env -i PATH="$PATH" HOME="$SK_TMP/home" LANG=C PYTHONDONTWRITEBYTECODE=1 \
  GIT_CEILING_DIRECTORIES="$GIT_CEILING_DIRECTORIES" \
  python3 "$SK_ROOT/skills/slack/tests/lib/mailbox_read_probe.py" "${SK_BIN%/*}/lib" "$ROOT" || PROBE_RC=$?
if [ "$format" = bound-reader ]; then
  sk_assert_red "$PROBE_RC" 0 'control: importing the historical bound reader fails the same output probe'
else
  assert_eq "$PROBE_RC" 0 "$format: in-process reader preserves the CLI output and cursor contract"
fi
sk_bin_reset
done

# The CLI maps overseer mail in a linked worktree to the main checkout.
# Separate tmp directories expose a reader that incorrectly uses the bound
# checkout. Historical reader code in both roots cannot supply read_events.
while IFS='|' read -r mode shape; do
  MAIN_NAME="store-linked-$mode-$shape"
  if [ "$shape" = newline ]; then MAIN_NAME=$'store-linked\n'"$mode-$shape"; fi
  MAIN_ROOT="$(sk_new_root "$MAIN_NAME")"
  git -C "$MAIN_ROOT" -c user.name=Fixture -c user.email=fixture@example.test commit --allow-empty -qm fixture || exit 1
  WORK_ROOT="$SK_TMP/linked checkout-$mode-$shape"
  git -C "$MAIN_ROOT" worktree add --quiet --detach "$WORK_ROOT" HEAD || exit 1
  mkdir -p "$WORK_ROOT/.agents/skills/mailbox" "$WORK_ROOT/.agents/skills/orch" "$WORK_ROOT/tmp"
  cp -R "$SK_ROOT/skills/slack/tests/fixtures/mailbox-pre-read-events/scripts" "$WORK_ROOT/.agents/skills/mailbox/scripts"
  ln -s "$SK_ROOT/skills/orch/scripts" "$WORK_ROOT/.agents/skills/orch/scripts"
  sk_historical_mailbox "$MAIN_ROOT"
  if [ "$mode" = bound-box ]; then
    sk_mutant linked-bound-box mailbox.py 'self\.box = Path\(mailbox_root\) / "tmp" / "lane-mail" / "overseer"' \
      'self.box = self.root / "tmp" / "lane-mail" / "overseer" # Path(mailbox_root)'
  fi
  PROBE_RC=0
  env -i PATH="$PATH" HOME="$SK_TMP/home" LANG=C PYTHONDONTWRITEBYTECODE=1 \
    GIT_CEILING_DIRECTORIES="$GIT_CEILING_DIRECTORIES" \
    python3 "$SK_ROOT/skills/slack/tests/lib/mailbox_read_probe.py" "${SK_BIN%/*}/lib" "$WORK_ROOT" "$MAIN_ROOT" \
    >"$SK_TMP/linked-$mode-$shape.log" 2>&1 || PROBE_RC=$?
  if [ "$mode" = production ]; then
    assert_eq "$PROBE_RC" 0 "$shape: linked worktree events and receipts match the actual CLI"
    [ "$PROBE_RC" -eq 0 ] || cat "$SK_TMP/linked-$mode-$shape.log"
  else
    sk_assert_red "$PROBE_RC" 0 'control: the bound checkout mailbox fails the same CLI equivalence probe'
  fi
  sk_bin_reset
done <<'ROWS'
production|plain
production|newline
bound-box|plain
ROWS

CONTROL="$(sk_new_root store-numbering-control)"
sk_store_fixture "$CONTROL" 'def read_events(box, jq_defs, previous, receipts=False, timeout=30):
    rows, receipt = _read_events(box, jq_defs, previous, receipts=receipts, timeout=timeout)
    if Path(str(box / "to-overseer.jsonl") + ".numbering").exists():
        rows = [dict(row, line=index + 1) for index, row in enumerate(rows)]
    return rows, receipt'
PROBE_RC=0
env -i PATH="$PATH" HOME="$SK_TMP/home" LANG=C PYTHONDONTWRITEBYTECODE=1 \
  GIT_CEILING_DIRECTORIES="$GIT_CEILING_DIRECTORIES" \
  python3 "$SK_ROOT/skills/slack/tests/lib/mailbox_read_probe.py" "${SK_BIN%/*}/lib" "$CONTROL" \
  >"$SK_TMP/numbering-control.log" 2>&1 || PROBE_RC=$?
sk_assert_red "$PROBE_RC" 0 'control: physical numbering fails the same output-equivalence assertion'

while IFS='|' read -r name pattern replacement; do
  CONTROL="$(sk_new_root "store-$name-control")"
  sk_store_mutant "$CONTROL" "$pattern" "$replacement"
  PROBE_RC=0
  env -i PATH="$PATH" HOME="$SK_TMP/home" LANG=C PYTHONDONTWRITEBYTECODE=1 \
    GIT_CEILING_DIRECTORIES="$GIT_CEILING_DIRECTORIES" \
    python3 "$SK_ROOT/skills/slack/tests/lib/mailbox_read_probe.py" "${SK_BIN%/*}/lib" "$CONTROL" \
    >"$SK_TMP/$name-control.log" 2>&1 || PROBE_RC=$?
  sk_assert_red "$PROBE_RC" 0 "$name: removing the reader rule fails the same probe"
done <<'ROWS'
cache|previous["stamp"] == before|True
safety|if path.is_symlink() or path.exists() and not (path.is_dir() if directory else path.is_file()):|if False:
stability|if retry or writer() or before != stamp():|if retry or writer():
deadline|if time.monotonic() >= deadline:|if False:
pair-lock|fcntl.flock(fd, fcntl.LOCK_EX|None # fcntl.flock(fd, fcntl.LOCK_EX
pair-bound|or time.monotonic() >= deadline|or False
ROWS

sk_fake_start
for format in current historical; do
  ROOT="$(sk_new_root "relay-format-$format")"
  [ "$format" = current ] || sk_historical_mailbox "$ROOT"
  sk_bin_reset
  sk_bind "$ROOT"
  sk_poll "$ROOT"
  CH="$(sk_channel "$ROOT")"
  WRITER="$ROOT/.agents/skills/mailbox/scripts/lane-mail"
  NOTICE_FILE="$(sk_text "notice-$format" "Mailbox notice $format.")"
  ASK_FILE="$(sk_text "ask-$format" "Mailbox ask $format?")"
  (cd "$ROOT" && "$WRITER" notice --item overseer --to owner --file "$NOTICE_FILE") >/dev/null || exit 1
  (cd "$ROOT" && "$WRITER" ask --item overseer --to owner --file "$ASK_FILE" --options yes,no --recommend no) >/dev/null || exit 1
  sk_poll "$ROOT"
  assert_eq "$RC=$(asks "$CH" "Mailbox notice $format.")=$(asks "$CH" "Mailbox ask $format?")" \
    '0=1=1' "$format: the relay posts the actual writer's owner notice and ask"
  DIRECTIVE="$(sk_inject "$CH" U001 "Catch-up directive $format.")"
  sk_poll "$ROOT"
  assert_eq "$RC=$(landed "$ROOT" "$CH:$DIRECTIVE" 1)" "0=Catch-up directive $format." \
    "$format: catch-up writes through the bound public writer"
  (cd "$ROOT" && "$WRITER" inbox --item overseer) >/dev/null || exit 1
  sk_poll "$ROOT"
  assert_eq "$RC=$(sk_reactions "$CH" "$DIRECTIVE")" \
    '0=white_check_mark' "$format: the actual writer's read cursor settles the receipt reaction"
done

sk_summary
