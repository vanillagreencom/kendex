#!/usr/bin/env bash
# Installation checks use complete verdict records, not human explanations.
set -euo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf -- "${TMP:?}"' EXIT
. "$TEST_DIR/lib/sandbox.sh"

sandbox
expect_clean 'sound installation' "$DIR"
# Under pipefail the shell writer requires a reader that consumes all output.
rows=0; before=$((PASS + FAIL))
while IFS='|' read -r check value; do
  rows=$((rows + 1))
  printf -v expected 'ok check=%s value=%q' "$check" "$value"
  if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -Fx -- "$expected" >/dev/null; then
    ok "reports $check"
  else
    bad "reports $check (rc=$RC, expected $expected)" "$OUT"
  fi
done <<'ROWS'
workflow-adopted|.github/workflows/review-gate-writer.yml
workflow-equality|.github/workflows/review-gate-writer.yml
settings-known|kendex.settings.toml
settings-env-table|kendex.settings.toml
settings-key-shapes|kendex.settings.toml
settings-values|0
ROWS
[ "$rows" -gt 0 ] && [ "$((PASS + FAIL - before))" -eq "$rows" ] || { printf 'fixture-error=report-table value=%q\n' "$rows" >&2; exit 2; }

rows=0; before=$((PASS + FAIL))
while IFS='|' read -r shape want_rc code value; do
  sandbox
  args=(); entry="$DIR/$VALIDATE_REL"; cwd="$DIR"
  case "$shape" in
    help) args=(--help) ;;
    extra) args=(--settings x) ;;
    outside)
      cwd="$TMP/not-a-repo"; mkdir "$cwd"
      if git -C "$cwd" rev-parse --show-toplevel >/dev/null 2>&1; then
        printf '  skip  outside-repository fixture is inside a Git worktree\n'
        continue
      fi
      entry="$SKILL_DIR/scripts/validate.sh"; value="$cwd" ;;
  esac
  rows=$((rows + 1))
  RC=0
  OUT="$(cd "$cwd" && "$entry" ${args[@]+"${args[@]}"} 2>&1)" || RC=$?
  expected=''
  [ -z "$code" ] || printf -v expected 'review-gate-error=%s value=%q' "$code" "$value"
  if [ "$RC" -eq "$want_rc" ] && { [ -z "$expected" ] || grep -qxF -- "$expected" <<<"$OUT"; }; then
    ok "$shape"
  else
    bad "$shape (rc=$RC, expected $expected)" "$OUT"
  fi
done <<'ROWS'
help|0||
extra|2|unknown-arguments|2
outside|2|repository|
ROWS
[ "$rows" -gt 0 ] && [ "$((PASS + FAIL - before))" -eq "$rows" ] || { printf 'fixture-error=arguments-table value=%q\n' "$rows" >&2; exit 2; }

# Each row changes one source shape. Optional records preserve the original
# predicate/loader and note comparisons. The forbidden note rejects a false
# empty-list report after a loader failure.
rows=0; before=$((PASS + FAIL))
while IFS='~' read -r label action data want check value error_code error_value note_check note_value forbidden; do
  [ "$label" != '' ] || continue
  if [ "$action" = unreadable ] && [ "$(id -u)" -eq 0 ]; then
    printf '  skip  unreadable source requires a non-root reader\n'
    continue
  fi
  rows=$((rows + 1))
  sandbox
  override=''; exported=''
  case "$action" in
    append) printf '%b\n' "$data" >>"$DIR/kendex.settings.toml" ;;
    replace) printf '%b\n' "$data" >"$DIR/kendex.settings.toml" ;;
    nested)
      mkdir -p "$DIR/.kendex"
      printf '%b\n' "$data" >"$DIR/.kendex/settings.toml"
      commit "$DIR" ;;
    exported) settings "$DIR" REVIEW_GATE_MODE bogus; exported=enforce ;;
    untracked|explicit)
      (cd "$DIR" && git rm -q --cached kendex.settings.toml && git commit -q -m "untrack settings")
      [ "$action" != explicit ] || override=kendex.settings.toml ;;
    directory) mkdir "$DIR/nonregular.dir"; override=nonregular.dir ;;
    dangling) ln -s missing.toml "$DIR/dangling.settings.toml"; override=dangling.settings.toml ;;
    nested-directory) mkdir -p "$DIR/.kendex/settings.toml" ;;
    unreadable)
      printf '[env]\nREVIEW_GATE_CONTEXT = "Review gate"\n' >"$DIR/unreadable.settings.toml"
      chmod 000 "$DIR/unreadable.settings.toml"; override=unreadable.settings.toml ;;
    absent) override=absent.settings.toml ;;
    settings-symlink)
      mv "$DIR/kendex.settings.toml" "$DIR/real-settings.toml"
      ln -s real-settings.toml "$DIR/kendex.settings.toml"
      commit "$DIR" ;;
    *) printf 'fixture-error=unknown-action value=%q\n' "$action" >&2; exit 2 ;;
  esac
  if [ "$override" != '' ]; then
    REVIEW_GATE_SETTINGS_FILE="$override" run_validate "$DIR"
  elif [ "$exported" != '' ]; then
    REVIEW_GATE_MODE="$exported" run_validate "$DIR"
  else
    run_validate "$DIR"
  fi
  case "$value" in @/*) value="$DIR/${value#@/}" ;; esac
  case "$note_value" in @/*) note_value="$DIR/${note_value#@/}" ;; esac
  expected=''; diagnostic=''; note=''
  [ -z "$check" ] || printf -v expected '%s check=%s value=%q' "$want" "$check" "$value"
  [ -z "$error_code" ] || printf -v diagnostic '        review-gate-error=%s value=%q' "$error_code" "$error_value"
  [ -z "$note_check" ] || printf -v note 'note check=%s value=%q' "$note_check" "$note_value"
  want_rc=1
  [ "$want" != clean ] || want_rc=0
  if [ "$RC" -eq "$want_rc" ] &&
      { [ -z "$expected" ] || grep -qxF -- "$expected" <<<"$OUT"; } &&
      { [ -z "$diagnostic" ] || grep -qxF -- "$diagnostic" <<<"$OUT"; } &&
      { [ -z "$note" ] || grep -qxF -- "$note" <<<"$OUT"; } &&
      { [ -z "$forbidden" ] || ! grep -q "^note check=$forbidden value=" <<<"$OUT"; } &&
      { [ "$want" != clean ] || { grep -qE '^ok check=[a-z-]+ value=' <<<"$OUT" && ! grep -q '^FAIL check=' <<<"$OUT"; }; }; then
    ok "$label"
  else
    bad "$label (rc=$RC, expected $expected $diagnostic $note)" "$OUT"
  fi
done <<'ROWS'
unknown key~append~REVIEW_GATE_CONTXET = "Review gate"~FAIL~settings-unknown~kendex.settings.toml:REVIEW_GATE_CONTXET~~~~~
caller handle in settings~append~REVIEW_GATE_SETTINGS_FILE = "other.toml"~FAIL~settings-seam~REVIEW_GATE_SETTINGS_FILE~~~~~
illegal mode with predicate diagnostic~append~REVIEW_GATE_MODE = "bogus"~FAIL~settings-values~2~predicate-mode~bogus~~~
numeric bound~append~REVIEW_GATE_SHA_PREFIX_FLOOR = "2"~FAIL~settings-values~2~~~~~
duplicate key~append~REVIEW_GATE_MODE = "off"\nREVIEW_GATE_MODE = "enforce"~FAIL~settings-values~2~~~~~
exported legal mode cannot hide committed error~exported~~FAIL~settings-values~2~~~~~
untracked settings~untracked~~FAIL~settings-untracked~kendex.settings.toml~~~~~
nested unknown key names its source~nested~[env]\nREVIEW_GATE_REVIEW_OBJECT_TRUSTED_LOGIN = "x"~FAIL~settings-unknown~.kendex/settings.toml:REVIEW_GATE_REVIEW_OBJECT_TRUSTED_LOGIN~~~~~
nested mode is unread~nested~[env]\nREVIEW_GATE_MODE = "off"~FAIL~settings-mode-source~.kendex/settings.toml~~~~~
root mode is read~append~REVIEW_GATE_MODE = "off"~clean~~~~~~~
explicit untracked source~explicit~~clean~~~~~settings-explicit~@/kendex.settings.toml~
double-quoted key~append~"REVIEW_GATE_THREADS" = "off"~FAIL~settings-key-shape~kendex.settings.toml:"REVIEW_GATE_THREADS" = "off"~~~~~
single-quoted key~append~'REVIEW_GATE_THREADS' = "off"~FAIL~settings-key-shape~kendex.settings.toml:'REVIEW_GATE_THREADS' = "off"~~~~~
bare key~append~REVIEW_GATE_THREADS = "off"~clean~~~~~~~
dotted key~append~REVIEW_GATE_MODE.typo = "off"~FAIL~settings-key-shape~kendex.settings.toml:REVIEW_GATE_MODE.typo = "off"~~~~~
spaced dotted key~append~REVIEW_GATE_MODE . typo = "off"~FAIL~settings-key-shape~kendex.settings.toml:REVIEW_GATE_MODE . typo = "off"~~~~~
quoted then dotted key~append~"REVIEW_GATE_MODE".typo = "off"~FAIL~settings-key-shape~kendex.settings.toml:"REVIEW_GATE_MODE".typo = "off"~~~~~
dotted then quoted key~append~REVIEW_GATE_THREADS."x" = "off"~FAIL~settings-key-shape~kendex.settings.toml:REVIEW_GATE_THREADS."x" = "off"~~~~~
plain env table~append~[env]\nREVIEW_GATE_THREADS = "off"~clean~~~~~~~
assignment above env table~replace~REVIEW_GATE_THREADS = "off"\n[env]\nREVIEW_GATE_CONTEXT = "Review gate"~FAIL~settings-outside-env~REVIEW_GATE_THREADS~~~~~
assignment under another table~append~\n[notes]\nREVIEW_GATE_THREADS = "off"~FAIL~settings-outside-env~REVIEW_GATE_THREADS~~~~~
header with comment~append~\n[env] # comment\nREVIEW_GATE_THREADS = "off"~FAIL~settings-header~kendex.settings.toml~~~~~
directory override~directory~~FAIL~settings-file-type~@/nonregular.dir~~~~~
dangling override~dangling~~FAIL~settings-file-type~@/dangling.settings.toml~~~~~
nested directory~nested-directory~~FAIL~settings-file-type~.kendex/settings.toml~~~~~
unreadable override~unreadable~~FAIL~settings-unreadable~@/unreadable.settings.toml~~~~~
absent override~absent~~clean~~~~~settings-absent~@/absent.settings.toml~
inline table key~append~container = { REVIEW_GATE_REVIEW_OBJECT_TRUSTED_LOGINS = "trusted[bot]" }~FAIL~settings-key-shape~kendex.settings.toml:container = { REVIEW_GATE_REVIEW_OBJECT_TRUSTED_LOGINS = "trusted[bot]" }~~~~~
key mentioned in value~append~PR_REVIEW_CHECK = "ask about REVIEW_GATE_MODE"~FAIL~settings-key-shape~kendex.settings.toml:PR_REVIEW_CHECK = "ask about REVIEW_GATE_MODE"~~~~~
key without assignment~append~notes = [\n  "REVIEW_GATE_MODE",\n]~FAIL~settings-key-shape~kendex.settings.toml:"REVIEW_GATE_MODE",~~~~~
symlinked settings~settings-symlink~~FAIL~settings-symlink~kendex.settings.toml~~~~~
repository variable as setting~append~REVIEW_GATE_CHECK_RUN_NAME = "CodeRabbit"~FAIL~settings-repository-variable~REVIEW_GATE_CHECK_RUN_NAME~~~~~
lowercase suffix~append~REVIEW_GATE_MODEe = "off"~FAIL~settings-unknown~kendex.settings.toml:REVIEW_GATE_MODEe~~~~~
dashed key returns exact unread line~append~REVIEW_GATE_MODE-x = "off"~FAIL~settings-key-shape~kendex.settings.toml:REVIEW_GATE_MODE-x = "off"~~~~~
malformed comment pair~append~REVIEW_GATE_COMMENT_REVIEWERS = "missing-colon"~FAIL~settings-values~2~predicate-comment-pair~missing-colon~~~
valid comment pair~append~REVIEW_GATE_COMMENT_REVIEWERS = "bot[bot]:Reviewed commit:"~clean~~~~~~~
refused loader value never becomes an empty list~append~REVIEW_GATE_CARRY_FORWARD_EXCLUDE_PROPHYLACTIC = ["a", "b"]~FAIL~carry-load~REVIEW_GATE_CARRY_FORWARD_EXCLUDE_PROPHYLACTIC~settings-syntax~REVIEW_GATE_CARRY_FORWARD_EXCLUDE_PROPHYLACTIC~carry-skipped~1~carry-exclusions-empty
live exclusions~append~REVIEW_GATE_CARRY_FORWARD = "docs"\nREVIEW_GATE_CARRY_FORWARD_EXCLUDE = "AGENTS.md;docs/*"~clean~~~~~~~
unmatched exclusion~append~REVIEW_GATE_CARRY_FORWARD_EXCLUDE = "no-such-directory/*.md"~FAIL~carry-unmatched~no-such-directory/*.md~~~~~
rejected glob retains predicate diagnostic~append~REVIEW_GATE_CARRY_FORWARD_EXCLUDE = "/AGENTS.md"~FAIL~settings-values~2~predicate-pattern~REVIEW_GATE_CARRY_FORWARD_EXCLUDE:/AGENTS.md~~~
prophylactic declaration cannot rescue rejected glob~append~REVIEW_GATE_CARRY_FORWARD_EXCLUDE = "../future/*"\nREVIEW_GATE_CARRY_FORWARD_EXCLUDE_PROPHYLACTIC = "../future/*"~FAIL~settings-values~2~~~~~
dot in filename~append~REVIEW_GATE_CARRY_FORWARD_EXCLUDE = "docs/*.md"~clean~~~~~~~
universal exclusion~append~REVIEW_GATE_CARRY_FORWARD_EXCLUDE = "*"~FAIL~carry-universal~*~~~~~
declared unmatched exclusion is reported~append~REVIEW_GATE_CARRY_FORWARD_EXCLUDE = "no-such-directory/*.md"\nREVIEW_GATE_CARRY_FORWARD_EXCLUDE_PROPHYLACTIC = "no-such-directory/*.md"~clean~~~~~carry-prophylactic~no-such-directory/*.md~
orphan declaration~append~REVIEW_GATE_CARRY_FORWARD_EXCLUDE = "AGENTS.md"\nREVIEW_GATE_CARRY_FORWARD_EXCLUDE_PROPHYLACTIC = "docs/*"~FAIL~carry-declaration-missing~docs/*~~~~~
declaration now matches~append~REVIEW_GATE_CARRY_FORWARD_EXCLUDE = "docs/*"\nREVIEW_GATE_CARRY_FORWARD_EXCLUDE_PROPHYLACTIC = "docs/*"~FAIL~carry-declaration-matched~docs/*~~~~~
ROWS
[ "$rows" -gt 0 ] && [ "$((PASS + FAIL - before))" -eq "$rows" ] || { printf 'fixture-error=settings-table value=%q\n' "$rows" >&2; exit 2; }

rows=0; before=$((PASS + FAIL))
while IFS='|' read -r shape target check value; do
  rows=$((rows + 1))
  sandbox
  path="$DIR/.agents/skills/review-gate/$target"
  case "$shape" in
    mode) chmod -x "$path" ;;
    missing) rm "$path" ;;
    untracked|untracked-target)
      (cd "$DIR" && git rm -q --cached ".agents/skills/review-gate/$target" && git commit -q -m "untrack runtime") ;;
    symlink|symlink-target)
      mv "$path" "$path.real"
      ln -s "${path##*/}.real" "$path"
      commit "$DIR" ;;
    syntax) printf 'if [ then\n' >>"$path" ;;
  esac
  expect_fail "$shape" "$DIR" "$check" "$value"
done <<'ROWS'
mode|scripts/review-writer.sh|runtime-mode|scripts/review-writer.sh
missing|scripts/pr-watch.sh|runtime-missing|scripts/pr-watch.sh
untracked|scripts/pr-watch.sh|runtime-untracked|scripts/pr-watch.sh
symlink|scripts/pr-watch.sh|runtime-symlink|scripts/pr-watch.sh
untracked-target|scripts/review-writer.sh|workflow-target-untracked|.agents/skills/review-gate/scripts/review-writer.sh
symlink-target|scripts/review-writer.sh|workflow-target-symlink|.agents/skills/review-gate/scripts/review-writer.sh
syntax|scripts/review-writer.sh|runtime-syntax|scripts/review-writer.sh
ROWS
[ "$rows" -gt 0 ] && [ "$((PASS + FAIL - before))" -eq "$rows" ] || { printf 'fixture-error=runtime-table value=%q\n' "$rows" >&2; exit 2; }
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
