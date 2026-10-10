#!/usr/bin/env bash
# Surface: shell settings readers, including every vendored project loader.
# Inputs: scripts/lib/kendex-env.sh tests/lib/assertions.sh
# The catalog root argument lets the same assertions judge disposable source
# copies for must-fail controls. No reader is replaced by a test parser.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CATALOG="${1:-$(cd -- "$TEST_DIR/../.." && pwd -P)}"
source "$TEST_DIR/lib/assertions.sh"
TMP_ROOT="$(mktemp -d)" || { echo "settings-literal-strings: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "settings-literal-strings: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "settings-literal-strings: scratch=resolve-failed" >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
mkdir "$TMP_ROOT/project"

read_value() { # LIBRARY FUNCTION KEY
  RC=0
  OUT="$(env -i GIT_CEILING_DIRECTORIES="$GIT_CEILING_DIRECTORIES" PATH="$PATH" "$BASH" -c '
    set -euo pipefail
    cd -- "$4"
    source "$1"
    if [[ "$2" == kendex_load_project_env ]]; then
      kendex_load_project_env "$4" || exit 1
      printf "%s" "${!3}"
    else
      "$2" "$3" fallback
    fi
  ' settings-reader "$1" "$2" "$3" "$TMP_ROOT/project" 2>"$TMP_ROOT/err")" || RC=$?
  ERR="$(cat "$TMP_ROOT/err")"
}

# KEN-3470 hook-command-safety-03 moved this shipped host policy into consumer
# settings. Its single-quoted form triggered the reported refusal.
HOST_POLICY='(^|[^[:alnum:]_-])systemd-run[[:space:]][^&;|]*Memory(Max|High)=[[:punct:]]?[0-9]+[KkMm]([^[:alnum:]]|$)'
readers=0
found_loader=0
found_guard=0
for lib in "$CATALOG"/*/scripts/lib/kendex-env.sh "$CATALOG"/*/scripts/lib/settings.sh; do
  [[ -f "$lib" ]] || continue
  package="${lib#"$CATALOG"/}"
  package="${package%%/*}"
  case "$package:${lib##*/}" in
    *:kendex-env.sh) reader=kendex_load_project_env; error='kendex-env: value-syntax'; field='key=SETTINGS_LITERAL_TEST' ;;
    commit-guards:settings.sh) reader=gg_setting; error='commit-guards: settings-string='; field='kendex.settings.toml:2:SETTINGS_LITERAL_TEST'; found_guard=1 ;;
    review-gate:settings.sh) reader=rg_setting; error='review-gate-error=settings-syntax'; field='value=SETTINGS_LITERAL_TEST' ;;
    doc-limits:settings.sh) reader=sr_setting; error='doc-limits-error=settings-syntax'; field='value=SETTINGS_LITERAL_TEST' ;;
    *) fail "$package has no settings-reader test route"; continue ;;
  esac
  [[ "$package" != orch ]] || found_loader=1
  readers=$((readers + 1))

  while IFS='|' read -r name raw expected status; do
    if [[ "$raw" == MULTILINE ]]; then
      printf "[env]\nSETTINGS_LITERAL_TEST = '''first\nsecond'''\n" >"$TMP_ROOT/project/kendex.settings.toml"
    else
      printf '[env]\nSETTINGS_LITERAL_TEST = %s\n' "$raw" >"$TMP_ROOT/project/kendex.settings.toml"
    fi
    read_value "$lib" "$reader" SETTINGS_LITERAL_TEST
    assert_eq "$RC" "$status" "$package: $name status" "$TMP_ROOT/err"
    if [[ "$status" == 0 ]]; then
      assert_eq "$OUT" "$expected" "$package: $name bytes"
    else
      assert_eq "$OUT" '' "$package: $name emits no value"
      assert_contains "${ERR%%$'\n'*}" "$error" "$package: $name refusal key"
      assert_contains "${ERR%%$'\n'*}" "$field" "$package: $name refused setting"
    fi
  done <<'CASES'
literal backslash|'a\b[.]c'|a\b[.]c|0
basic backslash stays unsupported|"a\\b[.]c"||1
literal twin|'a[.]c'|a[.]c|0
basic twin|"a[.]c"|a[.]c|0
empty literal|''||0
empty basic|""||0
literal comment|'  a#b = "c"\d  ' # don't change|  a#b = "c"\d  |0
adjacent TOML comment|'kept'# don't change|kept|0
basic containing literal declaration|"SETTINGS_LITERAL_TEST = 'kept'"|SETTINGS_LITERAL_TEST = 'kept'|0
apostrophe inside literal|'a'b'||1
unterminated literal|'unfinished||1
multiline literal|MULTILINE||1
single-line triple literal|'''value'''||1
CASES

  for quote in "'" '"'; do
    printf '[env]\nCOMMAND_SAFETY_DENY_PATTERN = %s%s%s\n' "$quote" "$HOST_POLICY" "$quote" >"$TMP_ROOT/project/kendex.settings.toml"
    read_value "$lib" "$reader" COMMAND_SAFETY_DENY_PATTERN
    assert_eq "$RC" 0 "$package: host policy $quote status" "$TMP_ROOT/err"
    assert_eq "$OUT" "$HOST_POLICY" "$package: host policy $quote bytes"
    if [[ "$reader" != kendex_load_project_env ]]; then
      read_value "$lib" "$reader" SETTINGS_LITERAL_TEST
      assert_eq "$RC:$OUT" '0:fallback' "$package: unrelated literal keeps other settings readable"
    fi
  done
done
assert_eq "$found_loader:$found_guard" '1:1' 'discovery includes both reader families'
[[ "$readers" -gt 0 ]] || fail 'discovery found no readers'
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]]
