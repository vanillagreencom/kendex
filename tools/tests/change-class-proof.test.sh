#!/usr/bin/env bash
# `.github/actions/change-class/proof` decides whether a passing run of the
# same workflow already tested the tree this run tests. One truth table over
# (event, the run's own fields, the GitHub API's answers) -> the decision, the
# reason key beside it, the run it names and how many gh calls it made. The
# call count is what tells "refused before touching the API" from an ordinary
# refusal; nothing else in the output can.
#
# Three surfaces:
#   1. the table: the two accepted rows, a push by the queue and a merge
#      group of one entry, and every refusal, each the accepted row with one
#      thing changed, so a refusal is attributable to that change alone.
#      Every row with no API call runs against a gh that fails every call.
#   2. the record: the accepted row's record is the file the artifact holds,
#      a run whose newest attempt lacks the artifact falls through to the run
#      that has it, and a failed run beside a passing one is passed over.
#   3. the must-fail inverses: one copy of proof per rule, that rule planted
#      away, answers the row the rule decides other than the table says.
set -euo pipefail

unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

ROOT="$(git rev-parse --show-toplevel)"
PROOF="$ROOT/.github/actions/change-class/proof"

mkdir -p "$ROOT/tmp"
TMP="$(mktemp -d "$ROOT/tmp/change-class-proof.XXXXXX")"
trap 'rm -rf -- "${TMP:?}"' EXIT

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }
check() { # DESC EXPECTED ACTUAL
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$2', got '$3')"; fi
}

# --- The judged checkout ------------------------------------------------------
# main at B, a pull request head P, and M the merge of P onto B: the commit a
# merge group of one entry tests, and the sha the queue then pushes to main.
REPO="$TMP/repo"
git init -q "$REPO"
git -C "$REPO" config user.email t@example.com
git -C "$REPO" config user.name t
git -C "$REPO" config commit.gpgsign false
printf 'a\n' >"$REPO/a"
git -C "$REPO" add a
git -C "$REPO" commit -q -m base
B="$(git -C "$REPO" rev-parse HEAD)"
git -C "$REPO" checkout -q -b topic
printf 'b\n' >"$REPO/b"
git -C "$REPO" add b
git -C "$REPO" commit -q -m topic
P="$(git -C "$REPO" rev-parse HEAD)"
git -C "$REPO" checkout -q -
git -C "$REPO" checkout -q -b other
printf 'c\n' >"$REPO/c"
git -C "$REPO" add c
git -C "$REPO" commit -q -m other
Q="$(git -C "$REPO" rev-parse HEAD)"
git -C "$REPO" checkout -q -
git -C "$REPO" merge -q --no-ff -m merge topic
M="$(git -C "$REPO" rev-parse HEAD)"
# An octopus merge of both branches onto B: three parents, so no group head.
git -C "$REPO" checkout -q -b octopus "$B"
git -C "$REPO" merge -q --no-ff -m octopus "$P" "$Q" >/dev/null
O="$(git -C "$REPO" rev-parse HEAD)"
git -C "$REPO" checkout -q main 2>/dev/null || git -C "$REPO" checkout -q master
TREE="$(git -C "$REPO" rev-parse "$M^{tree}")"
OTHER_TREE="$(git -C "$REPO" rev-parse "$B^{tree}")"

REPO_NAME=vanillagreencom/kendex
WORKFLOW=.github/workflows/ci.yml
WORKFLOW_ID=245303662
RUN_MG=29457108504
RUN_PR=29457108600
RUN_PR_OLDER=29457108500
ARTIFACT=770001

# --- Event payloads -----------------------------------------------------------
payload() { # NAME JSON
  printf '%s\n' "$2" >"$TMP/event-$1.json"
}
payload push "{\"ref\":\"refs/heads/main\",\"forced\":false,\"after\":\"$M\",\"repository\":{\"default_branch\":\"main\"}}"
payload push-forced "{\"ref\":\"refs/heads/main\",\"forced\":true,\"after\":\"$M\",\"repository\":{\"default_branch\":\"main\"}}"
payload push-other-after "{\"ref\":\"refs/heads/main\",\"forced\":false,\"after\":\"$B\",\"repository\":{\"default_branch\":\"main\"}}"
payload push-no-default "{\"ref\":\"refs/heads/main\",\"forced\":false,\"after\":\"$M\",\"repository\":{}}"
payload merge_group '{"repository":{"default_branch":"main"}}'

# --- The records the artifact zips hold ---------------------------------------
record_zip() { # NAME MEMBER CONTENT
  python3 - "$TMP/$1.zip" "$2" "$3" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w") as z:
    z.writestr(sys.argv[2], sys.argv[3])
PY
}
RECORD="tree=$TREE
workflow=$WORKFLOW
event=pull_request
change_class=small
docs_only=false
covers=all
changed_path=src/main.rs"
record_zip valid record "$RECORD"
record_zip wrong-tree record "tree=$OTHER_TREE
workflow=$WORKFLOW
covers=all"
record_zip wrong-workflow record "tree=$TREE
workflow=.github/workflows/other.yml
covers=all"
record_zip no-member other "$RECORD"
printf 'not a zip\n' >"$TMP/garbage.zip"

# --- The fake gh --------------------------------------------------------------
# It records EVERY invocation before deciding how to answer, api-error
# included: a log written only on the success path could not tell "the script
# never called gh" from "the script called gh and gh refused", which is the
# whole claim the no-call rows make. FAKE_GH_MODE picks the one thing wrong
# with the answer; FAKE_ZIP names the zip the download streams.
mkdir -p "$TMP/bin"
cat >"$TMP/bin/gh" <<'FAKE_GH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$FAKE_GH_CALLS"
mode="${FAKE_GH_MODE:-valid}"
[ "$mode" != api-error ] || exit 1
args="$*"

workflow_json() { # ID PATH STATE
  printf '{"id":%s,"path":"%s","state":"%s"}\n' "$1" "$2" "$3"
}
run_json() { # ID EVENT STATUS CONCLUSION SHA BRANCH PATH WORKFLOW_ID REPO HEAD_REPO
  printf '{"id":%s,"workflow_id":%s,"event":"%s","status":"%s","conclusion":"%s","head_sha":"%s","head_branch":"%s","path":"%s","repository":{"full_name":"%s"},"head_repository":{"full_name":"%s"}}' \
    "$1" "$8" "$2" "$3" "$4" "$5" "$6" "$7" "$9" "${10}"
}
runs_list() { # RUN_JSON... — a whole list
  local n=$# list=""
  for run in "$@"; do list="$list${list:+,}$run"; done
  printf '{"total_count":%s,"workflow_runs":[%s]}\n' "$n" "$list"
}
artifact_json() { # ID NAME EXPIRED RUN
  printf '{"id":%s,"name":"%s","expired":%s,"workflow_run":{"id":%s}}' "$1" "$2" "$3" "$4"
}

case "$args" in
  *"actions/workflows/ci.yml"*)
    case "$mode" in
      malformed-workflow) printf '{"id":"%s","path":"%s","state":"active"}\n' "$FAKE_WORKFLOW_ID" "$FAKE_WORKFLOW" ;;
      wrong-workflow-path) workflow_json "$FAKE_WORKFLOW_ID" .github/workflows/other.yml active ;;
      inactive-workflow) workflow_json "$FAKE_WORKFLOW_ID" "$FAKE_WORKFLOW" disabled_manually ;;
      *) workflow_json "$FAKE_WORKFLOW_ID" "$FAKE_WORKFLOW" active ;;
    esac
    exit 0 ;;
  *"actions/workflows/$FAKE_WORKFLOW_ID/runs"*)
    [ "$mode" != runs-api-error ] || exit 1
    [[ "$args" == *"--method GET"* ]] || exit 1
    [[ "$args" == *"status=completed"* ]] || exit 1
    [[ "$args" == *"per_page=100"* ]] || exit 1
    case "$args" in
      *"event=merge_group"*"head_sha=$FAKE_M"*)
        want=merge_group; sha="$FAKE_M"; branch="gh-readonly-queue/main/pr-261-$FAKE_B"; id="$FAKE_RUN_MG" ;;
      *"event=pull_request"*"head_sha=$FAKE_P"*)
        want=pull_request; sha="$FAKE_P"; branch=topic; id="$FAKE_RUN_PR" ;;
      *) exit 1 ;;
    esac
    valid="$(run_json "$id" "$want" completed success "$sha" "$branch" "$FAKE_WORKFLOW" "$FAKE_WORKFLOW_ID" "$FAKE_REPO" "$FAKE_REPO")"
    case "$mode" in
      malformed-runs) printf '{"workflow_runs":{}}\n' ;;
      truncated) printf '{"total_count":2,"workflow_runs":[%s]}\n' "$valid" ;;
      missing) runs_list ;;
      ambiguous) runs_list "$valid" "$valid" ;;
      wrong-event) runs_list "$(run_json "$id" push completed success "$sha" "$branch" "$FAKE_WORKFLOW" "$FAKE_WORKFLOW_ID" "$FAKE_REPO" "$FAKE_REPO")" ;;
      wrong-status) runs_list "$(run_json "$id" "$want" in_progress success "$sha" "$branch" "$FAKE_WORKFLOW" "$FAKE_WORKFLOW_ID" "$FAKE_REPO" "$FAKE_REPO")" ;;
      wrong-conclusion) runs_list "$(run_json "$id" "$want" completed failure "$sha" "$branch" "$FAKE_WORKFLOW" "$FAKE_WORKFLOW_ID" "$FAKE_REPO" "$FAKE_REPO")" ;;
      wrong-sha) runs_list "$(run_json "$id" "$want" completed success "$FAKE_B" "$branch" "$FAKE_WORKFLOW" "$FAKE_WORKFLOW_ID" "$FAKE_REPO" "$FAKE_REPO")" ;;
      wrong-branch) runs_list "$(run_json "$id" "$want" completed success "$sha" main "$FAKE_WORKFLOW" "$FAKE_WORKFLOW_ID" "$FAKE_REPO" "$FAKE_REPO")" ;;
      wrong-run-path) runs_list "$(run_json "$id" "$want" completed success "$sha" "$branch" .github/workflows/other.yml "$FAKE_WORKFLOW_ID" "$FAKE_REPO" "$FAKE_REPO")" ;;
      wrong-workflow-id) runs_list "$(run_json "$id" "$want" completed success "$sha" "$branch" "$FAKE_WORKFLOW" 1 "$FAKE_REPO" "$FAKE_REPO")" ;;
      wrong-repo) runs_list "$(run_json "$id" "$want" completed success "$sha" "$branch" "$FAKE_WORKFLOW" "$FAKE_WORKFLOW_ID" other/kendex "$FAKE_REPO")" ;;
      wrong-head-repo) runs_list "$(run_json "$id" "$want" completed success "$sha" "$branch" "$FAKE_WORKFLOW" "$FAKE_WORKFLOW_ID" "$FAKE_REPO" fork/kendex)" ;;
      malformed-run) printf '{"total_count":1,"workflow_runs":[{"id":%s}]}\n' "$id" ;;
      # Newest first, as the API lists them: a failed run ahead of the
      # passing one, or a passing run whose artifact is on the older run.
      failed-then-valid) runs_list "$(run_json "$FAKE_RUN_PR_OLDER" "$want" completed failure "$sha" "$branch" "$FAKE_WORKFLOW" "$FAKE_WORKFLOW_ID" "$FAKE_REPO" "$FAKE_REPO")" "$valid" ;;
      newest-without-artifact) runs_list "$valid" "$(run_json "$FAKE_RUN_PR_OLDER" "$want" completed success "$sha" "$branch" "$FAKE_WORKFLOW" "$FAKE_WORKFLOW_ID" "$FAKE_REPO" "$FAKE_REPO")" ;;
      *) runs_list "$valid" ;;
    esac
    exit 0 ;;
  *"actions/runs/"*"/artifacts"*)
    [ "$mode" != artifacts-api-error ] || exit 1
    run="${args#*actions/runs/}"
    run="${run%%/*}"
    [[ "$args" == *"name=change-class-proof-$FAKE_TREE"* ]] || exit 1
    name="change-class-proof-$FAKE_TREE"
    case "$mode" in
      malformed-artifacts) printf '{"artifacts":{}}\n' ;;
      no-artifact) printf '{"artifacts":[]}\n' ;;
      other-name) printf '{"artifacts":[%s]}\n' "$(artifact_json "$FAKE_ARTIFACT" "change-class-proof-$FAKE_OTHER_TREE" false "$run")" ;;
      other-run) printf '{"artifacts":[%s]}\n' "$(artifact_json "$FAKE_ARTIFACT" "$name" false 1)" ;;
      expired) printf '{"artifacts":[%s]}\n' "$(artifact_json "$FAKE_ARTIFACT" "$name" true "$run")" ;;
      newest-without-artifact)
        if [ "$run" = "$FAKE_RUN_PR_OLDER" ]; then printf '{"artifacts":[%s]}\n' "$(artifact_json "$FAKE_ARTIFACT" "$name" false "$run")"
        else printf '{"artifacts":[]}\n'; fi ;;
      *) printf '{"artifacts":[%s]}\n' "$(artifact_json "$FAKE_ARTIFACT" "$name" false "$run")" ;;
    esac
    exit 0 ;;
  *"actions/artifacts/$FAKE_ARTIFACT/zip"*)
    [ "$mode" != download-error ] || exit 1
    cat "$FAKE_ZIP"
    exit 0 ;;
esac
exit 1
FAKE_GH
chmod +x "$TMP/bin/gh"

# A PATH with only what the script needs, and one without gh or unzip.
mkdir -p "$TMP/tools" "$TMP/no-unzip"
for tool in bash git jq unzip sed cat; do
  ln -s "$(command -v "$tool")" "$TMP/tools/$tool"
done
for tool in bash git jq sed cat; do
  ln -s "$(command -v "$tool")" "$TMP/no-unzip/$tool"
done
BIN="$TMP/bin:$TMP/tools"

CALLS="$TMP/calls"
OUT="$TMP/out"
# Run a proof script with an explicit environment: the accepted merge-group
# row's, EVENT and its endpoints per KIND, then each NAME=VALUE override,
# the later winning. Prints the exit status; the lines are in $OUT.
run() { # SCRIPT KIND(push|merge_group) MODE ZIP [NAME=VALUE]...
  local script="$1" kind="$2" mode="$3" zip="$4" status=0 event_path base head
  shift 4
  : >"$CALLS"
  : >"$OUT"
  event_path="$TMP/event-$kind.json"
  case "$kind" in
    push) base="$B" head="$M" ;;
    merge_group) base="$B" head="$M" ;;
  esac
  mkdir -p "$TMP/work"
  rm -rf -- "${TMP:?}/work"/*
  (env -i PATH="$BIN" HOME="$TMP" \
    FAKE_GH_CALLS="$CALLS" FAKE_GH_MODE="$mode" FAKE_ZIP="$TMP/$zip.zip" \
    FAKE_WORKFLOW="$WORKFLOW" FAKE_WORKFLOW_ID="$WORKFLOW_ID" FAKE_REPO="$REPO_NAME" \
    FAKE_M="$M" FAKE_P="$P" FAKE_B="$B" FAKE_TREE="$TREE" FAKE_OTHER_TREE="$OTHER_TREE" \
    FAKE_RUN_MG="$RUN_MG" FAKE_RUN_PR="$RUN_PR" FAKE_RUN_PR_OLDER="$RUN_PR_OLDER" FAKE_ARTIFACT="$ARTIFACT" \
    EVENT="$kind" BASE="$base" HEAD="$head" REPO="$REPO" \
    GITHUB_SHA="$M" GITHUB_REPOSITORY="$REPO_NAME" GITHUB_REF=refs/heads/main \
    GITHUB_ACTOR='github-merge-queue[bot]' GITHUB_TRIGGERING_ACTOR='github-merge-queue[bot]' \
    GITHUB_WORKFLOW_REF="$REPO_NAME/$WORKFLOW@refs/heads/main" GITHUB_EVENT_PATH="$event_path" \
    GH_TOKEN=ghs_token \
    "$@" bash "$script" "$TMP/work" >"$OUT" 2>"$TMP/err") || status=$?
  printf '%s' "$status"
}
line() { sed -n "s/^$1=//p" "$OUT"; }
calls() { # the number of gh calls, or `unreadable`
  local n status=0
  n="$(grep -c . "$CALLS")" || status=$?
  [ "$status" -le 1 ] && printf '%s' "$n" || printf 'unreadable'
}
# `reuse reason run calls` for one row, or `exit=N` where the script failed.
answer() { # SCRIPT KIND MODE ZIP [NAME=VALUE]...
  local status
  status="$(run "$@")"
  if [ "$status" != 0 ]; then printf 'exit=%s %s' "$status" "$(head -1 "$TMP/err")"; return 0; fi
  printf '%s %s %s %s' "$(line reuse)" "$(line reason)" "$(line run)" "$(calls)"
}

# --- 1. The table ---------------------------------------------------------------
# LABEL|KIND|MODE|ZIP|OVERRIDES|EXPECTED (reuse reason run calls)
# Every row is an accepted row with ONE thing changed. The call column is the
# no-call rows' load-bearing assertion: they run under api-error, so a script
# that consulted the API before checking its own event would refuse for a
# plausible reason with a non-empty log.
rows() {
  cat <<ROWS
queue push with an exact merge-group proof|push|valid|valid||true exact-proof $RUN_MG 4
merge group of one entry with its pull request's proof|merge_group|valid|valid||true exact-proof $RUN_PR 4
ineligible: a pull request|merge_group|api-error|valid|EVENT=pull_request|false ineligible-event  0
ineligible: a schedule|merge_group|api-error|valid|EVENT=schedule|false ineligible-event  0
ineligible push: not the default branch|push|api-error|valid|GITHUB_REF=refs/heads/feature|false ineligible-push  0
ineligible push: a human actor|push|api-error|valid|GITHUB_ACTOR=bmethod|false ineligible-push  0
ineligible push: a human triggering actor|push|api-error|valid|GITHUB_TRIGGERING_ACTOR=bmethod|false ineligible-push  0
ineligible push: forced|push|api-error|valid|GITHUB_EVENT_PATH=$TMP/event-push-forced.json|false ineligible-push  0
ineligible push: after is not the judged sha|push|api-error|valid|GITHUB_EVENT_PATH=$TMP/event-push-other-after.json|false ineligible-push  0
ineligible merge group: head is not the tested sha|merge_group|api-error|valid|HEAD=$P|false ineligible-merge-group  0
ineligible merge group: base is not the first parent|merge_group|api-error|valid|BASE=$P|false ineligible-merge-group  0
ineligible merge group: the tested sha has one parent|merge_group|api-error|valid|GITHUB_SHA=$P HEAD=$P|false ineligible-merge-group  0
ineligible merge group: the tested sha has three parents|merge_group|api-error|valid|GITHUB_SHA=$O HEAD=$O|false ineligible-merge-group  0
no GITHUB_SHA|merge_group|api-error|valid|GITHUB_SHA=|false no-github-sha  0
tree unreadable: a sha the checkout lacks|merge_group|api-error|valid|GITHUB_SHA=0123456789abcdef0123456789abcdef01234567|false tree-unreadable  0
event unreadable: no payload file|push|api-error|valid|GITHUB_EVENT_PATH=$TMP/nowhere.json|false event-unreadable  0
event unreadable: no default branch|push|api-error|valid|GITHUB_EVENT_PATH=$TMP/event-push-no-default.json|false event-unreadable  0
invalid input: malformed repository|merge_group|api-error|valid|GITHUB_REPOSITORY=not-a-repo GITHUB_WORKFLOW_REF=not-a-repo/.github/workflows/ci.yml@refs/heads/main|false invalid-input  0
invalid input: a workflow ref outside .github/workflows|merge_group|api-error|valid|GITHUB_WORKFLOW_REF=$REPO_NAME/tools/ci.yml@refs/heads/main|false invalid-input  0
no gh on PATH|merge_group|api-error|valid|PATH=$TMP/tools|false gh-unavailable  0
no unzip on PATH|merge_group|api-error|valid|PATH=$TMP/bin:$TMP/no-unzip|false unzip-unavailable  0
no token|merge_group|api-error|valid|GH_TOKEN=|false no-token  0
workflow read fails|merge_group|api-error|valid|GH_TOKEN=ghs_token|false workflow-api-error  1
workflow id is not a number|merge_group|malformed-workflow|valid||false malformed-workflow  1
workflow answers for another path|merge_group|wrong-workflow-path|valid||false malformed-workflow  1
workflow is disabled|merge_group|inactive-workflow|valid||false malformed-workflow  1
runs read fails|merge_group|runs-api-error|valid||false runs-api-error  2
runs payload is not a list|merge_group|malformed-runs|valid||false malformed-runs  2
runs payload is truncated below its own total|merge_group|truncated|valid||false malformed-runs  2
no run for the sha|merge_group|missing|valid||false missing-proof  2
two merge-group runs for the pushed sha|push|ambiguous|valid||false ambiguous-proof  2
proof run has the wrong event|merge_group|wrong-event|valid||false mismatched-proof  2
proof run has not completed|merge_group|wrong-status|valid||false mismatched-proof  2
proof run did not succeed|merge_group|wrong-conclusion|valid||false mismatched-proof  2
proof run is for another sha|merge_group|wrong-sha|valid||false mismatched-proof  2
proof run is not from a queue branch|push|wrong-branch|valid||false mismatched-proof  2
proof run is for another workflow file|merge_group|wrong-run-path|valid||false mismatched-proof  2
proof run belongs to another workflow id|merge_group|wrong-workflow-id|valid||false mismatched-proof  2
proof run belongs to another repository|merge_group|wrong-repo|valid||false mismatched-proof  2
proof run came from a fork head|merge_group|wrong-head-repo|valid||false mismatched-proof  2
proof run is missing every field but its id|merge_group|malformed-run|valid||false mismatched-proof  2
artifacts read fails|merge_group|artifacts-api-error|valid||false artifacts-api-error  3
artifacts payload is not a list|merge_group|malformed-artifacts|valid||false malformed-artifacts  3
no artifact on the run|merge_group|no-artifact|valid||false missing-record  3
the artifact names another tree|merge_group|other-name|valid||false missing-record  3
the artifact belongs to another run|merge_group|other-run|valid||false missing-record  3
the artifact has expired|merge_group|expired|valid||false expired-record  3
record download fails|merge_group|download-error|valid||false record-download-error  4
the artifact is not a zip|merge_group|valid|garbage||false record-unreadable  4
the artifact holds no record|merge_group|valid|no-member||false record-unreadable  4
the record names another tree|merge_group|valid|wrong-tree||false record-mismatch  4
the record names another workflow|merge_group|valid|wrong-workflow||false record-mismatch  4
ROWS
}
row_answer() { # SCRIPT ROW-LABEL — the answer for the row named LABEL
  local line label kind mode zip overrides expected
  line="$(rows | grep -m1 -F -- "$2|")" || { echo "no row named $2" >&2; exit 1; }
  IFS='|' read -r label kind mode zip overrides expected <<<"$line"
  # shellcheck disable=SC2086 # the overrides are blank-separated words
  answer "$1" "$kind" "$mode" "$zip" $overrides
}
table_rows=0
while IFS='|' read -r label kind mode zip overrides expected; do
  table_rows=$((table_rows + 1))
  # shellcheck disable=SC2086 # the overrides are blank-separated words
  check "$label" "$expected" "$(answer "$PROOF" "$kind" "$mode" "$zip" $overrides)"
done < <(rows)
[ "$table_rows" -eq 52 ] || { echo "the table read $table_rows rows" >&2; exit 1; }

# A branch pattern is the default branch's: a queue branch of another branch
# is refused on a push to main.
run "$PROOF" merge_group api-error valid EVENT=schedule >/dev/null
refused_tree="$(line tree)"
run "$PROOF" merge_group valid valid >/dev/null
check "the tree line is printed on a refusal and on a proof alike" "$TREE $TREE" "$refused_tree $(line tree)"
check "a refusal prints what it saw" "event=schedule" \
  "$(run "$PROOF" merge_group api-error valid EVENT=schedule >/dev/null; line detail)"

# --- 2. The record ------------------------------------------------------------
run "$PROOF" merge_group valid valid >/dev/null
check "the accepted row's record is the file the artifact holds" "$RECORD" "$(cat "$(line record)")"
check "the record path is inside the work directory given" "$TMP/work/record" "$(line record)"
check "the calls are the workflow, its runs, the run's artifacts and the zip, in that order" \
  "actions/workflows/ci.yml
actions/workflows/$WORKFLOW_ID/runs
actions/runs/$RUN_PR/artifacts
actions/artifacts/$ARTIFACT/zip" \
  "$(sed 's/^api //; s/^--method GET //; s/^repos\/[^/]*\/[^/]*\///; s/ -f .*//' "$CALLS")"
check "a failed run ahead of the passing one is passed over" "true exact-proof $RUN_PR 4" \
  "$(answer "$PROOF" merge_group failed-then-valid valid)"
check "a passing run without the artifact falls through to the one that has it" \
  "true exact-proof $RUN_PR_OLDER 5" "$(answer "$PROOF" merge_group newest-without-artifact valid)"

# --- 3. The must-fail inverses ------------------------------------------------
# NEEDLE@REPLACEMENT@ROW LABEL: one copy per rule, the rule planted away and
# every other line kept; the copy must run to completion and answer the row
# other than the table says. Split on `@` because a rule spells `|`.
mutant="$TMP/mutant/proof"
mkdir -p "$TMP/mutant"
mutants=0
while IFS='@' read -r needle replacement row; do
  mutants=$((mutants + 1))
  [ "$(grep -cF -- "$needle" "$PROOF")" -eq 1 ] ||
    { echo "the rule '$needle' is no longer one line in $PROOF" >&2; exit 1; }
  NEEDLE="$needle" REPLACEMENT="$replacement" awk '
    { i = index($0, ENVIRON["NEEDLE"]) }
    i > 0 { $0 = substr($0, 1, i - 1) ENVIRON["REPLACEMENT"] substr($0, i + length(ENVIRON["NEEDLE"])) }
    { print }
  ' "$PROOF" >"$mutant"
  ! cmp -s "$PROOF" "$mutant" || { echo "the mutant for '$needle' changed nothing" >&2; exit 1; }
  expected="$(rows | grep -m1 -F -- "$row|" | awk -F '|' '{ print $6 }')"
  got="$(row_answer "$mutant" "$row")"
  case "$got" in
    exit=*) bad "must-fail: '$needle' planted as '$replacement' crashed the $row row: $got" ;;
    "$expected") bad "must-fail: '$needle' planted as '$replacement' still answers the $row row" ;;
    *) ok "must-fail: '$needle' planted as '$replacement' fails the $row row" ;;
  esac
done <<'ROWS'
  push | merge_group) ;;@  push | merge_group | pull_request) ;;@ineligible: a pull request
  [ "${GITHUB_REF:-}" = "refs/heads/$default_branch" ] &&@  true &&@ineligible push: not the default branch
    [ "${GITHUB_ACTOR:-}" = "$QUEUE_ACTOR" ] &&@    true &&@ineligible push: a human actor
    [ "${GITHUB_TRIGGERING_ACTOR:-}" = "$QUEUE_ACTOR" ] &&@    true &&@ineligible push: a human triggering actor
    [ "$forced" = false ] && [ "$after" = "$GITHUB_SHA" ] ||@    [ "$after" = "$GITHUB_SHA" ] ||@ineligible push: forced
    [ "$forced" = false ] && [ "$after" = "$GITHUB_SHA" ] ||@    [ "$forced" = false ] ||@ineligible push: after is not the judged sha
  [ "${HEAD:-}" = "$GITHUB_SHA" ] && [ "$#" -eq 3 ] && [ "$2" = "${BASE:-}" ] ||@  [ "$#" -eq 3 ] && [ "$2" = "${BASE:-}" ] ||@ineligible merge group: head is not the tested sha
  [ "${HEAD:-}" = "$GITHUB_SHA" ] && [ "$#" -eq 3 ] && [ "$2" = "${BASE:-}" ] ||@  [ "${HEAD:-}" = "$GITHUB_SHA" ] && [ "$#" -eq 3 ] ||@ineligible merge group: base is not the first parent
  [ "${HEAD:-}" = "$GITHUB_SHA" ] && [ "$#" -eq 3 ] && [ "$2" = "${BASE:-}" ] ||@  [ "${HEAD:-}" = "$GITHUB_SHA" ] && [ "$#" -ge 3 ] && [ "$2" = "${BASE:-}" ] ||@ineligible merge group: the tested sha has three parents
[[ "$repo" =~ $repo_re ]] &&@true &&@invalid input: malformed repository
  [[ "$workflow_path" =~ $path_re ]] ||@  true ||@invalid input: a workflow ref outside .github/workflows
[ -n "${GH_TOKEN:-}" ] || answer no-token "GH_TOKEN is empty"@:@no token
  ((.id | type) == "number") and (.id > 0) and (.path == $path) and (.state == "active")@  (.path == $path) and (.state == "active")@workflow id is not a number
  ((.id | type) == "number") and (.id > 0) and (.path == $path) and (.state == "active")@  ((.id | type) == "number") and (.id > 0) and (.state == "active")@workflow answers for another path
  ((.id | type) == "number") and (.id > 0) and (.path == $path) and (.state == "active")@  ((.id | type) == "number") and (.id > 0) and (.path == $path)@workflow is disabled
  ((.workflow_runs | type) == "array") and (.total_count == (.workflow_runs | length))@  ((.workflow_runs | type) == "array")@runs payload is truncated below its own total
[ "$EVENT" = merge_group ] || [ "$run_count" -eq 1 ] ||@true ||@two merge-group runs for the pushed sha
      (.workflow_id == $workflow_id) and (.event == $event) and@      (.workflow_id == $workflow_id) and@proof run has the wrong event
      (.status == "completed") and (.conclusion == "success") and@      (.conclusion == "success") and@proof run has not completed
      (.status == "completed") and (.conclusion == "success") and@      (.status == "completed") and@proof run did not succeed
      (.head_sha == $sha) and (.path == $path) and@      (.path == $path) and@proof run is for another sha
      (.head_sha == $sha) and (.path == $path) and@      (.head_sha == $sha) and@proof run is for another workflow file
      (.workflow_id == $workflow_id) and (.event == $event) and@      (.event == $event) and@proof run belongs to another workflow id
      ($event != "merge_group" or (.head_branch | test($branch_re))) and@      true and@proof run is not from a queue branch
      (.repository.full_name == $repo) and (.head_repository.full_name == $repo))@      (.head_repository.full_name == $repo))@proof run belongs to another repository
      (.repository.full_name == $repo) and (.head_repository.full_name == $repo))@      (.repository.full_name == $repo))@proof run came from a fork head
    [.artifacts[] | select(.name == $name and .workflow_run.id == $run)]@    [.artifacts[] | select(.name == $name)]@the artifact belongs to another run
    | map(select(.expired == false)) | .[0].id // empty' <<<"$artifacts_json" 2>/dev/null)"; then@    | .[0].id // empty' <<<"$artifacts_json" 2>/dev/null)"; then@the artifact has expired
    [ "$recorded_tree" = "$tree" ] && [ "$recorded_workflow" = "$workflow_path" ] ||@    [ "$recorded_workflow" = "$workflow_path" ] ||@the record names another tree
    [ "$recorded_tree" = "$tree" ] && [ "$recorded_workflow" = "$workflow_path" ] ||@    [ "$recorded_tree" = "$tree" ] ||@the record names another workflow
ROWS
[ "$mutants" -eq 30 ] || { echo "the mutant table read $mutants rows" >&2; exit 1; }

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
