#!/usr/bin/env bash
# Surface: mailbox store snapshots. Inputs: skills/mailbox/scripts/**,
# skills/slack/scripts/lib/mailbox.py and skills/slack/tests/lib/**.
# The unchanged CLI is the output oracle, including complete rows, tracker
# confirmation, logical numbering after compaction and appended tails.
set -uo pipefail
. "$(dirname "$0")/lib/harness.sh"

ROOT="$(sk_new_root store-reader)"
PROBE_RC=0
env -i PATH="$PATH" HOME="$SK_TMP/home" LANG=C PYTHONDONTWRITEBYTECODE=1 \
  GIT_CEILING_DIRECTORIES="$GIT_CEILING_DIRECTORIES" \
  python3 "$SK_ROOT/skills/slack/tests/lib/mailbox_read_probe.py" "${SK_BIN%/*}/lib" "$ROOT" || PROBE_RC=$?
assert_eq "$PROBE_RC" 0 'in-process reader preserves the CLI output and cursor contract'

# The CLI maps overseer mail in a linked worktree to the main checkout.
# Separate tmp directories expose a reader that incorrectly uses the bound
# checkout. A main-root library trap also proves bound-root code ownership.
while IFS='|' read -r mode shape; do
  MAIN_NAME="store-linked-$mode-$shape"
  if [ "$shape" = newline ]; then MAIN_NAME=$'store-linked\n'"$mode-$shape"; fi
  MAIN_ROOT="$(sk_new_root "$MAIN_NAME")"
  git -C "$MAIN_ROOT" -c user.name=Fixture -c user.email=fixture@example.test commit --allow-empty -qm fixture || exit 1
  WORK_ROOT="$SK_TMP/linked checkout-$mode-$shape"
  git -C "$MAIN_ROOT" worktree add --quiet --detach "$WORK_ROOT" HEAD || exit 1
  mkdir -p "$WORK_ROOT/.agents/skills/mailbox" "$WORK_ROOT/tmp"
  ln -s "$SK_ROOT/skills/mailbox/scripts" "$WORK_ROOT/.agents/skills/mailbox/scripts"
  sk_store_fixture "$MAIN_ROOT" 'def read_events(box, jq_defs, previous, receipts=False, timeout=30):
    raise AssertionError("the main checkout must not supply reader code")'
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

sk_summary
