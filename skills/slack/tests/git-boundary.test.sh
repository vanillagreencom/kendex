#!/usr/bin/env bash
# Lane TMPDIR sits inside a checkout. The reload suite must still read its
# launch directory's settings. Removing the harness ceiling exposes the
# default poll interval from the enclosing repository instead.
set -euo pipefail
. "$(dirname "$0")/lib/harness.sh"

assert_eq "$GIT_CEILING_DIRECTORIES" "${SK_TMP%/*}" "git discovery stops at the physical scratch parent"

LANE="$(sk_new_root lane)"

# Reload edits its script copies. Keep real directories here because cp -R
# would preserve a directory symlink and let those edits reach its target.
MUTANT="$SK_TMP/mutant"
mkdir -p "$MUTANT/skills/slack"
cp -R "$SK_ROOT/skills/slack/tests" "$MUTANT/skills/slack/tests"
cp -R "$SK_ROOT/skills/slack/scripts" "$MUTANT/skills/slack/scripts"
cp -R "$SK_ROOT/skills/slack/systemd" "$MUTANT/skills/slack/systemd"
ln -s "$SK_ROOT/skills/orch" "$MUTANT/skills/orch"
python3 - "$MUTANT/skills/slack/tests/lib/harness.sh" <<'PY' || exit 1
from pathlib import Path
import sys
path = Path(sys.argv[1])
text = path.read_text()
line = 'export GIT_CEILING_DIRECTORIES="${SK_TMP%/*}"\n'
if text.count(line) != 1:
    sys.exit("git-boundary: mutation-match-failed")
# Subject launches still expand the variable under set -u. An empty value
# disables Git's ceiling without aborting at that unrelated shell check.
changed = text.replace(line, 'GIT_CEILING_DIRECTORIES=""\n')
if changed == text:
    sys.exit("git-boundary: mutation-unchanged")
path.write_text(changed)
PY

while read -r name tree; do
  case "$tree" in
    real) SUITE="$SK_ROOT/skills/slack/tests/reload.test.sh" ;;
    mutant) SUITE="$MUTANT/skills/slack/tests/reload.test.sh" ;;
  esac
  RC=0
  env -u GIT_CEILING_DIRECTORIES TMPDIR="$LANE/tmp" "$BASH" "$SUITE" >"$SK_TMP/$name.out" 2>&1 || RC=$?
  OUT="$(cat "$SK_TMP/$name.out")"
  case "$tree" in
    real)
      assert_eq "$RC" "0" "reload passes with scratch inside a repository"
      assert_lacks "$OUT" "  FAIL " "nested reload reports no failed assertion"
      # This suite consumes sk_summary's machine-read result, as run-all does.
      SUMMARY="$(sed -n '/^reload\.test\.sh: [0-9][0-9]* passed, [0-9][0-9]* failed$/p' "$SK_TMP/$name.out")"
      PATTERN='^reload\.test\.sh: [1-9][0-9]* passed, 0 failed$'
      if [[ "$SUMMARY" =~ $PATTERN ]]; then
        ok "nested reload reports completed passing assertions"
      else
        bad "nested reload reports completed passing assertions" "$OUT"
      fi ;;
    mutant)
      if [ "$RC" -ne 0 ]; then ok "control: removing the ceiling makes nested reload fail"
      else bad "control: removing the ceiling makes nested reload fail" "$OUT"; fi
      assert_has "$OUT" $'  FAIL the relay reads the poll interval from the launch checkout\n       expected: 1 | got: 15' \
        "control: the poll assertion reads the enclosing repository's default" ;;
  esac
done <<'ROWS'
bounded real
unbounded mutant
ROWS

sk_summary
