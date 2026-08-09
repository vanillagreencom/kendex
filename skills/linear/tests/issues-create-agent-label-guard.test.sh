#!/usr/bin/env bash
# Regression test for VST-147: issues created outside the TPM pipeline land
# with no agent:* label and are invisible to agent routing, while the CLI
# prints a URL that looks like success.
#
# When the project declares its agent-label taxonomy (LINEAR_AGENT_LABELS in
# vstack.settings.toml [env]), a bare `issues create` must refuse before any
# API call, with an actionable error naming the TPM pipeline and the
# --no-agent-label escape hatch. Projects with no declaration are unaffected.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PROJECT="$TMP_ROOT/project"
mkdir -p "$PROJECT/.agents/skills" "$PROJECT/bin"
git -C "$PROJECT" init -q -b main
cp -R "$SKILL_DIR" "$PROJECT/.agents/skills/linear"

LINEAR="$PROJECT/.agents/skills/linear/scripts/linear.sh"
CURL_LOG="$TMP_ROOT/curl-payloads.jsonl"
ERR_FILE="$TMP_ROOT/stderr.txt"

cat >"$PROJECT/bin/curl" <<'SH'
#!/usr/bin/env bash
config="$(cat)"
payload="$(sed -n 's/^data = //p' <<<"$config" | jq -r)"
printf '%s\n' "$payload" >>"${CURL_LOG:?}"
query="$(jq -r '.query' <<<"$payload")"

case "$query" in
*"teams(filter:"*)
  printf '%s' '{"data":{"teams":{"nodes":[{"id":"team-uuid"}]}}}___HTTP_CODE___200'
  ;;
*"issueLabels(filter:"*)
  # agent:ghost simulates a label declared in LINEAR_AGENT_LABELS but since
  # deleted in Linear; any name that is not byte-exact (e.g. " agent:rust"
  # with a leading space) also misses, mirroring the API's eq filter.
  name="$(jq -r '.variables.name // empty' <<<"$payload")"
  if [ "$name" = "agent:ghost" ] || [ "$name" != "$(printf '%s' "$name" | sed 's/^ *//;s/ *$//')" ]; then
    printf '%s' '{"data":{"issueLabels":{"nodes":[]}}}___HTTP_CODE___200'
  else
    printf '%s' '{"data":{"issueLabels":{"nodes":[{"id":"label-uuid"}]}}}___HTTP_CODE___200'
  fi
  ;;
*"issueCreate(input:"*)
  printf '%s' '{"data":{"issueCreate":{"success":true,"issue":{"id":"issue-uuid","identifier":"TEAM-1","title":"t","description":"","state":{"name":"Todo","type":"unstarted"},"assignee":null,"project":null,"projectMilestone":null,"cycle":null,"parent":null,"team":{"name":"Configured"},"labels":{"nodes":[]},"priority":3,"estimate":null,"sortOrder":1.0,"url":"https://linear.app/x/issue/TEAM-1","createdAt":"2026-08-08T00:00:00Z","updatedAt":"2026-08-08T00:00:00Z","archivedAt":null,"trashed":null,"relations":{"nodes":[]},"inverseRelations":{"nodes":[]}}}}}___HTTP_CODE___200'
  ;;
*)
  printf '%s' '{"data":{}}___HTTP_CODE___200'
  ;;
esac
SH
chmod +x "$PROJECT/bin/curl"

OUT=""
ERR=""
RC=0

fail() {
  echo "FAIL $*"
  [[ -s "$CURL_LOG" ]] && echo "--- curl payloads ---" && cat "$CURL_LOG"
  exit 1
}

# Run the CLI inside the temp project with LINEAR_TEAM and LINEAR_AGENT_LABELS
# absent from the process environment (parent env wins over project files).
run_linear() {
  : >"$CURL_LOG"
  set +e
  OUT="$(cd "$PROJECT" && env -u LINEAR_TEAM -u LINEAR_AGENT_LABELS \
    PATH="$PROJECT/bin:$PATH" \
    LINEAR_API_KEY=test-token \
    CURL_LOG="$CURL_LOG" \
    bash "$LINEAR" "$@" 2>"$ERR_FILE")"
  RC=$?
  set -e
  ERR="$(cat "$ERR_FILE")"
}

set_settings() {
  # $1: LINEAR_AGENT_LABELS value ("" = key present but empty)
  printf '[env]\nLINEAR_TEAM = "Configured"\nLINEAR_AGENT_LABELS = "%s"\n' "$1" \
    >"$PROJECT/vstack.settings.toml"
}

set_settings_no_taxonomy_key() {
  printf '[env]\nLINEAR_TEAM = "Configured"\n' >"$PROJECT/vstack.settings.toml"
}

api_calls() {
  wc -l <"$CURL_LOG" | tr -d ' '
}

assert_refused_bare() {
  local label="$1"
  [[ "$RC" -ne 0 ]] || fail "$label exited 0; expected a refusal. stdout: $OUT"
  grep -q "agent" <<<"$ERR" || fail "$label refusal does not mention agent labels: $ERR"
  grep -q "LINEAR_AGENT_LABELS" <<<"$ERR" || fail "$label refusal does not name LINEAR_AGENT_LABELS: $ERR"
  grep -q "project-management" <<<"$ERR" || fail "$label refusal does not route to the TPM pipeline (project-management): $ERR"
  grep -q -- "--no-agent-label" <<<"$ERR" || fail "$label refusal does not name the --no-agent-label escape hatch: $ERR"
  grep -q "agent:rust" <<<"$ERR" || fail "$label refusal does not list the declared agent labels: $ERR"
  [[ "$(api_calls)" == "0" ]] || fail "$label attempted $(api_calls) API call(s) before refusing"
}

assert_created() {
  local label="$1"
  [[ "$RC" -eq 0 ]] || fail "$label exited $RC: $ERR"
  jq -s -e 'any(.[]; .query | contains("issueCreate"))' "$CURL_LOG" >/dev/null ||
    fail "$label did not reach issueCreate: $(cat "$CURL_LOG")"
}

echo "=== declared taxonomy: bare create refuses before any API call ==="

set_settings "agent:generalist, agent:rust"

run_linear issues create --title "Unrouted follow-up"
assert_refused_bare "bare create"

run_linear issues create --title "Unrouted follow-up" --labels "bug,docs"
assert_refused_bare "create with only non-agent labels"

echo "=== declared taxonomy: an unknown agent:* label refuses (typo guard) ==="

# resolve_label_id warns and SKIPS unresolved labels, so a typoed agent label
# would otherwise create an unrouted issue that looks routed.
run_linear issues create --title "Typo" --labels "agent:generalst"
[[ "$RC" -ne 0 ]] || fail "typoed agent label exited 0: $OUT"
grep -q "agent:generalst" <<<"$ERR" || fail "typo refusal does not name the unknown label: $ERR"
grep -q "LINEAR_AGENT_LABELS" <<<"$ERR" || fail "typo refusal does not name the declared set: $ERR"
[[ "$(api_calls)" == "0" ]] || fail "typoed agent label attempted $(api_calls) API call(s)"

echo "=== declared taxonomy: a declared agent label passes ==="

run_linear issues create --title "Routed" --labels "bug,agent:rust"
assert_created "create with declared agent label"
jq -s -e 'any(.[]; (.query | contains("issueCreate")) and (.variables.input.labelIds | length == 2))' "$CURL_LOG" >/dev/null ||
  fail "labels were not all resolved onto the create: $(cat "$CURL_LOG")"

run_linear issues create --title "Routed single" --label "agent:generalist"
assert_created "create with --label agent label"

echo "=== declared taxonomy: --no-agent-label permits a deliberate bare create ==="

run_linear issues create --title "Intake mirror" --no-agent-label
assert_created "bare create with --no-agent-label"

run_linear issues create --title "Intake mirror" --no-agent-label --labels "bug"
assert_created "non-agent-labeled create with --no-agent-label"

echo "=== no declaration: bare creates are unaffected ==="

set_settings_no_taxonomy_key
run_linear issues create --title "Bare repo create"
assert_created "bare create with no LINEAR_AGENT_LABELS key"

set_settings ""
run_linear issues create --title "Empty declaration create"
assert_created "bare create with empty LINEAR_AGENT_LABELS"

echo "=== declared taxonomy: comma-space labels normalize for guard AND resolver ==="

# Natural input "bug, agent:rust": the guard must accept it AND the resolver
# must receive the TRIMMED names — an untrimmed " agent:rust" misses Linear's
# eq filter and is silently skipped, recreating the unrouted-but-looks-routed
# create the guard exists to prevent.
set_settings "agent:generalist, agent:rust"
run_linear issues create --title "Natural input" --labels "bug, agent:rust"
assert_created "create with comma-space labels"
jq -s -e 'any(.[]; .variables.name == "agent:rust")' "$CURL_LOG" >/dev/null ||
  fail "resolver did not receive the trimmed agent label: $(cat "$CURL_LOG")"
if jq -s -e 'any(.[]; .variables.name == " agent:rust")' "$CURL_LOG" >/dev/null; then
  fail "resolver received an untrimmed label name: $(cat "$CURL_LOG")"
fi
jq -s -e 'any(.[]; (.query | contains("issueCreate")) and (.variables.input.labelIds | length == 2))' "$CURL_LOG" >/dev/null ||
  fail "both normalized labels must resolve onto the create: $(cat "$CURL_LOG")"

echo "=== declared taxonomy: a declared label missing in Linear hard-fails the create ==="

# The guard's promise is routed-or-refused: a label that passes the declared
# set but fails to resolve (declared in settings, deleted in Linear) must fail
# the create, never warn-and-skip into an unrouted issue.
set_settings "agent:generalist, agent:rust, agent:ghost"
run_linear issues create --title "Stale declared label" --labels "agent:ghost"
[[ "$RC" -ne 0 ]] || fail "unresolvable agent label exited 0: $OUT"
grep -q "agent:ghost" <<<"$ERR" || fail "hard-fail does not name the unresolvable label: $ERR"
if jq -s -e 'any(.[]; .query | contains("issueCreate"))' "$CURL_LOG" >/dev/null; then
  fail "issueCreate was reached despite an unresolvable agent label"
fi

echo "=== help never trips the guard ==="

set_settings "agent:generalist, agent:rust"
run_linear issues create --help
[[ "$RC" -eq 0 ]] || fail "issues create --help exited $RC: $ERR"
grep -q -- "--no-agent-label" <<<"$OUT" || fail "issues create --help does not document --no-agent-label: $OUT"
[[ "$(api_calls)" == "0" ]] || fail "issues create --help issued an API call"

echo "all pass"
