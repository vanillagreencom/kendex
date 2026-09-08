#!/usr/bin/env bash
# The JSON rejection contract for finding items. Each row changes one field
# in a valid artifact and checks the exit status and complete result object.
# English detail after the first diagnostic line is not a consumer contract.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
CHECK="$REPO_ROOT/skills/orch/scripts/review-artifact-check"
source "$TEST_DIR/lib/waiter-assertions.sh"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT

base='{"agent":"reviewer-safety","verdict":"pass","summary":"s","blockers":[],"suggestions":[{"id":1,"title":"t","location":"a.rs (f)","description":"d","recommendation":"r","priority":4,"estimate":2,"category":"issue","impact":"nightly importers hit this on every run"}],"qa_metadata":{}}'
file="$TMP_ROOT/review.json"

# The producer is a reviewer writing canonical fields or familiar aliases.
# Each alias row removes only its corresponding canonical field.
while IFS='^' read -r label change want_rc detail; do
  jq "$change" <<<"$base" > "$file"
  rc=0
  out=$("$CHECK" --file "$file" 2>"$TMP_ROOT/stderr") || rc=$?
  actual=$(jq -c 'if has("detail") then .detail |= split("\n")[0] else . end' <<<"$out")
  if [[ "$want_rc" == 0 ]]; then
    expected=$(jq -cn --arg path "$file" '{ok:true,path:$path,reason:"valid"}')
  else
    expected=$(jq -cn --arg path "$file" --arg detail "review-artifact-check: finding_item path=suggestions[0] $detail" \
      '{ok:false,path:$path,reason:"incomplete",detail:$detail}')
  fi
  assert_eq "$rc $actual" "$want_rc $expected" "$label" "$TMP_ROOT/stderr"
done <<'ROWS'
schema-correct issue finding^.^0^
issue finding without impact^del(.suggestions[0].impact)^1^missing=impact invalid=
issue finding with blank impact^.suggestions[0].impact = " "^1^missing= invalid=impact:blank
fix finding needs no impact^.suggestions[0].category = "fix" | del(.suggestions[0].impact)^0^
priority above the schema range^.suggestions[0].priority = 5^1^missing= invalid=priority:range[1,4]
missing id^del(.suggestions[0].id)^1^missing=id invalid=
detail is not description^.suggestions[0] |= (.detail = .description | del(.description))^1^missing=description invalid=
file and line are not location^.suggestions[0] |= (.file = "a.rs" | .line = 12 | del(.location))^1^missing=location invalid=
remediation is not recommendation^.suggestions[0] |= (.remediation = .recommendation | del(.recommendation))^1^missing=recommendation invalid=
missing estimate^del(.suggestions[0].estimate)^1^missing=estimate invalid=
missing category^del(.suggestions[0].category)^1^missing=category invalid=
ROWS

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
