#!/usr/bin/env bash
set -euo pipefail
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE
unset DOC_LIMITS_CLASSES DOC_LIMITS_DEFAULT_CLASSES DOC_LIMITS_EXCLUDES DOC_LIMITS_SETTINGS_FILE
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SR="$(cd "$TEST_DIR/../scripts" && pwd)/doc-limits"
TMP="$(mktemp -d)"
trap 'rm -rf -- "${TMP:?}"' EXIT
R="$TMP/repo"
mkdir -p "$R/tools"
git -C "$R" -c init.defaultBranch=main init -q
git -C "$R" config user.email test@example.com
git -C "$R" config user.name test
PASS=0
FAIL=0
expect() { # EXPECTED-EXIT LABEL: assert the preceding run's result
  if [ "$RC" -eq "$1" ]; then
    PASS=$((PASS + 1)); printf '  ok: %s\n' "$2"
  else
    FAIL=$((FAIL + 1)); printf '  FAIL: %s: exit %s\n%s\n' "$2" "$RC" "$OUT"
  fi
}
run() {
  RC=0
  OUT="$(cd "$R" && "$SR" "$@" 2>&1)" || RC=$?
}
bytes() { # PATH COUNT: create a byte-sized text fixture
  mkdir -p "$R/$(dirname "$1")"
  head -c "$2" /dev/zero | tr '\0' x >"$R/$1"
}
# Representative paths exercise each shipped document class at both edges.
while IFS=' ' read -r path limit; do
  bytes "$path" "$limit"
  git -C "$R" add -- "$path"
  run --staged
  expect 0 "$path at its class limit passes"
  bytes "$path" "$((limit + 1))"
  git -C "$R" add -- "$path"
  run --staged
  expect 1 "$path one byte over fails"
  case "$OUT" in
    *"$path: $((limit + 1)) bytes > $limit bytes"*) ;;
    *) FAIL=$((FAIL + 1)); printf '  FAIL: wrong document or limit: %s\n' "$OUT" ;;
  esac
  git -C "$R" rm -qf -- "$path"
done <<'CLASSES'
AGENTS.md 16384
CLAUDE.md 24576
pkg/AGENTS.md 6144
pkg/CLAUDE.md 24576
docs/architecture/overview.md 12288
docs/architecture/topic.md 16384
skills/demo/SKILL.md 24576
skills/demo/workflows/task.md 40960
README.md 16384
pkg/README.md 12288
skills/demo/references/contract.md 65536
CHANGELOG.md 65536
CLASSES
bytes src/large.rs 100000
git -C "$R" add src/large.rs
export DOC_LIMITS_CLASSES='*=1k'
run --staged
expect 0 'source files have no ceiling even when a byte class matches them'
unset DOC_LIMITS_CLASSES
bytes AGENTS.md 16385
git -C "$R" add AGENTS.md
printf 'AGENTS.md\tdeliberate fixture exception\n' >"$R/tools/doc-limits-excludes"
git -C "$R" add tools/doc-limits-excludes
run --staged
expect 0 'a reasoned exclusion permits the over-limit document'
printf 'AGENTS.md\n' >"$R/tools/doc-limits-excludes"
git -C "$R" add tools/doc-limits-excludes
run --staged
expect 2 'an exclusion without a reason refuses'
: >"$R/tools/doc-limits-excludes"
git -C "$R" add tools/doc-limits-excludes
run --staged
expect 1 'removing the exclusion restores the ceiling'
# The same oversized document must make the assertion fail if the comparison
# is disabled. Keep the comparison text and remove only its execution.
mkdir -p "$TMP/mutant/lib"
cp "$TEST_DIR/../scripts/lib/settings.sh" "$TMP/mutant/lib/settings.sh"
sed 's/if \[ "\$n" -gt "\$limit" \]; then/if false \&\& [ "$n" -gt "$limit" ]; then/' "$SR" >"$TMP/mutant/doc-limits"
if cmp -s "$SR" "$TMP/mutant/doc-limits"; then
  printf 'mutation did not change the comparison\n' >&2
  exit 1
fi
chmod +x "$TMP/mutant/doc-limits"
SR="$TMP/mutant/doc-limits"
run --staged
CONTROL_RC=0
(FAIL=0; expect 1 'must-fail: disabled comparison'; [ "$FAIL" -eq 0 ]) >"$TMP/control.log" || CONTROL_RC=$?
if [ "$RC" -eq 0 ] && [ "$CONTROL_RC" -ne 0 ]; then
  PASS=$((PASS + 1)); printf '  ok: disabling comparison makes the must-fail assertion fail\n'
else
  FAIL=$((FAIL + 1)); cat "$TMP/control.log"
fi
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
