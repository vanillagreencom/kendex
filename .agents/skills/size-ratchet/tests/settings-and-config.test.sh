#!/usr/bin/env bash
set -euo pipefail
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE
unset SIZE_RATCHET_CLASSES SIZE_RATCHET_DEFAULT_CLASSES SIZE_RATCHET_EXCLUDES SIZE_RATCHET_SETTINGS_FILE
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SR="$(cd "$TEST_DIR/../scripts" && pwd)/size-ratchet"
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
bytes AGENTS.md 2049
git -C "$R" add AGENTS.md
printf 'SIZE_RATCHET_CLASSES=*.md=1k\n' >"$R/.env"
run
expect 0 '.env is not a settings source'
printf '[env]\nSIZE_RATCHET_CLASSES = "*.md=1k"\n' >"$R/kendex.settings.toml"
run
expect 1 'project classes replace the shipped match'
mkdir -p "$R/.kendex"
printf '[env]\nSIZE_RATCHET_CLASSES = "*.md=3k"\n' >"$R/.kendex/settings.toml"
run
expect 0 'local settings precede project settings'
printf 'SIZE_RATCHET_CLASSES="*.md=2k" # local\n' >"$R/.env.local"
run
expect 1 '.env.local precedes both settings files'
export SIZE_RATCHET_CLASSES='*.md=3k'
run
expect 0 'environment precedes settings files'
export SIZE_RATCHET_CLASSES=''
run
expect 0 'an explicitly empty override leaves shipped classes'
unset SIZE_RATCHET_CLASSES
export SIZE_RATCHET_SETTINGS_FILE=/dev/null
run
expect 0 '/dev/null ignores every settings file'
export SIZE_RATCHET_CLASSES='*.md=1k'
run
expect 1 'environment still applies with /dev/null'
for value in '*.md=0k' '*.md=400' '*.md=invalid' '*.md' '=1k'; do
  export SIZE_RATCHET_CLASSES="$value"
  run
  expect 2 "invalid class $value refuses"
done
export SIZE_RATCHET_CLASSES='AGENTS.md=3k;*.md=1k'
run
expect 0 'the first matching class decides'
export SIZE_RATCHET_CLASSES='*.md=1k;AGENTS.md=3k'
run
expect 1 'reversing class order changes the decision'
unset SIZE_RATCHET_SETTINGS_FILE SIZE_RATCHET_CLASSES
printf '[env]\nDUP = "a"\nDUP = "b"\n' >"$R/kendex.settings.toml"
run
expect 2 'a malformed settings source refuses'
rm "$R/kendex.settings.toml" "$R/.env.local" "$R/.kendex/settings.toml"
printf '*.md\tfixture exception\n!AGENTS.md\tkeep root instructions checked\n' >"$R/tools/size-ratchet-excludes"
export SIZE_RATCHET_CLASSES='*.md=1k'
run
expect 1 'a carve-back row restores the document ceiling'
run --unknown
expect 2 'unknown flags refuse'
# Git is the real producer of both collection streams. Failed and truncated
# responses must not produce a clean verdict over an incomplete document set.
REAL_GIT="$(command -v git)"
export REAL_GIT
mkdir -p "$TMP/bin"
cat >"$TMP/bin/git" <<'GIT'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = "${FAIL_GIT_COMMAND:-}" ]; then exit 9; fi
if [ "${1:-}" = cat-file ] && [ "${EMPTY_BLOB_RESPONSE:-0}" = 1 ]; then
  cat >/dev/null
  exit 0
fi
exec "$REAL_GIT" "$@"
GIT
chmod +x "$TMP/bin/git"
export PATH="$TMP/bin:$PATH"
for command in ls-files cat-file; do
  export FAIL_GIT_COMMAND="$command"
  run --staged
  expect 2 "failed git $command refuses"
done
unset FAIL_GIT_COMMAND
export EMPTY_BLOB_RESPONSE=1
run --staged
expect 2 'empty blob-size response refuses'
unset EMPTY_BLOB_RESPONSE
run --staged
expect 1 'real collection still reaches the over-limit document'
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
