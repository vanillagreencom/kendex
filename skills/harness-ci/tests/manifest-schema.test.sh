#!/usr/bin/env bash
# Surface: harness-only's schema-step changed-path filter.
# Inputs: skills/harness-ci/scripts/harness-only skills/harness-ci/scripts/lib/change-class.sh
set -euo pipefail
# shellcheck source=lib/sandbox.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/sandbox.sh"

manifest='schema = 6\n\n[bot-instructions]\nschema = 1\n'
rows=0
check_case() { # NAME PATH BASE_TEXT HEAD_TEXT EXTRA EXPECTED LISTED
  local name="$1" path="$2" before="$3" after="$4" extra="$5" expected="$6" listed="$7"
  local repo base mode key verdict log paths actual_listed
  repo="$(new_repo "$name")"
  if [ "$before" != absent ]; then printf '%b' "$before" >"$repo/$path"; fi
  commit_paths "$repo" base .agents/skills/orch/SKILL.md
  base="$(git -C "$repo" rev-parse HEAD)"
  if [ "$after" = absent ]; then
    rm -- "$repo/$path"
  else
    printf '%b' "$after" >"$repo/$path"
  fi
  # A mode-only change keeps the same schema bytes on git's changed-path list.
  if [ "$extra" = mode ]; then chmod +x "$repo/$path"; fi
  if [ "$extra" = product ]; then printf 'product\n' >"$repo/app.conf"; fi
  if [ "$extra" = schema-only ]; then
    git -C "$repo" add -A
    git -C "$repo" commit -q -m head
  else
    commit_paths "$repo" head .agents/skills/orch/SKILL.md
  fi
  for mode in harness render-candidate; do
    key=harness_only
    [ "$mode" != render-candidate ] || key=render_candidate
    log="$SANDBOX/$name-$mode.log"
    paths="$SANDBOX/$name-$mode.paths"
    verdict="$("$HARNESS_ONLY" --mode "$mode" --repo "$repo" --event pull_request \
      --base "$base" --head HEAD --paths-output "$paths" 2>"$log")"
    assert_eq "$name: $mode verdict" "$key=$expected" "$verdict"
    actual_listed=false
    if grep -qxF -- "$path" "$paths"; then actual_listed=true; fi
    assert_eq "$name: $mode manifest path" "$listed" "$actual_listed"
    actual_listed=false
    if grep -qxF -- "changed-path: path=$path" "$log"; then actual_listed=true; fi
    assert_eq "$name: $mode changed-path log" "$listed" "$actual_listed"
    if [ "$extra" = schema-only ]; then
      assert_eq "$name: $mode filtered paths are empty" '' "$(cat -- "$paths")"
      assert_eq "$name: $mode changed-path log is empty" '' \
        "$(sed -n '/^changed-path: /p' "$log")"
    fi
    if [ "$listed" = false ]; then
      assert_eq "$name: $mode schema-step log" 'schema-bump: path=kendex.toml from=6 to=7' \
        "$(sed -n '/^schema-bump: /p' "$log")"
    else
      assert_eq "$name: $mode has no schema-step log" '' \
        "$(sed -n '/^schema-bump: /p' "$log")"
    fi
  done
  assert_docs_verdict "$name: docs mode keeps its refusal" false \
    --repo "$repo" --event pull_request --base "$base" --head HEAD
}

while IFS='|' read -r name path before after extra expected listed; do
  rows=$((rows + 1))
  check_case "$name" "$path" "$before" "$after" "$extra" "$expected" "$listed"
done <<'ROWS'
step|kendex.toml|schema = 6\n\n[bot-instructions]\nschema = 1\n|schema = 7\n\n[bot-instructions]\nschema = 1\n||true|false
schema-only|kendex.toml|schema = 6\n\n[bot-instructions]\nschema = 1\n|schema = 7\n\n[bot-instructions]\nschema = 1\n|schema-only|true|false
second-line|kendex.toml|schema = 6\n\n[bot-instructions]\nschema = 1\n|schema = 7\n\n[bot-instructions]\nschema = 2\n||false|true
downgrade|kendex.toml|schema = 6\n\n[bot-instructions]\nschema = 1\n|schema = 5\n\n[bot-instructions]\nschema = 1\n||false|true
jump|kendex.toml|schema = 6\n\n[bot-instructions]\nschema = 1\n|schema = 8\n\n[bot-instructions]\nschema = 1\n||false|true
same-schema|kendex.toml|schema = 6\n\n[bot-instructions]\nschema = 1\n|schema = 6\n\n[bot-instructions]\nschema = 1\n|mode|false|true
added|kendex.toml|absent|schema = 7\n\n[bot-instructions]\nschema = 1\n||false|true
deleted|kendex.toml|schema = 6\n\n[bot-instructions]\nschema = 1\n|absent||false|true
table-schema|kendex.toml|schema = 6\n\n[bot-instructions]\nschema = 1\n|schema = 6\n\n[bot-instructions]\nschema = 2\n||false|true
table-only|kendex.toml|[bot-instructions]\nschema = 1\n|[bot-instructions]\nschema = 2\n||false|true
local-manifest|kendex-local.toml|schema = 6\n\n[bot-instructions]\nschema = 1\n|schema = 7\n\n[bot-instructions]\nschema = 1\n||false|true
product|kendex.toml|schema = 6\n\n[bot-instructions]\nschema = 1\n|schema = 7\n\n[bot-instructions]\nschema = 1\n|product|false|false
crlf|kendex.toml|schema = 6\r\n\r\n[bot-instructions]\r\nschema = 1\r\n|schema = 7\r\n\r\n[bot-instructions]\r\nschema = 1\r\n||true|false
newline-change|kendex.toml|schema = 6\r\n\r\n[bot-instructions]\r\nschema = 1\r\n|schema = 7\n\n[bot-instructions]\nschema = 1\n||false|true
no-final-newline|kendex.toml|schema = 6\n[bot-instructions]\nschema = 1|schema = 7\n[bot-instructions]\nschema = 1||true|false
final-newline-change|kendex.toml|schema = 6\n[bot-instructions]\nschema = 1|schema = 7\n[bot-instructions]\nschema = 1\n||false|true
inline-comment|kendex.toml|schema = 6 # root\n[bot-instructions]\nschema = 1\n|schema = 7 # root\n[bot-instructions]\nschema = 1\n||false|true
spacing|kendex.toml|schema=6\n[bot-instructions]\nschema = 1\n|schema=7\n[bot-instructions]\nschema = 1\n||false|true
signed|kendex.toml|schema = +6\n[bot-instructions]\nschema = 1\n|schema = +7\n[bot-instructions]\nschema = 1\n||false|true
leading-zero|kendex.toml|schema = 06\n[bot-instructions]\nschema = 1\n|schema = 7\n[bot-instructions]\nschema = 1\n||false|true
indented-table|kendex.toml|  [bot-instructions]\nschema = 6\n|  [bot-instructions]\nschema = 7\n||false|true
ROWS
require_rows manifest-schema "$rows"

# The original empty diff comes from identical resolved endpoints, not filtering.
repo="$(new_repo empty-diff)"
commit_paths "$repo" base .agents/skills/orch/SKILL.md
for mode in harness render-candidate; do
  key=harness_only
  [ "$mode" != render-candidate ] || key=render_candidate
  log="$SANDBOX/empty-$mode.log"
  assert_eq "empty diff: $mode remains refused" "$key=false" \
    "$("$HARNESS_ONLY" --mode "$mode" --repo "$repo" --event pull_request \
      --base HEAD --head HEAD 2>"$log")"
  assert_eq "empty diff: $mode retains its cause" cause=empty-diff \
    "$(sed -n 's/^fallback: \(cause=[^ ]*\).*/\1/p' "$log")"
done

# Each control runs the same case assertions against a private production copy.
control() { # NAME SCRIPT CASE BASE HEAD [EXTRA EXPECTED LISTED]
  local name="$1" script="$2" case_name="$3" before="$4" after="$5" status=0
  (PASS=0; FAIL=0; HARNESS_ONLY="${script%/*}/harness-only"
    check_case "control-$name-$case_name" kendex.toml "$before" "$after" \
      "${6:-}" "${7:-false}" "${8:-true}"
    report "control-$name") >"$SANDBOX/control-$name-$case_name.log" 2>&1 || status=$?
  assert_eq "control $name: $case_name turns the case red" 1 "$status"
}
mutant_class="$(mutant schema-any-change harness-only \
  '    if b"".join(expected) != after:' '    if False:')"
control any-change "$mutant_class" second-line "$manifest" 'schema = 7\n\n[bot-instructions]\nschema = 2\n'
mutant_class="$(mutant schema-any-step harness-only \
  '    expected[index] = expected[index].replace(content, f"schema = {previous + 1}".encode(), 1)' \
  '    expected[index] = after.splitlines(keepends=True)[index]')"
control any-step "$mutant_class" downgrade "$manifest" 'schema = 5\n\n[bot-instructions]\nschema = 1\n'
control any-step "$mutant_class" jump "$manifest" 'schema = 8\n\n[bot-instructions]\nschema = 1\n'
mutant_class="$(mutant schema-past-table harness-only '        break' '        continue')"
control past-table "$mutant_class" table-schema "$manifest" 'schema = 6\n\n[bot-instructions]\nschema = 2\n'
mutant_class="$(mutant schema-empty-refusal harness-only \
  '  changed="$schema_paths"' \
  $'  changed="$schema_paths"\n  [ -n "$changed" ] || verdict false "cause=empty-diff" "the filtered path set is empty"')"
control empty-refusal "$mutant_class" schema-only "$manifest" \
  'schema = 7\n\n[bot-instructions]\nschema = 1\n' schema-only true false

report manifest-schema
