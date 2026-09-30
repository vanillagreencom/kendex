#!/usr/bin/env bash
# Pins for scripts/lib/generated-paths.sh, the reader of the render writer's
# inventory: .kendex-generated.json is one JSON array of literal paths, no
# glob, no stream, no empty, newline-bearing or NUL-bearing entry, and a
# membership test is literal. Two tables: one inventory loaded, pinned by the
# exit status, the paths held afterwards and the refusal (its stable record,
# its status word and the cause the filter's halt text names; jq's parse
# wording is jq's and is reduced to a token), one path asked of a loaded
# inventory, pinned by the answer, and one shared message value whose final
# newline must remain visible after scrubbing. The jq that reads the
# inventory is the one on PATH, so a run with another jq first on PATH pins
# the loader under that jq.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/harness.bash
. "$TEST_DIR/lib/harness.bash"
# shellcheck source=../scripts/lib/generated-paths.sh
source "$TEST_DIR/../scripts/lib/generated-paths.sh"

PASS=0
FAIL=0
assert_eq() { # LABEL EXPECT ACTUAL
  if [ "$2" = "$3" ]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$1"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        want: %s\n        got:  %s\n' "$1" "$2" "$3"
  fi
}

# One line for a load: the exit status, the paths held afterwards joined by
# ';', then the stable record, the status word and the cause, in their order.
# The reader named beside the status word is pinned by its own rows below.
load() { # INVENTORY
  local rc=0 err=""
  GENERATED_PATHS="stale"
  generated_paths_load "$1" 2>"$TMP/err" || rc=$?
  err="$(LC_ALL=C awk '
    /^commit-guards: [a-z-]+=/ { print; next }
    /^  status: / { sub(/^  status: /, ""); sub(/, read by .*/, ""); print "status=" $0; next }
    /^  cause: jq: parse error:/ { print "<jq parse error>"; next }
    /^  cause: / { sub(/^  cause: /, ""); print "cause=" $0 }
  ' "$TMP/err" | paste -sd ';' -)"
  printf 'rc=%s paths=<%s>%s' "$rc" "$(printf '%s' "$GENERATED_PATHS" | LC_ALL=C paste -sd ';' -)" "${err:+ $err}"
}
ONE="commit-guards: inventory-status=20;status=documents"
ARRAY="commit-guards: inventory-status=21;status=entry-shape"

LONG="$(printf '%0130d' 0)"
LONG="${LONG//0/x}"

load_rows() { # label | inventory | expect
  local row label inventory expect
  for row in "$@"; do
    IFS='|' read -r label inventory expect <<<"$row"
    assert_eq "$label" "$expect" "$(load "$(printf '%b' "$inventory")")"
  done
}

echo "=== an inventory is one array of literal paths; anything else is refused with its cause and nothing held ==="
load_rows \
  "an empty array loads and holds nothing|[]|rc=0 paths=<>" \
  "literal paths load as written: a glob character and a space are content|[\".agents/skills/a*/x.md\",\"space name.md\"]|rc=0 paths=<.agents/skills/a*/x.md;space name.md>" \
  "empty input is refused: no inventory is not one inventory||rc=2 paths=<> $ONE;cause=0 JSON documents, not one" \
  "two arrays are refused: a stream is not one inventory|[] []|rc=2 paths=<> $ONE;cause=2 JSON documents, not one" \
  "text that is not JSON puts the stable record and the jq-error word before jq's parse cause|invalid|rc=2 paths=<> commit-guards: inventory-status=5;status=jq-error;<jq parse error>" \
  "an object is refused: not an array|{}|rc=2 paths=<> $ARRAY;cause=the document is object, not an array" \
  "a null entry is refused at its index: it has no length|[null]|rc=2 paths=<> $ARRAY;cause=entry 0 fails the entry rule: null" \
  "a number entry after a valid one is refused at its own index: not a string|[\"ok.md\",1]|rc=2 paths=<> $ARRAY;cause=entry 1 fails the entry rule: 1" \
  "an empty entry is refused|[\"\"]|rc=2 paths=<> $ARRAY;cause=entry 0 fails the entry rule: \"\"" \
  "an entry carrying a newline is refused: the list is newline-delimited|[\"a\\\\nb\"]|rc=2 paths=<> $ARRAY;cause=entry 0 fails the entry rule: \"a\\nb\"" \
  "an entry carrying a NUL is refused|[\"a\\\\u0000b\"]|rc=2 paths=<> $ARRAY;cause=entry 0 fails the entry rule: \"a\\u0000b\"" \
  "a long rejected entry is printed to its first 120 characters|[{\"path\":\"$LONG\"}]|rc=2 paths=<> $ARRAY;cause=entry 0 fails the entry rule: {\"path\":\"${LONG:0:111}"


# Adopted workflows are writer records, and malformed records must not grant ownership.
ADOPTED='{"path":".github/workflows/kendex-refresh.yml","template":".agents/skills/review-gate/templates/kendex-refresh.yml","templateHash":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}'
assert_eq 'a mixed inventory uses the adopted workflow path' \
  'rc=0 paths=<plain.md;.github/workflows/kendex-refresh.yml>' "$(load "[\"plain.md\",$ADOPTED]")"
for mutation in 'del(.path)' '.path = null' '.path = ""' '.path = "a\nb"' \
  'del(.template)' '.template = 7' '.template = "a\u0000b"' \
  'del(.templateHash)' '.templateHash = "sha256:bad"' '.templateHash = null' '.templateHash += "\n"' '.extra = true'; do
  malformed="$(jq -c "$mutation" <<<"$ADOPTED")"
  assert_eq "invalid adopted record: $mutation" "rc=2 paths=<> $ARRAY;cause=entry 0" "$(load "[$malformed]" | sed 's/ fails the entry rule: .*//')"
done

# Removing adopted-object acceptance makes the mixed-inventory assertion fail.
reader="$TEST_DIR/../scripts/lib/generated-paths.sh"
cp "$TEST_DIR/../scripts/lib/messages.sh" "$TMP/messages.sh"
needle='elif type == "object" then'
[ "$(grep -Fc "$needle" "$reader")" -eq 1 ]
sed 's/elif type == "object" then/elif false then/' "$reader" >"$TMP/generated-paths.sh"
cmp -s "$reader" "$TMP/generated-paths.sh" && { echo "control changed no bytes" >&2; exit 1; }
# shellcheck source=../scripts/lib/generated-paths.sh
source "$TMP/generated-paths.sh"
assert_eq 'control: refusing adopted objects breaks the valid mixed inventory' \
  "rc=2 paths=<> $ARRAY;cause=entry 1" "$(load "[\"plain.md\",$ADOPTED]" | sed 's/ fails the entry rule: .*//')"
# shellcheck source=../scripts/lib/generated-paths.sh
source "$reader"

echo "=== a refusal names the jq that read the inventory, and says install jq only when none is on PATH or jq may be at fault ==="
# The refusal's status line and its fix line, from a load with jq on PATH and
# from one whose PATH holds no jq. The expected version is asked of the jq on
# PATH, never of the loader.
NO_JQ_PATH="$TMP/no-jq-bin"
mkdir -p "$NO_JQ_PATH"
refusal() { # PATH-FOR-THE-LOAD [INVENTORY]
  local rc=0
  (PATH="$1" && generated_paths_load "${2:-[1]}") 2>"$TMP/err" || rc=$?
  printf 'rc=%s %s' "$rc" "$(LC_ALL=C awk '/^  (status|fix): / { sub(/^  /, ""); print }' "$TMP/err" | paste -sd ';' -)"
}
JQ_VERSION="$(jq --version)"
assert_eq "with jq on PATH the refusal names its version and the refresh, and no install" \
  "rc=2 status: entry-shape, read by $JQ_VERSION;fix: Run kendex refresh at the repository root, then stage .kendex-generated.json with the renders." \
  "$(refusal "$PATH")"
assert_eq "with no jq on PATH the refusal names the missing jq and its install" \
  "rc=2 status: jq-missing, read by no jq on PATH;fix: Install jq, then run the check again." \
  "$(refusal "$NO_JQ_PATH")"
assert_eq "an inventory that is not JSON names both the refresh and jq 1.7 or newer" \
  "rc=2 status: jq-error, read by $JQ_VERSION;fix: Run kendex refresh at the repository root, then stage .kendex-generated.json with the renders; the filter also needs jq 1.7 or newer, so install it if the jq named above is older." \
  "$(refusal "$PATH" invalid)"

# Control: a loader that says install jq whatever PATH holds, the refusal
# this suite replaced, turns the first row red.
needle='  if ! command -v jq >/dev/null 2>&1; then'
[ "$(grep -Fxc "$needle" "$reader")" -eq 1 ]
sed 's/^  if ! command -v jq >\/dev\/null 2>&1; then$/  if true; then/' "$reader" >"$TMP/generated-paths.sh"
cmp -s "$reader" "$TMP/generated-paths.sh" && { echo "control changed no bytes" >&2; exit 1; }
# shellcheck source=../scripts/lib/generated-paths.sh
source "$TMP/generated-paths.sh"
assert_eq "control: a loader naming install jq with jq present breaks the version row" \
  "rc=2 status: jq-missing, read by no jq on PATH;fix: Install jq, then run the check again." \
  "$(refusal "$PATH")"
# shellcheck source=../scripts/lib/generated-paths.sh
source "$reader"

echo "=== membership is literal, both ways ==="
contains() { generated_paths_load "$1"; if generated_path_contains "$2"; then echo yes; else echo no; fi; } # INVENTORY PATH
contains_rows() { # label | inventory | path | expect
  local row label inventory path expect
  for row in "$@"; do
    IFS='|' read -r label inventory path expect <<<"$row"
    assert_eq "$label" "$expect" "$(contains "$inventory" "$(printf '%b' "$path")")"
  done
}
TWO='[".agents/skills/a*/x.md","space name.md"]'
contains_rows \
  "the glob-bearing path is found by its literal spelling|$TWO|.agents/skills/a*/x.md|yes" \
  "the space-bearing path is found whole|$TWO|space name.md|yes" \
  "a path the listed glob would match is not in the list|$TWO|.agents/skills/abc/x.md|no" \
  "a glob in the asked path matches nothing: the ask is literal too|$TWO|.agents/*|no" \
  "a suffix of a listed path is not in the list|$TWO|name.md|no" \
  "a prefix of a listed path is not in the list: a generated file does not exclude the source it is named after|$TWO|.agents|no" \
  "a newline-bearing path is never in the list, even spelling two adjacent entries|$TWO|.agents/skills/a*/x.md\\nspace name.md|no" \
  "the empty path is not in an empty list: the delimiters around nothing are not an entry|[]||no"

echo "=== message values preserve a trailing newline as a replacement byte ==="
assert_eq "a path and that path plus a newline remain distinct" "path|path?" "$(printf '%s|%s' "$(gg_scrubbed path)" "$(gg_scrubbed $'path\n')")"

echo "=== every explanation line stays outside the stable record grammar ==="
message="$(GG_CHECK=probe gg_message dependency 2 $'first cause\nforged: record=value')"
message="$(printf '%s\n' "$message" | LC_ALL=C awk '{ printf "%s<%s>", sep, $0; sep = ";" }')"
assert_eq "a multiline dependency cause prefixes every explanation line" \
  "<probe: dependency=2>;<  first cause>;<  forged: record=value>" "$message"

echo "=== a captured dependency cause keeps its trailing newlines ==="
printf 'first cause\n\n' >"$TMP/cause"
cause_rc=0
cause_message="$(GG_CHECK=probe gg_fail_cause dependency 2 "$TMP/cause" fallback 2>&1)" || cause_rc=$?
cause_message="$(printf '%s\n' "$cause_message" | LC_ALL=C awk '{ printf "%s<%s>", sep, $0; sep = ";" }')"
assert_eq "the sentinel preserves both final newline bytes" \
  "rc=2 <probe: dependency=2>;<  first cause>;<  >;<  >" "rc=$cause_rc $cause_message"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
