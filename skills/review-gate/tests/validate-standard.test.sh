#!/usr/bin/env bash
# validate-standard.sh against a fake GitHub: a repository matching the
# standard reports every row ok, and each drifted element reports its own
# row and no other. The whole verdict listing is compared, so a row that
# goes missing or flips beside the drifted one is caught too.
set -euo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf -- "${TMP:?}"' EXIT

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() {
  FAIL=$((FAIL + 1))
  printf '  FAIL  %s\n' "$1"
  printf '%s\n' "$2" | sed 's/^/        /'
}

# A skill copy with a test-owned standard, so the expected values below are
# literals and not a second reading of the shipped manifest.
SKILL="$TMP/skill"
BIN="$TMP/bin"
BASE="$TMP/base"
mkdir -p "$SKILL" "$BIN" "$BASE"
cp -R "$SKILL_DIR/scripts" "$SKILL/scripts"
. "$TEST_DIR/lib/workflow-edit.sh"

cat >"$SKILL/standard.json" <<'JSON'
{
  "ci_context": "CI",
  "gate_context": "Review gate"
}
JSON
cp "$TEST_DIR/lib/gh-shim.sh" "$BIN/gh"
chmod +x "$BIN/gh"

# This suite's wrapper injects real gh diagnostics at the branch read only.
mv "$BIN/gh" "$BIN/gh-base"
cat >"$BIN/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
for arg in "$@"; do
  if [ "$arg" = repos/acme/widgets/branches/main ] && [ -f "$GH_SHIM_FIXTURES/.retry-error" ]; then
    count=0
    [ ! -f "$GH_SHIM_FIXTURES/.retry-count" ] || count="$(cat "$GH_SHIM_FIXTURES/.retry-count")"
    count=$((count + 1))
    printf '%s\n' "$count" >"$GH_SHIM_FIXTURES/.retry-count"
    limit="$(cat "$GH_SHIM_FIXTURES/.retry-limit")"
    if [ "$count" -le "$limit" ]; then
      cat "$GH_SHIM_FIXTURES/.retry-error" >&2
      exit 1
    fi
  fi
done
exec "${BASH_SOURCE[0]%/*}/gh-base" "$@"
SH
cat >"$BIN/sleep" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$GH_SHIM_FIXTURES/.retry-waits"
SH
chmod +x "$BIN/gh" "$BIN/sleep"

# The consumer checkouts the script runs from, each declaring the
# repository's values in its own kendex.settings.toml or not. `full` is the
# consumer every case uses unless it names another; its contexts are out of
# order, so the sorted value below is the loader's.
settings_consumer() { # NAME [ASSIGNMENT...]
  local dir="$TMP/consumer-$1"
  shift
  mkdir -p "$dir"
  printf '[env]\n' >"$dir/kendex.settings.toml"
  [ "$#" -eq 0 ] || printf '%s\n' "$@" >>"$dir/kendex.settings.toml"
}
# `full` also admits bypass actors on a ruleset holding one rule type alone:
# two apps on the queue ruleset, one of them in pull-request mode on the
# checks ruleset. `no-bypass` declares the rest and admits none.
QUEUE_BYPASS='REVIEW_GATE_STANDARD_QUEUE_BYPASS = "Integration:4925608:always; Integration:5115517:pull_request"'
CHECKS_BYPASS='REVIEW_GATE_STANDARD_CHECKS_BYPASS = "Integration:5115517:pull_request"'
CONTEXTS='REVIEW_GATE_STANDARD_CONTEXTS = "Cargo (workspace tests); CI"'
settings_consumer full "$CONTEXTS" "$QUEUE_BYPASS" "$CHECKS_BYPASS"
settings_consumer no-bypass "$CONTEXTS"
settings_consumer bad-bypass "$CONTEXTS" 'REVIEW_GATE_STANDARD_QUEUE_BYPASS = "Integration:4925608:always;lanes-app;Integration:5115517:bypass"'
settings_consumer no-contexts
settings_consumer empty-contexts 'REVIEW_GATE_STANDARD_CONTEXTS = ""'
settings_consumer gated 'REVIEW_GATE_STANDARD_CONTEXTS = "Cargo (workspace tests);CI;Review gate"'
# The organization keys this report read before the organization's own
# tooling took the environment and app rows: the report reads none of them,
# so a consumer still holding them, set or empty, reads like `full`.
settings_consumer retired "$CONTEXTS" "$QUEUE_BYPASS" "$CHECKS_BYPASS" 'REVIEW_GATE_STANDARD_APP = ""' 'REVIEW_GATE_STANDARD_ENVIRONMENT = "kendex"' 'REVIEW_GATE_STANDARD_SECRETS = "app-id; 9KEY"'
CONSUMER="$TMP/consumer-full"

# The matching world: it reads ok on every row of the BASELINE below and is
# not the whole target, whose contexts are bound to their app and whose
# repository rulesets name bypass actors. The organization rulesets 1 and 2
# hold the shared rules, the repository ruleset 3 the merge queue and the
# repository ruleset 4 the required checks.
cat >"$BASE/repository.json" <<'JSON'
{"full_name": "acme/widgets", "default_branch": "main"}
JSON
cat >"$BASE/rules.json" <<'JSON'
[
  {"type": "deletion", "ruleset_source_type": "Organization", "ruleset_id": 1},
  {"type": "non_fast_forward", "ruleset_source_type": "Organization", "ruleset_id": 1},
  {"type": "pull_request", "parameters": {"required_approving_review_count": 1, "dismiss_stale_reviews_on_push": true, "required_review_thread_resolution": true}, "ruleset_source_type": "Organization", "ruleset_id": 1},
  {"type": "workflows", "parameters": {"do_not_enforce_on_create": false, "workflows": [{"repository_id": 1190866154, "path": ".github/workflows/request-copilot-review.yml", "ref": "refs/heads/main", "sha": "0123456789abcdef0123456789abcdef01234567"}]}, "ruleset_source_type": "Organization", "ruleset_id": 2},
  {"type": "merge_queue", "parameters": {"merge_method": "SQUASH"}, "ruleset_source_type": "Repository", "ruleset_id": 3},
  {"type": "required_status_checks", "parameters": {"required_status_checks": [{"context": "CI"}, {"context": "Cargo (workspace tests)"}]}, "ruleset_source_type": "Repository", "ruleset_id": 4}
]
JSON
# Each ruleset is read through the endpoint of the level that owns it. The
# repository-endpoint copy of ruleset 2 carries an actor, so a read through
# the wrong endpoint reports 1.
printf '{"id": 1, "bypass_actors": []}\n' >"$BASE/org-ruleset-1.json"
printf '{"id": 2, "bypass_actors": []}\n' >"$BASE/org-ruleset-2.json"
printf '{"id": 1, "bypass_actors": []}\n' >"$BASE/ruleset-1.json"
printf '{"id": 2, "bypass_actors": [{"actor_type": "RepositoryRole", "actor_id": 9}]}\n' >"$BASE/ruleset-2.json"
printf '{"id": 3, "bypass_actors": []}\n' >"$BASE/ruleset-3.json"
printf '{"id": 4, "bypass_actors": []}\n' >"$BASE/ruleset-4.json"
printf '{"name": "main", "protected": true, "protection": {"enabled": false}}\n' >"$BASE/branch.json"
# The default branch's head, dead, is the queue's merge commit. Its first
# associated pull request merged into another branch, so a read that ignores
# the base takes the wrong head.
printf '{"sha": "dead"}\n' >"$BASE/commit.json"
cat >"$BASE/commit-pulls.json" <<'JSON'
[
  {"number": 20, "merged_at": "2026-09-22T09:00:00Z", "base": {"ref": "release"}, "head": {"sha": "cafe"}},
  {"number": 12, "merged_at": null, "base": {"ref": "main"}, "head": {"sha": "c0c0"}},
  {"number": 11, "merged_at": "2026-09-21T09:00:00Z", "base": {"ref": "main"}, "head": {"sha": "beef"}}
]
JSON
# The pull_request leg: the CI workflow's run carries the lanes and their
# aggregate; the second run is another workflow's. The merge_group leg on the
# head runs the CI workflow alone.
printf '{"workflow_runs": [{"id": 7}, {"id": 8}]}\n' >"$BASE/workflow-runs.json"
printf '{"jobs": [{"name": "lint-typecheck"}, {"name": "build"}, {"name": "CI"}]}\n' >"$BASE/jobs-7.json"
printf '{"jobs": [{"name": "writer"}]}\n' >"$BASE/jobs-8.json"
printf '{"workflow_runs": [{"id": 9}]}\n' >"$BASE/workflow-runs-merge-group.json"
printf '{"jobs": [{"name": "lint-typecheck"}, {"name": "build"}, {"name": "CI"}]}\n' >"$BASE/jobs-9.json"

BASELINE='ok check=standard-ruleset-source value=Organization\,Repository
ok check=standard-merge-queue value=present
ok check=standard-required-contexts value=CI\;Cargo\ \(workspace\ tests\)
ok check=standard-required-approvals value=1
ok check=standard-stale-dismissal value=true
ok check=standard-conversation-resolution value=true
ok check=standard-copilot-review value=present
ok check=standard-bypass-actors value=0
ok check=standard-classic-protection value=off
ok check=standard-ci-context value=CI\;build\;lint-typecheck\;writer'

# The baseline with each named row turned to its status at its observed
# value. OVERRIDES is `[STATUS:]check=value` pairs separated by `^`, values
# as printed; STATUS is advisory or ok, and FAIL where it is left out.
expected_listing() { # OVERRIDES
  local line check pair status out=""
  while IFS= read -r line; do
    check="${line#ok check=}"
    check="${check%% value=*}"
    local hit=""
    local rest="$1"
    while [ -n "$rest" ]; do
      pair="${rest%%^*}"
      [ "$pair" = "$rest" ] && rest="" || rest="${rest#*^}"
      case "$pair" in
        advisory:* | ok:*) status="${pair%%:*}"; pair="${pair#*:}" ;;
        *) status=FAIL ;;
      esac
      [ "${pair%%=*}" = "$check" ] && hit="$status check=$check value=${pair#*=}"
    done
    out="${out:+$out
}${hit:-$line}"
  done <<<"$BASELINE"
  printf '%s' "$out"
}

# The exit status and the advisory warning count OVERRIDES call for: 1 where
# one row is FAIL, else 0; one standard-advisory warning where one row is
# advisory, else none.
want_rc_of() { # OVERRIDES
  local pair rest="$1"
  while [ -n "$rest" ]; do
    pair="${rest%%^*}"
    [ "$pair" = "$rest" ] && rest="" || rest="${rest#*^}"
    case "$pair" in
      advisory:* | ok:*) ;;
      *) echo 1; return ;;
    esac
  done
  echo 0
}
want_advisories_of() { # OVERRIDES
  case "^$1" in
    *^advisory:*) echo 1 ;;
    *) echo 0 ;;
  esac
}

run() { # FIXTURES SHIM_FAIL [ARGS...] — sets OUT (verdict lines), RC, and
  # ADVISORIES, the count of the advisory warnings
  local fixtures="$1" shim_fail="$2"
  shift 2
  RC=0
  RAW="$(cd "$CONSUMER" && env -i PATH="$BIN:/usr/bin:/bin" HOME="$TMP" GH_SHIM_FIXTURES="$fixtures" GH_SHIM_FAIL="$shim_fail" \
    "$SKILL/scripts/validate-standard.sh" "$@" 2>&1)" || RC=$?
  OUT="$(grep -E '^(ok|advisory|FAIL) check=' <<<"$RAW" || true)"
  ADVISORIES="$(grep -c '^review-gate-warning=standard-advisory ' <<<"$RAW" || true)"
}

echo "=== each drifted element reports its own row ==="
# One drift case against the script copy as it stands: CASE_MATCH is true
# where the listing, the exit status and the warning counts are the ones
# OVERRIDES calls for, and CASE_DIFF says how they differ where not.
CASE_MATCH=false
CASE_DIFF=""
CASES=0
drift_case() { # NAME SHIM_FAIL FILES EDIT OVERRIDES [CONSUMER]
  local dir file want want_rc want_adv
  CASES=$((CASES + 1))
  dir="$TMP/case-$CASES"
  cp -R "$BASE" "$dir"
  for file in $(tr ',' ' ' <<<"$3"); do
    if [ -f "$dir/$file" ]; then
      jq "$4" "$dir/$file" >"$dir/$file.new"
    else
      jq -n "$4" >"$dir/$file.new"
    fi
    mv "$dir/$file.new" "$dir/$file"
  done
  CONSUMER="$TMP/consumer-${6:-full}"
  run "$dir" "$2"
  CONSUMER="$TMP/consumer-full"
  want="$(expected_listing "$5")"
  want_rc="$(want_rc_of "$5")"
  want_adv="$(want_advisories_of "$5")"
  CASE_MATCH=false
  if [ "$RC" -eq "$want_rc" ] && [ "$OUT" = "$want" ] && [ "$ADVISORIES" -eq "$want_adv" ]; then
    CASE_MATCH=true
  fi
  CASE_DIFF="rc=$RC want $want_rc; advisory warnings=$ADVISORIES want $want_adv
$(diff <(printf '%s\n' "$want") <(printf '%s\n' "$OUT") || true)
$RAW"
}

# name ~ shim failure ~ fixture files (comma-separated) ~ jq edit of each
# ~ overrides. A fixture that does not exist yet, such as a second page, is
# written from the edit alone. A row with an advisory override exits 0 with
# exactly one advisory warning, and the matching row prints none.
rows=0
while IFS='~' read -r name fail files edit overrides; do
  [ -n "$name" ] || continue
  rows=$((rows + 1))
  drift_case "$name" "$fail" "$files" "$edit" "$overrides"
  if [ "$CASE_MATCH" = true ]; then ok "$name"; else bad "$name" "$CASE_DIFF"; fi
done <<'ROWS'
a repository matching the standard~~~~
a pull-request rule from a repository ruleset~~rules.json~.[2].ruleset_source_type = "Repository"~advisory:standard-ruleset-source=Repository:1:pull_request\,missing:pull_request^advisory:standard-required-approvals=absent^advisory:standard-stale-dismissal=absent
no deletion rule~~rules.json~del(.[0])~advisory:standard-ruleset-source=missing:deletion
no force-push rule~~rules.json~del(.[1])~advisory:standard-ruleset-source=missing:non_fast_forward
required checks from an enterprise ruleset~~rules.json~.[5].ruleset_source_type = "Enterprise"~advisory:standard-ruleset-source=Enterprise:4:required_status_checks^standard-bypass-actors=unreadable:4
required checks from an organization ruleset~~rules.json~.[5] |= (.ruleset_source_type = "Organization" | .ruleset_id = 2)~advisory:standard-ruleset-source=Organization:2:required_status_checks
a merge queue from an organization ruleset~~rules.json~.[4] |= (.ruleset_source_type = "Organization" | .ruleset_id = 2)~advisory:standard-ruleset-source=Organization:2:merge_queue
no ruleset at all~~rules.json~[]~advisory:standard-ruleset-source=none^standard-merge-queue=absent^standard-required-contexts=''^advisory:standard-required-approvals=absent^advisory:standard-stale-dismissal=absent^standard-conversation-resolution=false^standard-copilot-review=absent
no merge queue~~rules.json~del(.[4])~standard-merge-queue=absent
an extra required context~~rules.json~.[5].parameters.required_status_checks += [{"context": "Other"}]~standard-required-contexts=CI\;Cargo\ \(workspace\ tests\)\;Other
a missing required context~~rules.json~.[5].parameters.required_status_checks = [{"context": "CI"}]~standard-required-contexts=CI
the gate context required~~rules.json~.[5].parameters.required_status_checks += [{"context": "Review gate"}]~standard-required-contexts=gate-required:CI\;Cargo\ \(workspace\ tests\)\;Review\ gate
no approval required~~rules.json~.[2].parameters.required_approving_review_count = 0~advisory:standard-required-approvals=0
stale approvals kept on push~~rules.json~.[2].parameters.dismiss_stale_reviews_on_push = false~advisory:standard-stale-dismissal=false
a laxer second organization pull-request rule~~rules.json~. += [{"type": "pull_request", "parameters": {"required_approving_review_count": 0, "dismiss_stale_reviews_on_push": false}, "ruleset_source_type": "Organization", "ruleset_id": 2}]~
threads need no resolution~~rules.json~.[2].parameters.required_review_thread_resolution = false~standard-conversation-resolution=false
no Copilot review~~rules.json~del(.[3])~advisory:standard-ruleset-source=missing:workflows^standard-copilot-review=absent
a bypass actor on each ruleset is named on each~~org-ruleset-1.json,org-ruleset-2.json~.bypass_actors = [{"actor_type": "RepositoryRole", "actor_id": 5}]~standard-bypass-actors=1=RepositoryRole:5:always\,2=RepositoryRole:5:always
an admitted queue actor on the ruleset holding every other rule is a departure~~org-ruleset-1.json~.bypass_actors = [{"actor_type": "Integration", "actor_id": 5115517, "bypass_mode": "pull_request"}]~standard-bypass-actors=1=Integration:5115517:pull_request
bypass actors withheld from the token~~org-ruleset-1.json~del(.bypass_actors)~standard-bypass-actors=unreadable:1
a repository ruleset's actors read through the repository endpoint~~rules.json~.[3].ruleset_source_type = "Repository"~advisory:standard-ruleset-source=Repository:2:workflows\,missing:workflows^standard-copilot-review=absent^standard-bypass-actors=2=RepositoryRole:9:always
a ruleset source with no ruleset read is unreadable~~rules.json~.[3].ruleset_source_type = "Enterprise"~advisory:standard-ruleset-source=Enterprise:2:workflows\,missing:workflows^standard-copilot-review=absent^standard-bypass-actors=unreadable:2
a repository deletion rule on the second page~~rules.page2.json~[{"type": "deletion", "ruleset_source_type": "Repository", "ruleset_id": 1}]~advisory:standard-ruleset-source=Repository:1:deletion
classic protection beside the rulesets~~branch.json~.protection.enabled = true~standard-classic-protection=on
the branch unreadable~branch~~~standard-classic-protection=unreadable
lanes reporting their own names and no CI aggregate~~jobs-7.json~.jobs |= map(select(.name != "CI"))~standard-ci-context=ci-context-missing:pull_request:build\;lint-typecheck\;writer
an aggregate whose name only starts with CI~~jobs-7.json~.jobs |= map(if .name == "CI" then .name = "CI Required" else . end)~standard-ci-context=ci-context-missing:pull_request:CI\ Required\;build\;lint-typecheck\;writer
no job ran on the pull request~~workflow-runs.json~.workflow_runs = []~standard-ci-context=ci-context-missing:pull_request:none
the CI job on the second page of a run's jobs~~jobs-7.json,jobs-7.page2.json~if . == null then {"jobs": [{"name": "CI"}]} else .jobs |= map(select(.name != "CI")) end~
the CI run on the second page of runs~~jobs-7.json,workflow-runs.page2.json,jobs-10.json~if . == null then {"workflow_runs": [{"id": 10}], "jobs": [{"name": "CI"}]} else .jobs |= map(select(.name != "CI")) end~
a head that did not come through the merge queue~~workflow-runs-merge-group.json~.workflow_runs = []~standard-ci-context=merge-group-unobserved:CI\;build\;lint-typecheck\;writer
a head outside the queue after an older merge group that ran CI~~workflow-runs-merge-group.json,workflow-runs-merge-group-latest.json,workflow-runs-merge-group-f00d.json,jobs-11.json~if . == null then {"workflow_runs": [{"id": 11, "head_branch": "gh-readonly-queue/main/pr-10-f00d", "head_sha": "f00d"}], "jobs": [{"name": "CI"}]} else .workflow_runs = [] end~standard-ci-context=merge-group-unobserved:CI\;build\;lint-typecheck\;writer
a merge group that ran no CI job~~jobs-9.json~.jobs |= map(select(.name != "CI"))~standard-ci-context=ci-context-missing:merge_group:build\;lint-typecheck
a head no merged pull request produced~~commit-pulls.json~map(.merged_at = null)~standard-ci-context=no-associated-pull-request
a head merged only into another branch~~commit-pulls.json~map(select(.base.ref != "main"))~standard-ci-context=no-associated-pull-request
a branch head that is not a sha~~commit.json~.sha = "main"~standard-ci-context=unreadable
a merged head that is not a sha~~commit-pulls.json~.[2].head.sha = "main"~standard-ci-context=unreadable
the branch head unreadable~commit~~~standard-ci-context=unreadable
the head's pull requests unreadable~commit-pulls~~~standard-ci-context=unreadable
pull_request runs unreadable~workflow-runs~~~standard-ci-context=unreadable
the head's merge_group runs unreadable~workflow-runs-merge-group~~~standard-ci-context=unreadable
a run's jobs unreadable~jobs-8~~~standard-ci-context=unreadable
ROWS

# The organization ruleset requests the review through kendex's workflow
# (the base fixture's rule 3, as the live ruleset carries it). The source row
# judges the workflow's repository and path; the review row also judges its
# ref and pin.
SOURCE_FAILURE='advisory:standard-ruleset-source=missing:workflows^standard-copilot-review=absent'
PIN_FAILURE='standard-copilot-review=absent'
while IFS='~' read -r name edit overrides; do
  [ -n "$name" ] || continue
  drift_case "$name" '' rules.json "$edit" "$overrides"
  if [ "$CASE_MATCH" = true ]; then ok "$name"; else bad "$name" "$CASE_DIFF"; fi
done <<ROWS
the live organization ruleset~.~
the native Copilot rule without the workflow~.[3] = {"type": "copilot_code_review", "parameters": {"review_on_push": true}, "ruleset_source_type": "Organization", "ruleset_id": 2}~advisory:standard-ruleset-source=missing:workflows
the native Copilot rule beside the workflow~. += [{"type": "copilot_code_review", "parameters": {"review_on_push": true}, "ruleset_source_type": "Organization", "ruleset_id": 2}]~
a workflow in a different repository~.[3].parameters.workflows[0].repository_id = 7~$SOURCE_FAILURE
a repository id with the wrong type~.[3].parameters.workflows[0].repository_id = "1190866154"~$SOURCE_FAILURE
a different workflow path~.[3].parameters.workflows[0].path = ".github/workflows/refresh-consumer.yml"~$SOURCE_FAILURE
a missing workflow declaration~.[3].parameters.workflows = []~$SOURCE_FAILURE
a workflow on the wrong rule type~.[3].type = "required_deployments"~$SOURCE_FAILURE
a workflow from a repository ruleset~.[3].ruleset_source_type = "Repository"~advisory:standard-ruleset-source=Repository:2:workflows\,missing:workflows^standard-copilot-review=absent^standard-bypass-actors=2=RepositoryRole:9:always
a re-pinned workflow~.[3].parameters.workflows[0].sha = "fedcba9876543210fedcba9876543210fedcba98"~
a different workflow ref~.[3].parameters.workflows[0].ref = "refs/heads/release"~$PIN_FAILURE
an unpinned workflow~del(.[3].parameters.workflows[0].sha)~$PIN_FAILURE
a short workflow pin~.[3].parameters.workflows[0].sha = "0123456"~$PIN_FAILURE
a non-hex workflow pin~.[3].parameters.workflows[0].sha = "g123456789abcdef0123456789abcdef01234567"~$PIN_FAILURE
a non-string workflow pin~.[3].parameters.workflows[0].sha = 7~$PIN_FAILURE
the pinned workflow beside an unrelated workflow~.[3].parameters.workflows += [{"repository_id": 7, "path": ".github/workflows/build.yml"}]~
ROWS

# The contexts row against consumers other than the table's: the list the
# repository declares is the other half of its comparison.
echo "=== the required contexts against the repository's declared list ==="
# name ~ consumer ~ jq edit of rules.json ~ overrides
while IFS='~' read -r name consumer edit overrides; do
  [ -n "$name" ] || continue
  drift_case "$name" "" "${edit:+rules.json}" "$edit" "$overrides" "$consumer"
  if [ "$CASE_MATCH" = true ]; then ok "$name"; else bad "$name" "$CASE_DIFF"; fi
done <<'ROWS'
a repository that declares no context list~no-contexts~~advisory:standard-required-contexts=undeclared:CI\;Cargo\ \(workspace\ tests\)
a repository that declares an empty context list~empty-contexts~~advisory:standard-required-contexts=undeclared:CI\;Cargo\ \(workspace\ tests\)
a required gate context the repository also declares~gated~.[5].parameters.required_status_checks += [{"context": "Review gate"}]~standard-required-contexts=gate-required:CI\;Cargo\ \(workspace\ tests\)\;Review\ gate
a required gate context a repository with no context list fails~no-contexts~.[5].parameters.required_status_checks += [{"context": "Review gate"}]~standard-required-contexts=gate-required:CI\;Cargo\ \(workspace\ tests\)\;Review\ gate
a required gate context a repository with an empty context list fails~empty-contexts~.[5].parameters.required_status_checks += [{"context": "Review gate"}]~standard-required-contexts=gate-required:CI\;Cargo\ \(workspace\ tests\)\;Review\ gate
ROWS

echo "=== the retired organization keys are not read ==="
drift_case "a consumer still holding the retired organization keys" "" "" "" "" retired
if [ "$CASE_MATCH" = true ]; then ok "a consumer still holding the retired organization keys reads the matching world"
else bad "a consumer still holding the retired organization keys" "$CASE_DIFF"; fi
# The control reads one retired key in a disposable copy of the loader.
cp "$SKILL/scripts/lib/standard.sh" "$TMP/standard-lib.keep"
file_edit "$SKILL" scripts/lib/standard.sh 1 '^  WANT_CHECKS_BYPASS=' \
  's/^  WANT_CHECKS_BYPASS=.*$/&\n  rg_standard_actors REVIEW_GATE_STANDARD_SECRETS >\/dev\/null || return 1/'
drift_case "control: a retired key read" "" "" "" "" retired
if [ "$CASE_MATCH" = false ]; then ok "control: a loader that reads a retired key turns the retired-key case red"
else bad "control: a loader that reads a retired key" "$CASE_DIFF"; fi
cp "$TMP/standard-lib.keep" "$SKILL/scripts/lib/standard.sh"

echo "=== a ruleset holding one rule type admits the standard's actors there ==="
# The matching world's repository rulesets, the merge queue in ruleset 3
# alone and the required checks in ruleset 4 alone, each carrying the same
# actors. The inverse of the admitted row is the
# same world read by a consumer that admits none.
bypass_row() { # LABEL CONSUMER ACTORS_JSON WANT_RC WANT_LINE
  local dir="$TMP/case-split-$((PASS + FAIL))" id
  cp -R "$BASE" "$dir"
  for id in 3 4; do
    printf '{"id": %s, "bypass_actors": %s}\n' "$id" "$3" >"$dir/ruleset-$id.json"
  done
  CONSUMER="$TMP/consumer-$2"
  run "$dir" ""
  CONSUMER="$TMP/consumer-full"
  got="$(grep 'check=standard-bypass-actors ' <<<"$OUT" || true)"
  if [ "$RC" -eq "$4" ] && [ "$got" = "$5" ]; then ok "$1"; else bad "$1 (rc=$RC, want $4)" "$got
$RAW"; fi
}
OVERSEER='[{"actor_type": "Integration", "actor_id": 5115517, "bypass_mode": "pull_request"}]'
bypass_row "the overseer app in pull-request mode on the queue and checks rulesets is admitted" full "$OVERSEER" 0 \
  'ok check=standard-bypass-actors value=2'
bypass_row "a consumer that admits no actor reads the same actors as departures" no-bypass "$OVERSEER" 1 \
  'FAIL check=standard-bypass-actors value=3=Integration:5115517:pull_request\,4=Integration:5115517:pull_request'
bypass_row "the lanes app is admitted on the queue ruleset and a departure on the checks ruleset" full \
  '[{"actor_type": "Integration", "actor_id": 4925608, "bypass_mode": "always"}]' 1 \
  'FAIL check=standard-bypass-actors value=4=Integration:4925608:always'
bypass_row "an admitted app in another bypass mode is a departure" full \
  '[{"actor_type": "Integration", "actor_id": 5115517, "bypass_mode": "always"}]' 1 \
  'FAIL check=standard-bypass-actors value=3=Integration:5115517:always\,4=Integration:5115517:always'

echo "=== a failed read is unreadable, never a match ==="
run "$BASE" rules
want="$(expected_listing 'standard-ruleset-source=unreadable^standard-merge-queue=unreadable^standard-required-contexts=unreadable^standard-required-approvals=unreadable^standard-stale-dismissal=unreadable^standard-conversation-resolution=unreadable^standard-copilot-review=unreadable^standard-bypass-actors=unreadable')"
if [ "$RC" -eq 1 ] && [ "$OUT" = "$want" ]; then ok "the effective rules unreadable"; else bad "the effective rules unreadable (rc=$RC)" "$RAW"; fi

echo "=== each failed read keeps its own cause ==="
# A withheld field beside a failed read: each cause line names its own read.
dir="$TMP/case-causes"
cp -R "$BASE" "$dir"
jq 'del(.bypass_actors)' "$dir/org-ruleset-1.json" >"$dir/r" && mv "$dir/r" "$dir/org-ruleset-1.json"
run "$dir" org-ruleset-2
if grep -qx '  2: gh-shim-error=api value=org-ruleset-2' <<<"$RAW" && grep -q '^  1: ' <<<"$RAW" &&
  ! grep -q '^  1: gh-shim' <<<"$RAW" && grep -qx 'FAIL check=standard-bypass-actors value=unreadable:1\\,2' <<<"$RAW"; then
  ok "a withheld field and a failed ruleset read each name their own cause"
else
  bad "a withheld field and a failed ruleset read each name their own cause" "$RAW"
fi

echo "=== the CI context is read on both legs of the latest merge ==="
# The row's reads in order: the branch head, its pull requests, the
# pull_request leg on the merged pull request's head, and the merge_group leg
# on the branch head.
dir="$TMP/case-latest-merge"
cp -R "$BASE" "$dir"
rm -f -- "${dir:?}/.urls.log"
run "$dir" ""
want_urls='repos/acme/widgets/commits/main
repos/acme/widgets/commits/dead/pulls
repos/acme/widgets/actions/runs?head_sha=beef&event=pull_request&per_page=100
repos/acme/widgets/actions/runs?head_sha=dead&event=merge_group&per_page=100'
got_urls="$(grep -E '/commits/|/actions/runs\?' "$dir/.urls.log" || true)"
if [ "$got_urls" = "$want_urls" ]; then
  ok "the reads name the branch head, its merged pull request's head and the merge_group leg"
else
  bad "the reads name the branch head, its merged pull request's head and the merge_group leg" "$(diff <(printf '%s\n' "$want_urls") <(printf '%s\n' "$got_urls") || true)"
fi

echo "=== the check could not run ==="
# name ~ shim failure ~ manifest replacement (empty keeps the test's) ~
# consumer ~ argument ~ first error line ~ its value (empty: not compared)
while IFS='~' read -r name fail manifest consumer arg key value; do
  [ -n "$name" ] || continue
  cp "$SKILL/standard.json" "$TMP/standard.keep"
  [ -z "$manifest" ] || printf '%s\n' "$manifest" >"$SKILL/standard.json"
  RC=0
  RAW="$(cd "$TMP/consumer-$consumer" && env -i PATH="$BIN:/usr/bin:/bin" HOME="$TMP" GH_SHIM_FIXTURES="$BASE" GH_SHIM_FAIL="$fail" \
    "$SKILL/scripts/validate-standard.sh" ${arg:+"$arg"} 2>&1)" || RC=$?
  mv "$TMP/standard.keep" "$SKILL/standard.json"
  first="${RAW%%
*}"
  if [ "$RC" -eq 2 ] && [ "${first%% value=*}" = "$key" ] &&
    { [ -z "$value" ] || [ "${first#* value=}" = "$value" ]; } && ! grep -qE '^(ok|FAIL) check=' <<<"$RAW"; then
    ok "$name"
  else
    bad "$name (rc=$RC)" "$RAW"
  fi
done <<'ROWS'
the repository unreadable~repository~~full~~review-gate-error=repository-read~
a manifest without a gate context~~{"ci_context": "CI"}~full~~review-gate-error=standard-malformed~
a manifest without a CI context~~{"gate_context": "Review gate"}~full~~review-gate-error=standard-malformed~
a manifest whose two contexts are one~~{"ci_context": "CI", "gate_context": "CI"}~full~~review-gate-error=standard-malformed~
a bypass entry that is not TYPE:ID:MODE~~~bad-bypass~~review-gate-error=standard-bypass-invalid~Integration:5115517:bypass\;lanes-app
an argument~~~full~--repo~review-gate-error=unknown-arguments~
ROWS

# The shipped manifest passes the same shape check: with the repository
# read failing, the first refusal is the read, not the manifest.
RC=0
RAW="$(cd "$CONSUMER" && env -i PATH="$BIN:/usr/bin:/bin" HOME="$TMP" GH_SHIM_FIXTURES="$BASE" GH_SHIM_FAIL=repository \
  "$SKILL_DIR/scripts/validate-standard.sh" 2>&1)" || RC=$?
if [ "$RC" -eq 2 ] && [ "${RAW%% value=*}" = "review-gate-error=repository-read" ]; then
  ok "the shipped standard.json is well-formed"
else
  bad "the shipped standard.json is well-formed (rc=$RC)" "$RAW"
fi

# The controls below edit a disposable copy of the script and restore it
# from this keep.
cp "$SKILL/scripts/validate-standard.sh" "$TMP/standard-script.keep"

echo "=== transient reads retry, permanent failures keep their first answer ==="
retry_case() { # DIAGNOSTIC FAILURES ATTEMPTS WAITS RC
  local dir="$TMP/retry-case" got_attempts got_waits want
  rm -rf -- "${dir:?}"
  cp -R "$BASE" "$dir"
  printf '%b\n' "$1" >"$dir/.retry-error"
  printf '%s\n' "$2" >"$dir/.retry-limit"
  run "$dir" ''
  got_attempts="$(cat "$dir/.retry-count")"
  got_waits=""
  [ ! -f "$dir/.retry-waits" ] || got_waits="$(tr '\n' ',' <"$dir/.retry-waits")"
  want="$BASELINE"
  if [ "$5" -eq 1 ]; then
    want="$(expected_listing 'standard-classic-protection=unreadable')"
  fi
  CASE_MATCH=false
  if [ "$RC" -eq "$5" ] && [ "$OUT" = "$want" ] && [ "$got_attempts" = "$3" ] && [ "$got_waits" = "$4" ]; then
    CASE_MATCH=true
  fi
  CASE_DIFF="rc=$RC want $5; attempts=$got_attempts want $3; waits=$got_waits want $4
$RAW"
}
while IFS='~' read -r name diagnostic failures attempts waits rc; do
  [ -n "$name" ] || continue
  retry_case "$diagnostic" "$failures" "$attempts" "$waits" "$rc"
  if [ "$CASE_MATCH" = true ]; then ok "$name"; else bad "$name" "$CASE_DIFF"; fi
done <<'ROWS'
500 once recovers~gh: Server Error (HTTP 500)~1~2~1,~0
500 three times remains unreadable~gh: Server Error (HTTP 500)~3~3~1,2,~1
502 recovers after both waits~gh: Bad Gateway (HTTP 502)~2~3~1,2,~0
503 recovers~gh: Service Unavailable (HTTP 503)~1~2~1,~0
504 recovers~gh: Gateway Timeout (HTTP 504)~1~2~1,~0
no HTTP answer recovers~error connecting to api.github.com\ncheck your internet connection or https://githubstatus.com~1~2~1,~0
transport EOF recovers~Get "https://api.github.com/repos/acme/widgets/branches/main": EOF~1~2~1,~0
transport failure stays bounded~Get "https://api.github.com/repos/acme/widgets/branches/main": context deadline exceeded~3~3~1,2,~1
404 stays on its first answer~gh: Not Found (HTTP 404)~1~1~~1
401 stays on its first answer~gh: Bad credentials (HTTP 401)~1~1~~1
501 stays on its first answer~gh: Not Implemented (HTTP 501)~1~1~~1
HTTP status takes precedence~gh: Not Found (HTTP 404)\nerror connecting to api.github.com~1~1~~1
jq error stays on its first answer~failed to parse jq expression: unexpected token~1~1~~1
authentication error stays on its first answer~To get started with GitHub CLI, please run: gh auth login~1~1~~1
usage error stays on its first answer~unknown flag: --bad~1~1~~1
ROWS

# Each changed retry rule has a control in the disposable script copy.
while IFS='@' read -r name match edit diagnostic failures attempts waits rc; do
  [ -n "$name" ] || continue
  file_edit "$SKILL" scripts/validate-standard.sh 1 "$match" "$edit"
  retry_case "$diagnostic" "$failures" "$attempts" "$waits" "$rc"
  if [ "$CASE_MATCH" = false ]; then ok "control: $name"; else bad "control: $name" "$CASE_DIFF"; fi
  cp "$TMP/standard-script.keep" "$SKILL/scripts/validate-standard.sh"
done <<'ROWS'
HTTP retry removed@500\|502\|503\|504\) retryable=1@s/500|502|503|504) retryable=1/500|502|503|504) retryable=0/@gh: Server Error (HTTP 500)@1@2@1,@0
transport retry removed@Get "http://.*retryable=1@s/retryable=1/retryable=0/@error connecting to api.github.com@1@2@1,@0
retry bound shortened@"\$attempt" -lt 2@s/"$attempt" -lt 2/"$attempt" -lt 1/@gh: Server Error (HTTP 500)@3@3@1,2,@1
HTTP precedence removed@if \[\[ "\$error" =~ HTTP@s/if \[\[ "\$error" =~ HTTP/if false \&\& [[ "$error" =~ HTTP/@gh: Not Found (HTTP 404)\nerror connecting to api.github.com@1@1@@1
doubling wait removed@delay=\$\(\(delay \* 2\)\)@s/delay=$((delay \* 2))/delay=1/@gh: Server Error (HTTP 500)@3@3@1,2,@1
ROWS

# The default-branch rules' controls, one per rule. Each plants one defect in
# the copy that keeps the rule's text and drops its behavior, runs the case
# that reaches the rule, and passes when the rule's row is still printed but
# no longer as the real script prints it.
# name ~ match ~ sed edit of scripts/validate-standard.sh ~ consumer ~ jq
# edit of rules.json ~ the real script's verdict line for the case
controls=0
while IFS='~' read -r name match edit consumer rules_edit real; do
  [ -n "$name" ] || continue
  controls=$((controls + 1))
  file_edit "$SKILL" scripts/validate-standard.sh 1 "$match" "$edit"
  chmod +x "$SKILL/scripts/validate-standard.sh"
  dir="$TMP/control-rule-$controls"
  cp -R "$BASE" "$dir"
  [ -z "$rules_edit" ] || { jq "$rules_edit" "$dir/rules.json" >"$dir/r" && mv "$dir/r" "$dir/rules.json"; }
  CONSUMER="$TMP/consumer-$consumer"
  run "$dir" ""
  CONSUMER="$TMP/consumer-full"
  check="${real#* check=}"
  check="${check%% value=*}"
  if [ "$RC" -le 1 ] && grep -qE "^(ok|advisory|FAIL) check=$check " <<<"$OUT" && ! grep -qxF -- "$real" <<<"$OUT"; then
    ok "control: $name"
  else
    bad "control: $name (rc=$RC)" "$RAW"
  fi
  cp "$TMP/standard-script.keep" "$SKILL/scripts/validate-standard.sh"
done <<'ROWS'
required checks and a merge queue that may not come from a repository ruleset fail the matching layout~!= "Repository" else~s/!= "Repository" else/!= "Repository" or true else/~full~~ok check=standard-ruleset-source value=Organization\,Repository
required checks that may come from an organization ruleset pass~!= "Repository" else~s/!= "Repository" else/!= "Repository" and .ruleset_source_type != "Organization" else/~full~.[5] |= (.ruleset_source_type = "Organization" | .ruleset_id = 2)~advisory check=standard-ruleset-source value=Organization:2:required_status_checks
a shared-rule list without deletion passes a branch with no deletion rule~"pull_request", "deletion", "non_fast_forward"\] -~s/"deletion", "non_fast_forward"\] -/"non_fast_forward"] -/~full~del(.[0])~advisory check=standard-ruleset-source value=missing:deletion
an unchecked context list passes an extra required context~elif \[ "\$contexts" = "\$WANT_CONTEXTS" \]; then~s/elif \[ "\$contexts" = "\$WANT_CONTEXTS" \]; then/elif [ "$contexts" = "$WANT_CONTEXTS" ] || true; then/~full~.[5].parameters.required_status_checks += [{"context": "Other"}]~FAIL check=standard-required-contexts value=CI\;Cargo\ \(workspace\ tests\)\;Other
a skipped gate exclusion passes a required gate context the repository declares~if \[ "\$gated" = true \]; then~s/if \[ "\$gated" = true \]; then/if [ "$gated" = true ] \&\& false; then/~gated~.[5].parameters.required_status_checks += [{"context": "Review gate"}]~FAIL check=standard-required-contexts value=gate-required:CI\;Cargo\ \(workspace\ tests\)\;Review\ gate
a skipped undeclared-list failure reports no undeclared list~elif \[ -z "\$WANT_CONTEXTS" \]; then~s/elif \[ -z "\$WANT_CONTEXTS" \]; then/elif [ -z "$WANT_CONTEXTS" ] \&\& false; then/~no-contexts~~advisory check=standard-required-contexts value=undeclared:CI\;Cargo\ \(workspace\ tests\)
an undeclared list read before the gate exclusion turns a required gate context advisory~if \[ "\$gated" = true \]; then~s/if \[ "\$gated" = true \]; then/if [ "$gated" = true ] \&\& [ -n "$WANT_CONTEXTS" ]; then/~no-contexts~.[5].parameters.required_status_checks += [{"context": "Review gate"}]~FAIL check=standard-required-contexts value=gate-required:CI\;Cargo\ \(workspace\ tests\)\;Review\ gate
a threshold that takes 0 passes a rule requiring no approval~"" \| \*\[!0-9\]\* \| 0\)~s/ | 0)/)/~full~.[2].parameters.required_approving_review_count = 0~advisory check=standard-required-approvals value=0
an unchecked dismissal passes stale approvals kept on push~\[ "\$stale" = true \]; then~s/\[ "\$stale" = true \]; then/[ "$stale" = true ] || true; then/~full~.[2].parameters.dismiss_stale_reviews_on_push = false~advisory check=standard-stale-dismissal value=false
ROWS
[ "$controls" -gt 0 ] || bad "the rule-control table ran no row" ""

# Each identity condition gets a failing control in the disposable script
# copy. The two consumers also get controls that sever their shared check.
while IFS='~' read -r name match mutation fixture overrides; do
  [ -n "$name" ] || continue
  file_edit "$SKILL" scripts/validate-standard.sh 1 "$match" "$mutation"
  drift_case "$name" '' rules.json "$fixture" "$overrides"
  if [ "$RC" -le 1 ] && [ "$CASE_MATCH" = false ]; then
    ok "control: $name"
  else
    bad "control: $name (rc=$RC)" "$CASE_DIFF"
  fi
  cp "$TMP/standard-script.keep" "$SKILL/scripts/validate-standard.sh"
done <<ROWS
the old native-rule assertion~"pull_request", "deletion", "non_fast_forward"\] -~s/"pull_request", "deletion"/"pull_request", "copilot_code_review", "deletion"/~.~
workflow rule type~^      \.type == "workflows"$~s/\.type == "workflows"/.type == "workflows" or true/~.[3].type = "required_deployments"~$SOURCE_FAILURE
workflow source~^      and \.ruleset_source_type == "Organization"$~s/and \.ruleset_source_type == "Organization"/and (.ruleset_source_type == "Organization" or true)/~.[3].ruleset_source_type = "Repository"~advisory:standard-ruleset-source=Repository:2:workflows\,missing:workflows^standard-copilot-review=absent^standard-bypass-actors=2=RepositoryRole:9:always
workflow repository~^        \.repository_id == 1190866154$~s/\.repository_id == 1190866154/(.repository_id == 1190866154 or true)/~.[3].parameters.workflows[0].repository_id = 7~$SOURCE_FAILURE
workflow path~^        and \.path ==~s/and \.path == "[^"]*"/and (.path == ".github\/workflows\/request-copilot-review.yml" or true)/~.[3].parameters.workflows[0].path = ".github/workflows/refresh-consumer.yml"~$SOURCE_FAILURE
workflow ref~^        and \.ref ==~s/and \.ref == "[^"]*"/and (.ref == "refs\/heads\/main" or true)/~.[3].parameters.workflows[0].ref = "refs/heads/release"~$PIN_FAILURE
workflow pin~then test\(~s/{40}/{1,40}/~.[3].parameters.workflows[0].sha = "0123456"~$PIN_FAILURE
workflow pin type~if type == "string" then test~s/else false end/else true end/~.[3].parameters.workflows[0].sha = 7~$PIN_FAILURE
workflow source accounting~if any\(\.\[\]; kendex_review_workflow\) then~s/if any(\.\[\]; kendex_review_workflow) then/if false then/~.~
workflow review accounting~any\(\.\[\]; \.type == "copilot_code_review" or kendex_copilot_workflow\)~s/or kendex_copilot_workflow/or false/~.~
ROWS

echo "=== a departure from a 1.3.0 requirement is advisory until 2.0 ==="
# The drift cases of the four advisory rows. Each row's control turns that
# row's advisory back into a failure in a copy of the script, and the shared
# warning's control drops the warning; each passes when the case turns red.
ADVISORY_ROWS='standard-ruleset-source~full~rules.json~del(.[0])~advisory:standard-ruleset-source=missing:deletion
standard-required-contexts~no-contexts~~~advisory:standard-required-contexts=undeclared:CI\;Cargo\ \(workspace\ tests\)
standard-required-approvals~full~rules.json~.[2].parameters.required_approving_review_count = 0~advisory:standard-required-approvals=0
standard-stale-dismissal~full~rules.json~.[2].parameters.dismiss_stale_reviews_on_push = false~advisory:standard-stale-dismissal=false'
advisories=0
while IFS='~' read -r check consumer files edit overrides; do
  [ -n "$check" ] || continue
  advisories=$((advisories + 1))
  calls="$(grep -Ec -- "advise $check " "$SKILL/scripts/validate-standard.sh")" || calls=0
  file_edit "$SKILL" scripts/validate-standard.sh "$calls" "advise $check " "s/advise $check /bad $check /"
  chmod +x "$SKILL/scripts/validate-standard.sh"
  drift_case "control $check" "" "$files" "$edit" "$overrides" "$consumer"
  if [ "$calls" -gt 0 ] && [ "$CASE_MATCH" = false ]; then
    ok "control: $check reported as a failure turns its advisory case red"
  else
    bad "control: $check reported as a failure turns its advisory case red" "$CASE_DIFF"
  fi
  cp "$TMP/standard-script.keep" "$SKILL/scripts/validate-standard.sh"
done <<<"$ADVISORY_ROWS"
[ "$advisories" -eq 4 ] || bad "the advisory table ran $advisories rows, not 4" ""
file_edit "$SKILL" scripts/validate-standard.sh 1 '^if \[ -n "\$ADVISED" \]; then$' 's/^if \[ -n "\$ADVISED" \]; then$/if false; then/'
chmod +x "$SKILL/scripts/validate-standard.sh"
green=""
while IFS='~' read -r check consumer files edit overrides; do
  [ -n "$check" ] || continue
  drift_case "control warning $check" "" "$files" "$edit" "$overrides" "$consumer"
  [ "$CASE_MATCH" = false ] || green="${green:+$green; }$check"
done <<<"$ADVISORY_ROWS"
if [ -z "$green" ]; then ok "control: a dropped advisory warning turns each advisory case red"; else bad "control: a dropped advisory warning turns each advisory case red" "still green: $green"; fi
cp "$TMP/standard-script.keep" "$SKILL/scripts/validate-standard.sh"

[ "$rows" -gt 0 ] || { bad "the drift table ran no row" ""; }
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
