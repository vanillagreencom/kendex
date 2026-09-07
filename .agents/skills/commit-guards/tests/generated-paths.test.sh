#!/usr/bin/env bash
# Pins for scripts/lib/generated-paths.sh, the reader of the render writer's
# inventory: .kendex-generated.json is one JSON array of literal paths, no
# glob, no stream, no empty, newline-bearing or NUL-bearing entry, and a
# membership test is literal. Two tables: one inventory loaded, pinned by the
# exit status, the paths held afterwards and the cause (the loader's own
# clauses; jq's parse wording is jq's and is reduced to a token), and one
# path asked of a loaded inventory, pinned by the answer.
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
# ';', then every stderr line joined by ';' with jq's framing stripped.
load() { # INVENTORY
  local rc=0 err=""
  GENERATED_PATHS="stale"
  generated_paths_load "$1" 2>"$TMP/err" || rc=$?
  err="$(LC_ALL=C sed -e 's/^jq: error (at <stdin>:[0-9]*): //' -e 's/^jq: parse error: .*/<jq parse error>/' "$TMP/err" | LC_ALL=C paste -sd ';' -)"
  printf 'rc=%s paths=<%s>%s' "$rc" "$(printf '%s' "$GENERATED_PATHS" | LC_ALL=C paste -sd ';' -)" "${err:+ $err}"
}
REFUSED='::error::generated paths: cannot read .kendex-generated.json; jq is required; install or refresh kendex at the Git repository root in the main checkout and stage the inventory with the renders'
ONE="expected one inventory;$REFUSED"
ARRAY="expected an array of paths without newline or NUL;$REFUSED"

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
  "empty input is refused: no inventory is not one inventory||rc=2 paths=<> $ONE" \
  "two arrays are refused: a stream is not one inventory|[] []|rc=2 paths=<> $ONE" \
  "text that is not JSON is refused with jq's parse error ahead of the cause|invalid|rc=2 paths=<> <jq parse error>;$REFUSED" \
  "an object is refused: not an array|{}|rc=2 paths=<> $ARRAY" \
  "a null entry is refused: it has no length|[null]|rc=2 paths=<> $ARRAY" \
  "a number entry is refused: not a string|[1]|rc=2 paths=<> $ARRAY" \
  "an empty entry is refused|[\"\"]|rc=2 paths=<> $ARRAY" \
  "an entry carrying a newline is refused: the list is newline-delimited|[\"a\\\\nb\"]|rc=2 paths=<> $ARRAY" \
  "an entry carrying a NUL is refused|[\"a\\\\u0000b\"]|rc=2 paths=<> $ARRAY"

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

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
