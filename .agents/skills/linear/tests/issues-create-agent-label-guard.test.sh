#!/usr/bin/env bash
# issues created outside the TPM pipeline land
# with no agent:* label and are invisible to agent routing, while the CLI
# prints a URL that looks like success.
#
# When the project declares its agent-label taxonomy (LINEAR_AGENT_LABELS in
# kendex.settings.toml [env]), a bare `issues create` must refuse before any
# API call, with an actionable error naming the TPM pipeline and the
# --no-agent-label escape hatch. Projects with no declaration are unaffected.
#
# One table. A row names the declared taxonomy and the create's arguments and
# pins what came back as one line: the exit status, every logged operation
# with the label it resolved or the labels the create carried, then stderr
# whole, so a refusal is pinned on its entire line and a create on the labels
# that reached it.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/assert.sh
source "$SCRIPT_DIR/lib/assert.sh"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
assert_tmpdir TMP_ROOT

PROJECT="$TMP_ROOT/project"
mkdir -p "$PROJECT/.agents/skills" "$PROJECT/bin"
git -C "$PROJECT" init -q -b main
cp -R "$SKILL_DIR" "$PROJECT/.agents/skills/linear"

LINEAR="$PROJECT/.agents/skills/linear/scripts/linear.sh"
CURL_LOG="$TMP_ROOT/curl-payloads.jsonl"

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

# --- the renderer -------------------------------------------------------------
# Every logged payload as `Operation(path=value,...)`: a lookup's name (as
# JSON, so a stray space shows) and the create's title and labelIds, an empty
# list rendered as `input.labelIds=[]` so it is told from no key.
wire() {
  jq -r '
    def op: (.query | capture("^[[:space:]]*(query|mutation)[[:space:]]+(?<n>[A-Za-z_]+)").n)
      // (.query | capture("\\{[[:space:]]*(?<n>[A-Za-z_]+)").n);
    def shown: [(.variables // {}) as $v | $v | paths(scalars) as $p
      | select($p == ["name"] or $p == ["input", "title"] or ($p[0:2] == ["input", "labelIds"]))
      | "\($p | map(tostring) | join("."))=\($v | getpath($p) | tojson)"]
      + (if (.variables.input.labelIds? // null) == [] then ["input.labelIds=[]"] else [] end);
    "\(op)(\(shown | join(",")))"' "$CURL_LOG" | paste -sd, -
}

# run TAXONOMY VIEW ARGS... — `issues create ARGS` in the project whose
# settings declare TAXONOMY (`none`: no LINEAR_AGENT_LABELS key; `empty`: the
# key with no value; else the declared list), with LINEAR_TEAM and
# LINEAR_AGENT_LABELS absent from the process (parent env wins over project
# files). VIEW `err` renders the wire and stderr; `out` the first stdout line;
# `doc` stdout whole.
run() {
  local taxonomy="$1" view="$2" rc=0 out err
  shift 2
  case "$taxonomy" in
  none) printf '[env]\nLINEAR_TEAM = "Configured"\n' >"$PROJECT/kendex.settings.toml" ;;
  empty) printf '[env]\nLINEAR_TEAM = "Configured"\nLINEAR_AGENT_LABELS = ""\n' >"$PROJECT/kendex.settings.toml" ;;
  *) printf '[env]\nLINEAR_TEAM = "Configured"\nLINEAR_AGENT_LABELS = "%s"\n' "$taxonomy" >"$PROJECT/kendex.settings.toml" ;;
  esac
  : >"$CURL_LOG"
  out="$(cd "$PROJECT" && env -u LINEAR_TEAM -u LINEAR_AGENT_LABELS PATH="$PROJECT/bin:$PATH" LINEAR_API_KEY=test-token \
    CURL_LOG="$CURL_LOG" bash "$LINEAR" issues create "$@" 2>"$TMP_ROOT/err")" || rc=$?
  err="$(paste -sd';' "$TMP_ROOT/err")"
  case "$view" in
  out) printf 'rc=%s calls=%s %s' "$rc" "$(wc -l <"$CURL_LOG" | tr -d ' ')" "$(printf '%s\n' "$out" | head -1)" ;;
  err) printf 'rc=%s wire=%s%s' "$rc" "$(wire)" "${err:+ $err}" ;;
  doc) printf '%s' "$out" ;;
  *) printf 'UNKNOWN-VIEW:%s' "$view" ;;
  esac
}

# --- the expected lines --------------------------------------------------------
# expected SPEC — from the row's spec:
#   unrouted DECLARED       the bare-create refusal, listing DECLARED
#   unknown NAMES~DECLARED  the typo refusal for NAMES against DECLARED
#   unresolved NAME         the hard failure of a declared label Linear lacks,
#                           after the resolver's own warning
#   created WIRE            exit 0, the team lookup then exactly WIRE, nothing
#                           on stderr
#   created WIRE warn NAME  the same, with the warn-and-skip lines for NAME
#   help                    one help document, no call
TEAM='GetTeam(name="Configured")'
warned() { printf "Warning: Label not found: '%s';" "$1"; }
expected() {
  local spec="$1"
  case "$spec" in
  unrouted\ *)
    printf 'rc=1 wire= {"error":"Refusing to create an unrouted issue: this project declares an agent-label taxonomy (LINEAR_AGENT_LABELS in kendex.settings.toml [env]) and no agent:* label was supplied. An issue created without one gets no agent routing - the create would print a URL and look like success while the issue sits invisible to every agent. Route tracked issue creation through the TPM pipeline (project-management skill), which owns labels, project, priority, and relations. Direct create is for exceptions only: pass --labels with one of [%s], or --no-agent-label for a deliberate bare create (e.g. intake mirroring)."}' "${spec#unrouted }" ;;
  unknown\ *)
    spec="${spec#unknown }"
    printf 'rc=1 wire= {"error":"Unknown agent label(s): %s - not in this project declared agent-label set (LINEAR_AGENT_LABELS in kendex.settings.toml [env]): %s. Label resolution silently skips unknown names, so this would create an issue that is invisible to agent routing. Fix the label name, or pass --no-agent-label for a deliberate bare create."}' "${spec%%~*}" "${spec#*~}" ;;
  unresolved\ *)
    spec="${spec#unresolved }"
    printf 'rc=1 wire=%s,GetLabel(name="%s") %s{"error":"Agent label failed to resolve in Linear: %s - refusing to create an issue that would look routed but is not. Create the label in Linear (or fix LINEAR_AGENT_LABELS), then retry."}' "$TEAM" "$spec" "$(warned "$spec")" "$spec" ;;
  created\ *\ warn\ *)
    spec="${spec#created }"
    printf "rc=0 wire=%s,%s %sSkipped label '%s' — not found; the create proceeds without it" "$TEAM" "${spec% warn *}" "$(warned "${spec##* warn }")" "${spec##* warn }" ;;
  created\ *) printf 'rc=0 wire=%s,%s' "$TEAM" "${spec#created }" ;;
  help) printf 'rc=0 calls=0 Issue Operations' ;;
  *) printf 'UNKNOWN-SPEC:%s' "$spec" ;;
  esac
}

# --- the table ------------------------------------------------------------------
# label|taxonomy|view|args|expect
# The declared taxonomy is split on commas and spaces; the supplied labels on
# commas only (a label name may hold a space), so `bug, agent:rust` reaches
# the guard and the resolver trimmed.
ROWS='
bare create is refused|agent:generalist, agent:rust|err|--title "Unrouted follow-up"|unrouted agent:generalist, agent:rust
a create with only non-agent labels is refused|agent:generalist, agent:rust|err|--title "Unrouted follow-up" --labels "bug,docs"|unrouted agent:generalist, agent:rust
a typoed agent label is refused, naming it and the declared set|agent:generalist, agent:rust|err|--title Typo --labels "agent:generalst"|unknown agent:generalst~agent:generalist, agent:rust
two typoed agent labels are both named|agent:generalist, agent:rust|err|--title Typo --labels "agent:generalst,agent:rustt"|unknown agent:generalst, agent:rustt~agent:generalist, agent:rust
a declared agent label passes and every label resolves onto the create|agent:generalist, agent:rust|err|--title Routed --labels "bug,agent:rust"|created GetLabel(name="bug"),GetLabel(name="agent:rust"),CreateIssue(input.title="Routed",input.labelIds.0="label-uuid",input.labelIds.1="label-uuid")
a declared agent label passes through --label|agent:generalist, agent:rust|err|--title "Routed single" --label "agent:generalist"|created GetLabel(name="agent:generalist"),CreateIssue(input.title="Routed single",input.labelIds.0="label-uuid")
--no-agent-label permits a deliberate bare create|agent:generalist, agent:rust|err|--title "Intake mirror" --no-agent-label|created CreateIssue(input.title="Intake mirror")
--no-agent-label permits a non-agent-labeled create|agent:generalist, agent:rust|err|--title "Intake mirror" --no-agent-label --labels bug|created GetLabel(name="bug"),CreateIssue(input.title="Intake mirror",input.labelIds.0="label-uuid")
no declaration: a bare create is unaffected|none|err|--title "Bare repo create"|created CreateIssue(input.title="Bare repo create")
no declaration: an unresolvable agent label warn-skips|none|err|--title "Undeclared skip" --labels "agent:ghost"|created GetLabel(name="agent:ghost"),CreateIssue(input.title="Undeclared skip") warn agent:ghost
an empty declaration: a bare create is unaffected|empty|err|--title "Empty declaration create"|created CreateIssue(input.title="Empty declaration create")
comma-space labels reach the guard and the resolver trimmed|agent:generalist, agent:rust|err|--title "Natural input" --labels "bug, agent:rust"|created GetLabel(name="bug"),GetLabel(name="agent:rust"),CreateIssue(input.title="Natural input",input.labelIds.0="label-uuid",input.labelIds.1="label-uuid")
a declared label missing in Linear hard-fails the create|agent:generalist, agent:rust, agent:ghost|err|--title "Stale declared label" --labels "agent:ghost"|unresolved agent:ghost
--help never trips the guard|agent:generalist, agent:rust|out|--help|help
'

while IFS='|' read -r label taxonomy view args spec; do
  [ -n "$label$taxonomy$view$args$spec" ] || continue
  eval "set -- $args"
  assert_eq "$label" "$(run "$taxonomy" "$view" "$@")" "$(expected "$spec")"
done <<<"$ROWS"

# The help document names the escape hatch.
assert_contains "issues create --help documents --no-agent-label" \
  "$(run "agent:generalist, agent:rust" doc --help)" "--no-agent-label"
