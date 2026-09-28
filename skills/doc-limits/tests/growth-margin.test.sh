#!/usr/bin/env bash
# Pins for doc-limits --against: a document the change grows into the margin
# under its limit fails, and a run without --against judges the limit alone.
#
# Two pull requests that each grow one document pass their own runs and meet
# over its limit only in the merge group that carries both. The pull request
# run passes --against with the branch it merges into and fails the growth
# while the document can still be split; the merge group run passes no
# --against, so a group that fits merges.
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
# DOC_LIMITS_MARGIN_PCT ("-" for unset). Sets RC and OUT.
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
    *) printf 'harness: unknown mode %s\n' "$mode" >&2; exit 2 ;;
  esac
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
a ref that names no commit is refused|900|1023|-|bad-ref|2|error=against-ref-invalid ref=no-such-ref
ROWS
if [ "$ROWS" -lt 15 ]; then
  printf 'FAIL: ROWS executed %s rows, fewer than its 15\n' "$ROWS" >&2
  exit 1
fi

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

mutant no-growth-test '[ "$n" -gt "$prior" ] &&' '{ [ "$n" -gt "$prior" ] || true; } &&'
control 'must-fail: without the growth test, an unchanged document inside the margin fails' 1023 1023 - against 0 "$OK"

mutant no-margin-refusal 'config_error margin-pct-invalid' ': config_error margin-pct-invalid'
control 'must-fail: without the margin refusal, a margin of 100 runs' 900 1023 100 against 2 'error=margin-pct-invalid value=100'

mutant no-ref-refusal '|| config_error against-ref-invalid' '|| : config_error against-ref-invalid'
control 'must-fail: without the ref refusal, an unknown ref runs' 900 1023 - bad-ref 2 'error=against-ref-invalid ref=no-such-ref'

printf '\n%s: %s passed, %s failed\n' doc-limits-growth-margin "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
