#!/usr/bin/env bash
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SR="$TEST_DIR/../scripts/size-ratchet"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

unset SIZE_RATCHET_THRESHOLD SIZE_RATCHET_CLASSES SIZE_RATCHET_DEFAULT_CLASSES SIZE_RATCHET_FROZEN_CLASSES SIZE_RATCHET_BASELINE SIZE_RATCHET_EXCLUDES SIZE_RATCHET_SETTINGS_FILE RATCHET_RAISE 2>/dev/null || true
export SIZE_RATCHET_THRESHOLD=10 SIZE_RATCHET_DEFAULT_CLASSES="" SIZE_RATCHET_FROZEN_CLASSES=""

new_repo() {
  R="$TMP/$1"
  mkdir -p "$R/tools"
  git -C "$R" -c init.defaultBranch=main init -q
  git -C "$R" config user.email test@example.com
  git -C "$R" config user.name test
}

run_seed() {
  RC=0
  OUT="$(cd "$R" && "$SR" --seed "$@" 2>&1)" || RC=$?
}

new_repo fresh
printf 'small\n' >"$R/small.txt"
git -C "$R" add -A
git -C "$R" commit -q -m born
for n in 01 02 03 04 05 06 07 08 09 10 11 12; do
  awk 'BEGIN { for (i = 1; i <= 15; i++) print "line " i }' >"$R/big-$n.txt"
done
: >"$R/tools/size-ratchet-baseline.tsv"
git -C "$R" add -A
run_seed
[ "$RC" -eq 0 ] || { printf 'FAIL: first seed rc=%s\n%s\n' "$RC" "$OUT" >&2; exit 1; }
rows="$(wc -l <"$R/tools/size-ratchet-baseline.tsv" | tr -d ' ')"
[ "$rows" -eq 12 ] || { printf 'FAIL: seed rows=%s\n' "$rows" >&2; exit 1; }
case "$(cat "$R/tools/size-ratchet-baseline.tsv")" in
  *tools/size-ratchet-baseline.tsv*) printf 'FAIL: seed wrote a self row\n' >&2; exit 1 ;;
esac
RC=0
OUT="$(cd "$R" && "$SR" 2>&1)" || RC=$?
[ "$RC" -eq 0 ] || { printf 'FAIL: immediate check after seed rc=%s\n%s\n' "$RC" "$OUT" >&2; exit 1; }

cp "$R/tools/size-ratchet-baseline.tsv" "$TMP/populated.before"
run_seed
[ "$RC" -eq 2 ] || { printf 'FAIL: populated baseline reseeded rc=%s\n%s\n' "$RC" "$OUT" >&2; exit 1; }
cmp -s "$TMP/populated.before" "$R/tools/size-ratchet-baseline.tsv" \
  || { printf 'FAIL: populated refusal changed the baseline\n' >&2; exit 1; }

new_repo malformed
printf 'not a row\n' >"$R/tools/size-ratchet-baseline.tsv"
git -C "$R" add -A
cp "$R/tools/size-ratchet-baseline.tsv" "$TMP/malformed.before"
run_seed
[ "$RC" -eq 2 ] || { printf 'FAIL: malformed baseline accepted rc=%s\n%s\n' "$RC" "$OUT" >&2; exit 1; }
cmp -s "$TMP/malformed.before" "$R/tools/size-ratchet-baseline.tsv" \
  || { printf 'FAIL: malformed refusal changed the baseline\n' >&2; exit 1; }

new_repo lexical-alias
awk 'BEGIN { for (i = 1; i <= 15; i++) print "line " i }' >"$R/big.txt"
: >"$R/tools/policy"
git -C "$R" add -A
cp "$R/tools/policy" "$TMP/alias.before"
run_seed --baseline tools/policy --excludes tools/policy
[ "$RC" -eq 2 ] || { printf 'FAIL: lexical policy alias accepted rc=%s\n%s\n' "$RC" "$OUT" >&2; exit 1; }
cmp -s "$TMP/alias.before" "$R/tools/policy" \
  || { printf 'FAIL: lexical alias refusal changed the policy\n' >&2; exit 1; }

new_repo existing-alias
awk 'BEGIN { for (i = 1; i <= 15; i++) print "line " i }' >"$R/big.txt"
: >"$R/tools/base"
ln "$R/tools/base" "$R/tools/excludes"
git -C "$R" add -A
run_seed --baseline tools/base --excludes tools/excludes
[ "$RC" -eq 2 ] || { printf 'FAIL: existing policy alias accepted rc=%s\n%s\n' "$RC" "$OUT" >&2; exit 1; }
[ ! -s "$R/tools/base" ] && [ ! -s "$R/tools/excludes" ] \
  || { printf 'FAIL: existing alias refusal changed the policies\n' >&2; exit 1; }

new_repo parent-link
awk 'BEGIN { for (i = 1; i <= 15; i++) print "line " i }' >"$R/big.txt"
mkdir -p "$TMP/outside-parent"
ln -s "$TMP/outside-parent" "$R/policy"
git -C "$R" add -A
run_seed --baseline policy/base.tsv
[ "$RC" -eq 2 ] || { printf 'FAIL: out-of-repo parent accepted rc=%s\n%s\n' "$RC" "$OUT" >&2; exit 1; }
[ ! -e "$TMP/outside-parent/base.tsv" ] \
  || { printf 'FAIL: seed wrote through an out-of-repo parent\n' >&2; exit 1; }

new_repo destination-link
awk 'BEGIN { for (i = 1; i <= 15; i++) print "line " i }' >"$R/big.txt"
: >"$TMP/outside-baseline"
ln -s "$TMP/outside-baseline" "$R/tools/size-ratchet-baseline.tsv"
git -C "$R" add -A
run_seed
[ "$RC" -eq 2 ] || { printf 'FAIL: symlink baseline accepted rc=%s\n%s\n' "$RC" "$OUT" >&2; exit 1; }
[ -L "$R/tools/size-ratchet-baseline.tsv" ] && [ ! -s "$TMP/outside-baseline" ] \
  || { printf 'FAIL: symlink refusal changed the destination\n' >&2; exit 1; }

printf 'seed.test.sh: PASS\n'
