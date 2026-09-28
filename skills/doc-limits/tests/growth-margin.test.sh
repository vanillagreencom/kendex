#!/usr/bin/env bash
# Pins for doc-limits --against: a document the change grows into the margin
# under its limit fails, and a run without --against judges the limit alone.
#
# Two pull requests that each grow one document pass their own runs and meet
# over its limit only in the merge group that carries both. The pull request
# run passes --against with the tree it is measured from, the merge commit's
# first parent, and fails the growth while the document can still be split;
# the merge group run passes no --against, so a group that fits merges.
set -euo pipefail
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE
unset DOC_LIMITS_CLASSES DOC_LIMITS_DEFAULT_CLASSES DOC_LIMITS_EXCLUDES DOC_LIMITS_SETTINGS_FILE DOC_LIMITS_MARGIN_PCT
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_COMMAND="$(cd "$TEST_DIR/../scripts" && pwd)/doc-limits"
TMP="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf -- "${TMP:?}"' EXIT
export HOME="$TMP/home"
mkdir -p "$HOME"
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL="$HOME/.gitconfig"
: >"$GIT_CONFIG_GLOBAL"
R="$TMP/repo"
mkdir -p "$R"
git -C "$R" -c init.defaultBranch=main init -q
git -C "$R" config user.email test@example.com
git -C "$R" config user.name test
git -C "$R" config gc.auto 0
git -C "$R" config maintenance.auto false
printf '[]\n' >"$R/.kendex-generated.json"
git -C "$R" add .kendex-generated.json

# One 1 KiB class: at the default 2 percent the margin is 20 bytes, so a
# grown document of 1005 to 1024 bytes fails under --against.
export DOC_LIMITS_SETTINGS_FILE=/dev/null
export DOC_LIMITS_CLASSES='*.md=1k'
export DOC_LIMITS_DEFAULT_CLASSES=''

PASS=0
FAIL=0
check() { # LABEL WANT-RC WANT-FIRST-LINE RC OUT
  local first="${5%%$'\n'*}"
  if [ "$4" = "$2" ] && [ "$first" = "$3" ]; then
    PASS=$((PASS + 1)); printf '  ok: %s\n' "$1"
  else
    FAIL=$((FAIL + 1)); printf '  FAIL: %s\n    want: rc=%s %s\n    got:  rc=%s\n%s\n' "$1" "$2" "$3" "$4" "$5"
  fi
}

# Commits doc.md at PRIOR bytes ("-" for absent), then writes and stages NOW
# bytes, as a pull request tree tracks it. Runs COMMAND in MODE with PCT as
# DOC_LIMITS_MARGIN_PCT ("-" for unset, "empty" for the empty string). Sets
# RC and OUT.
scenario() { # COMMAND PRIOR NOW PCT MODE
  local cmd="$1" prior="$2" now="$3" pct="$4" mode="$5" base
  rm -f -- "$R/doc.md"
  [ "$prior" = - ] || head -c "$prior" /dev/zero | tr '\0' x >"$R/doc.md"
  git -C "$R" add -A
  git -C "$R" commit -q --allow-empty -m base
  base="$(git -C "$R" rev-parse HEAD)"
  head -c "$now" /dev/zero | tr '\0' x >"$R/doc.md"
  git -C "$R" add doc.md
  set --
  case "$mode" in
    ceiling) ;;
    against) set -- --against "$base" ;;
    staged) set -- --staged --against "$base" ;;
    bad-ref) set -- --against no-such-ref ;;
    empty-ref) set -- --against "" ;;
    unstaged) git -C "$R" reset -q -- doc.md; set -- --against "$base" ;;
    *) printf 'harness: unknown mode %s\n' "$mode" >&2; exit 2 ;;
  esac
  [ "$pct" != empty ] || pct=""
  RC=0
  if [ "$pct" = - ]; then
    OUT="$(cd "$R" && "$cmd" "$@" 2>&1)" || RC=$?
  else
    OUT="$(cd "$R" && DOC_LIMITS_MARGIN_PCT="$pct" "$cmd" "$@" 2>&1)" || RC=$?
  fi
}

NEAR='notice=document-near-limit path=doc.md'
OVER='notice=document-over-limit path=doc.md'
OK='notice=documents-checked count=1'

printf '%s\n' doc-limits-growth-margin
ROWS=0
while IFS='|' read -r label prior now pct mode rc first; do
  case "$first" in
    NEAR) first="$NEAR" ;;
    OVER) first="$OVER" ;;
    OK) first="$OK" ;;
  esac
  scenario "$SOURCE_COMMAND" "$prior" "$now" "$pct" "$mode"
  check "$label" "$rc" "$first" "$RC" "$OUT"
  ROWS=$((ROWS + 1))
done <<'ROWS'
a pull request growing a document to one byte under its limit fails|900|1023|-|against|1|NEAR
the merge group judging the same tree passes|900|1023|-|ceiling|0|OK
growth to the margin's lower edge passes|900|1004|-|against|0|OK
growth one byte into the margin fails|900|1005|-|against|1|NEAR
a document left unchanged inside the margin passes|1023|1023|-|against|0|OK
a document shrunk inside the margin passes|1023|1010|-|against|0|OK
a document absent from the ref counts as grown|-|1010|-|against|1|NEAR
a document over its limit reports the limit first|900|1025|-|against|1|OVER
staged growth into the margin fails|900|1023|-|staged|1|NEAR
a margin of 0 keeps the limit alone|900|1023|0|against|0|OK
a margin of 10 percent widens the band|900|923|10|against|1|NEAR
a margin setting is read only under --against|900|1023|abc|ceiling|0|OK
a non-numeric margin is refused|900|1023|abc|against|2|error=margin-pct-invalid value=abc
a margin of 100 is refused|900|1023|100|against|2|error=margin-pct-invalid value=100
a zero-padded margin is refused|900|1023|08|against|2|error=margin-pct-invalid value=08
an empty margin is refused|900|1023|empty|against|2|error=margin-pct-invalid value=''
a ref that names no commit is refused|900|1023|-|bad-ref|2|error=against-ref-invalid ref=no-such-ref
an empty ref is refused|900|1023|-|empty-ref|2|error=against-ref-empty ref=''
an unstaged edit counts as growth once staged|900|1023|-|unstaged|0|OK
ROWS
if [ "$ROWS" -lt 19 ]; then
  printf 'FAIL: ROWS executed %s rows, fewer than its 19\n' "$ROWS" >&2
  exit 1
fi

has_line() { # LABEL LINE: some line of OUT after its first equals LINE
  case "
${OUT#*$'\n'}
" in
    *"
$2
"*) PASS=$((PASS + 1)); printf '  ok: %s\n' "$1" ;;
    *) FAIL=$((FAIL + 1)); printf '  FAIL: %s: no line <%s> after the first\n%s\n' "$1" "$2" "$OUT" ;;
  esac
}
lacks_text() { # LABEL TEXT: no part of OUT holds TEXT
  case "$OUT" in
    *"$2"*) FAIL=$((FAIL + 1)); printf '  FAIL: %s: output holds <%s>\n%s\n' "$1" "$2" "$OUT" ;;
    *) PASS=$((PASS + 1)); printf '  ok: %s\n' "$1" ;;
  esac
}

# A near-limit finding names the docs-writing rule for its class, as an
# over-limit one does.
scenario "$SOURCE_COMMAND" 900 1023 - against
check 'a near-limit finding leads the output' 1 "$NEAR" "$RC" "$OUT"
has_line 'a near-limit finding names its docs-writing rule' 'notice=document-rule rule=docs-writing/SKILL.md#per-file-type'

# Each document is judged against its own size in the ref: of a.md grown into
# the margin and b.md left inside it, a.md alone is named.
rm -f -- "$R/doc.md"
head -c 900 /dev/zero | tr '\0' x >"$R/a.md"
head -c 1023 /dev/zero | tr '\0' x >"$R/b.md"
git -C "$R" add -A
git -C "$R" commit -q -m base
PAIR_BASE="$(git -C "$R" rev-parse HEAD)"
head -c 1023 /dev/zero | tr '\0' x >"$R/a.md"
git -C "$R" add a.md
RC=0
OUT="$(cd "$R" && "$SOURCE_COMMAND" --against "$PAIR_BASE" 2>&1)" || RC=$?
check 'of two documents inside the margin, the grown one is named' 1 'notice=document-near-limit path=a.md' "$RC" "$OUT"
has_line 'of two documents inside the margin, one is counted' 'notice=documents-over-limit count=1'
lacks_text 'of two documents inside the margin, the unchanged one is not named' 'path=b.md'
rm -f -- "$R/a.md" "$R/b.md"

# Growth compares stored blobs. An unchanged crlf.md checks out with CRLF line
# ends, 1010 bytes in the worktree over its 1000-byte blob, inside the margin
# and under the limit; it is judged on the limit alone.
crlf_case() { # COMMAND: sets RC and OUT
  local i=0 base
  rm -f -- "$R/crlf.md" "$R/.gitattributes"
  printf 'crlf.md text eol=crlf\n' >"$R/.gitattributes"
  while [ "$i" -lt 10 ]; do
    head -c 99 /dev/zero | tr '\0' x >>"$R/crlf.md"
    printf '\r\n' >>"$R/crlf.md"
    i=$((i + 1))
  done
  git -C "$R" add -A
  git -C "$R" commit -q -m base
  base="$(git -C "$R" rev-parse HEAD)"
  RC=0
  OUT="$(cd "$R" && "$1" --against "$base" 2>&1)" || RC=$?
  rm -f -- "$R/crlf.md" "$R/.gitattributes"
}
crlf_case "$SOURCE_COMMAND"
check 'an unchanged document whose checkout adds CRLF bytes inside the margin passes' 0 "$OK" "$RC" "$OUT"

# One control per rule the margin adds: a copy of the command with OLD
# replaced by NEW keeps the matched text and loses that rule, and the row
# that pins it must go red.
mutant() { # NAME OLD NEW: copy the command with OLD, which occurs once, replaced
  local root="$TMP/$1" text rest
  mkdir -p "$root/skills/doc-limits"
  cp -R "$TEST_DIR/../scripts" "$root/skills/doc-limits/scripts"
  ln -s "$TEST_DIR/../../commit-guards" "$root/skills/commit-guards"
  MUTANT="$root/skills/doc-limits/scripts/doc-limits"
  text="$(cat -- "$MUTANT")"
  rest="${text#*"$2"}"
  if [ "$rest" = "$text" ]; then
    printf 'harness: mutant %s: pattern not found\n' "$1" >&2; exit 2
  fi
  case "$rest" in *"$2"*) printf 'harness: mutant %s: pattern occurs more than once\n' "$1" >&2; exit 2 ;; esac
  printf '%s\n' "${text%%"$2"*}$3$rest" >"$MUTANT"
  if [ "$(cat -- "$MUTANT")" = "$text" ]; then
    printf 'harness: mutant %s: edit changed nothing\n' "$1" >&2; exit 2
  fi
}
control() { # LABEL PRIOR NOW PCT MODE WANT-RC WANT-FIRST-LINE: the mutant's run must miss it
  local label="$1"
  shift
  scenario "$MUTANT" "$1" "$2" "$3" "$4"
  if [ "$RC" = "$5" ] && [ "${OUT%%$'\n'*}" = "$6" ]; then
    FAIL=$((FAIL + 1)); printf '  FAIL: %s: the mutant still gives rc=%s %s\n' "$label" "$5" "$6"
  else
    PASS=$((PASS + 1)); printf '  ok: %s\n' "$label"
  fi
}

mutant no-margin 'elif [ -n "$AGAINST_OID" ]' 'elif false && [ -n "$AGAINST_OID" ]'
control 'must-fail: without the margin rule, growth to one byte under the limit passes' 900 1023 - against 1 "$NEAR"

mutant no-growth-test '[ "$stored" -gt "$prior" ] &&' '{ [ "$stored" -gt "$prior" ] || true; } &&'
control 'must-fail: without the growth test, an unchanged document inside the margin fails' 1023 1023 - against 0 "$OK"

mutant measured-growth '[ "$stored" -gt "$prior" ]' '[ "$n" -gt "$prior" ]'
crlf_case "$MUTANT"
if [ "$RC" = 0 ] && [ "${OUT%%$'\n'*}" = "$OK" ]; then
  FAIL=$((FAIL + 1)); printf '  FAIL: %s\n' 'must-fail: with growth read from the worktree size, the CRLF document still passes'
else
  PASS=$((PASS + 1)); printf '  ok: %s\n' 'must-fail: with growth read from the worktree size, an unchanged CRLF document fails'
fi

mutant absent-not-grown '"commit "*) prior=0 ;;' '"commit "*) prior="$n" ;;'
control 'must-fail: without the absent-document rule, a new document inside the margin passes' - 1010 - against 1 "$NEAR"

mutant margin-always-read $'MARGIN_PCT=0\nif [ -n "$AGAINST_OID" ]; then' $'MARGIN_PCT=0\nif true || [ -n "$AGAINST_OID" ]; then'
control 'must-fail: with the margin read on every run, a bad margin refuses a run without --against' 900 1023 abc ceiling 0 "$OK"

mutant no-margin-refusal 'config_error margin-pct-invalid' ': config_error margin-pct-invalid'
control 'must-fail: without the margin refusal, a margin of 100 runs' 900 1023 100 against 2 'error=margin-pct-invalid value=100'

mutant no-ref-refusal '|| config_error against-ref-invalid' '|| : config_error against-ref-invalid'
control 'must-fail: without the ref refusal, an unknown ref runs' 900 1023 - bad-ref 2 'error=against-ref-invalid ref=no-such-ref'

printf '\n%s: %s passed, %s failed\n' doc-limits-growth-margin "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
