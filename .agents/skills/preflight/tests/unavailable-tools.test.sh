#!/usr/bin/env bash
set -euo pipefail
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE
unset PREFLIGHT_JSONC_GLOBS PREFLIGHT_MIGRATION_GLOBS

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PF="${PREFLIGHT_UNDER_TEST:-$TEST_DIR/../scripts/preflight}"
TMP="$(mktemp -d)"
trap 'rm -rf -- "${TMP:?}"' EXIT
R="$TMP/repo"
BIN="$TMP/bin"
mkdir -p "$R/scripts" "$R/data" "$BIN"
git -C "$R" -c init.defaultBranch=main init -q
git -C "$R" config user.email test@example.com
git -C "$R" config user.name test
printf '# Fixture\n' >"$R/README.md"
git -C "$R" add README.md
git -C "$R" commit -qm fixture

# The restricted PATH has preflight's required tools but no optional parser.
for tool in bash git awk cat cmp cp cut dirname grep head mkdir mktemp mv readlink rm sed sort tail tr wc; do
  real="$(command -v "$tool")"
  ln -s "$real" "$BIN/$tool"
done
for name in one two; do
  printf '#!/usr/bin/env bash\nset -euo pipefail\nprintf "fixture\\n"\n' >"$R/scripts/$name.sh"
  printf '{"fixture":true}\n' >"$R/data/$name.json"
done
printf 'fixture = true\n' >"$R/data/config.toml"
git -C "$R" add -A

PASS=0 FAIL=0 OUT="" RC=0
run_pf() {
  RC=0
  OUT="$(cd "$R" && PATH="$BIN" "$PF" --staged 2>&1)" || RC=$?
}
has() { case "$OUT" in *"$1"*) return 0 ;; esac; return 1; }
ok() { PASS=$((PASS + 1)); printf '  ok: %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL: %s (exit %s)\n%s\n' "$1" "$RC" "$OUT"; }

run_pf
[ "$RC" -eq 0 ] && ok 'missing optional tools keep exit 0' || bad 'optional exit status'
for lane in shellcheck-errors masked-returns data-syntax; do
  has "[$lane] not run:" && ok "$lane is named" || bad "$lane is named"
done
has 'JSON: jq is unavailable' && has 'TOML: taplo or python3 with tomllib is unavailable' \
  && ok 'data-syntax identifies each unavailable format' || bad 'data format skip details'
summary="$(printf '%s\n' "$OUT" | tail -n 1)"
case "$summary" in
  'preflight: clean ('*'; not run: data-syntax, masked-returns, shellcheck-errors') ok 'clean summary lists the skipped lanes' ;;
  *) bad 'clean summary lists the skipped lanes' ;;
esac
[ "$(printf '%s\n' "$OUT" | grep -cF '[shellcheck-errors] not run:')" -eq 1 ] \
  && ok 'multiple shell files produce one skip detail' || bad 'skip detail deduplication'

git -C "$R" reset -q HEAD
printf 'Documentation only.\n' >>"$R/README.md"
git -C "$R" add README.md
run_pf
[ "$RC" -eq 0 ] && ! has 'not run:' \
  && ok 'unneeded optional tools produce no skip' || bad 'docs-only scope'
printf '// comment dialect\n{"fixture":true,}\n' >"$R/data/config.jsonc"
git -C "$R" add data/config.jsonc
run_pf
[ "$RC" -eq 0 ] && ! has 'not run:' \
  && ok 'JSONC remains outside strict JSON parsing' || bad 'JSONC scope'

git -C "$R" add -A
printf '#!/usr/bin/env bash\necho fixture\n' >"$R/scripts/loose.sh"
git -C "$R" add scripts/loose.sh
run_pf
[ "$RC" -eq 1 ] && has '[fail-open]' && has '[shellcheck-errors] not run:' \
  && ok 'other findings still fail while optional checks are skipped' || bad 'findings retain exit 1'
git -C "$R" rm -qf scripts/loose.sh

if real="$(command -v jq)"; then
  ln -s "$real" "$BIN/jq"
  printf '{"fixture":\n' >"$R/data/one.json"
  git -C "$R" add data/one.json
  run_pf
  [ "$RC" -eq 1 ] && has 'invalid JSON:' && ! has 'JSON: jq is unavailable' \
    && has 'TOML: taplo or python3 with tomllib is unavailable' \
    && ok 'available jq runs while TOML remains skipped' || bad 'JSON partial coverage'
  printf '{"fixture":true}\n' >"$R/data/one.json"
  git -C "$R" add data/one.json
  rm "$BIN/jq"
else
  printf '  skip: available-jq control (jq is not installed)\n'
fi

if real="$(command -v python3)" && "$real" -c 'import tomllib' >/dev/null 2>&1; then
  ln -s "$real" "$BIN/python3"
  printf 'fixture = [\n' >"$R/data/config.toml"
  git -C "$R" add data/config.toml
  run_pf
  [ "$RC" -eq 1 ] && has 'invalid TOML:' && ! has 'TOML: taplo or python3 with tomllib is unavailable' \
    && has 'JSON: jq is unavailable' \
    && ok 'Python TOML fallback still runs without taplo' || bad 'TOML fallback coverage'
  rm "$BIN/python3"
else
  printf '  skip: Python TOML fallback control (tomllib is not installed)\n'
fi

# An installed Python without tomllib is also an unavailable TOML parser.
printf '#!/usr/bin/env bash\nexit 1\n' >"$BIN/python3"
chmod +x "$BIN/python3"
run_pf
[ "$RC" -eq 0 ] && has 'TOML: taplo or python3 with tomllib is unavailable' \
  && ok 'Python without tomllib preserves the optional-parser status' || bad 'missing tomllib reporting'

printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
