#!/usr/bin/env bash
# bash-runtime: 4
# `issues create` refuses, before any API call, a body whose Location or
# Expected delta line an orch lane's launch refuses or reads as no delta, as
# `orch-runtime tier --filing` reads it, and creates a body in the
# project-management template's form. The package runs beside the catalog's
# own orch and its siblings, as an install lays them out, so the reader is
# the one a launch runs.
# Inputs: skills/orch/runtime/, skills/orch/scripts/, skills/agent-runtime/,
# skills/change-scope/scripts/, skills/change-scope/references/.

set -euo pipefail
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/assert.sh
source "$SCRIPT_DIR/lib/assert.sh"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SKILLS="$(cd "$SKILL_DIR/.." && pwd)"
assert_tmpdir TMP_ROOT

CURL_LOG="$TMP_ROOT/curl-payloads.jsonl"
ERR_FILE="$TMP_ROOT/stderr.txt"
mkdir -p "$TMP_ROOT/bin"
cat >"$TMP_ROOT/bin/curl" <<'SH'
#!/usr/bin/env bash
payload="$(sed -n 's/^data = //p' <<<"$(cat)" | jq -r)"
printf '%s\n' "$payload" >>"${CURL_LOG:?}"
case "$(jq -r '.query' <<<"$payload")" in
*"teams(filter:"*) printf '%s' '{"data":{"teams":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"id":"team-uuid"}]}}}___HTTP_CODE___200' ;;
*"issueCreate(input:"*) printf '%s' '{"data":{"issueCreate":{"success":true,"issue":{"id":"issue-uuid","identifier":"TEAM-1","title":"t","description":"","state":{"name":"Todo","type":"unstarted"},"assignee":null,"project":null,"projectMilestone":null,"cycle":null,"parent":null,"team":{"name":"Configured"},"labels":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]},"priority":3,"estimate":null,"sortOrder":1.0,"url":"https://linear.app/x/issue/TEAM-1","createdAt":"2026-08-08T00:00:00Z","updatedAt":"2026-08-08T00:00:00Z","archivedAt":null,"trashed":null,"relations":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]},"inverseRelations":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}}}___HTTP_CODE___200' ;;
*) printf '%s' '{"data":{}}___HTTP_CODE___200' ;;
esac
SH
chmod +x "$TMP_ROOT/bin/curl"

# checkout DIR: a repository under the filing bar, holding no package.
checkout() {
  mkdir -p "$1"
  git -C "$1" init -q -b main
  git -C "$1" config gc.auto 0
  git -C "$1" config maintenance.auto false
  printf '[env]\nLINEAR_TEAM = "Configured"\nLINEAR_REQUIRE_REACH = "1"\n' >"$1/kendex.settings.toml"
}

# project DIR: a checkout holding this package.
project() {
  checkout "$1"
  mkdir -p "$1/.agents/skills"
  cp -R "$SKILL_DIR" "$1/.agents/skills/linear"
}

# install SKILLS_DIR: this package with every other catalog package beside
# it, the real reader among them.
install() {
  mkdir -p "$1"
  [ -d "$1/linear" ] || cp -R "$SKILL_DIR" "$1/linear"
  for package in "$SKILLS"/*/; do
    package="${package%/}"
    [ "${package##*/}" = linear ] || ln -s "$package" "$1/${package##*/}"
  done
}

LAUNCH="$TMP_ROOT/launch"
project "$LAUNCH"
install "$LAUNCH/.agents/skills"
# A Claude alias of this package alone, as an install lays one out when orch
# is installed for another harness only.
mkdir -p "$LAUNCH/.claude/skills"
ln -s ../../.agents/skills/linear "$LAUNCH/.claude/skills/linear"

# orch copied into Claude's own directory alone, beside a Claude alias of this
# package, so the shared tree holds no orch. The copy relays to the catalog's
# reader and records the change-scope it was given.
COPIED="$TMP_ROOT/copied"
project "$COPIED"
mkdir -p "$COPIED/.claude/skills/orch/scripts"
ln -s ../../.agents/skills/linear "$COPIED/.claude/skills/linear"
ln -s "$SKILLS/change-scope" "$COPIED/.claude/skills/change-scope"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$CHANGE_SCOPE_PATHS_CLI" >"%s"\nexec "%s" "$@"\n' \
  "$COPIED/scope" "$SKILLS/orch/scripts/orch-runtime" >"$COPIED/.claude/skills/orch/scripts/orch-runtime"
chmod +x "$COPIED/.claude/skills/orch/scripts/orch-runtime"

# A home-scope install, and a checkout that holds no package filing from it.
HOME_SKILLS="$TMP_ROOT/home/.agents/skills"
install "$HOME_SKILLS"
BARE="$TMP_ROOT/bare"
checkout "$BARE"

# A checkout whose settings name a change-scope of its own, which records
# that it ran.
PLANTED="$TMP_ROOT/planted"
checkout "$PLANTED"
mkdir -p "$PLANTED/scope"
printf '#!/usr/bin/env bash\n: >"%s"\nexit 0\n' "$PLANTED/ran" >"$PLANTED/scope/change-scope"
cp "$PLANTED/scope/change-scope" "$PLANTED/scope/harness-only"
chmod +x "$PLANTED/scope/change-scope" "$PLANTED/scope/harness-only"
printf 'CHANGE_SCOPE_PATHS_CLI = "%s"\n' "$PLANTED/scope/harness-only" >>"$PLANTED/kendex.settings.toml"

# A reader that reaches no verdict: orch's wrapper with its runtime unbuilt
# and no cargo to build it.
UNBUILT="$TMP_ROOT/unbuilt"
project "$UNBUILT"
mkdir -p "$UNBUILT/.agents/skills/orch/scripts"
printf '#!/usr/bin/env bash\necho "orch-runtime: setup-required key=k run=setup" >&2\nexit 69\n' \
  >"$UNBUILT/.agents/skills/orch/scripts/orch-runtime"
chmod +x "$UNBUILT/.agents/skills/orch/scripts/orch-runtime"

# A reader that records which Linear credentials reached it, one line each.
CREDENTIALS=(LINEAR_API_KEY LINEAR_API_KEY_OVERRIDE LINEAR_APP_TOKEN LINEAR_CLIENT_ID LINEAR_CLIENT_SECRET)
WITNESS="$TMP_ROOT/witness"
project "$WITNESS"
mkdir -p "$WITNESS/.agents/skills/orch/scripts"
{
  printf '#!/usr/bin/env bash\n{\n'
  for key in "${CREDENTIALS[@]}"; do
    printf '  printf "%s=%%s\\n" "${%s-unset}"\n' "$key" "$key"
  done
  printf '} >"%s"\nexit 0\n' "$WITNESS/credential"
} >"$WITNESS/.agents/skills/orch/scripts/orch-runtime"
chmod +x "$WITNESS/.agents/skills/orch/scripts/orch-runtime"

# The parent environment wins over project files, so every key either
# package reads is unset for the run and the settings file is the only source.
run_create() { # CWD BODY_FILE [SKILLS_DIR]
  : >"$CURL_LOG"
  RC=0
  (cd "$1" && env -u LINEAR_TEAM -u LINEAR_AGENT_LABELS -u LINEAR_REQUIRE_REACH -u CHANGE_SCOPE_PATHS_CLI \
    PATH="$TMP_ROOT/bin:$PATH" LINEAR_API_KEY=test-token CURL_LOG="$CURL_LOG" \
    bash "${3:-$1/.agents/skills}/linear/scripts/linear.sh" issues create --title "Launch read" --description-file "$2" \
    >/dev/null 2>"$ERR_FILE") || RC=$?
  ERR="$(cat "$ERR_FILE")"
}

api_calls() { wc -l <"$CURL_LOG" | tr -d ' '; }

# body FILE DELTA CONTEXT: a template-form body with DELTA under Filing record
# and CONTEXT under Context, each `-` for none and `\n` a line break.
body() {
  {
    printf '%s\n' '> **Story:** A filer creates an item and its lane launches.' '' \
      '> **Why this matters:** A refused launch costs a lane walk.' '' \
      '## Done when' '' '- [ ] The item launches.' '' '## Filing record' '' \
      '**Reached by**: every `linear.sh issues create` a lane later launches.' '' \
      '**Supersession**: none found; searched: launch read'
    [ "$2" = - ] || printf '\n%b\n' "$2"
    [ "$3" = - ] || printf '\n## Context\n\n%b\n' "$3"
  } >"$1"
}

echo "=== a body the launch refuses or reads as no delta is refused before any API call ==="
# expected|reader cause|row|Expected delta line|Context
while IFS='|' read -r expected cause row delta context; do
  body "$TMP_ROOT/body.md" "$delta" "$context"
  run_create "$LAUNCH" "$TMP_ROOT/body.md"
  case "$expected" in
    created)
      assert_eq "$row creates" "$RC" 0
      assert "$row reaches issueCreate" jq -s -e 'any(.[]; .query | contains("issueCreate"))' "$CURL_LOG"
      ;;
    refused)
      assert_ne "$row is refused" "$RC" 0
      assert_eq "$row is refused before any API call" "$(api_calls)" 0
      assert_contains "$row is refused on the reader's $cause" "$ERR" "orch-runtime: tier cause=$cause"
      ;;
  esac
done <<'ROWS'
refused|location-unread|a Location whose paths are on the next line|**Expected delta**: 30 lines|**Location**:\n`skills/linear/scripts/lib/issue-validation.sh` `skills/linear/tests`
refused|invalid-delta|a delta of test lines alone|**Expected delta**: 20 test lines|**Location**: `skills/linear/tests`
refused|invalid-delta|an approximate delta of added lines|**Expected delta**: about 110 lines added|**Location**: `skills/linear/tests`
refused|invalid-delta|a delta the launch drops in a body with no Location yet|**Expected delta**: about 110 lines added|-
created|-|the template form|**Expected delta**: 30 lines, 40 test lines|**Location**: `skills/linear/scripts/lib/issue-validation.sh` `skills/linear/tests` `skills/orch/runtime/src`
created|-|a body with no Location and no delta|-|-
ROWS

echo "=== a reader that reaches no verdict refuses the create ==="
body "$TMP_ROOT/body.md" '**Expected delta**: 30 lines' '**Location**: `skills/linear/tests`'
run_create "$UNBUILT" "$TMP_ROOT/body.md"
assert_ne "an unbuilt reader's create is refused" "$RC" 0
assert_eq "an unbuilt reader's create is refused before any API call" "$(api_calls)" 0
assert_contains "the refusal relays the reader's setup line" "$ERR" "orch-runtime: setup-required"

echo "=== the reader reads beside the install, whatever checkout the create runs from ==="
TEMPLATE_DELTA='**Expected delta**: 30 lines, 40 test lines'
TEMPLATE_LOCATION='**Location**: `skills/linear/tests`'
body "$TMP_ROOT/body.md" "$TEMPLATE_DELTA" "$TEMPLATE_LOCATION"
run_create "$BARE" "$TMP_ROOT/body.md" "$HOME_SKILLS"
assert_eq "a home-scope install creates the template form from a checkout with no package" "$RC" 0
assert "a home-scope install's create reaches issueCreate" jq -s -e 'any(.[]; .query | contains("issueCreate"))' "$CURL_LOG"
body "$TMP_ROOT/body.md" '**Expected delta**: 20 test lines' "$TEMPLATE_LOCATION"
run_create "$BARE" "$TMP_ROOT/body.md" "$HOME_SKILLS"
assert_eq "a home-scope install's refused body is refused before any API call" "$(api_calls)" 0
assert_contains "a home-scope install's refused body is refused on the reader's invalid-delta" "$ERR" "orch-runtime: tier cause=invalid-delta"
body "$TMP_ROOT/body.md" "$TEMPLATE_DELTA" "$TEMPLATE_LOCATION"
run_create "$PLANTED" "$TMP_ROOT/body.md" "$HOME_SKILLS"
assert_eq "a checkout naming its own change-scope creates the template form" "$RC" 0
assert_eq "a checkout's own change-scope never runs in the create" "$([ -e "$PLANTED/ran" ] && echo ran || echo not-run)" not-run

body "$TMP_ROOT/body.md" '**Expected delta**: 20 test lines' "$TEMPLATE_LOCATION"
run_create "$LAUNCH" "$TMP_ROOT/body.md" "$LAUNCH/.claude/skills"
assert_eq "a create through a Claude alias with no orch alias is refused before any API call" "$(api_calls)" 0
assert_contains "a create through a Claude alias is refused on the shared orch's invalid-delta" "$ERR" "orch-runtime: tier cause=invalid-delta"
run_create "$COPIED" "$TMP_ROOT/body.md" "$COPIED/.claude/skills"
assert_eq "a create through a Claude alias with orch copied for Claude alone is refused before any API call" "$(api_calls)" 0
assert_contains "a create through a Claude alias is refused on the copied orch's invalid-delta" "$ERR" "orch-runtime: tier cause=invalid-delta"
assert_eq "the copied orch's read is given the change-scope beside it" \
  "$(cat "$COPIED/scope" 2>/dev/null || echo unread)" "$COPIED/.claude/skills/change-scope/scripts/harness-only"

echo "=== the reader gets no Linear credential ==="
body "$TMP_ROOT/body.md" "$TEMPLATE_DELTA" "$TEMPLATE_LOCATION"
LINEAR_API_KEY_OVERRIDE=test-override LINEAR_APP_TOKEN=test-app-token \
  LINEAR_CLIENT_ID=test-client-id LINEAR_CLIENT_SECRET=test-client-secret \
  run_create "$WITNESS" "$TMP_ROOT/body.md"
assert_eq "a reader's create proceeds" "$RC" 0
for key in "${CREDENTIALS[@]}"; do
  assert "the reader runs without $key" grep -qFx "$key=unset" "$WITNESS/credential"
done
